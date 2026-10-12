#!/usr/bin/env python3
"""Build the fork's omarchy-dev package for aarch64 from this git tree.

The canonical packaging spec is upstream's released PKGBUILD
(omacom/omarchy-pkgs, pkgbuilds/omarchy/PKGBUILD, _commit c668141e). This
builder reproduces that PKGBUILD's package() rules on hosts without makepkg
(the Pi port's development container has no pacman), naming and versioning the
result like upstream's dev-channel pair so pacman orders it against the
published [omarchy] repository honestly:

  name     omarchy-dev
  version  4.0.0.r<git-rev-count>.g<short-sha>-1
  provides omarchy, conflicts omarchy

omarchy-settings-dev is NOT rebuilt here: this fork ships no changes under
default/, so upstream's published settings-dev package stays authoritative.

Dependencies mirror the published omarchy-dev aarch64 pair minus
omarchy-security-functions, which the [omarchy] edge aarch64 repository has not
published at audit time (upstream packaging work in progress; the script itself
ships in bin/ here exactly as the release recipe ships it). See
docs/pi/porting-decisions.md D8.

Reproducibility: every archive entry carries the source commit's timestamp
(like SOURCE_DATE_EPOCH), uid/gid 0 with uname/gname root, PAX tar format and
zstd level 3 (makepkg's default), and entries are emitted in a deterministic
order. Two builds from the same commit produce identical bytes.

Layout produced (mirrors the unpacked upstream omarchy 4.0.4-2 aarch64
package, verified against it during development):

  .BUILDINFO .MTREE .PKGINFO
  etc/skel/.local/state/omarchy/migrations/<migration>.sh   (empty markers)
  usr/bin/<command>                                          (bin/ minus debug helpers)
  usr/share/libalpm/hooks/{00,10,90}-omarchy-*.hook
  usr/share/omarchy/{bin->/usr/bin symlinks,install,themes,migrations,shell,version}

Usage: tools/pi/build-package.py [--output-dir dist] [--arch aarch64]
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import subprocess
import sys
import tarfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent

SKIP_BINS = {"omarchy-debug", "omarchy-debug-idle", "omarchy-upload-log"}
SHIP_HOOKS = [
    "00-omarchy-update-guard.hook",
    "10-omarchy-hyprland-reload-pause.hook",
    "90-omarchy-hyprland-reload-resume.hook",
]
DEPENDS = [
    "omarchy-keyring",
    "omarchy-settings-dev",
    "hyprland",
    "quickshell",
    "uwsm",
    "sddm",
    "xdg-desktop-portal-hyprland",
    "wireplumber",
    "pipewire",
    "gnome-keyring",
    "gum",
    "jq",
    "git",
    "perl",
    "fakeroot",
    "pacman-contrib",
    "ttf-jetbrains-mono-nerd-basic",
    "networkmanager",
]


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(REPO), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def git_modes() -> dict[str, int]:
    """File path -> mode (0o644 / 0o755) exactly as git tracks it."""
    modes = {}
    out = git("ls-tree", "-r", "HEAD")
    for line in out.splitlines():
        meta, path = line.split("\t", 1)
        _mode, otype, _sha = meta.split()
        if otype == "blob":
            modes[path] = int(_mode, 8) & 0o777
    return modes


def build_entries(epoch: int, modes: dict[str, int]) -> list[dict]:
    """The package payload as an ordered list of entry dicts.

    Order: package metadata first, then the tree lexicographically (which is
    parent-dir-first for prefixed paths, matching the reference package).
    """
    entries: list[dict] = []

    def add_dir(arc: str) -> None:
        entries.append({"name": arc, "type": "dir", "mode": 0o755, "time": epoch})

    def add_file(arc: str, src: Path, mode: int) -> None:
        entries.append({"name": arc, "type": "file", "mode": mode, "time": epoch,
                        "src": src})

    def add_blob(arc: str, data: bytes, mode: int) -> None:
        entries.append({"name": arc, "type": "file", "mode": mode, "time": epoch,
                        "data": data})

    def add_symlink(arc: str, target: str) -> None:
        entries.append({"name": arc, "type": "link", "mode": 0o777, "time": epoch,
                        "target": target})

    # bin/ -> /usr/bin plus symlinks under /usr/share/omarchy/bin
    bin_names = []
    for path, mode in sorted(modes.items()):
        if not path.startswith("bin/"):
            continue
        base = path[len("bin/"):]
        if "/" in base or base in SKIP_BINS:
            continue
        bin_names.append(base)
        add_file(f"usr/bin/{base}", REPO / path, mode)
        add_symlink(f"usr/share/omarchy/bin/{base}", f"/usr/bin/{base}")

    # alpm hooks shipped with their Exec targets
    for hook in SHIP_HOOKS:
        add_file(f"usr/share/libalpm/hooks/{hook}",
                 REPO / "default" / "libalpm" / "hooks" / hook, 0o644)

    # Whole trees, cp -a semantics: git's modes are the checkout's modes.
    for top in ("install", "themes", "migrations", "shell"):
        for path, mode in sorted(modes.items()):
            if path.startswith(top + "/"):
                add_file(f"usr/share/omarchy/{path}", REPO / path, mode)

    # Runtime version file.
    add_file("usr/share/omarchy/version", REPO / "version", 0o644)

    # /etc/skel migration markers for users created after install.
    for path in sorted(modes):
        if path.startswith("migrations/") and path.endswith(".sh"):
            add_blob(f"etc/skel/.local/state/omarchy/migrations/{path.split('/', 1)[1]}",
                     b"", 0o644)

    # Insert every parent directory before its first child (lexicographic
    # sorting already puts "./a" before "./a/b", so one pass works).
    seen: set[str] = set()
    with_dirs: list[dict] = []
    for entry in sorted(entries, key=lambda e: e["name"]):
        parts = entry["name"].split("/")
        for i in range(1, len(parts)):
            d = "/".join(parts[:i])
            if d not in seen:
                seen.add(d)
                with_dirs.append({"name": d, "type": "dir", "mode": 0o755, "time": epoch})
        seen.add(entry["name"])
        with_dirs.append(entry)
    return sorted(with_dirs, key=lambda e: e["name"])


def buildinfo(pkgver: str, arch: str, epoch: int) -> bytes:
    spec_sha = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    lines = [
        "format = 2",
        "pkgname = omarchy-dev",
        "pkgbase = omarchy-dev",
        f"pkgver = {pkgver}",
        f"pkgarch = {arch}",
        f"pkgbuild_sha256sum = {spec_sha}",
        "packager = Omarchy Pi Port <pi-port@localhost.invalid>",
        f"builddate = {epoch}",
        "builddir = /src/omarchy",
        "startdir = /src/omarchy",
        "buildtool = tools/pi/build-package.py",
        "buildenv = !distcc",
        "buildenv = color",
        "buildenv = !ccache",
        "buildenv = check",
        "buildenv = !sign",
        "options = strip",
        "options = docs",
        "options = !libtool",
        "options = !staticlibs",
        "options = emptydirs",
    ]
    return ("\n".join(lines) + "\n").encode()


def full_pkginfo(pkgver: str, arch: str, epoch: int, size: int) -> bytes:
    body = [
        "# Generated by tools/pi/build-package.py (makepkg-equivalent, no host pacman)",
        "pkgname = omarchy-dev",
        "pkgbase = omarchy-dev",
        "xdata = pkgtype=pkg",
        f"pkgver = {pkgver}",
        "pkgdesc = Omarchy desktop, Raspberry Pi (aarch64-pi) port of the quattro tree",
        "url = https://github.com/omacom/omarchy",
        f"builddate = {epoch}",
        f"packager = Omarchy Pi Port <pi-port@localhost.invalid>",
        f"size = {size}",
        f"arch = {arch}",
        "license = MIT",
        "conflict = omarchy",
    ]
    for dep in DEPENDS:
        body.append(f"depend = {dep}")
    body.append("provides = omarchy")
    return ("\n".join(body) + "\n").encode()


def entry_bytes(entry: dict) -> bytes:
    if "data" in entry:
        return entry["data"]
    return entry["src"].read_bytes()


def mtree(entries: list[dict], buildinfo_data: bytes, pkginfo_data: bytes,
          epoch: int) -> bytes:
    # The reference package's mtree lists .BUILDINFO and .PKGINFO but never
    # .MTREE itself; every payload entry follows in archive order.
    lines = ["#mtree", "/set type=file uid=0 gid=0 mode=644"]
    t = f"{epoch}.0"
    for name, data in ((".BUILDINFO", buildinfo_data), (".PKGINFO", pkginfo_data)):
        lines.append(f"./{name} time={t} size={len(data)} "
                     f"sha256digest={hashlib.sha256(data).hexdigest()}")
    for entry in entries:
        arc = "./" + entry["name"]
        if entry["type"] == "dir":
            lines.append(f"{arc} time={t} mode=755 type=dir")
        elif entry["type"] == "link":
            lines.append(f"{arc} time={t} type=link link={entry['target']}")
        else:
            data = entry_bytes(entry)
            lines.append(
                f"{arc} time={t} size={len(data)} "
                f"sha256digest={hashlib.sha256(data).hexdigest()}"
            )
    return ("\n".join(lines) + "\n").encode()


def write_package(path: Path, entries: list[dict], buildinfo_data: bytes,
                  pkginfo_data: bytes, mtree_gz: bytes, epoch: int) -> None:
    import zstandard

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        def add_meta(name: str, data: bytes) -> None:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            ti.mode = 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            ti.mtime = epoch
            tf.addfile(ti, io.BytesIO(data))

        add_meta(".BUILDINFO", buildinfo_data)
        add_meta(".MTREE", mtree_gz)
        add_meta(".PKGINFO", pkginfo_data)

        for entry in entries:
            if entry["type"] == "dir":
                ti = tarfile.TarInfo(entry["name"])
                ti.type = tarfile.DIRTYPE
                ti.mode = entry["mode"]
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = "root"
                ti.mtime = entry["time"]
                tf.addfile(ti)
            elif entry["type"] == "link":
                ti = tarfile.TarInfo(entry["name"])
                ti.type = tarfile.SYMTYPE
                ti.linkname = entry["target"]
                ti.mode = entry["mode"]
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = "root"
                ti.mtime = entry["time"]
                tf.addfile(ti)
            else:
                data = entry_bytes(entry)
                ti = tarfile.TarInfo(entry["name"])
                ti.size = len(data)
                ti.mode = entry["mode"]
                ti.uid = ti.gid = 0
                ti.uname = ti.gname = "root"
                ti.mtime = entry["time"]
                tf.addfile(ti, io.BytesIO(data))

    compressed = zstandard.ZstdCompressor(level=3).compress(buf.getvalue())
    path.write_bytes(compressed)


def verify(path: Path, pkgver: str) -> None:
    """Re-open the built package and check it against the packaging rules."""
    import zstandard

    raw = path.read_bytes()
    stream = zstandard.ZstdDecompressor().decompress(raw, max_output_size=2 << 30)
    problems: list[str] = []
    with tarfile.open(fileobj=io.BytesIO(stream), mode="r:") as tf:
        members = tf.getmembers()
        names = [m.name for m in members]
        if names[:3] != [".BUILDINFO", ".MTREE", ".PKGINFO"]:
            problems.append(f"metadata files not first: {names[:3]}")
        info = tf.extractfile(".PKGINFO").read().decode()
        if f"pkgver = {pkgver}" not in info:
            problems.append("wrong pkgver in .PKGINFO")
        for required in ("conflict = omarchy", "provides = omarchy"):
            if required not in info:
                problems.append(f"missing {required!r}")
        for banned in SKIP_BINS:
            if f"usr/bin/{banned}" in names:
                problems.append(f"debug helper shipped: {banned}")
        for required in (
            "usr/share/omarchy/install/omarchy-aarch64-pi.packages",
            "usr/share/omarchy/install/hardware/pi/setup.sh",
            "usr/share/omarchy/bin/omarchy",
            "usr/bin/omarchy",
            "usr/share/omarchy/version",
        ):
            if required not in names:
                problems.append(f"missing {required}")
        # mtree digests must match every payload file.
        mtree_data = gzip.decompress(tf.extractfile(".MTREE").read()).decode()
        digest: dict[str, str] = {}
        for line in mtree_data.splitlines():
            if line.startswith("./") and "sha256digest=" in line:
                arc = line.split()[0][2:]
                digest[arc] = line.split("sha256digest=")[1].strip()
        for m in members:
            if m.isfile() and m.name != ".MTREE":
                data = tf.extractfile(m).read()
                want = digest.get(m.name)
                if want is None:
                    problems.append(f"mtree missing {m.name}")
                elif hashlib.sha256(data).hexdigest() != want:
                    problems.append(f"mtree digest mismatch: {m.name}")
        for m in members:
            if m.uid != 0 or m.gid != 0:
                problems.append(f"non-root ownership: {m.name}")
    if problems:
        for problem in problems:
            sys.stderr.write(f"VERIFY FAIL: {problem}\n")
        sys.exit(1)
    print(f"verified {path.name}: {len(members)} entries, mtree digests, layout rules")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", default="dist")
    parser.add_argument("--arch", default="aarch64", choices=["aarch64"])
    args = parser.parse_args()

    count = git("rev-list", "--count", "HEAD")
    sha8 = git("rev-parse", "--short=8", "HEAD")
    epoch = int(git("log", "-1", "--format=%ct"))
    pkgver = f"4.0.0.r{count}.g{sha8}-1"

    modes = git_modes()
    entries = build_entries(epoch, modes)

    total = sum(len(entry_bytes(e)) for e in entries if e["type"] == "file")
    buildinfo_data = buildinfo(pkgver, args.arch, epoch)
    pkginfo_data = full_pkginfo(pkgver, args.arch, epoch, total)
    mtree_gz = gzip.compress(mtree(entries, buildinfo_data, pkginfo_data, epoch),
                             mtime=epoch)

    out_dir = REPO / args.output_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"omarchy-dev-{pkgver}-{args.arch}.pkg.tar.zst"
    write_package(out, entries, buildinfo_data, pkginfo_data, mtree_gz, epoch)

    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"built {out} ({out.stat().st_size} bytes)")
    print(f"sha256 {digest}")
    (out_dir / f"{out.name}.sha256").write_text(f"{digest}  {out.name}\n")

    verify(out, pkgver)
    return 0


if __name__ == "__main__":
    sys.exit(main())
