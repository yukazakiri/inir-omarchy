# Autostart and session

Choose the apps that start with iNiR, and what happens when you lock, reboot or shut down.

## Apps and commands at login

**Settings › Autostart** (Waffle: **Waffle Settings › Autostart**) has three tabs:

- **Applications**: turn on the apps from your menu that should start at login.
- **Commands**: add a command, such as `telegram-desktop --start-minimized`, to run at login.
- **Guide**: how it works.

Niri launches these, so they keep running if the shell restarts. The page only works while Niri or Umbriel is your compositor.

iNiR starts from a systemd user unit wired to the compositor session:

```
~/.config/systemd/user/niri.service.wants/inir.service
~/.config/systemd/user/umbriel.service.wants/inir.service
```

When the compositor starts, `inir.service` waits for its `Type=notify` unit to report ready, so it inherits the authoritative `DISPLAY`, `WAYLAND_DISPLAY` and `NIRI_SOCKET` / `UMBRIEL_SOCKET`. When the compositor stops, iNiR stops. Manage the link with:

```bash
inir service enable     # create wants links
inir service disable    # remove them
inir service status     # check state
```

### uwsm-managed Niri sessions (Omarchy)

Omarchy's Niri entry (`/usr/local/share/wayland-sessions/omarchy-niri.desktop`)
starts the compositor through uwsm, so Niri runs inside the generated
`wayland-wm@niri.desktop.service` and `niri.service` never becomes active.
The shipped `inir.service` names that unit in its `PartOf=` / `After=` lists, so
the shell stops with the uwsm session and never leaks into the next login.
`setup install`, `setup update` and `inir service enable` detect the
`omarchy-niri.desktop` session and add the matching wants link:

```
~/.config/systemd/user/wayland-wm@niri.desktop.service.wants/inir.service
```

Startup is still gated by the wants link, so iNiR does not appear under
Hyprland, KDE, or GNOME. Hyprland is accepted by the unit's `ExecCondition` only
so the shell can be swapped in place inside a live Omarchy session
(`scripts/shell-switch.sh`). Older installs may still have the
`inir.service.d/omarchy-uwsm.conf` drop-in from v2.33; it is harmless and can be
deleted once the new wants link is present.

On Void without a usable systemd user manager, setup renders
`~/.config/service/inir/run`. Turnstile provides the user-session lifecycle and
environment directory when available; otherwise Niri owns a single runsvdir
fallback. Do not add a second handwritten `spawn-at-startup` shell entry on top
of that. `inir restart`, `inir logs`, `inir doctor` and the other normal CLI
operations select the active supervisor for you.

For the full boot sequence, see [Runtime and Boot Pipeline](RUNTIME.md).

## App autostart

There are two layers of autostart in a typical iNiR setup:

### Compositor level (spawn-at-startup)

These are defined in `~/.config/niri/config.d/50-startup.kdl` and managed by the compositor:

- `wl-paste --no-newline --type text --watch ~/.config/quickshell/inir/scripts/clipboard-store.py` (clipboard text history; avoids synthetic trailing newlines and strips browser markup)
- `wl-paste --type image --watch ~/.config/quickshell/inir/scripts/clipboard-image-store.sh` (clipboard image history; internal preview frames are filtered)
- `kbuildsycoca6` (KDE desktop entry cache)

These run before iNiR starts and are independent of the shell.

### Shell level (Autostart service)

iNiR has its own autostart manager that handles:

- **Desktop entries**: standard `.desktop` files in `~/.config/autostart/`
- **Custom commands**: user-defined commands configured through Settings
- **Systemd units**: user-level systemd services when that user manager exists

Manage autostart entries from Settings > System > Autostart (there is no CLI for this, it is managed through the settings UI, backed by `services/Autostart.qml`).

## Lock screen

<!-- preview shot=lock -->

- **Super+Alt+L** locks the session. Unlock with your password.
- If the shell's lock screen does not appear within two seconds, swaylock or hyprlock takes over, whichever is installed.

Settings › System › Lock screen:

- **Use Hyprlock (instead of Quickshell)** is off by default.
- **Launch on startup** is off by default. Turn it on to use Quickshell as your lock screen provider.
- **Require password to power off/restart** is on by default. It guards against accidents only.
- **Also unlock keyring** is on by default.
- **Show notifications on lock screen** is off by default.

The lock screen's look (blur, clock, widgets) is further down the same page, under **Style: Blurred**.

## Session screen

**Super+Shift+Q** opens the session screen with log out, reboot, shut down and hibernate. It warns you first if a package manager is running or a download may be in progress.

## Idle and sleep

Material: **Settings › Services › System › Idle & Sleep**. Each timeout is in seconds, and 0 means never.

- **Screen off**: 300 seconds by default.
- **Lock screen**: 600 seconds by default.
- **Suspend**: off by default.

**Lock before sleep** is on by default. **Separate timeouts on battery** gives battery its own values. In iRiS, idle is in iRiS Settings instead.

## Authentication prompts

iNiR is your system's authentication agent. When something needs your password, such as installing a package, the prompt appears in the shell's look. If you run another agent, iNiR steps aside. To turn iNiR's agent off, use **Settings › Modules › Polkit Agent**.
