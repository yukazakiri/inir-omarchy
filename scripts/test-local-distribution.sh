#!/usr/bin/env bash
# Smoke checks for the Omarchy flavor on the iNiR 3.x base.
#
# No root, no live compositor and no systemd user manager are required: a fake
# `systemctl` in a temp PATH stands in for the session. Run from anywhere:
#
#   scripts/test-local-distribution.sh
#
# This replaces the old v2 distribution harness, which tested migrations and
# modules that the 3.0 base no longer ships.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check(){ local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

printf 'iNiR Omarchy smoke checks\n'

# ── Syntax ───────────────────────────────────────────────────────────────────
for f in setup scripts/inir scripts/lib/compositor.sh scripts/shell-switch.sh \
         scripts/shell-dispatch scripts/compositor-switch.sh \
         scripts/sddm-set-autologin-session scripts/colors/apply-gtk-theme.sh \
         scripts/colors/switchwall.sh scripts/colors/modules/30-editors.sh; do
    if bash -n "$ROOT/$f"; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

# ── systemd unit names every lifecycle owner ─────────────────────────────────
unit="$ROOT/assets/systemd/inir.service"
check "unit PartOf includes niri, umbriel and uwsm Niri" \
    grep -qx 'PartOf=niri.service umbriel.service wayland-wm@niri.desktop.service' "$unit"
check "unit After includes niri, umbriel and uwsm Niri" \
    grep -qx 'After=niri.service umbriel.service wayland-wm@niri.desktop.service' "$unit"
check "unit gate accepts Hyprland for live shell swaps" \
    grep -q 'HYPRLAND_INSTANCE_SIGNATURE' "$unit"
check "unit has exactly one ExecCondition" \
    test "$(grep -c '^ExecCondition=' "$unit")" = 1
check "ExecCondition lives in the [Service] section" \
    bash -c 'awk "\$0==\"[Service]\"{s=1} s && /^ExecCondition=/{found=1} END{exit !found}" "$1"' _ "$unit"

# ── compositor_units adds the Omarchy uwsm unit ──────────────────────────────
mkdir -p "$TMP/bin" "$TMP/sessions" "$TMP/config/inir" "$TMP/run"
touch "$TMP/sessions/omarchy-niri.desktop"
printf 'niri\n' > "$TMP/config/inir/compositor"
cat > "$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
# Test double: compositor units exist, but no unit is active.
if [[ "${1:-}" == "--user" ]]; then
    case "${2:-}" in
        is-active) exit 1 ;;
        show-environment) exit 0 ;;
        cat) exit 0 ;;
    esac
fi
exit 0
SH
cat > "$TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/systemctl" "$TMP/bin/pgrep"

units="$(HOME="$TMP" XDG_CONFIG_HOME="$TMP/config" XDG_RUNTIME_DIR="$TMP/run" \
    INIR_WAYLAND_SESSIONS_DIRS="$TMP/sessions" PATH="$TMP/bin:$PATH" \
    bash -c 'source "$1/scripts/lib/compositor.sh"; compositor_units' _ "$ROOT")"
check "compositor_units emits niri.service" grep -qx 'niri.service' <<< "$units"
check "compositor_units emits wayland-wm@niri.desktop.service" \
    grep -qx 'wayland-wm@niri.desktop.service' <<< "$units"
check "niri-only choice omits umbriel.service" bash -c '! grep -qx umbriel.service <<< "$1"' _ "$units"

printf 'inir\n' > "$TMP/config/inir/compositor"
units="$(HOME="$TMP" XDG_CONFIG_HOME="$TMP/config" XDG_RUNTIME_DIR="$TMP/run" \
    INIR_WAYLAND_SESSIONS_DIRS="" PATH="$TMP/bin:$PATH" \
    bash -c 'source "$1/scripts/lib/compositor.sh"; compositor_units' _ "$ROOT")"
check "no Omarchy session: uwsm unit is not wired" \
    bash -c '! grep -qx "wayland-wm@niri.desktop.service" <<< "$1"' _ "$units"

# ── Live shell switch refuses to leave the session bare ─────────────────────
status="$(HOME="$TMP" XDG_CONFIG_HOME="$TMP/config" XDG_RUNTIME_DIR="$TMP/run" \
    OMARCHY_PATH="$TMP/omarchy" PATH="$TMP/bin:$PATH" \
    bash "$ROOT/scripts/shell-switch.sh" status 2>/dev/null)"
check "shell-switch status reports none without a shell" test "$status" = none

switch_help="$(bash "$ROOT/scripts/shell-switch.sh" --help 2>&1)"
check "shell-switch documents to-omarchy" grep -q 'to-omarchy' <<< "$switch_help"
check "shell-switch documents to-inir" grep -q 'to-inir' <<< "$switch_help"

# ── Launcher/session-screen wiring ──────────────────────────────────────────
check "GlobalActions exposes switch-to-omarchy" \
    grep -q 'id: "switch-to-omarchy"' "$ROOT/services/GlobalActions.qml"
check "GlobalActions exposes switch-session-to-niri" \
    grep -q 'id: "switch-session-to-niri"' "$ROOT/services/GlobalActions.qml"
check "session screen has the Omarchy button" \
    grep -q 'Session.switchShell("omarchy")' "$ROOT/modules/shared/sessionScreen/SessionScreen.qml"
check "Session exposes both switch modes" \
    bash -c 'grep -q "function switchShell" "$1/modules/common/functions/Session.qml" && grep -q "function switchCompositor" "$1/modules/common/functions/Session.qml"' _ "$ROOT"

# ── Shared-HOME theming guards ──────────────────────────────────────────────
check "GTK pipeline honours enableAppsAndShell=false for icons" \
    grep -q 'if \[\[ "$enable_apps_shell" == "false" \]\]; then' "$ROOT/scripts/colors/apply-gtk-theme.sh"
check "IconThemeService skips system-wide apply when desktop theming is off" \
    grep -q '_systemApplyAllowed' "$ROOT/services/IconThemeService.qml"

echo
if [[ "$FAIL" -gt 0 ]]; then
    printf '%d check(s) failed\n' "$FAIL" >&2
    exit 1
fi
printf 'All checks passed\n'
