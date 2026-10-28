#!/usr/bin/python3
"""Change the icon of a desktop entry through a user-local override.

    set-icon.py set <desktop-id> <icon>     set Icon= (a theme name or an image path)
    set-icon.py reset <desktop-id>          restore the icon Omaview replaced
    set-icon.py list                        print the ids whose icon Omaview replaced

An entry that only exists in a system directory (/usr/share/applications and
the other XDG_DATA_DIRS) is first cloned into XDG_DATA_HOME/applications at the
same relative path, so it keeps its id and shadows the system file. The
original icon is kept in the [Desktop Entry] group as X-Omaview-Icon-Original so
that reset can restore it; a clone that then matches the system file again is
removed. Only the Icon key of the main group is edited; actions, localized
keys and comments are left as they are.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import sys
import tempfile

MARKER = "X-Omaview-Icon-Original"
GROUP = "[Desktop Entry]"
KEY = re.compile(r"^(\s*)([A-Za-z0-9-]+)(\s*=\s*)(.*)$")


class IconError(RuntimeError):
    pass


def data_home() -> Path:
    value = os.environ.get("XDG_DATA_HOME", "")
    return Path(value) if value else Path.home() / ".local/share"


def data_dirs() -> list[Path]:
    value = os.environ.get("XDG_DATA_DIRS", "") or "/usr/local/share:/usr/share"
    return [Path(part) for part in value.split(":") if part]


def entry_id(relative: Path) -> str:
    return "-".join(relative.with_suffix("").parts)


def find_entry(root: Path, desktop_id: str) -> Path | None:
    if not root.is_dir():
        return None
    for path in sorted(root.rglob("*.desktop")):
        if path.is_file() and entry_id(path.relative_to(root)) == desktop_id:
            return path
    return None


def main_group(lines: list[str]) -> tuple[int, int]:
    """Line range [start, end) of the [Desktop Entry] group's body."""
    start = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if start is None:
            if stripped == GROUP:
                start = index + 1
        elif stripped.startswith("[") and stripped.endswith("]"):
            return start, index
    if start is None:
        raise IconError("The desktop entry has no [Desktop Entry] group.")
    return start, len(lines)


def find_key(lines: list[str], start: int, end: int, key: str) -> int:
    for index in range(start, end):
        match = KEY.match(lines[index])
        if match and match.group(2) == key:
            return index
    return -1


def set_key(lines: list[str], key: str, value: str) -> None:
    start, end = main_group(lines)
    at = find_key(lines, start, end, key)
    if at >= 0:
        lines[at] = f"{key}={value}"
        return
    # Insert after the last key of the group, before trailing blank lines.
    insert = end
    while insert > start and not lines[insert - 1].strip():
        insert -= 1
    lines.insert(insert, f"{key}={value}")


def get_key(lines: list[str], key: str) -> str | None:
    start, end = main_group(lines)
    at = find_key(lines, start, end, key)
    if at < 0:
        return None
    return KEY.match(lines[at]).group(4).strip()


def remove_key(lines: list[str], key: str) -> None:
    start, end = main_group(lines)
    at = find_key(lines, start, end, key)
    if at >= 0:
        del lines[at]


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8").split("\n")
    except OSError as error:
        raise IconError(f"Cannot read {path}: {error.strerror}.") from error
    except UnicodeDecodeError as error:
        raise IconError(f"{path} is not UTF-8 text.") from error


def write_lines(path: Path, lines: list[str]) -> None:
    text = "\n".join(lines)
    if not text.endswith("\n"):
        text += "\n"
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".omaview-", suffix=".tmp", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(text)
            os.chmod(temporary, 0o644)
            os.replace(temporary, path)
        except BaseException:
            os.unlink(temporary)
            raise
    except OSError as error:
        raise IconError(f"Cannot write {path}: {error.strerror}.") from error


def local_root() -> Path:
    return data_home() / "applications"


def system_entry(desktop_id: str) -> Path | None:
    for directory in data_dirs():
        found = find_entry(directory / "applications", desktop_id)
        if found:
            return found
    return None


def valid_icon(value: str) -> str:
    icon = value.strip()
    if not icon or "\n" in icon:
        raise IconError("An icon name or image path is required.")
    if icon.startswith("~/"):
        icon = str(Path.home() / icon[2:])
    if icon.startswith("/"):
        if not Path(icon).is_file():
            raise IconError(f"No image file at {icon}.")
    elif "/" in icon:
        raise IconError("Use a theme icon name, or an absolute image path.")
    return icon


def set_icon(desktop_id: str, value: str) -> None:
    icon = valid_icon(value)
    local = find_entry(local_root(), desktop_id)
    if local:
        path, lines = local, read_lines(local)
    else:
        source = system_entry(desktop_id)
        if not source:
            raise IconError(f"No desktop entry named {desktop_id} was found.")
        root = next(d / "applications" for d in data_dirs() if source.is_relative_to(d / "applications"))
        path = local_root() / source.relative_to(root)
        lines = read_lines(source)
    if get_key(lines, MARKER) is None:
        set_key(lines, MARKER, get_key(lines, "Icon") or "")
    set_key(lines, "Icon", icon)
    write_lines(path, lines)


def reset_icon(desktop_id: str) -> None:
    local = find_entry(local_root(), desktop_id)
    if not local:
        raise IconError(f"{desktop_id} has no custom icon.")
    lines = read_lines(local)
    original = get_key(lines, MARKER)
    if original is None:
        raise IconError(f"The icon of {desktop_id} was not set by Omaview.")
    remove_key(lines, MARKER)
    if original:
        set_key(lines, "Icon", original)
    else:
        remove_key(lines, "Icon")
    source = system_entry(desktop_id)
    if source and read_lines(source) == lines:
        try:
            local.unlink()
        except OSError as error:
            raise IconError(f"Cannot remove {local}: {error.strerror}.") from error
        return
    write_lines(local, lines)


def list_overrides() -> None:
    root = local_root()
    if not root.is_dir():
        return
    for path in sorted(root.rglob("*.desktop")):
        if not path.is_file():
            continue
        try:
            lines = read_lines(path)
            if get_key(lines, MARKER) is not None:
                print(entry_id(path.relative_to(root)))
        except IconError:
            continue


def main(argv: list[str]) -> int:
    if len(argv) == 1 and argv[0] == "list":
        list_overrides()
        return 0
    if len(argv) == 2 and argv[0] == "reset":
        reset_icon(argv[1])
        return 0
    if len(argv) == 3 and argv[0] == "set":
        set_icon(argv[1], argv[2])
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except IconError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
