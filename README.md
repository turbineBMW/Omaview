# Omaview

Omaview is a fullscreen overview for the Omarchy shell on Hyprland: niri-style workspaces
on top, a GNOME-style grid of apps and Omarchy menus in the middle, a dock at
the bottom.

```bash
omarchy-shell shell toggle turbinebmw.omaview '{}'
```

## Install

The supported target is Omarchy with its Quickshell shell and Hyprland 0.56.2
(the version tested). Install and enable the plugin with:

```bash
omarchy plugin add https://github.com/turbineBMW/Omaview --enable
```

Replace the existing overview/menu binding in `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + SPACE")
hl.bind("SUPER + SPACE", function()
  hl.exec_cmd("omarchy-shell shell toggle turbinebmw.omaview '{}'")
end)
```

Reload with `hyprctl reload` and check `hyprctl configerrors`. The first open
builds and loads the bundled native companion automatically. Standard Omarchy
already supplies its build dependencies; no separate Hyprpm installation or
personal Lua helper files are needed. The plugin does not edit Hyprland
configuration. Other Hyprland versions have not been validated.

## Top: workspaces

The mode follows the layout (`tiledLayout` from `hyprctl`) of the workspace you
open omaview on, and stays put while you move between workspaces inside it.

- **Scrolling layout** — the current workspace is always centered on its
  wallpaper, with live window previews at their real positions. Columns
  outside the monitor sit off the wallpaper to the left and right; where they
  run past the edge of the screen they fade out. A sliver of the workspace
  above and below peeks in; the one below is an empty workspace when you are
  on the last, as in niri.
- **Any other layout** — no large view: every workspace on the monitor sits in
  one horizontal strip, the focused one slightly larger. The strip shrinks to
  fit when there are many workspaces, and the app grid gets the freed space.

Window and workspace changes take effect in Hyprland immediately. The native
companion keeps the overview's search input available while Hyprland owns the
active window and the tiling layout. Closing only hides the overview.

- Click a window to focus it while staying in the overview; double-click to exit
  onto it. Middle-click requests that the application close the window.
- Click a workspace thumbnail or a peek to switch workspace and stay open.
- `Ctrl+Up` / `Ctrl+Down` switch between numbered workspaces on the current
  monitor. Moving down from the last occupied workspace creates one empty
  workspace; repeated presses there keep the same empty workspace.
- `Ctrl+Left` / `Ctrl+Right` dispatch native focus for the active workspace's
  layout, including scrolling columns and ordinary tiled/floating focus.
- Your normal Super focus, move, resize, float, fullscreen, consume/expel, and
  workspace bindings continue to operate on the real active window.
- `Esc` clears search, goes back in a menu, then closes. `SUPER+SPACE` toggles.

The preview uses Hyprland's actual reported positions and focused address.
There is no independent window selection, guessed neighbor, simulated scroll
offset, focus replay on close, or callback required in individual bindings.
Geometry notifications come from the native companion; the shell does not poll.

## Native companion

`native/omaview.cpp` is a small Hyprland plugin loaded on the first open. The
launcher `native/ensure-native.sh` compiles it against installed headers and
caches the binary under `~/.cache/omaview/<Hyprland ABI>/<source hash>/`.
It needs `g++`, `pkg-config`, `jq`, `flock`, and the development headers supplied
by the installed Hyprland and its dependencies. Omarchy includes `base-devel`,
`jq`, and `hyprland`; a trimmed installation missing those prerequisites gets an
error identifying what is missing. No package installation or elevated access
is attempted. The ABI guard rejects mismatched
headers. An incompatible Hyprland upgrade can require updating this companion;
an ordinary compatible rebuild happens automatically on the next session's first
open. A load failure produces a notification and leaves the overview closed.

The plugin uses event listeners and a custom state query, without replacing
Hyprland functions or modifying its layout. It routes keyboard input only while
Omaview's nonexclusive layer is mapped. Lock screens, exclusive layers and seat
grabs retain Hyprland's normal handling.

`hyprctl omaview-state` reads clients, monitors, workspaces and the active window
in a single compositor turn. `omaview>>geometry` events indicate changed layout
coordinates. The QML view reads those observations and sends normal dispatches.
Window capture stops while the overview is closed.

For details, alternatives, source references and limitations, see
[NATIVE-OVERVIEW.md](NATIVE-OVERVIEW.md).

To run the integration checks (opens a separate, temporary Hyprland window):

```bash
python3 ~/.config/omarchy/plugins/turbinebmw.omaview/tests/integration.py
```

The test mounts an empty temporary home using Bubblewrap, starts a separate
compositor and the real Omarchy shell, and runs the actual plugin installer.
It verifies the first-open native build from an empty cache, navigation in
scrolling and dwindle layouts, search after focus changes, geometry updates,
workspace switching, and close/reopen. It uses the machine's installed system
packages, so this tests independence from personal configuration rather than a
fresh OS installation. Test-only tools are `bwrap`, `dbus-run-session`, `git`,
`python3`, `foot`, and `wtype`.

## Middle: apps and Omarchy menus

Every root entry of the Omarchy menu other than Apps (Learn, Trigger, Style,
Setup, …) is a glyph tile ahead of the app icons. Opening one replaces the grid
with that submenu's items; `Backspace`, `Esc`, or the back pill returns.

The menu is read from the same sources as the Omarchy menu —
`$OMARCHY_PATH/default/omarchy/omarchy-menu.jsonc` plus
`~/.config/omarchy/extensions/omarchy-menu.jsonc` — including `when:` /
`checked:` guards and the font and power-profile providers, so your own
extensions show up here too.

Type to search apps and menu entries together. Arrows move, `Enter` activates,
`Esc` clears the search, then goes back, then closes.

## Bottom: dock

Pinned apps, then running apps that aren't pinned. Click focuses the app's
most recent window (again to step to its next window) or launches it;
middle-click launches a new instance; right-click pins or unpins. Right-click
an app in the grid to pin it. Pins live in
`~/.config/omarchy/omaview-pinned.json`.
Menu extensions and pins respect `XDG_CONFIG_HOME` when set.

## Payload

| Key      | Values                  | Effect                                  |
|----------|-------------------------|-----------------------------------------|
| `layout` | `scrolling`, `strip`    | Force the top section's mode            |
| `menu`   | a menu id or alias      | Open straight into that Omarchy submenu |

## Notes

- `MenuModel.js` is a copy of the Omarchy menu's model
  (`$OMARCHY_PATH/shell/plugins/menu/MenuModel.js`); re-copy it if the menu
  format changes upstream. Its license is preserved in
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- The manifest sets `keepLoaded` so omaview opens instantly. The kept
  instance is not replaced on hot reload, so after editing the QML run
  `omarchy restart shell`.
- Window previews use Hyprland's toplevel export via Quickshell's
  `ScreencopyView`, so windows on other workspaces are live too.
