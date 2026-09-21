# Developing Omaview

See the [README](README.md) for installation and controls.

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

Hyprland 0.56.2 normally skips capture frames for windows entirely outside their
desktop monitor. The companion completes the overview's pending frames for
those windows through Hyprland's existing capture renderer. Capture permissions
and `no_screen_share` rules still apply. This uses internal capture interfaces
as well as event listeners, so matching compositor headers remain required.

After an update that changes the native companion, restart the Hyprland session
to load the new version. The loader reports an old loaded companion instead of
silently continuing with it.

For details, alternatives, source references and limitations, see
[NATIVE-OVERVIEW.md](NATIVE-OVERVIEW.md).

## Integration checks

From the repository root, run (opens a separate, temporary Hyprland window):

```bash
python3 tests/integration.py
```

The test mounts an empty temporary home using Bubblewrap, starts a separate
compositor and the real Omarchy shell, and runs the actual plugin installer.
It verifies the first-open native build from an empty cache, navigation in
scrolling and dwindle layouts, actual preview pixels for offscreen windows,
capture visibility, search after focus changes, geometry updates,
workspace switching, close/reopen, Ctrl+letter dock focus/launch actions, and
pointer-driven pin reordering, cancellation, launcher/dock context menus,
hiding and unhiding apps, search exclusion, and persistence across shell restarts.
Workspace animation checks sample intermediate positions in both directions
and reverse a transition while Hyprland's active workspace changes immediately.
Pixel checks verify rounded and square window/wallpaper corners after a config
reload, plus rounding in the strip layout after reopening.
The launch test uses a temporary desktop entry and runs `gtk-launch` directly
inside the test session, bypassing UWSM's host-systemd scope wrapper.
It uses the machine's installed system
packages, so this tests independence from personal configuration rather than a
fresh OS installation. Test-only tools are `bwrap`, `dbus-run-session`, `git`,
`python3`, `foot`, `wtype`, and `grim`.

## Preview behavior

The overview follows Hyprland's reported window positions and focused address.
Focus, layout and workspace changes take effect immediately; closing the view
only hides it. Geometry notifications come from the native companion, without
shell polling or changes to individual keybindings.

Scrolling workspaces slide vertically with a 220 ms ease-out animation.
Reversing direction mid-transition continues from the current position.
The layout mode is chosen when the overview opens and stays fixed until it closes.

Every window intersecting the overview viewport gets a live preview, including
scrolling columns outside the desktop monitor. Fully clipped previews stop
capturing, as do all previews when the overview closes.

Window previews and wallpapers follow Hyprland's `decoration:rounding`, scaled
to their size. Their content is clipped to those corners in both layouts.
Config reloads update the rounding while open, and reopening refreshes it too.

## Menu model and reloads

- `MenuModel.js` is a copy of the Omarchy menu's model
  (`$OMARCHY_PATH/shell/plugins/menu/MenuModel.js`); re-copy it if the menu
  format changes upstream. Its license is preserved in
  [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
- The manifest sets `keepLoaded` so omaview opens instantly. The kept
  instance is not replaced on hot reload, so after editing the QML run
  `omarchy restart shell`.
- Window previews use Hyprland's toplevel export via Quickshell's
  `ScreencopyView`, so windows on other workspaces are live too.
