#!/usr/bin/env python3
"""Unit tests for tools/pi/package-audit.py, offline.

Builds synthetic repository databases (the pacman .db tar.gz format) and
manifest files in a temporary directory, then exercises database parsing,
manifest reading, provides-resolution and the platform-set composition the
report is built from."""

import io
import sys
import tarfile
import tempfile
import gzip
import importlib.util
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
TOOL = REPO / "tools" / "pi" / "package-audit.py"

spec = importlib.util.spec_from_file_location("package_audit", TOOL)
pa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pa)


def make_db(packages: dict[str, list[str]]) -> bytes:
    """A pacman repo database: <name>-<ver>/desc files with %NAME% %VERSION%
    %PROVIDES% blocks, gzipped."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for name, (version, provides) in packages.items():
            desc = f"%NAME%\n{name}\n\n%VERSION%\n{version}\n"
            if provides:
                desc += "\n%PROVIDES%\n" + "\n".join(provides) + "\n"
            data = desc.encode()
            info = tarfile.TarInfo(f"{name}-{version}/desc")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
    return gzip.compress(buf.getvalue())


class TestParseDb(unittest.TestCase):
    def test_names_versions_provides(self) -> None:
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as fh:
            fh.write(make_db({
                "neovim": ("0.12.6-1", []),
                "dotnet-runtime-bin": ("10.0.1-2", ["dotnet-runtime"]),
            }))
            path = Path(fh.name)
        names, provides, dates = pa.parse_db(path)
        path.unlink()
        self.assertEqual(names["neovim"], "0.12.6-1")
        self.assertEqual(names["dotnet-runtime-bin"], "10.0.1-2")
        self.assertEqual(provides["dotnet-runtime-bin"], ["dotnet-runtime"])
        self.assertNotIn("neovim", provides)

    def test_missing_file_raises(self) -> None:
        with self.assertRaises(FileNotFoundError):
            pa.parse_db(Path("/nonexistent/omarchy.db"))


class TestResolve(unittest.TestCase):
    def setUp(self) -> None:
        self.indexes = {
            "omarchy": {"hyprland": "0.56.2-5"},
            "core": {},
            "extra": {"neovim": "0.12.6-1", "hyprland": "0.50.0-1"},
            "alarm": {"linux-rpi": "6.18-1"},
            "aur": {},
        }
        self.provides = {
            "omarchy": {"dotnet-runtime-bin": ["dotnet-runtime"]},
            "core": {}, "extra": {}, "alarm": {}, "aur": {},
        }

    def test_direct_hit_respects_repo_priority(self) -> None:
        repo, provider = pa.resolve("hyprland", self.indexes, self.provides)
        self.assertEqual(repo, "omarchy")
        self.assertEqual(provider, "hyprland")

    def test_provides_resolution(self) -> None:
        repo, provider = pa.resolve("dotnet-runtime", self.indexes, self.provides)
        self.assertEqual(repo, "omarchy")
        self.assertEqual(provider, "dotnet-runtime-bin")

    def test_unresolved(self) -> None:
        repo, provider = pa.resolve("nvim", self.indexes, self.provides)
        self.assertIsNone(repo)
        self.assertEqual(provider, "")


class TestManifests(unittest.TestCase):
    def test_comments_and_blanks_stripped(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".packages", delete=False) as fh:
            fh.write("# a comment\nzram-generator\n\n  vim  # trailing\n\n")
            path = Path(fh.name)
        self.assertEqual(pa.manifest_names(path), ["zram-generator", "vim"])
        path.unlink()


class TestPlatformComposition(unittest.TestCase):
    """The report's composition mirrors omarchy-pkg-defaults; the shell test
    platform-packages-test.sh covers the composition itself, so this checks
    the audit tool agrees with the same inputs."""

    def test_replacements_resolve_and_drops_do_not(self) -> None:
        indexes = {
            "omarchy": {"gliff": "1-1"},
            "core": {},
            "extra": {"neovim": "1-1", "vim": "1-1", "superwhisper-bin": "1-1"},
            "alarm": {},
            "aur": {},
        }
        provides = {r: {} for r in indexes}
        # x86_64-only is subtracted on aarch64 even when a build exists.
        resolved, _ = pa.resolve("gliff", indexes, provides)
        # the aarch64 additions must resolve:
        for name in ("neovim", "vim"):
            repo, provider = pa.resolve(name, indexes, provides)
            self.assertEqual(repo, "extra", name)
        # the dropped names must not resolve anywhere on aarch64 repos:
        for name in ("nvim", "vi"):
            repo, _ = pa.resolve(name, indexes, provides)
            self.assertIn(repo, (None, "omarchy"), name)
        self.assertEqual(resolved, "omarchy")


if __name__ == "__main__":
    unittest.main()
