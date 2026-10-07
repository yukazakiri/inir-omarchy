#!/bin/bash
# compositor-switch: switch the login compositor (Hyprland <-> Niri) on
# SDDM-autologin systems and log straight back into it.
#
# Background: with SDDM autologin + Relogin=true, logging out returns directly
# to the configured Session=. So switching = rewrite that Session= line (via
# the privileged sddm-set-autologin-session helper), then exit the compositor.
#
# Usage: compositor-switch {status|target|switch {hyprland|niri}|logout}
set -u

cmd="${1:-status}"
AUTOLOGIN_CONF="/etc/sddm.conf.d/autologin.conf"
SETTER_CANDIDATES=(
  "/usr/local/bin/local-niri-switch-set-session"
  "/usr/local/bin/sddm-set-autologin-session"
)

current_compositor() {
  local desktop="${XDG_CURRENT_DESKTOP:-} ${XDG_SESSION_DESKTOP:-} ${DESKTOP_SESSION:-}"
  case "$desktop" in
    *[Nn]iri*) echo "Niri"; return 0 ;;
    *[Hh]yprland*) echo "Hyprland"; return 0 ;;
  esac
  if pgrep -x niri >/dev/null 2>&1; then echo "Niri"; return 0; fi
  if pgrep -x Hyprland >/dev/null 2>&1; then echo "Hyprland"; return 0; fi
  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then echo "Hyprland"; return 0; fi
  if [ -n "${NIRI_SOCKET:-}" ]; then echo "Niri"; return 0; fi
  echo "Unknown"
}

boot_target() {
  local session=""
  [ -f "$AUTOLOGIN_CONF" ] && session=$(sed -n 's/^Session=//p' "$AUTOLOGIN_CONF" | head -n 1)
  case "$session" in
    omarchy-niri.desktop|niri.desktop) echo "Niri" ;;
    omarchy.desktop|hyprland.desktop|hyprland-uwsm.desktop) echo "Hyprland" ;;
    "") echo "Unknown (no Session= in $AUTOLOGIN_CONF)" ;;
    *) echo "Unknown ($session)" ;;
  esac
}

find_setter() {
  local s
  for s in "${SETTER_CANDIDATES[@]}"; do
    if [ -x "$s" ]; then echo "$s"; return 0; fi
  done
  return 1
}

elevate() {
  if [ -t 0 ] && [ -t 1 ]; then
    sudo "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    pkexec "$@"
  else
    echo "compositor-switch: need root (no terminal for sudo, no pkexec)." >&2
    return 1
  fi
}

set_session() {
  local want="${1:-}" desktop="" setter=""
  case "$want" in
    hyprland|hypr) desktop="omarchy.desktop" ;;
    niri) desktop="omarchy-niri.desktop" ;;
    *)
      echo "Usage: compositor-switch set-session {hyprland|niri}" >&2
      return 2
      ;;
  esac
  # Prefer an Omarchy session when installed, else fall back to stock entries.
  if [ ! -f "/usr/local/share/wayland-sessions/$desktop" ] && [ ! -f "/usr/share/wayland-sessions/$desktop" ]; then
    case "$want" in
      hyprland|hypr) desktop="hyprland.desktop" ;;
      niri) desktop="niri.desktop" ;;
    esac
  fi
  setter=$(find_setter) || {
    echo "compositor-switch: no SDDM setter installed." >&2
    echo "Install one (needs root once):" >&2
    echo "  sudo cp \"\$(inir scripts-path 2>/dev/null)/sddm-set-autologin-session\" /usr/local/bin/ && sudo chmod 755 /usr/local/bin/sddm-set-autologin-session" >&2
    return 1
  }
  elevate "$setter" "$desktop"
}

do_logout() {
  if command -v uwsm >/dev/null 2>&1; then
    nohup bash -c 'sleep 1 && uwsm stop' >/dev/null 2>&1 &
    return 0
  fi
  if pgrep -x niri >/dev/null 2>&1; then
    command -v niri >/dev/null 2>&1 && niri msg action quit >/dev/null 2>&1 &
    sleep 1
  fi
  if pgrep -x Hyprland >/dev/null 2>&1 && command -v hyprctl >/dev/null 2>&1; then
    hyprctl dispatch exit >/dev/null 2>&1 &
    sleep 1
  fi
  echo "compositor-switch: could not find a logout method (need uwsm)." >&2
  return 1
}

do_switch() {
  case "${1:-}" in
    hyprland|hypr|niri) ;;
    *) echo "Usage: compositor-switch switch {hyprland|niri}" >&2; return 2 ;;
  esac
  set_session "$1" || return $?
  sleep 1
  do_logout
}

case "$cmd" in
  status) current_compositor ;;
  current) current_compositor ;;
  target|boot-target) boot_target ;;
  set-session) set_session "${2:-}" ;;
  switch) do_switch "${2:-}" ;;
  logout) do_logout ;;
  -h|--help|help)
    echo "Usage: compositor-switch {status|target|switch {hyprland|niri}|logout}"
    ;;
  *) echo "Unknown command: $cmd" >&2; exit 2 ;;
esac
