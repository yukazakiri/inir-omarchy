#!/usr/bin/env bash
# shell-switch: swap the desktop shell inside a live session. No logout.
#
# Only the shell process changes. The compositor session, every window,
# workspace, clipboard and running app stay exactly as they are.
#
#   shell-switch status       -> "omarchy" | "inir" | "none"
#   shell-switch to-inir      -> stop the Omarchy shell, start iNiR
#   shell-switch to-omarchy   -> stop iNiR, start the Omarchy shell
#   shell-switch toggle       -> switch to whichever one is not running
#
# Both shells are single Quickshell instances that own the same tray bus name
# (org.kde.StatusNotifierWatcher), so exactly one may run at a time: the other
# is stopped and its bus name released before the new one starts, otherwise the
# Type=dbus inir.service start job would fail on a taken name.
set -u

INIR_UNIT="inir.service"
TRAY_BUS_NAME="org.kde.StatusNotifierWatcher"

log()  { printf 'shell-switch: %s\n' "$1" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# Serialise invocations. A plugin button (or a double press) can fire two
# switches at once; without this they interleave — one stops the Omarchy shell
# while the other is already starting iNiR — and the session can end up with
# no shell at all. Held for the whole run, so a second caller waits its turn
# and then finds the work already done.
LOCK_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/inir-shell-switch.lock"
LOCK_FD=""

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0   # degrade gracefully
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || return 0
    # A redirection that fails on `exec` is fatal in a non-interactive shell:
    # the `|| return 0` never runs and the script exits silently with status 1.
    # So prove the file is writable with an ordinary redirection first, and
    # skip locking entirely when it is not.
    : >>"$LOCK_FILE" 2>/dev/null || return 0
    exec {LOCK_FD}>>"$LOCK_FILE" || return 0
    # 120s ceiling: a wedged switch must not block the desktop forever.
    if ! flock -w 120 "$LOCK_FD"; then
        log "another shell switch is still running; giving up"
        return 1
    fi
    return 0
}

# The shell may be invoked from a bare environment — an omarchy bar widget, a
# desktop entry, cron, or a terminal started before the session. Without
# HYPRLAND_INSTANCE_SIGNATURE hyprctl cannot reach the compositor, and without
# the bus variables systemctl --user cannot reach the manager, so the handoff
# fails with a bare "is hyprland running?". The user manager already knows the
# session environment, so borrow whatever is missing from it.
ensure_session_env() {
    have systemctl || return 0

    if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" && -n "${XDG_RUNTIME_DIR:-}" ]]; then
        local hypr_dir
        hypr_dir="$(find "${XDG_RUNTIME_DIR}/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null |
            sort -n | tail -n 1 | cut -d' ' -f2-)"
        [[ -n "$hypr_dir" ]] && export HYPRLAND_INSTANCE_SIGNATURE="${hypr_dir##*/}"
    fi

    local dump key value
    dump="$(systemctl --user show-environment 2>/dev/null)" || return 0
    [[ -n "$dump" ]] || return 0
    for key in DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE \
               WAYLAND_DISPLAY NIRI_SOCKET OMARCHY_PATH; do
        [[ -n "${!key:-}" ]] && continue
        value="$(printf '%s\n' "$dump" | sed -n "s/^${key}=//p" | tail -n 1)"
        [[ -n "$value" ]] && export "${key}=${value}"
    done
    return 0
}

ensure_session_env

# OMARCHY_PATH lives in the user manager environment, so a shell-switch run from
# any terminal (or a plugin, or the other shell) still sees the session's value.
omarchy_path() {
    local p
    p="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)"
    [ -n "${p:-}" ] || p="${OMARCHY_PATH:-/usr/share/omarchy}"
    printf '%s' "$p"
}

omarchy_shell_dir() { printf '%s/shell' "$(omarchy_path)"; }
inir_runtime_dir()   { printf '%s/quickshell/inir' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

omarchy_running() {
    local dir
    dir="$(omarchy_shell_dir)"
    pgrep -f "quickshell .*-p ${dir}([[:space:]]|\$)" >/dev/null 2>&1
}

inir_running() {
    systemctl --user is-active --quiet "$INIR_UNIT" && return 0
    # A shell started outside systemd (inir run) still counts as running.
    local dir
    dir="$(inir_runtime_dir)"
    pgrep -f "qs .*-p ${dir}([[:space:]]|\$)" >/dev/null 2>&1 ||
        pgrep -f "quickshell .*-p ${dir}([[:space:]]|\$)" >/dev/null 2>&1
}

current_shell() {
    if inir_running;    then printf 'inir';    return 0; fi
    if omarchy_running; then printf 'omarchy'; return 0; fi
    printf 'none'
}

# PID owning the tray bus name, empty when the name is free.
tray_owner() {
    systemctl --user status "$TRAY_BUS_NAME" 2>/dev/null |
        sed -n 's/.*PID=\([0-9]\+\).*/\1/p' | head -n 1
}

# inir.service is Type=dbus on that name: starting it while the previous owner
# is still alive fails, so wait for the name to actually go away.
wait_tray_free() {
    local deadline=$((SECONDS + ${1:-8})) owner
    while [ "$SECONDS" -lt "$deadline" ]; do
        owner="$(tray_owner)"
        [ -z "$owner" ] && return 0
        kill -0 "$owner" 2>/dev/null || return 0
        sleep 0.2
    done
    return 1
}

session_locked() {
    have omarchy-hyprland-session-locked &&
        omarchy-hyprland-session-locked >/dev/null 2>&1 && return 0
    local locker
    for locker in hyprlock swaylock iNiR-lock; do
        pgrep -x "$locker" >/dev/null 2>&1 && return 0
    done
    return 1
}

# omarchy-launch-shell relaunches quickshell unless the shell exits cleanly,
# and it exits cleanly when the supervisor itself is terminated. Signalling the
# supervisor is therefore the deliberate stop; killing quickshell directly can
# look like a crash and trigger a relaunch.
stop_omarchy_shell() {
    local dir deadline
    dir="$(omarchy_shell_dir)"

    pkill -TERM -f 'omarchy-launch-shell' 2>/dev/null || true

    deadline=$((SECONDS + 6))
    while [ "$SECONDS" -lt "$deadline" ]; do
        omarchy_running || break
        sleep 0.2
    done

    if omarchy_running; then
        # Fall back to the same kill path omarchy-restart-shell uses.
        while timeout 5 quickshell kill -p "$dir" --any-display >/dev/null 2>&1; do :; done
    fi

    ! omarchy_running
}

stop_inir_shell() {
    systemctl --user stop "$INIR_UNIT" >/dev/null 2>&1 || true
    local deadline=$((SECONDS + 8))
    while [ "$SECONDS" -lt "$deadline" ]; do
        inir_running || break
        sleep 0.2
    done
    ! inir_running
}

start_inir_shell() {
    wait_tray_free 8 || log "warning: $TRAY_BUS_NAME still owned; inir may fail to start"

    systemctl --user reset-failed "$INIR_UNIT" >/dev/null 2>&1 || true

    if ! systemctl --user start "$INIR_UNIT"; then
        log "inir.service did not start:"
        systemctl --user status "$INIR_UNIT" --no-pager 2>&1 | sed -n '1,6p' >&2
        return 1
    fi

    # The unit is Type=dbus, so a returning start job already means the tray
    # name was acquired; give the QML tree a moment to boot before reporting.
    sleep 0.5
    systemctl --user is-active --quiet "$INIR_UNIT"
}

# iNiR answers IPC on the launcher; a successful call means the QML tree is up.
Quickshell_IPC_ping() {
    have inir && inir dev current >/dev/null 2>&1
}

# iNiR's theming pipeline (scripts/colors/applycolor.sh) writes the shared
# GTK3/GTK4/Qt5/Qt6 settings and the gsettings color + icon theme when it
# applies its palette, and those files are global rather than per-shell. So
# after iNiR has run, Omarchy's apps render with iNiR's palette — dark windows,
# black icons — until Omarchy's theme is put back. This has to happen after
# iNiR is stopped, or iNiR can re-claim those files on its way out.
apply_omarchy_theme() {
    have omarchy-theme-refresh || return 0
    log "re-applying the Omarchy theme…"
    # Bounded: re-theming walks every target (terminals, browsers, Qt), which
    # can be slow. It must never be able to hang the swap — iNiR is already
    # stopped by this point, so nothing can re-claim those files behind us.
    timeout 120 omarchy-theme-refresh >/dev/null 2>&1 ||
        log "warning: omarchy theme refresh did not finish; re-run 'omarchy theme refresh'"
}

# omarchy-restart-shell can only bring the shell up through Hyprland: it spawns
# it with `hyprctl dispatch hl.dsp.exec_cmd("omarchy-launch-shell")` so the shell
# inherits the canonical session environment. With no live Hyprland that dispatch
# fails ("is hyprland running?"), the shell is never spawned, and the command
# gives up after its ping loop. So on a non-Hyprland compositor this swap can
# never succeed, and attempting it is destructive: iNiR is stopped first, the
# Omarchy shell never arrives, and only the fallback restarts iNiR again — the
# desktop just bounces. Probe for a reachable Hyprland before anything is torn
# down, so the refusal happens while the session is still whole.
omarchy_shell_startable() {
    have omarchy || return 1
    have hyprctl || return 1
    hyprctl version >/dev/null 2>&1 || return 1
    return 0
}

start_omarchy_shell() {
    have omarchy || { log "omarchy command not found"; return 1; }
    omarchy_shell_startable || { log "no running Hyprland to host the Omarchy shell"; return 1; }
    wait_tray_free 8 || log "warning: $TRAY_BUS_NAME still owned; the Omarchy shell may fail to start"
    # omarchy restart shell kills anything left on that config path, respawns it
    # from Hyprland (so it inherits the canonical session environment) and
    # waits for its IPC ping. It also refuses to run while the session is locked.
    omarchy restart shell
}

to_inir() {
    if inir_running; then
        log "iNiR is already the active shell"
        return 0
    fi
    if session_locked; then
        log "session is locked — unlock before switching shells"
        return 1
    fi

    if omarchy_running; then
        log "stopping the Omarchy shell…"
        stop_omarchy_shell || log "warning: an Omarchy shell process is still present"
    fi

    log "starting iNiR…"
    if start_inir_shell; then
        log "iNiR is now the active shell"
        return 0
    fi

    # Never leave the session without a desktop. iNiR did not come up, so put
    # the shell we just took away back.
    log "iNiR failed to start — restoring the Omarchy shell"
    if start_omarchy_shell; then
        log "the Omarchy shell is back; iNiR did not start"
    else
        log "ERROR: neither shell is running. Run: omarchy restart shell"
    fi
    return 1
}

to_omarchy() {
    if omarchy_running; then
        log "Omarchy is already the active shell"
        return 0
    fi
    # Refuse while iNiR is still running: stopping it here would only produce a
    # stop, a failed Omarchy start, and a fallback restart — the restart loop.
    if ! omarchy_shell_startable; then
        log "this session is not Hyprland, so the Omarchy shell cannot start here"
        log "iNiR was left running; nothing was switched"
        return 1
    fi
    if session_locked; then
        log "session is locked — unlock before switching shells"
        return 1
    fi

    if inir_running; then
        log "stopping iNiR…"
        stop_inir_shell || log "warning: an iNiR shell process is still present"
    fi

    log "starting the Omarchy shell…"
    if start_omarchy_shell; then
        log "Omarchy is now the active shell"
        # Re-apply Omarchy's theme after iNiR is gone, so apps stop rendering
        # with iNiR's palette. Done once the bar is back: the shell does not
        # depend on it, and re-theming every target can take a while.
        apply_omarchy_theme
        return 0
    fi

    # Same safety net in the other direction.
    log "the Omarchy shell failed to start — falling back to iNiR"
    if start_inir_shell; then
        log "iNiR is running instead; the Omarchy shell did not start"
    else
        log "ERROR: neither shell is running. Run: omarchy restart shell"
    fi
    return 1
}

usage() {
    cat <<EOF
Usage: shell-switch [status|toggle|to-inir|to-omarchy]

  status      print the active shell: omarchy | inir | none
  toggle      switch to whichever shell is not running
  to-inir     replace the Omarchy shell with iNiR, in this session
  to-omarchy  replace iNiR with the Omarchy shell, in this session
EOF
}

case "${1:-status}" in
    status)     current_shell ;;
    current)    current_shell ;;
    toggle)     acquire_lock || exit 1
                if [ "$(current_shell)" = "inir" ]; then to_omarchy; else to_inir; fi ;;
    to-inir|inir)    acquire_lock || exit 1
                to_inir ;;
    to-omarchy|omarchy) acquire_lock || exit 1
                to_omarchy ;;
    -h|--help|help)   usage ;;
    *) log "Unknown command: $1"; usage >&2; exit 2 ;;
esac