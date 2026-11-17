#!/usr/bin/python3
"""Ask the desktop's file chooser for an image file and print its path.

    pick-image.py <title> [<folder>]

The dialog comes from xdg-desktop-portal's FileChooser, so it is the file
chooser the desktop provides (GTK on Omarchy), filtered to image files and
opened in <folder> when one is given. The chosen path is printed on stdout.
Exits 0 with a path, 1 when the dialog is cancelled, and 2 when the portal
cannot be reached or fails.
"""

from __future__ import annotations

import os
import sys

# Python exits 1 on an uncaught error, which Omaview reads as a cancelled
# dialog; a missing PyGObject must report a failure (2) instead.
try:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib  # noqa: E402
except (ImportError, ValueError) as error:
    print(f"PyGObject (python-gobject) is not available: {error}", file=sys.stderr)
    raise SystemExit(2)

PORTAL = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
REQUEST = "org.freedesktop.portal.Request"
IMAGE_TYPES = ["image/png", "image/svg+xml", "image/svg+xml-compressed", "image/jpeg",
               "image/webp", "image/x-xpixmap", "image/vnd.microsoft.icon", "image/bmp"]


class PickError(RuntimeError):
    pass


def pick(title: str, folder: str) -> str | None:
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error as error:
        raise PickError(f"No session bus: {error.message}") from error
    token = f"omaview{os.getpid()}"
    sender = bus.get_unique_name().lstrip(":").replace(".", "_")
    loop = GLib.MainLoop()
    answer: dict = {}

    def on_response(_bus, _sender, _path, _interface, _signal, parameters):
        answer["code"], answer["results"] = parameters.unpack()
        loop.quit()

    def subscribe(path: str) -> int:
        return bus.signal_subscribe(None, REQUEST, "Response", path, None,
                                    Gio.DBusSignalFlags.NONE, on_response)

    # Subscribe before calling so a fast answer cannot be missed.
    expected = f"{PORTAL_PATH}/request/{sender}/{token}"
    subscription = subscribe(expected)
    options = {
        "handle_token": GLib.Variant("s", token),
        "modal": GLib.Variant("b", True),
        "filters": GLib.Variant("a(sa(us))", [("Images", [(1, kind) for kind in IMAGE_TYPES])]),
    }
    if folder and os.path.isdir(folder):
        options["current_folder"] = GLib.Variant("ay", os.fsencode(folder) + b"\0")
    try:
        reply = bus.call_sync(PORTAL, PORTAL_PATH, "org.freedesktop.portal.FileChooser", "OpenFile",
                              GLib.Variant("(ssa{sv})", ("", title, options)),
                              GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, -1, None)
    except GLib.Error as error:
        raise PickError(f"The file chooser portal is unavailable: {error.message}") from error
    handle = reply.unpack()[0]
    if handle != expected:
        # Portals older than handle_token support pick their own path.
        bus.signal_unsubscribe(subscription)
        subscribe(handle)
    loop.run()

    if answer["code"] == 1:
        return None
    uris = answer["results"].get("uris") or []
    if answer["code"] != 0 or not uris:
        raise PickError("The file chooser did not return a file.")
    try:
        return GLib.filename_from_uri(uris[0])[0]
    except GLib.Error as error:
        raise PickError(f"{uris[0]} is not a local file.") from error


def main(argv: list[str]) -> int:
    if len(argv) not in (1, 2):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = pick(argv[0], argv[1] if len(argv) == 2 else "")
    if path is None:
        return 1
    print(path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except PickError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
    except Exception as error:  # Never let a crash exit 1 and pass for a cancel.
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(2)
