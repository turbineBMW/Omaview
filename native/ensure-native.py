#!/usr/bin/python3
"""Build and load Omaview's native companion through a narrow trust boundary."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import stat
import subprocess
import sys


PLUGIN_VERSION = "1.1.3"
BUILD_RECIPE = "omaview-native-v2"
PACKAGES = (
    "hyprland",
    "pixman-1",
    "libdrm",
    "libinput",
    "libudev",
    "wayland-server",
    "xkbcommon",
    "lua",
)
BUILD_FLAGS = (
    "-shared",
    "-fPIC",
    "-fno-gnu-unique",
    "-fno-access-control",
    "-std=c++23",
    "-O2",
    "-Wall",
    "-Wextra",
)
TOOL_PATHS = {
    "compiler": "/usr/bin/g++",
    "hyprctl": "/usr/bin/hyprctl",
    "pkg_config": "/usr/bin/pkg-config",
}
PKG_CONFIG_LIBDIR = "/usr/lib/pkgconfig:/usr/share/pkgconfig"
MAX_METADATA_SIZE = 64 * 1024
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9._-]+$")
ARTIFACT_NAME = re.compile(r"^omaview-([0-9a-f]{64})\.so$")


class BootstrapError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise BootstrapError(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def hash_fd(fd: int) -> str:
    digest = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while chunk := os.read(fd, 1024 * 1024):
        digest.update(chunk)
    os.lseek(fd, 0, os.SEEK_SET)
    return digest.hexdigest()


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            fail("Cannot write cache metadata.")
        view = view[written:]


def trusted_system_location(path: Path, info: os.stat_result) -> bool:
    if info.st_uid == 0:
        return True
    # An unprivileged user namespace can map host root to the overflow UID.
    # Accept that representation only when the containing mount is read-only.
    return info.st_uid == 65534 and bool(os.statvfs(path).f_flag & os.ST_RDONLY)


def trusted_file(path: str, description: str) -> tuple[str, os.stat_result]:
    requested = Path(path)
    if not requested.is_absolute():
        fail(f"{description} path is not absolute.")
    try:
        resolved = requested.resolve(strict=True)
        info = resolved.stat()
    except OSError as error:
        fail(f"Cannot resolve trusted {description} {path}: {error.strerror}.")
    if not stat.S_ISREG(info.st_mode) or not trusted_system_location(resolved, info) or info.st_mode & 0o022:
        fail(f"Trusted {description} is not an immutable system regular file: {resolved}.")
    for parent in resolved.parents:
        parent_info = parent.stat()
        if (
            not stat.S_ISDIR(parent_info.st_mode)
            or not trusted_system_location(parent, parent_info)
            or parent_info.st_mode & 0o022
        ):
            fail(f"Trusted {description} has an unsafe parent directory: {parent}.")
        if parent == Path("/"):
            break
    return str(resolved), info


def clean_environment(include_hyprland: bool = False, temporary_directory: str | None = None) -> dict[str, str]:
    environment = {
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin",
        "PKG_CONFIG_LIBDIR": PKG_CONFIG_LIBDIR,
    }
    if temporary_directory:
        environment["TMPDIR"] = temporary_directory
    if include_hyprland:
        for key in ("HYPRLAND_INSTANCE_SIGNATURE", "XDG_RUNTIME_DIR"):
            value = os.environ.get(key)
            if value:
                environment[key] = value
    return environment


def run_checked(command: list[str], description: str, *, environment: dict[str, str]) -> bytes:
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail(f"{description} failed to start: {error}.")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        fail(f"{description} failed" + (f": {detail}" if detail else "."))
    return result.stdout


def read_json_command(command: list[str], description: str, *, environment: dict[str, str]):
    output = run_checked(command, description, environment=environment)
    try:
        return json.loads(output)
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail(f"{description} returned invalid JSON.")


def native_loaded(hyprctl: str, environment: dict[str, str]) -> bool:
    plugins = read_json_command(
        [hyprctl, "-j", "plugin", "list"],
        "Cannot contact the running Hyprland instance",
        environment=environment,
    )
    if not isinstance(plugins, list):
        fail("Hyprland returned an invalid plugin list.")
    versions = [
        entry.get("version")
        for entry in plugins
        if isinstance(entry, dict) and entry.get("name") == "omaview"
    ]
    if not versions:
        return False
    if versions[0] != PLUGIN_VERSION:
        fail("An older native companion is still loaded. Restart your Hyprland session to finish updating Omaview.")
    return True


def running_abi(hyprctl: str, environment: dict[str, str]) -> str:
    version = read_json_command(
        [hyprctl, "-j", "version"],
        "Cannot read the running Hyprland version",
        environment=environment,
    )
    abi = version.get("abiHash") if isinstance(version, dict) else None
    if not isinstance(abi, str) or not SAFE_COMPONENT.fullmatch(abi):
        fail("Hyprland does not expose a safe ABI identifier. This companion is tested with Hyprland 0.56.2.")
    return abi


def open_absolute_directory(path: Path, *, create: bool, uid: int) -> int:
    if not path.is_absolute() or ".." in path.parts:
        fail("The cache home must be an absolute path without parent traversal.")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    current = os.open("/", flags)
    try:
        for component in path.parts[1:]:
            if not component or component == ".":
                continue
            try:
                next_fd = os.open(component, flags, dir_fd=current)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(component, 0o700, dir_fd=current)
                except FileExistsError:
                    pass
                next_fd = os.open(component, flags, dir_fd=current)
            os.close(current)
            current = next_fd
        info = os.fstat(current)
        if info.st_uid != uid or info.st_mode & 0o022:
            fail("The cache home must be owned by the current user and not writable by group or others.")
        return current
    except BaseException:
        os.close(current)
        raise


def open_private_directory(parent_fd: int, name: str, uid: int) -> int:
    if not SAFE_COMPONENT.fullmatch(name) or name in (".", ".."):
        fail("Refusing an unsafe cache directory component.")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    try:
        directory_fd = os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        fail(f"Cannot open private cache directory {name}: {error.strerror}.")
    info = os.fstat(directory_fd)
    if info.st_uid != uid:
        os.close(directory_fd)
        fail(f"Private cache directory {name} is not owned by the current user.")
    permissions = stat.S_IMODE(info.st_mode)
    if permissions & 0o022:
        os.close(directory_fd)
        fail(f"Private cache directory {name} was writable by another user or group.")
    if permissions != 0o700:
        os.fchmod(directory_fd, 0o700)
    return directory_fd


def cache_root(uid: int) -> tuple[Path, int]:
    configured = os.environ.get("XDG_CACHE_HOME")
    if configured:
        base = Path(configured)
    else:
        try:
            base = Path(pwd.getpwuid(uid).pw_dir) / ".cache"
        except KeyError:
            fail("Cannot determine the current user's cache directory.")
    base_fd = open_absolute_directory(base, create=True, uid=uid)
    try:
        root_fd = open_private_directory(base_fd, "omaview", uid)
    finally:
        os.close(base_fd)
    return base / "omaview", root_fd


def open_regular(parent_fd: int, name: str, uid: int, *, writable: bool = False) -> int:
    flags = (os.O_RDWR if writable else os.O_RDONLY) | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open(name, flags, dir_fd=parent_fd)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1:
        os.close(descriptor)
        fail(f"Cache entry {name} is not a private regular file.")
    return descriptor


def exclusive_file(parent_fd: int, suffix: str, mode: int = 0o600) -> tuple[str, int]:
    for _ in range(32):
        name = f".omaview-{secrets.token_hex(16)}{suffix}"
        try:
            descriptor = os.open(
                name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                mode,
                dir_fd=parent_fd,
            )
            return name, descriptor
        except FileExistsError:
            continue
    fail("Cannot reserve an exclusive native build file.")


def read_small_file(parent_fd: int, name: str, uid: int) -> bytes:
    descriptor = open_regular(parent_fd, name, uid)
    try:
        if stat.S_IMODE(os.fstat(descriptor).st_mode) != 0o600:
            fail(f"Cache metadata {name} does not have private permissions.")
        data = os.read(descriptor, MAX_METADATA_SIZE + 1)
        if len(data) > MAX_METADATA_SIZE:
            fail(f"Cache metadata {name} is too large.")
        return data
    finally:
        os.close(descriptor)


def package_inputs(pkg_config: str, environment: dict[str, str]) -> tuple[list[str], list[dict[str, str]]]:
    missing = []
    details = []
    for package in PACKAGES:
        result = subprocess.run(
            [pkg_config, "--exists", package],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=environment,
            check=False,
        )
        if result.returncode != 0:
            missing.append(package)
            continue
        version = run_checked(
            [pkg_config, "--modversion", package],
            f"Cannot identify {package}",
            environment=environment,
        ).decode().strip()
        pc_path = run_checked(
            [pkg_config, "--path", package],
            f"Cannot locate {package} metadata",
            environment=environment,
        ).decode().strip()
        resolved_pc, _ = trusted_file(pc_path, f"{package} pkg-config metadata")
        details.append({
            "name": package,
            "version": version,
            "metadataPath": resolved_pc,
            "metadataSha256": sha256_bytes(Path(resolved_pc).read_bytes()),
        })
    if missing:
        fail(
            "Missing development files: "
            + " ".join(missing)
            + ". Install the corresponding packages for your distribution."
        )
    raw_flags = run_checked(
        [pkg_config, "--cflags", *PACKAGES],
        "Cannot read native build flags",
        environment=environment,
    ).decode("utf-8", "strict").strip()
    return shlex.split(raw_flags), details


def build_identity(
    source_sha: str,
    abi: str,
    compiler: str,
    pkg_config: str,
    compiler_flags: list[str],
    packages: list[dict[str, str]],
) -> dict:
    compiler_version = run_checked(
        [compiler, "--version"],
        "Cannot identify the compiler",
        environment=clean_environment(),
    ).decode("utf-8", "replace").splitlines()[0]
    python_path, _ = trusted_file(sys.executable, "Python interpreter")
    compiler_components = []
    for component in ("cc1plus", "as", "ld"):
        reported = run_checked(
            [compiler, f"-print-prog-name={component}"],
            f"Cannot locate compiler component {component}",
            environment=clean_environment(),
        ).decode("utf-8", "strict").strip()
        candidate = Path(reported)
        if not candidate.is_absolute():
            if candidate.name != reported or reported in ("", ".", ".."):
                fail(f"Compiler returned an unsafe path for {component}.")
            candidate = Path("/usr/bin") / reported
        component_path, _ = trusted_file(str(candidate), f"compiler component {component}")
        compiler_components.append({
            "name": component,
            "path": component_path,
            "sha256": sha256_bytes(Path(component_path).read_bytes()),
        })
    return {
        "recipe": BUILD_RECIPE,
        "sourceSha256": source_sha,
        "hyprlandAbi": abi,
        "compiler": {
            "path": compiler,
            "sha256": sha256_bytes(Path(compiler).read_bytes()),
            "version": compiler_version,
            "components": compiler_components,
        },
        "python": {
            "path": python_path,
            "sha256": sha256_bytes(Path(python_path).read_bytes()),
        },
        "pkgConfig": {
            "path": pkg_config,
            "sha256": sha256_bytes(Path(pkg_config).read_bytes()),
            "libdir": PKG_CONFIG_LIBDIR,
        },
        "packages": packages,
        "pkgConfigFlags": compiler_flags,
        "buildFlags": list(BUILD_FLAGS),
    }


def identity_digest(identity: dict) -> str:
    encoded = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    return sha256_bytes(encoded)


def cached_artifact(build_fd: int, uid: int, expected_identity: dict, expected_digest: str) -> tuple[int, str] | None:
    try:
        raw_manifest = read_small_file(build_fd, "binding.json", uid)
    except (OSError, BootstrapError):
        return None
    try:
        manifest = json.loads(raw_manifest)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(manifest, dict):
        return None
    if (
        manifest.get("schema") != 1
        or manifest.get("inputDigest") != expected_digest
        or manifest.get("inputs") != expected_identity
    ):
        return None
    artifact = manifest.get("artifact")
    name = artifact.get("file") if isinstance(artifact, dict) else None
    match = ARTIFACT_NAME.fullmatch(name) if isinstance(name, str) else None
    if not match or artifact.get("sha256") != match.group(1):
        return None
    try:
        descriptor = open_regular(build_fd, name, uid)
    except (OSError, BootstrapError):
        return None
    info = os.fstat(descriptor)
    if (
        stat.S_IMODE(info.st_mode) != 0o400
        or info.st_size <= 0
        or artifact.get("size") != info.st_size
        or hash_fd(descriptor) != artifact["sha256"]
    ):
        os.close(descriptor)
        return None
    return descriptor, name


def write_manifest(
    build_fd: int,
    identity: dict,
    digest: str,
    artifact_name: str,
    artifact_sha: str,
    artifact_size: int,
) -> None:
    manifest = {
        "schema": 1,
        "inputDigest": digest,
        "inputs": identity,
        "artifact": {"file": artifact_name, "sha256": artifact_sha, "size": artifact_size},
    }
    encoded = (json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n").encode()
    temporary_name, descriptor = exclusive_file(build_fd, ".json")
    try:
        write_all(descriptor, encoded)
        os.fchmod(descriptor, 0o600)
        os.fsync(descriptor)
        os.replace(temporary_name, "binding.json", src_dir_fd=build_fd, dst_dir_fd=build_fd)
        os.fsync(build_fd)
    finally:
        os.close(descriptor)
        try:
            os.unlink(temporary_name, dir_fd=build_fd)
        except FileNotFoundError:
            pass


def compile_artifact(
    build_path: Path,
    build_fd: int,
    uid: int,
    source_fd: int,
    compiler: str,
    compiler_flags: list[str],
    identity: dict,
    digest: str,
) -> tuple[int, str]:
    temporary_name, output_fd = exclusive_file(build_fd, ".so")
    source_reference = f"/proc/{os.getpid()}/fd/{source_fd}"
    output_reference = f"/proc/{os.getpid()}/fd/{output_fd}"
    environment = clean_environment(temporary_directory=str(build_path))
    try:
        run_checked(
            [compiler, *BUILD_FLAGS, *compiler_flags, "-x", "c++", source_reference, "-o", output_reference],
            "Native build",
            environment=environment,
        )
        os.fsync(output_fd)
        info = os.fstat(output_fd)
        if info.st_size <= 0:
            fail("Native build produced an empty artifact.")
        os.lseek(output_fd, 0, os.SEEK_SET)
        if os.read(output_fd, 4) != b"\x7fELF":
            fail("Native build did not produce an ELF shared object.")
        artifact_sha = hash_fd(output_fd)
        artifact_name = f"omaview-{artifact_sha}.so"
        os.fchmod(output_fd, 0o400)
        os.fsync(output_fd)
        os.replace(temporary_name, artifact_name, src_dir_fd=build_fd, dst_dir_fd=build_fd)
        temporary_name = ""
        os.fsync(build_fd)
        write_manifest(build_fd, identity, digest, artifact_name, artifact_sha, info.st_size)
    finally:
        os.close(output_fd)
        if temporary_name:
            try:
                os.unlink(temporary_name, dir_fd=build_fd)
            except FileNotFoundError:
                pass
    cached = cached_artifact(build_fd, uid, identity, digest)
    if cached is None:
        fail("The newly built native artifact failed verification.")
    return cached


def source_descriptor() -> tuple[int, str]:
    source_path = Path(__file__).resolve().with_name("omaview.cpp")
    try:
        descriptor = os.open(source_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        fail(f"Cannot open the reviewed native source: {error.strerror}.")
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode):
        os.close(descriptor)
        fail("The reviewed native source is not a regular file.")
    return descriptor, hash_fd(descriptor)


def main() -> int:
    uid = os.getuid()
    compiler, _ = trusted_file(TOOL_PATHS["compiler"], "compiler")
    hyprctl, _ = trusted_file(TOOL_PATHS["hyprctl"], "Hyprland controller")
    pkg_config, _ = trusted_file(TOOL_PATHS["pkg_config"], "pkg-config")
    hypr_environment = clean_environment(include_hyprland=True)
    if native_loaded(hyprctl, hypr_environment):
        return 0

    abi = running_abi(hyprctl, hypr_environment)
    compiler_flags, packages = package_inputs(pkg_config, clean_environment())
    source_fd, source_sha = source_descriptor()
    root_fd = abi_fd = build_fd = lock_fd = artifact_fd = -1
    try:
        identity = build_identity(source_sha, abi, compiler, pkg_config, compiler_flags, packages)
        digest = identity_digest(identity)
        root_path, root_fd = cache_root(uid)
        abi_fd = open_private_directory(root_fd, abi, uid)
        build_fd = open_private_directory(abi_fd, digest, uid)
        build_path = root_path / abi / digest
        try:
            lock_fd = os.open(
                "build.lock",
                os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC,
                0o600,
                dir_fd=build_fd,
            )
        except OSError as error:
            fail(f"Cannot open the native build lock: {error.strerror}.")
        lock_info = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != uid or lock_info.st_nlink != 1:
            fail("The native build lock is not a private regular file.")
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)

        if native_loaded(hyprctl, hypr_environment):
            return 0
        cached = cached_artifact(build_fd, uid, identity, digest)
        if cached is None:
            cached = compile_artifact(build_path, build_fd, uid, source_fd, compiler, compiler_flags, identity, digest)
        artifact_fd, _ = cached

        # Hyprland opens this exact verified inode while the descriptor remains
        # held, so a pathname replacement cannot change what gets loaded.
        artifact_reference = f"/proc/{os.getpid()}/fd/{artifact_fd}"
        reply = run_checked(
            [hyprctl, "plugin", "load", artifact_reference],
            "Hyprland could not load its companion",
            environment=hypr_environment,
        ).decode("utf-8", "replace").strip()
        if reply != "ok":
            fail(reply or "Hyprland rejected its native companion.")
        return 0
    finally:
        for descriptor in (artifact_fd, lock_fd, build_fd, abi_fd, root_fd, source_fd):
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                except OSError:
                    pass


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BootstrapError as error:
        print(f"Omaview: {error}", file=sys.stderr)
        raise SystemExit(1)
    except (OSError, ValueError) as error:
        print(f"Omaview: secure native bootstrap failed: {error}", file=sys.stderr)
        raise SystemExit(1)
