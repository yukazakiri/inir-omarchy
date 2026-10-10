#!/usr/bin/env bash
# Migration 045: keep inir.service alive under the Omarchy-Niri uwsm session.

MIGRATION_ID="045-omarchy-uwsm-session"
MIGRATION_TITLE="Wire inir.service to the Omarchy-Niri uwsm session"
MIGRATION_DESCRIPTION="The stock wayland-sessions/omarchy-niri.desktop session starts niri through uwsm, so the compositor runs inside the generated wayland-wm@niri.desktop.service and niri.service never becomes active. The stock inir.service still requires niri.service, so iNiR silently never starts in that session. Adds a drop-in that drops the Requisite=niri.service gate, ties the unit lifecycle to the uwsm session, and wires the wants link the compositor service owns."
MIGRATION_TARGET_FILE="~/.config/systemd/user/inir.service.d/omarchy-uwsm.conf + ~/.config/systemd/user/wayland-wm@niri.desktop.service.wants/inir.service"
MIGRATION_REQUIRED=true

MIGRATION_SESSION_IMPACT=true
MIGRATION_SESSION_REFERENCE="inir.service lifecycle owner under the Omarchy-Niri uwsm session"
MIGRATION_SESSION_REASON="omarchy-niri.desktop runs niri through uwsm, so niri.service is not the unit that owns the session there."
MIGRATION_SESSION_EFFECT="A shell already running in this login keeps the old lifecycle wiring until the next session."
MIGRATION_SESSION_ACTION="Log out and back in through the Niri (uwsm) session, or switch to Omarchy and return, so the new drop-in and wants link take effect."

# Source the predicate helper when migrations run outside the installer.
_migration_repo_root="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=/dev/null
source "${_migration_repo_root}/sdata/lib/functions.sh" 2>/dev/null || true

_systemd_user_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
_service_file="${_systemd_user_dir}/inir.service"
_dropin_dir="${_service_file}.d"
_dropin="${_dropin_dir}/omarchy-uwsm.conf"
_uwsm_unit="wayland-wm@niri.desktop.service"
_wants_dir="${_systemd_user_dir}/${_uwsm_unit}.wants"
_wants_link="${_wants_dir}/inir.service"

_dropin_contents() {
  cat <<EOF
# Managed by iNiR migration ${MIGRATION_ID}: Omarchy-Niri uwsm session lifecycle.
#
# omarchy-niri.desktop starts niri through uwsm, so the compositor runs inside
# ${_uwsm_unit} and niri.service never activates. The stock unit's
# Requisite=niri.service would therefore refuse every start and iNiR would
# never come up in that session. Startup is gated by the wants link instead,
# so the shell still cannot appear under Hyprland/KDE/GNOME sessions.
#
# Remove this file when you stop using the Omarchy-Niri uwsm session.
[Unit]
Requisite=
After=${_uwsm_unit}
PartOf=${_uwsm_unit}
EOF
}

_session_search_dirs() {
  # INIR_WAYLAND_SESSIONS_DIRS lets the test harness point this at a temp dir.
  if [[ -n "${INIR_WAYLAND_SESSIONS_DIRS:-}" ]]; then
    printf '%s\n' ${INIR_WAYLAND_SESSIONS_DIRS}
    return 0
  fi
  printf '%s\n' /usr/local/share/wayland-sessions /usr/share/wayland-sessions
}

_omarchy_niri_session_installed() {
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    [[ -f "${dir}/omarchy-niri.desktop" ]] && return 0
  done < <(_session_search_dirs)
  return 1
}

migration_check() {
  # No-op if usable systemd user manager is not available (ADR-0002).
  # Without the predicate, systemctl --user can block for 10-30s.
  has_usable_systemd_user_manager || return 1

  # Only machines that actually offer the Omarchy-Niri uwsm session need this.
  _omarchy_niri_session_installed || return 1

  # The unit itself is installed by the normal sync; without it there is
  # nothing to rewire.
  [[ -f "$_service_file" ]] || return 1

  [[ -f "$_dropin" ]] || return 0
  grep -qx 'Requisite=' "$_dropin" 2>/dev/null || return 0
  grep -qx "PartOf=${_uwsm_unit}" "$_dropin" 2>/dev/null || return 0

  [[ -e "$_wants_link" || -L "$_wants_link" ]] || return 0

  return 1
}

migration_preview() {
  echo -e "${STY_GREEN}+ ${_dropin}${STY_RST}"
  echo -e "  drops Requisite=niri.service (niri.service never runs under uwsm)"
  echo -e "  adds After=/PartOf=${_uwsm_unit}"
  echo ""
  echo -e "${STY_GREEN}+ ${_wants_link}${STY_RST}"
  echo ""
  echo "iNiR then starts only under the Omarchy-Niri session and stops with it,"
  echo "instead of silently never starting."
}

migration_apply() {
  # No-op if usable systemd user manager is not available (ADR-0002).
  has_usable_systemd_user_manager || return 0

  _omarchy_niri_session_installed || return 0
  [[ -f "$_service_file" ]] || return 0

  mkdir -p "$_dropin_dir" || return 1
  local tmp="${_dropin}.$$"
  _dropin_contents > "$tmp" || { rm -f "$tmp"; return 1; }
  if [[ -f "$_dropin" ]] && cmp -s "$tmp" "$_dropin"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$_dropin" || { rm -f "$tmp"; return 1; }
  fi
  chmod 644 "$_dropin" 2>/dev/null || true

  mkdir -p "$_wants_dir" || return 1
  local link_real service_real
  service_real="$(readlink -f "$_service_file" 2>/dev/null || printf '%s' "$_service_file")"
  link_real="$(readlink -f "$_wants_link" 2>/dev/null || true)"
  if [[ ! -L "$_wants_link" || "$link_real" != "$service_real" ]]; then
    ln -sf "$_service_file" "$_wants_link" || return 1
  fi

  systemctl --user daemon-reload >/dev/null 2>&1 || true
  return 0
}