"""Install and exercise the plugin with a clean home and a separate compositor.

The outer process mounts a temporary directory over the home path inside
bubblewrap. HOME itself is unchanged. System packages are those on this machine;
this proves configuration independence, not a fresh OS installation.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from pointer import VirtualPointer

plugin = Path(__file__).resolve().parents[1]

if os.environ.get("OMAVIEW_TEST_ISOLATED") != "1":
    for command in ("bwrap", "dbus-run-session", "git", "Hyprland", "qs", "foot", "wtype", "grim"):
        if not shutil.which(command):
            raise SystemExit(f"Test prerequisite missing: {command}")
    with tempfile.TemporaryDirectory(prefix="omaview-clean-install-") as directory:
        outer = Path(directory)
        clean_home = outer / "home"
        clean_home.mkdir()
        release = outer / "release"
        shutil.copytree(plugin, release, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        runtime = os.environ["XDG_RUNTIME_DIR"]
        command = ["bwrap", "--ro-bind", "/", "/", "--dev-bind", "/dev", "/dev",
                   "--proc", "/proc", "--tmpfs", "/tmp", "--bind", str(outer), str(outer),
                   "--bind", str(clean_home), str(Path.home()), "--bind", runtime, runtime,
                   "--die-with-parent", "--setenv", "OMAVIEW_TEST_ISOLATED", "1"]
        for key in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                    "QS_CONFIG_PATH", "QS_CONFIG_NAME", "QS_MANIFEST"):
            command += ["--unsetenv", key]
        command += ["dbus-run-session", "--", "python3", str(release / "tests/integration.py")]
        result = subprocess.run(command, cwd=outer)
        raise SystemExit(result.returncode)

assert not (Path.home() / ".config/hypr").exists(), "Test must have an empty home"
assert not (Path.home() / ".cache/omaview").exists(), "Test must start without a native binary"
work = tempfile.TemporaryDirectory(prefix="omaview-test-")
base = Path(work.name)
config = base / "hyprland.lua"
config.write_text("""hl.monitor({output="", mode="1280x800@60", position="auto", scale=1})
hl.config({general={layout="scrolling"}, decoration={rounding=0}, input={resolve_binds_by_sym=true}, animations={enabled=false}, misc={disable_hyprland_logo=true, disable_splash_rendering=true}, ecosystem={no_update_news=true, no_donation_nag=true}})
hl.bind("SUPER + Left", hl.dsp.layout("focus l"))
hl.bind("SUPER + SPACE", function()
    hl.exec_cmd("omarchy-shell shell toggle turbinebmw.omaview '{}'")
end)
""")
config_base = config.read_text()
# A real image is needed to catch rectangular image content covering a
# rounded wallpaper background. Use a uniform color for pixel assertions.
wallpaper_color = bytes.fromhex("e0c050")
wallpaper_file = base / "wallpaper.ppm"
wallpaper_file.write_bytes(b"P6\n16 16\n255\n" + wallpaper_color * 256)
background = Path.home() / ".local/state/omarchy/current/background"
background.parent.mkdir(parents=True)
background.symlink_to(wallpaper_file)
server_log = (base / "hyprland.log").open("w")
server = subprocess.Popen(["Hyprland", "--config", str(config)],
                          env=os.environ | {"AQ_DRM_DEVICES": "/dev/null"},
                          stdout=server_log, stderr=server_log)
processes = []
env = os.environ.copy()


def run(*args, timeout=15):
    return subprocess.check_output(args, env=env, text=True, timeout=timeout).strip()


def compositor():
    return json.loads(run("hyprctl", "omaview-state"))


def shell(method, *args):
    return run("omarchy-shell", "shell", method, *args)


def ipc(method, arg=""):
    return shell("call", "turbinebmw.omaview", method, arg)


def observed():
    return json.loads(ipc("status"))


def wait_for(predicate, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError("Timed out waiting for compositor/overview state")


def matches_focus():
    return observed()["focusedAddress"] == compositor()["activewindow"].get("address", "")


def wait_focus_change(before):
    wait_for(lambda: compositor()["activewindow"].get("address", "") != before)
    wait_for(matches_focus)


try:
    # Every mutating command below targets this isolated compositor's signature.
    deadline = time.monotonic() + 10
    instance = None
    while time.monotonic() < deadline and server.poll() is None:
        instances = json.loads(subprocess.check_output(["hyprctl", "-j", "instances"], text=True))
        instance = next((i for i in instances if i["pid"] == server.pid), None)
        if instance:
            break
        time.sleep(.1)
    if not instance:
        raise RuntimeError((base / "hyprland.log").read_text())
    env.update(HYPRLAND_INSTANCE_SIGNATURE=instance["instance"], WAYLAND_DISPLAY=instance["wl_socket"])
    # Keep application launches inside this test's compositor and session bus.
    # The real gtk-launch still resolves and starts the test desktop entry;
    # only UWSM's host-systemd scope wrapper is replaced for isolation.
    launcher_bin = base / "bin"
    launcher_bin.mkdir()
    launcher_wrapper = launcher_bin / "uwsm-app"
    launcher_wrapper.write_text('#!/bin/sh\nif [ "$1" = "--" ]; then shift; fi\nexec "$@"\n')
    launcher_wrapper.chmod(0o755)
    env["PATH"] = str(launcher_bin) + os.pathsep + env["PATH"]
    applications = Path.home() / ".local/share/applications"
    applications.mkdir(parents=True)
    (applications / "omaview-dock-launch.desktop").write_text(
        '[Desktop Entry]\nType=Application\nName=Omaview Dock Launch\n'
        'Exec=foot -a omaview-dock-launch -T "Omaview dock launch" sleep 600\n'
        'Icon=utilities-terminal\nTerminal=false\nStartupWMClass=omaview-dock-launch\n')
    pin_file = Path.home() / ".config/omarchy/omaview-pinned.json"
    pin_file.parent.mkdir(parents=True)
    for suffix in ("two", "three"):
        (applications / f"omaview-dock-{suffix}.desktop").write_text(
            '[Desktop Entry]\nType=Application\nName=Omaview Dock ' + suffix + '\n'
            'Exec=foot -a omaview-dock-' + suffix + ' sleep 600\nIcon=utilities-terminal\nTerminal=false\n')
    pin_file.write_text('["omaview-dock-launch", "omaview-dock-two", "omaview-dock-three"]\n')
    time.sleep(.5)
    assert run("hyprctl", "eval", "assert(not pcall(require, 'hypr.layout_aware')); assert(not pcall(require, 'hypr.dynamic_workspaces'))") == "ok"
    assert json.loads(run("hyprctl", "-j", "plugin", "list")) == []
    colors = dict(zip("abcdef", ("cc2244", "22aa55", "2266cc", "cc9922", "9933bb", "22aabb")))
    for name, color in colors.items():
        processes.append(subprocess.Popen(["foot", "-a", "omaview-test-" + name,
            "-o", "colors-dark.background=" + color,
            "-T", "Omaview test " + name, "sleep", "600"], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(.2)
    shell_log = (base / "shell.log").open("w")
    shell_command = ["qs", "-p", os.environ.get("OMARCHY_PATH", "/usr/share/omarchy") + "/shell"]
    shell_process = subprocess.Popen(shell_command, env=env, stdout=shell_log, stderr=shell_log)
    processes.append(shell_process)
    wait_for(lambda: subprocess.run(["omarchy-shell", "shell", "ping"], env=env,
              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0, timeout=15)

    # Use the real installer and the real shell, not a mock plugin loader.
    run("git", "init", "-q", str(plugin))
    run("git", "-C", str(plugin), "add", ".")
    run("git", "-C", str(plugin), "-c", "user.name=Omaview Test", "-c", "user.email=test@localhost",
        "commit", "-qm", "Test release")
    print(run("omarchy", "plugin", "add", str(plugin), "--yes", "--enable"), flush=True)
    installed = Path.home() / ".config/omarchy/plugins/turbinebmw.omaview"
    assert (installed / "Navigation.js").is_file()
    run("omarchy", "plugin", "validate", str(installed))
    wait_for(lambda: ipc("ping") == "ok", timeout=15)
    run("wtype", "-M", "logo", "-k", "space", "-m", "logo")
    wait_for(lambda: observed()["opened"] and observed()["nativeReady"] and observed()["clients"], timeout=30)
    assert len(list((Path.home() / ".cache/omaview").rglob("omaview.so"))) == 1
    wait_for(matches_focus)
    print("PASS: actual plugin install, enable, keybind, and automatic build with an empty home/cache", flush=True)

    original = compositor()
    mon = next(m for m in original["monitors"] if m["focused"])
    offscreen = {c["address"] for c in original["clients"]
                 if c["at"][0] + c["size"][0] <= mon["x"] or c["at"][0] >= mon["x"] + mon["width"]}
    visible_offscreen = {p["address"] for p in observed()["previews"] if p["capturing"]} & offscreen
    assert visible_offscreen, "Regression needs a window outside the desktop but inside the overview"
    wait_for(lambda: all(p["hasContent"] for p in observed()["previews"] if p["capturing"]))
    assert any(not p["capturing"] for p in observed()["previews"]), "Test should also include clipped previews"
    assert all(not p["hasContent"] for p in observed()["previews"] if not p["capturing"])
    current = compositor()
    assert current["activewindow"]["address"] == original["activewindow"]["address"]
    assert {c["address"]: c["at"] for c in current["clients"]} == {c["address"]: c["at"] for c in original["clients"]}

    # Verify pixels, not just successful frame delivery: the offscreen
    # terminal's solid background must appear in the overview screenshot.
    ppm = subprocess.check_output(["grim", "-t", "ppm", "-"], env=env)
    magic, size, maximum, pixels = ppm.split(b"\n", 3)
    assert magic == b"P6" and maximum == b"255"
    width, height = map(int, size.split())
    previews = [p for p in observed()["previews"] if p["address"] in visible_offscreen]
    sample = max(previews, key=lambda p: min(width - 100, p["x"] + p["w"]) - max(100, p["x"]))
    x = int((max(100, sample["x"]) + min(width - 100, sample["x"] + sample["w"])) / 2)
    y = int(sample["y"] + sample["h"] * .35)
    client = next(c for c in current["clients"] if c["address"] == sample["address"])
    expected = bytes.fromhex(colors[client["class"].removeprefix("omaview-test-")])
    actual = pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]
    assert len(actual) == 3 and all(abs(a - b) < 12 for a, b in zip(actual, expected)), (actual.hex(), expected.hex())
    print("PASS: offscreen desktop windows have visible preview pixels without moving focus or layout; clipped captures stop", flush=True)

    def screenshot_pixel(x, y):
        shot = subprocess.check_output(["grim", "-t", "ppm", "-"], env=env)
        magic, size, maximum, pixels = shot.split(b"\n", 3)
        width, height = map(int, size.split())
        x, y = int(x), int(y)
        assert 0 <= x < width and 0 <= y < height
        return pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]

    def close_color(actual, expected):
        return all(abs(a - b) < 12 for a, b in zip(actual, expected))

    def set_rounding(value):
        config.write_text(config_base + f'\nhl.config({{decoration={{rounding={value}}}}})\n')
        run("hyprctl", "reload")
        wait_for(lambda: observed()["rounding"] == value)
        time.sleep(.15)

    address = original["activewindow"]["address"]
    window_color = bytes.fromhex(colors[original["activewindow"]["class"].removeprefix("omaview-test-")])

    def window_corner():
        preview = next(p for p in observed()["previews"] if p["address"] == address)
        assert preview["capturing"] and preview["hasContent"] and preview["border"] > 0
        return screenshot_pixel(preview["x"] + 3, preview["y"] + 3)

    assert observed()["rounding"] == 0
    assert all(p["radius"] == 0 for p in observed()["previews"])
    assert close_color(window_corner(), window_color)
    set_rounding(48)
    assert all(p["radius"] > 0 for p in observed()["previews"])
    assert not close_color(window_corner(), window_color), "Window capture must be clipped at rounded corners"

    ipc("stepWorkspace", "1")
    wait_for(lambda: observed()["workspace"] == 2 and not observed()["workspaceMotion"]["running"])

    def wallpaper_corner():
        wall = next(w for w in observed()["wallpapers"] if w["workspace"] == 2)
        assert abs(wall["radius"] - observed()["rounding"] * wall["scale"]) < .001
        assert close_color(screenshot_pixel(wall["x"] + wall["w"] / 2, wall["y"] + wall["h"] / 2), wallpaper_color)
        return screenshot_pixel(wall["x"] + 2, wall["y"] + wall["h"] - 3)

    assert not close_color(wallpaper_corner(), wallpaper_color), "Wallpaper image must be clipped at rounded corners"
    set_rounding(0)
    assert close_color(wallpaper_corner(), wallpaper_color), "Zero rounding must restore square wallpaper corners"
    ipc("stepWorkspace", "-1")
    wait_for(lambda: observed()["workspace"] == 1 and not observed()["workspaceMotion"]["running"])
    wait_for(lambda: all(p["hasContent"] for p in observed()["previews"] if p["capturing"]))
    assert close_color(window_corner(), window_color), "Zero rounding must restore square window corners"
    print("PASS: actual window and wallpaper pixels follow Hyprland rounding, including zero after a live config reload", flush=True)

    for direction in ("l", "l", "r", "r"):
        before = compositor()["activewindow"]["address"]
        ipc("focusDirection", direction)
        wait_focus_change(before)
        run("wtype", "z")
    wait_for(lambda: observed()["filter"] == "zzzz")
    print("PASS: scrolling navigation and search without personal Lua modules", flush=True)

    before = compositor()["activewindow"]["address"]
    run("wtype", "-M", "ctrl", "-k", "Left", "-m", "ctrl")
    wait_focus_change(before)
    ipc("focusDirection", "r")
    wait_for(lambda: compositor()["activewindow"]["address"] == before)
    run("wtype", "-M", "logo", "-k", "Left", "-m", "logo")
    wait_focus_change(before)
    print("PASS: Ctrl navigation and ordinary compositor bindings", flush=True)

    run("hyprctl", "dispatch", 'hl.dsp.layout("colresize -0.1")')
    def matches_geometry():
        data = compositor()
        actual = data["activewindow"]
        mon = next(m for m in data["monitors"] if m["focused"])
        clients = observed()["clients"].get(str(actual["workspace"]["id"]), [])
        client = next((c for c in clients if c["address"] == actual["address"]), None)
        return client and (client["x"], client["y"], client["w"], client["h"]) == (
            actual["at"][0] - mon["x"], actual["at"][1] - mon["y"], *actual["size"])
    wait_for(matches_geometry)
    print("PASS: native geometry updates without per-binding callbacks", flush=True)

    settled_workspace_y = next(v for v in observed()["workspaceMotion"]["views"] if v["active"])["y"]

    def collect_workspace_motion(workspace, direction):
        frames = []
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            frame = observed()
            motion = frame["workspaceMotion"]
            if frame["workspace"] == workspace:
                frames.append(motion)
                if not motion["running"]:
                    break
            time.sleep(.01)
        moving = [m for m in frames if m["running"]]
        assert len(moving) >= 2, "Workspace transition must have intermediate frames"
        assert not frames[-1]["running"], "Workspace transition must settle"
        positions = [m["position"] for m in frames]
        assert all((b - a) * direction >= 0 for a, b in zip(positions, positions[1:])), positions
        assert abs(positions[-1] - positions[0]) > .01
        assert all(m["duration"] == 220 for m in frames)
        assert all({v["id"] for v in m["views"]} == {1, 2} for m in frames)
        active = next(v for v in frames[-1]["views"] if v["active"])
        assert active["id"] == workspace and active["y"] == settled_workspace_y
        return frames

    run("wtype", "-M", "ctrl", "-k", "Down", "-m", "ctrl")
    downward = collect_workspace_motion(2, 1)
    assert compositor()["activewindow"] == {}
    for _ in range(3):
        run("wtype", "-M", "ctrl", "-k", "Down", "-m", "ctrl")
    run("wtype", "q")
    wait_for(lambda: observed()["filter"] == "zzzzq")
    assert observed()["workspace"] == 2
    assert max(w["id"] for w in compositor()["workspaces"]) == 2
    run("wtype", "-M", "ctrl", "-k", "Up", "-m", "ctrl")
    upward = collect_workspace_motion(1, -1)
    print("PASS: native workspace navigation and a single trailing empty workspace", flush=True)
    assert next(v for v in downward[0]["views"] if v["id"] == 1)["y"] > next(v for v in downward[-1]["views"] if v["id"] == 1)["y"]
    assert next(v for v in upward[0]["views"] if v["id"] == 1)["y"] < next(v for v in upward[-1]["views"] if v["id"] == 1)["y"]
    print("PASS: workspace previews slide both directions with intermediate frames and the shared 220 ms timing", flush=True)

    # Reverse while moving. Hyprland switches immediately; presentation
    # continues from its current position instead of jumping to either end.
    ipc("stepWorkspace", "1")
    wait_for(lambda: observed()["workspaceMotion"]["running"] and
             .1 < observed()["workspaceMotion"]["position"] < .9)
    ipc("stepWorkspace", "-1")
    wait_for(lambda: observed()["workspace"] == 1)
    reversing = observed()["workspaceMotion"]
    assert reversing["running"] and 0 < reversing["position"] < 1
    assert next(m for m in compositor()["monitors"] if m["focused"])["activeWorkspace"]["id"] == 1
    wait_for(lambda: not observed()["workspaceMotion"]["running"])
    assert observed()["workspaceMotion"]["position"] == 0
    print("PASS: rapid workspace reversal stays continuous while compositor focus updates immediately", flush=True)

    # A departing empty workspace may vanish from Hyprland's list before
    # its slide finishes. Keep its view through the animation, then remove it.
    ipc("stepWorkspace", "1")
    wait_for(lambda: observed()["workspace"] == 2 and not observed()["workspaceMotion"]["running"])
    run("hyprctl", "dispatch", 'hl.dsp.focus({workspace="3"})')
    wait_for(lambda: observed()["workspace"] == 3)
    departing = observed()["workspaceMotion"]
    assert departing["running"] and any(v["id"] == 2 for v in departing["views"])
    wait_for(lambda: not observed()["workspaceMotion"]["running"])
    assert {v["id"] for v in observed()["workspaceMotion"]["views"]} == {1, 3}
    run("hyprctl", "dispatch", 'hl.dsp.focus({workspace="1"})')
    wait_for(lambda: observed()["workspace"] == 1 and not observed()["workspaceMotion"]["running"])
    assert {v["id"] for v in observed()["workspaceMotion"]["views"]} == {1, 2}
    print("PASS: destroyed empty workspaces slide out before their previews are removed", flush=True)

    run("hyprctl", "eval", 'hl.workspace_rule({workspace="1", layout="dwindle"})')
    wait_for(lambda: next(w for w in compositor()["workspaces"] if w["id"] == 1)["tiledLayout"] == "dwindle")
    windows = sorted(compositor()["clients"], key=lambda c: (c["at"][0], c["at"][1]))
    run("hyprctl", "dispatch", 'hl.dsp.focus({window="address:' + windows[-1]["address"] + '"})')
    wait_for(matches_focus)
    before = compositor()["activewindow"]["address"]
    run("wtype", "-M", "ctrl", "-k", "Left", "-m", "ctrl")
    wait_focus_change(before)
    run("wtype", "d")
    wait_for(lambda: observed()["filter"] == "zzzzqd")
    print("PASS: dwindle navigation uses the actual layout without configuration helpers", flush=True)

    selected = compositor()["activewindow"]["address"]
    shell("hide", "turbinebmw.omaview")
    time.sleep(.2)
    assert compositor()["activewindow"]["address"] == selected
    assert not observed()["opened"]
    assert all(not p["capturing"] for p in observed()["previews"])
    binary = next((Path.home() / ".cache/omaview").rglob("omaview.so"))
    mtime = binary.stat().st_mtime_ns
    shell("summon", "turbinebmw.omaview", "{}")
    wait_for(lambda: observed()["nativeReady"] and observed()["opened"])
    assert binary.stat().st_mtime_ns == mtime
    shell("hide", "turbinebmw.omaview")
    assert run("hyprctl", "configerrors") == ""
    assert not (Path.home() / ".config/hypr").exists()
    print("PASS: close/reopen preserves focus and reuses the compiled companion; no Hyprland config installed", flush=True)

    shell("summon", "turbinebmw.omaview", "{}")
    wait_for(lambda: observed()["opened"] and observed()["nativeReady"] and observed()["dock"])
    run("wtype", "search")
    wait_for(lambda: observed()["filter"] == "search")
    assert not observed()["dockHintsVisible"]

    def dock_chord(*keys):
        # wtype's -M sends only a modifiers packet. Include the actual Ctrl
        # key press/release that a physical keyboard sends to show the hints.
        return subprocess.Popen(["wtype", "-P", "Control_L", "-M", "ctrl", "-s", "700",
                                 *keys, "-p", "Control_L", "-m", "ctrl"], env=env)

    held = dock_chord()
    processes.append(held)
    wait_for(lambda: observed()["dockHintsVisible"])
    shortcuts = observed()["dockShortcutKeys"]
    assert shortcuts == [d["key"] for d in observed()["dock"]][:26]
    held.wait(timeout=3)
    wait_for(lambda: not observed()["dockHintsVisible"])
    assert observed()["filter"] == "search" and observed()["opened"]
    print("PASS: holding Ctrl shows left-to-right dock hints; releasing hides them without editing search", flush=True)

    # Use the same MRU/cycling behavior as a mouse click, and ensure the
    # chord does not enter its letter into the search field.
    target = next(d for d in observed()["dock"] if d["windows"] and not any(w["focused"] for w in d["windows"]))
    index = next(i for i, d in enumerate(observed()["dock"]) if d["key"] == target["key"])
    address = min(target["windows"], key=lambda w: w["focusOrder"])["address"]
    held = dock_chord("-k", chr(ord("a") + index))
    processes.append(held)
    wait_for(lambda: observed()["dockHintsVisible"])
    held.wait(timeout=3)
    wait_for(lambda: not observed()["opened"])
    wait_for(lambda: compositor()["activewindow"].get("address") == address)
    assert observed()["filter"] == "search" and not observed()["dockHintsVisible"]
    print("PASS: Ctrl+letter focuses the dock app, closes the overview, and preserves search text", flush=True)

    shell("summon", "turbinebmw.omaview", "{}")
    wait_for(lambda: observed()["opened"] and observed()["nativeReady"])
    assert not observed()["dockHintsVisible"]
    launcher = observed()["dock"][0]
    assert launcher["appId"] == "omaview-dock-launch" and not launcher["windows"]
    held = dock_chord("-k", "a")
    processes.append(held)
    wait_for(lambda: observed()["dockHintsVisible"])
    held.wait(timeout=3)
    wait_for(lambda: not observed()["opened"])
    wait_for(lambda: any(c["class"] == "omaview-dock-launch" for c in compositor()["clients"]))
    print("PASS: Ctrl+A launches an unstarted pinned app and closes the overview", flush=True)

    shell("summon", "turbinebmw.omaview", "{}")
    wait_for(lambda: observed()["opened"] and observed()["nativeReady"] and observed()["dockSlots"])
    def pinned_order():
        return [d["appId"] for d in observed()["dock"] if d["pinned"]]

    def pinned_slots():
        return [d for d in observed()["dockSlots"] if d["pinned"]]

    pointer = VirtualPointer(env, 1280, 800)

    def pointer_move(x, y):
        pointer.move(x, y)
        time.sleep(.06)

    def pointer_button(state):
        pointer.button(state == "down")
        time.sleep(.06)

    def center(slot):
        return slot["x"] + slot["w"] / 2, slot["y"] + slot["h"] / 2

    original_pins = pinned_order()
    before_drag = compositor()
    first, second, last = pinned_slots()
    pointer_move(*center(first))
    pointer_button("down")
    pointer_move(last["x"] + last["w"] * .8, center(last)[1])
    wait_for(lambda: observed()["dockDragging"] and observed()["dockDropValid"])
    assert json.loads(pin_file.read_text()) == original_pins
    pointer_button("up")
    reordered = original_pins[1:] + original_pins[:1]
    wait_for(lambda: pinned_order() == reordered and not observed()["dockDragging"])
    wait_for(lambda: json.loads(pin_file.read_text()) == reordered)
    assert observed()["opened"]
    after_drag = compositor()
    assert after_drag["activewindow"]["address"] == before_drag["activewindow"]["address"]
    assert {c["address"] for c in after_drag["clients"]} == {c["address"] for c in before_drag["clients"]}
    print("PASS: actual pointer drag reorders pinned icons, persists once on drop, and does not activate an app", flush=True)

    held = dock_chord()
    processes.append(held)
    wait_for(lambda: observed()["dockHintsVisible"])
    assert observed()["dockShortcutKeys"] == [d["key"] for d in observed()["dock"]][:26]
    held.wait(timeout=3)

    # Cancel inside the original icon so an accidental click would launch it.
    first, second, last = pinned_slots()
    pointer_move(*center(first))
    pointer_button("down")
    pointer_move(*center(last))
    wait_for(lambda: observed()["dockDragging"])
    run("wtype", "-k", "Escape")
    pointer_move(*center(first))
    pointer_button("up")
    assert observed()["opened"] and pinned_order() == reordered
    assert json.loads(pin_file.read_text()) == reordered

    pointer_move(*center(first))
    pointer_button("down")
    pointer_move(center(first)[0], first["y"] - 80)
    wait_for(lambda: observed()["dockDragging"] and not observed()["dockDropValid"])
    pointer_button("up")
    assert observed()["opened"] and pinned_order() == reordered
    assert json.loads(pin_file.read_text()) == reordered
    print("PASS: Escape and dropping outside the pinned section cancel; Ctrl badges follow the new order", flush=True)

    def click(slot, button=272):
        pointer_move(*center(slot))
        pointer.button(True, button)
        pointer.button(False, button)
        time.sleep(.1)

    def menu_action(action):
        menu = observed()["appMenu"]
        index = next(i for i, row in enumerate(menu["actions"]) if row["action"] == action)
        pointer_move(menu["x"] + menu["w"] / 2, menu["y"] + 4 + menu["rowHeight"] * (index + .5))
        pointer_button("down")
        pointer_button("up")
        wait_for(lambda: not observed()["appMenu"]["appId"])

    test_app = "omaview-dock-two"
    slot = next(d for d in pinned_slots() if d["key"] == test_app)
    click(slot, 273)
    wait_for(lambda: observed()["appMenu"]["appId"] == test_app)
    assert pinned_order() == reordered, "Right-click must not immediately change pins"
    assert [a["label"] for a in observed()["appMenu"]["actions"]] == ["Unpin from dock"]
    run("wtype", "-k", "Escape")
    assert not observed()["appMenu"]["appId"] and observed()["opened"]
    click(slot, 273)
    menu_action("pin")
    wait_for(lambda: test_app not in pinned_order())

    run("wtype", "Omaview Dock two")
    wait_for(lambda: len(observed()["gridSlots"]) == 1)
    tile = observed()["gridSlots"][0]
    assert tile["appId"] == test_app
    click(tile, 273)
    assert [a["label"] for a in observed()["appMenu"]["actions"]] == ["Pin to dock", "Hide app"]
    assert test_app not in pinned_order()
    # Clicking outside dismisses without activating the tile or closing the overview.
    click({"x": 1, "y": 1, "w": 1, "h": 1})
    assert observed()["opened"] and not observed()["appMenu"]["appId"]
    click(tile, 273)
    menu_action("pin")
    reordered = [app for app in reordered if app != test_app] + [test_app]
    wait_for(lambda: pinned_order() == reordered)
    click(tile, 273)
    menu_action("hide")
    hidden_file = pin_file.with_name("omaview-hidden.json")
    wait_for(lambda: json.loads(hidden_file.read_text()) == [test_app])
    assert observed()["rows"] == [], "Hidden apps must be excluded from normal search"
    assert test_app in pinned_order(), "Hiding a launcher tile must preserve dock pins"
    run("wtype", "-k", "Escape")
    assert observed()["rows"][-1]["label"] == "Hidden"
    assert all(r["appId"] != test_app for r in observed()["rows"])
    # Keyboard navigation reaches the final tile even when the grid must scroll.
    pointer_move(1, 1)
    for direction in ("Down", "Right"):
        for _ in range(len(observed()["rows"])):
            run("wtype", "-k", direction)
    wait_for(lambda: any(t["itemId"] == "__omaview_hidden" for t in observed()["gridSlots"]))
    time.sleep(.3)  # Let keyboard scrolling settle before clicking.
    hidden_tile = next(t for t in observed()["gridSlots"] if t["itemId"] == "__omaview_hidden")
    click(hidden_tile)
    wait_for(lambda: observed()["activeMenu"] == "__omaview_hidden")
    assert [r["appId"] for r in observed()["rows"]] == [test_app]
    click(observed()["gridSlots"][0], 273)
    assert [a["label"] for a in observed()["appMenu"]["actions"]] == ["Unhide app"]
    run("wtype", "-k", "Escape")
    assert observed()["activeMenu"] == "__omaview_hidden"
    print("PASS: launcher/dock context menus, dismissal, explicit pin actions, hiding, search exclusion, and Hidden submenu", flush=True)

    # Restart only this test shell to prove the saved order is loaded from disk.
    shell_process.terminate()
    shell_process.wait(timeout=5)
    shell_process = subprocess.Popen(shell_command, env=env, stdout=shell_log, stderr=shell_log)
    processes.append(shell_process)
    wait_for(lambda: subprocess.run(["omarchy-shell", "shell", "ping"], env=env,
              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0, timeout=15)
    wait_for(lambda: ipc("ping") == "ok", timeout=15)
    shell("summon", "turbinebmw.omaview", "{}")
    wait_for(lambda: observed()["opened"] and observed()["nativeReady"] and pinned_order() == reordered)
    assert observed()["hiddenApps"] == [test_app]
    run("wtype", "Omaview Dock two")
    assert observed()["rows"] == []
    run("wtype", "-k", "Escape")
    pointer_move(1, 1)
    for direction in ("Down", "Right"):
        for _ in range(len(observed()["rows"])):
            run("wtype", "-k", direction)
    wait_for(lambda: any(t["itemId"] == "__omaview_hidden" for t in observed()["gridSlots"]))
    time.sleep(.3)  # Let keyboard scrolling settle before clicking.
    hidden_tile = next(t for t in observed()["gridSlots"] if t["itemId"] == "__omaview_hidden")
    click(hidden_tile)
    wait_for(lambda: observed()["activeMenu"] == "__omaview_hidden")
    click(observed()["gridSlots"][0], 273)
    # Enter activates the context menu rather than launching the hidden app.
    run("wtype", "-k", "Return")
    wait_for(lambda: observed()["hiddenApps"] == [] and observed()["rows"] == [])
    wait_for(lambda: json.loads(hidden_file.read_text()) == [])
    assert observed()["opened"]
    run("wtype", "-k", "Escape")
    run("wtype", "Omaview Dock two")
    wait_for(lambda: [r["appId"] for r in observed()["rows"]] == [test_app])
    run("wtype", "-k", "Escape")
    print("PASS: hidden apps survive shell restart; Unhide restores launcher and search without launching", flush=True)
    running_slot = next(d for d in pinned_slots() if d["key"] == "omaview-dock-launch")
    pointer_move(*center(running_slot))
    pointer_button("down")
    pointer_move(center(running_slot)[0] + 1, center(running_slot)[1])
    pointer_button("up")
    wait_for(lambda: not observed()["opened"])
    assert json.loads(pin_file.read_text()) == reordered
    print("PASS: pin order survives shell restart; a small pointer movement still behaves as a normal click", flush=True)

    # A runtime change made while the overview is closed is refreshed on open.
    run("hyprctl", "eval", 'hl.config({decoration={rounding=24}})')
    shell("summon", "turbinebmw.omaview", '{"layout":"strip"}')
    wait_for(lambda: observed()["opened"] and observed()["nativeReady"] and observed()["rounding"] == 24)
    assert all(abs(w["radius"] - 24 * w["scale"]) < .001 for w in observed()["wallpapers"])
    assert all(p["radius"] > 0 for p in observed()["previews"])
    shell("hide", "turbinebmw.omaview")
    print("PASS: strip previews use the same rounding and pick up runtime changes on reopen", flush=True)
except Exception:
    for name in ("shell.log", "hyprland.log"):
        path = base / name
        if path.exists():
            print(name + ":\n" + path.read_text()[-6000:])
    raise
finally:
    if "pointer" in locals():
        pointer.close()
    for process in reversed(processes):
        process.terminate()
    for process in processes:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    server.terminate()
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
        server.wait()
    work.cleanup()
