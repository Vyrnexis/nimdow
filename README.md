# nimdow

A window manager written in [Nim](https://nim-lang.org/)

**NOTE: Nimdow is in Beta but is very usable. Please report any bugs you may find.**

I am using this project to learn Nim, x11, and to replace my build of **dwm** (written in C).

**Discord community:** https://discord.gg/vPCumzeqqa

[See the progress of development in the local Kanban Board](https://github.com/avahe-kellenberger/nimdow/projects/1?fullscreen=true)

# Table of Contents

1. [Screenshots](#screenshots)
2. [Installation](#installation)
    1. [Building from source](#building)
    2. [Arch Linux (AUR)](#aur)
3. [Config File](#config)
4. [Wayland / River](#wayland)
5. [Command Line Arguments](#cli)
6. [Command Line Client](#cli-client)
7. [Status Bar](#statusbar)
8. [Issues with Java Applications](#issues-with-java-applications)
9. [Roadmap](#roadmap)
10. [Testing Locally](#testing)

## Screenshots

![](https://user-images.githubusercontent.com/34498340/187017440-95f191ae-5701-45ce-9481-9c1f5fd450dc.png)
![](https://user-images.githubusercontent.com/34498340/132368685-570a2629-f948-4f24-9ab8-00804824a497.png)
![](https://user-images.githubusercontent.com/34498340/84605679-209c3d80-ae6d-11ea-8823-09b2c8626b55.png)

## Installation

### Building from source <a name="building"></a>

1. Ensure you have `nim` (version 1.2.0 or higher) and `nimble` installed. My preferred method is to use `choosenim` to install these.
2. Clone this repo
3. Execute `nimble install` from the package directory to install dependencies
4. Execute `nimble release` from the package directory to create a release build (The built binary will be in `./bin/nimdow`)
5. Copy the default config (`config.default.toml`) to `${XDG_CONFIG_HOME}/nimdow/config.toml`, OR to `${HOME}/.config/nimdow/config.toml`.

### AUR

If you are on an Arch Linux based system, use `nimdow-bin` in the AUR to install a pre-built binary.

Default config is stored at `/usr/share/nimdow/config.default.toml`

## Nixos

If you are on Nixos, you can set `services.xserver.windowManager.nimdow.enable=true;` to install and
enable nimdow in your login manager. (in `nixos-unstable` or in stable from 2023-05 release).

## Config File <a name="config"></a>

Nimdow searches for a config file in 3 locations in this order:

1. `${XDG_CONFIG_HOME}/nimdow/config.toml`
2. `${HOME}/.config/nimdow/config.toml`
3. `/usr/share/nimdow/config.default.toml`

If no config file is found, Nimdow will not launch.

**See [the wiki](https://github.com/avahe-kellenberger/nimdow/wiki/User-Configuration-File) for information about the specifics of the config file.**

## Wayland / River <a name="wayland"></a>

This branch is a [River](https://codeberg.org/river/river) (0.5 or newer) window manager client
using `river-window-management-v1`. X11 is no longer supported.

- Build dependencies: `wayland`, `xkbcommon`, `cairo`, `pango`, `librsvg`, `libsystemd`, `river >= 0.5` (plus
  `nim` and the `parsetoml` nimble package).
- Installing on Arch Linux: `cd packaging/arch && makepkg -si` builds and installs `nimdow-wayland-git` (it
  fetches the `wayland` branch and a pinned parsetoml, no nimble needed). Elsewhere: `nimble install -d`,
  `nimble release`, then copy `bin/nimdow` to `/usr/bin`, `config.default.toml` to
  `/usr/share/nimdow/` (or `~/.config/nimdow/config.toml`) and `wayland-sessions/nimdow.desktop` to
  `/usr/share/wayland-sessions/`.
- Run with `river -c nimdow`. For a login manager, install `wayland-sessions/nimdow.desktop`
  to `/usr/share/wayland-sessions/`.
- The status text is set with `nimdow --status "text"`, for example:
  `while true; do nimdow --status "$(date +%H:%M)"; sleep 30; done`
- Layer shell clients (launchers, notifications, wallpapers, other bars such as noctalia) are supported;
  their exclusive zones shrink the tiled area and nimdow's own bar is placed below them.
- The bar is rendered at the output's (fractional) scale.

- Floating windows (rules, scratchpad, dialogs) are placed and clamped inside the usable area, i.e. the
  output minus layer shell exclusive zones and nimdow's bar.
- App rules are evaluated when a window is first placed; a window that has no `app_id` (or no title, if a rule
  matches on titles) yet is held back for one manage sequence. If a title-based rule did not match and the
  title arrives (or changes) within 500ms of the placement, the rules are evaluated again and apply the tags and
  floating/fullscreen state (but never the monitor). `maximize_requested` is ignored.
- Some clients ignore the size they are offered when they open floating. Alacritty (winit) is one: a
  floating rule's `width`/`height` is sent, but alacritty opens at its own default size.

Differences from the X11 version: no system tray, no urgency hints, and app rules match the
window's `app_id` (`class` and `instance` both match it).

## Command Line Arguments <a name="cli"></a>

- Providing an alternative config file, e.g. `nimdow --config ./some-config.toml`
- Version information: `nimdow -v` or `nimdow --version`
- Setting the bar's status text of the running instance: `nimdow --status "text"`
- Debug: `nimdow --dumpState [file]` makes the running instance write its state (monitors, tags, clients with
  app_id/title/tags/floating/fullscreen/geometry, the focused client, bar visibility) as JSON to `file`
  (default `$XDG_RUNTIME_DIR/nimdow-state.json`).

## Command Line Client <a name="cli-client"></a>

Nimdow controls can be executed via the cli client.

See [the wiki page](https://github.com/avahe-kellenberger/nimdow/wiki/CLI-Client) for a list of commands,
or read the **man page**.

## Status Bar <a name="statusbar"></a>

The status bar displays:
- The available tags on the top left
- The focused window's title in the center
- The status (set by the user) on the right

### System tray <a name="tray"></a>

nimdow shows tray icons on the right of the bar, using the StatusNotifierItem D-Bus protocol (what waybar, KDE
and noctalia use; XEmbed does not exist on Wayland). It needs the D-Bus session bus and libsystemd (sd-bus);
SVG icons need librsvg.

- nimdow tries to own `org.kde.StatusNotifierWatcher`. If another program already owns it (waybar, noctalia, ...)
  nimdow acts as a host only: it shows the items registered with that watcher, and takes over the name if the
  other watcher goes away. It also owns `org.kde.StatusNotifierHost-<pid>`.
- Left click calls `Activate` (or `ContextMenu` for menu-only items), middle click `SecondaryActivate`, right click
  `ContextMenu`, scrolling `Scroll` (up: -1, down: 1). Items with status `Passive` are hidden, `NeedsAttention`
  shows the attention icon.
- Icons: `IconName` is looked up in the item's `IconThemePath`, the user's icon theme and its `Inherits` chain,
  hicolor and `/usr/share/pixmaps` (SVG preferred, `a-b-c` falls back to `a-b`); otherwise the `IconPixmap` is
  used; otherwise a placeholder letter is drawn. The theme is `trayIconTheme`, else `gtk-icon-theme-name` of the
  GTK 3/4 `settings.ini`, else Adwaita (gsettings/dconf is not queried).
- Settings (in `[settings]`): `trayEnabled` (default `true`; a config reload starts or stops the tray), `trayMonitor` (default `1`, the
  first monitor; `0` follows the selected monitor), `trayIconPadding` (default `2`), `trayIconSpacing`
  (default `4`), `trayIconTheme`.
- Context menus: right click opens the item's `com.canonical.dbusmenu` (its `Menu` object path) as a popup under
  the icon, drawn with the bar's font and colors; left click does so for items with `ItemIsMenu`. Items without
  a `Menu` get `ContextMenu(x, y)` instead. Entries: labels (mnemonics stripped), separators, check/radio marks,
  icons (`icon-name`), disabled entries, submenus (opened on click, or after hovering the entry for 200ms; an
  open submenu is kept for 300ms while the pointer crosses other entries on its way to it; shown to the right of
  their parent or to the left at the screen edge). The menu closes after an activation, with Escape, when clicking elsewhere on the
  bar, on a window or on the icon again, on a tag change, or when the item disappears. Keyboard: Up/Down (skip
  separators and disabled entries; holding the key repeats at the seat's `wl_keyboard.repeat_info` rate/delay), Right/Enter/Space (open submenu/activate), Left (close submenu), Escape. The
  menu takes the keyboard focus (the previous window gets it back when it closes). The menu follows
  `LayoutUpdated`/`ItemsPropertiesUpdated`. Settings: `menuBorderColor` (default: `barSelectionColor`),
  `menuWidthMin` (default `150`).
- Tooltips: hovering an icon for 600ms shows a small popup below it with the item's `ToolTip` title (and the first
  line of its description; simple HTML markup is stripped), else its `Title`, else its `Id`. It is drawn with the
  bar's colors and font and `menuBorderColor`, and hides when the pointer leaves, on a click and while a menu is
  open.
- Limitation: River sends no event for clicks that hit neither a window nor one of our surfaces (the bare
  desktop), so an open menu is not dismissed by a click on empty desktop; use Escape, a window, the bar or a tag
  change.
- Not implemented yet: scrolling of menus taller than the screen.

### Setting the status <a name="setting-status"></a>

See the [wiki page](https://github.com/avahe-kellenberger/nimdow/wiki/Setting-the-status) about statuses.

### Emojis Not showing up / some characters invisible

In short, there's a bug in the xft library most distros use.

[This fork of xft](https://gitlab.freedesktop.org/xorg/lib/libxft) has a fix for emojis and other font issues.

If using an Arch Linux based distro, there is [libxft-bgra-git](https://aur.archlinux.org/packages/libxft-bgra-git/) in the AUR.

## Issues with Java Applications

### The fix

There are multiple fixes, per the [arch wiki](https://wiki.archlinux.org/index.php/Java#Gray_window,_applications_not_resizing_with_WM,_menus_immediately_closing).

Fix #1:
For jre7-openjdk or jre8-openjdk, append the line `export _JAVA_AWT_WM_NONREPARENTING=1` in `/etc/profile.d/jre.sh`.
Then, source the file `/etc/profile.d/jre.sh` or log out and log back in.

Fix #2:
For last version of JDK append line `export AWT_TOOLKIT=MToolkit` in `~/.xinitrc` before `exec nimdow`.

Fix #3:
Try to use [wmname](https://tools.suckless.org/x/wmname/) with line `wmname compiz` in your `~/.xinitrc`.

Fix #4:
For Oracle's JRE/JDK, use [SetWMName](https://wiki.haskell.org/Xmonad/Frequently_asked_questions#Using_SetWMName).
However,
its effect may be canceled when also using XMonad.Hooks.EwmhDesktops.
In this case,
appending `>> setWMName "LG3D"` to the LogHook may help.

### Why is this happening?

The standard Java GUI toolkit has a hard-coded list of "non-reparenting" window managers.
Nimdow is not (yet) included in this list.

## Roadmap

See the [1.0 release project board](https://github.com/avahe-kellenberger/nimdow/projects/1)

## End-to-end tests (Wayland) <a name="e2e"></a>

`bash tests/e2e/run.sh [-o outdir] [-b] [-s scenario,...]` runs nimdow in a nested River (needs `river`, `grim`,
`alacritty`, `jq`, `dbus-run-session`, python3 with PyGObject and a running Wayland session) with `tests/e2e/config.toml`. Input (key bindings, typing, pointer
moves, clicks, super+drag, scrolling) is injected through the virtual keyboard/pointer protocols by
`bin/nimdowinput` (`tests/e2e/nimdowinput.nim`, built by `-b` or on first use; `nimdowinput key super+shift+1`,
`type "text"`, `move X Y`, `click left`, `drag super left X1 Y1 X2 Y2`, `scroll up`). Results are asserted
through `nimdow --dumpState`; the nested River runs in a private D-Bus session (`dbus-run-session`) with
`tests/e2e/fake_sni.py` as fake tray items/watcher; screenshots, the river/nimdow logs and `results.txt` end up in the output dir
(default `./e2e-out`).

## Testing locally (for development) <a name="testing"></a>

0. Create a copy or symlink of the config file in `$XDG_CONFIG_HOME/nimdow/config.toml`
1. Start up Xephyr: `Xephyr -ac -screen 1920x1080 -br -reset -terminate 2> /dev/null :1 &`
2. Execute nimdow on the new display: `DISPLAY=:1 ./nimdow`

