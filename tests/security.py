"""Focused regression checks for the native bootstrap trust boundary."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


PLUGIN = Path(__file__).resolve().parents[1]
BOOTSTRAP_PATH = PLUGIN / "native/ensure-native.py"
SPEC = importlib.util.spec_from_file_location("omaview_native_bootstrap", BOOTSTRAP_PATH)
BOOTSTRAP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOOTSTRAP)


class NativeBootstrapSecurityTests(unittest.TestCase):
    def test_subprocess_environment_is_an_allowlist(self):
        poisoned = {
            "BASH_ENV": "/tmp/attacker",
            "LD_PRELOAD": "/tmp/attacker.so",
            "COMPILER_PATH": "/tmp/attacker",
            "CPATH": "/tmp/attacker",
            "PKG_CONFIG_PATH": "/tmp/attacker",
        }
        previous = {key: os.environ.get(key) for key in poisoned}
        try:
            os.environ.update(poisoned)
            environment = BOOTSTRAP.clean_environment()
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        self.assertEqual(
            environment,
            {
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin",
                "PKG_CONFIG_LIBDIR": "/usr/lib/pkgconfig:/usr/share/pkgconfig",
            },
        )

    def test_tool_paths_are_absolute_and_trusted(self):
        for name, path in BOOTSTRAP.TOOL_PATHS.items():
            self.assertTrue(Path(path).is_absolute())
            resolved, info = BOOTSTRAP.trusted_file(path, name)
            self.assertTrue(Path(resolved).is_file())
            self.assertTrue(BOOTSTRAP.trusted_system_location(Path(resolved), info))
            self.assertFalse(info.st_mode & 0o022)

    def test_cache_root_rejects_a_symlink(self):
        uid = os.getuid()
        with tempfile.TemporaryDirectory(prefix="omaview-cache-test-") as temporary:
            base = Path(temporary)
            target = base / "target"
            target.mkdir()
            (base / "omaview").symlink_to(target, target_is_directory=True)
            old_cache = os.environ.get("XDG_CACHE_HOME")
            os.environ["XDG_CACHE_HOME"] = str(base)
            try:
                with self.assertRaises(BOOTSTRAP.BootstrapError):
                    BOOTSTRAP.cache_root(uid)
                (base / "omaview").unlink()
                (base / "omaview").mkdir(mode=0o777)
                (base / "omaview").chmod(0o777)
                with self.assertRaises(BOOTSTRAP.BootstrapError):
                    BOOTSTRAP.cache_root(uid)
            finally:
                if old_cache is None:
                    os.environ.pop("XDG_CACHE_HOME", None)
                else:
                    os.environ["XDG_CACHE_HOME"] = old_cache

    def test_tampered_or_linked_artifact_is_not_reused(self):
        uid = os.getuid()
        identity = {"recipe": "test", "sourceSha256": "1" * 64}
        digest = BOOTSTRAP.identity_digest(identity)
        with tempfile.TemporaryDirectory(prefix="omaview-artifact-test-") as temporary:
            directory_fd = os.open(temporary, os.O_RDONLY | os.O_DIRECTORY)
            artifact_name = "omaview-" + BOOTSTRAP.sha256_bytes(b"artifact") + ".so"
            artifact_path = Path(temporary) / artifact_name
            artifact_path.write_bytes(b"artifact")
            artifact_path.chmod(0o400)
            BOOTSTRAP.write_manifest(
                directory_fd,
                identity,
                digest,
                artifact_name,
                BOOTSTRAP.sha256_bytes(b"artifact"),
                len(b"artifact"),
            )
            cached = BOOTSTRAP.cached_artifact(directory_fd, uid, identity, digest)
            self.assertIsNotNone(cached)
            os.close(cached[0])

            artifact_path.chmod(0o600)
            artifact_path.write_bytes(b"tampered")
            artifact_path.chmod(0o400)
            self.assertIsNone(BOOTSTRAP.cached_artifact(directory_fd, uid, identity, digest))

            artifact_path.unlink()
            artifact_path.symlink_to("/etc/passwd")
            self.assertIsNone(BOOTSTRAP.cached_artifact(directory_fd, uid, identity, digest))
            os.close(directory_fd)

    def test_qml_clears_bootstrap_environment_and_bounds_collectors(self):
        qml = (PLUGIN / "Omaview.qml").read_text()
        self.assertIn("clearEnvironment: true", qml)
        self.assertIn('["/usr/bin/python3", "-I", "-S"', qml)
        self.assertIn("collectorCharacterLimit: 262144", qml)
        self.assertIn("target.signal(9)", qml)
        self.assertEqual(qml.count('splitMarker: ""'), 2)
        self.assertNotIn("collected += data", qml)


if __name__ == "__main__":
    unittest.main()
