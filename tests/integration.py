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

plugin = Path(__file__).resolve().parents[1]

if os.environ.get("OMAVIEW_TEST_ISOLATED") != "1":
    for command in ("bwrap", "dbus-run-session", "git", "Hyprland", "qs", "foot", "wtype"):
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
hl.config({general={layout="scrolling"}, input={resolve_binds_by_sym=true}, animations={enabled=false}, misc={disable_hyprland_logo=true, disable_splash_rendering=true}, ecosystem={no_update_news=true, no_donation_nag=true}})
hl.bind("SUPER + Left", hl.dsp.layout("focus l"))
hl.bind("SUPER + SPACE", function()
    hl.exec_cmd("omarchy-shell shell toggle turbinebmw.omaview '{}'")
end)
""")
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
    time.sleep(.5)
    assert run("hyprctl", "eval", "assert(not pcall(require, 'hypr.layout_aware')); assert(not pcall(require, 'hypr.dynamic_workspaces'))") == "ok"
    assert json.loads(run("hyprctl", "-j", "plugin", "list")) == []
    for name in ("a", "b", "c"):
        processes.append(subprocess.Popen(["foot", "-a", "omaview-test-" + name,
            "-T", "Omaview test " + name, "sleep", "600"], env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(.2)
    shell_log = (base / "shell.log").open("w")
    processes.append(subprocess.Popen(["qs", "-p", os.environ.get("OMARCHY_PATH", "/usr/share/omarchy") + "/shell"],
                                      env=env, stdout=shell_log, stderr=shell_log))
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
    run("wtype", "-M", "logo", "-k", "space", "-m", "logo")
    wait_for(lambda: observed()["opened"] and observed()["nativeReady"] and observed()["clients"], timeout=30)
    assert len(list((Path.home() / ".cache/omaview").rglob("omaview.so"))) == 1
    wait_for(matches_focus)
    print("PASS: actual plugin install, enable, keybind, and automatic build with an empty home/cache", flush=True)

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

    run("wtype", "-M", "ctrl", "-k", "Down", "-m", "ctrl")
    wait_for(lambda: observed()["workspace"] == 2)
    assert compositor()["activewindow"] == {}
    for _ in range(3):
        run("wtype", "-M", "ctrl", "-k", "Down", "-m", "ctrl")
    run("wtype", "q")
    wait_for(lambda: observed()["filter"] == "zzzzq")
    assert observed()["workspace"] == 2
    assert max(w["id"] for w in compositor()["workspaces"]) == 2
    run("wtype", "-M", "ctrl", "-k", "Up", "-m", "ctrl")
    wait_for(lambda: observed()["workspace"] == 1)
    print("PASS: native workspace navigation and a single trailing empty workspace", flush=True)

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
    binary = next((Path.home() / ".cache/omaview").rglob("omaview.so"))
    mtime = binary.stat().st_mtime_ns
    shell("summon", "turbinebmw.omaview", "{}")
    wait_for(lambda: observed()["nativeReady"] and observed()["opened"])
    assert binary.stat().st_mtime_ns == mtime
    shell("hide", "turbinebmw.omaview")
    assert run("hyprctl", "configerrors") == ""
    assert not (Path.home() / ".config/hypr").exists()
    print("PASS: close/reopen preserves focus and reuses the compiled companion; no Hyprland config installed", flush=True)
except Exception:
    for name in ("shell.log", "hyprland.log"):
        path = base / name
        if path.exists():
            print(name + ":\n" + path.read_text()[-6000:])
    raise
finally:
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
