#!/usr/bin/env python3
"""Package compatibility audit for Omarchy aarch64-pi (Raspberry Pi 5).

Verifies every package named in Omarchy's install manifests against real
repository databases downloaded from the repositories an aarch64 Omarchy
system would use:

  [omarchy]  https://pkgs.omarchy.org/edge/aarch64      (zstd repo db)
  [core]     https://arm-mirror.omarchy.org/aarch64/core
  [extra]    https://arm-mirror.omarchy.org/aarch64/extra
  [alarm]    https://arm-mirror.omarchy.org/aarch64/alarm
  [aur]      https://arm-mirror.omarchy.org/aarch64/aur  (ALARM's prebuilt AUR set)

Everything here is read-only: the tool downloads database files (or reuses
already-downloaded ones) and never touches a package manager.

Usage:
  package-audit.py fetch  [--data-dir DIR]                    download repo dbs
  package-audit.py report [--data-dir DIR] [--out-md FILE]    classify + write report
  package-audit.py check  [--data-dir DIR]                    exit 1 on unresolved

Repository database format: a tarball (gzip or zstandard) whose entries are
"<pkgname>-<fullversion>/desc" files with %NAME%/%VERSION%/%PROVIDES% blocks.
"""

from __future__ import annotations

import argparse
import datetime
import io
import json
import os
import sys
import tarfile
import urllib.request
from pathlib import Path

REPOS = {
    "omarchy": "https://pkgs.omarchy.org/edge/aarch64/omarchy.db",
    "core": "https://arm-mirror.omarchy.org/aarch64/core/core.db",
    "extra": "https://arm-mirror.omarchy.org/aarch64/extra/extra.db",
    "alarm": "https://arm-mirror.omarchy.org/aarch64/alarm/alarm.db",
    "aur": "https://arm-mirror.omarchy.org/aarch64/aur/aur.db",
}

REPO_ORDER = ["omarchy", "core", "extra", "alarm", "aur"]

# Virtual packages we resolve to a concrete provider when a manifest names
# them (none today, but keeps the resolver honest if upstream adds one).
KNOWN_PROVIDERS = {}


def db_path(data_dir: Path, repo: str) -> Path:
    return data_dir / f"{repo}.db"


def fetch(data_dir: Path) -> dict[str, str]:
    """Download the repo databases. Returns {repo: 'fresh'|'cached'}."""
    data_dir.mkdir(parents=True, exist_ok=True)
    status = {}
    for repo, url in REPOS.items():
        dest = db_path(data_dir, repo)
        marker = dest.with_suffix(".db.fetched")
        if dest.exists() and marker.exists() and marker.read_text().strip() == REPOS[repo]:
            status[repo] = "cached"
            continue
        sys.stderr.write(f"fetching {repo}: {url}\n")
        tmp = dest.with_suffix(".db.part")
        urllib.request.urlretrieve(url, tmp)
        os.replace(tmp, dest)
        marker.write_text(REPOS[repo] + "\n")
        status[repo] = "fresh"
    return status


def _block(field: str, text: str) -> str | None:
    """Return the first value of a %FIELD% block from a pacman desc file."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() == f"%{field}%":
            for j in range(i + 1, len(lines)):
                if lines[j].strip() == "":
                    return None
                if lines[j].startswith("%"):
                    return None
                return lines[j].strip()
    return None


def parse_db(path: Path) -> tuple[dict[str, str], dict[str, list[str]], dict[str, str]]:
    """Parse one repo db -> ({name: version}, {name: provides}, {name: builddate})."""
    raw = path.read_bytes()
    if raw[:2] == b"\x1f\x8b":
        import gzip

        stream = gzip.decompress(raw)
    elif raw[:4] == b"\x28\xb5\x2f\xfd":
        import zstandard

        stream = zstandard.ZstdDecompressor().decompress(raw, max_output_size=1 << 30)
    else:
        stream = raw
    names: dict[str, str] = {}
    provides: dict[str, list[str]] = {}
    builddates: dict[str, str] = {}
    with tarfile.open(fileobj=io.BytesIO(stream), mode="r:") as tf:
        for member in tf.getmembers():
            if not member.name.endswith("/desc") or not member.isfile():
                continue
            text = tf.extractfile(member).read().decode("utf-8", errors="replace")
            name = _block("NAME", text)
            version = _block("VERSION", text)
            if not name:
                continue
            names[name] = version or "?"
            prov = _block("PROVIDES", text) or ""
            if prov:
                provides[name] = [p.split("=")[0] for p in prov.split() if p]
            date = _block("BUILDDATE", text)
            if date:
                builddates[name] = date
    return names, provides, builddates


def manifest_names(path: Path) -> list[str]:
    """Names from an Omarchy .packages manifest (comments/blanks stripped)."""
    out = []
    for line in path.read_text().splitlines():
        line = line.split("#")[0].strip()
        if line:
            out.append(line)
    return out


def aur_info(names: list[str]) -> dict[str, dict]:
    """Query the AUR RPC v5 info endpoint for the given package names."""
    results: dict[str, dict] = {}
    for i in range(0, len(names), 40):
        batch = names[i : i + 40]
        qs = "&".join(f"arg%5B%5D={urllib.request.quote(n)}" for n in batch)
        url = f"https://aur.archlinux.org/rpc/v5/info?{qs}"
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                data = json.load(resp)
        except Exception as exc:  # network unavailable: report, don't crash
            sys.stderr.write(f"warning: AUR RPC failed ({exc}); AUR data unavailable\n")
            return results
        for item in data.get("results", []):
            results[item["Name"]] = item
    return results


def aur_pkgbuild_arch(name: str) -> str | None:
    """Fetch the PKGBUILD's arch= line for one AUR package, or None."""
    url = f"https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h={urllib.request.quote(name)}"
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            text = resp.read().decode("utf-8", errors="replace")
    except Exception:
        return None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("arch="):
            return s
    return None


def resolve(name: str, indexes: dict[str, dict[str, str]],
            provides_index: dict[str, dict[str, list[str]]]) -> tuple[str | None, str]:
    """Which repo (in priority order) provides `name`?

    Returns (repo, provider) where provider is the concrete package name
    (equals `name` on a direct hit, the provider package on a provides match).
    Mirrors pacman's own resolution: direct name first, then providers, in
    repository-priority order.
    """
    for repo in REPO_ORDER:
        if name in indexes[repo]:
            return repo, name
    for repo in REPO_ORDER:
        for provider, provs in provides_index[repo].items():
            if name in provs:
                return repo, provider
    return None, ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_fetch = sub.add_parser("fetch")
    p_fetch.add_argument("--data-dir", default="tools/pi/data")

    p_report = sub.add_parser("report")
    p_report.add_argument("--data-dir", default="tools/pi/data")
    p_report.add_argument("--out-md", default=None)
    p_report.add_argument("--manifest-dir", default="install")
    p_report.add_argument("--include-other", action="store_true",
                          help="also classify install/omarchy-other.packages")
    p_report.add_argument("--skip-aur", action="store_true",
                          help="do not query the AUR RPC (offline mode)")

    p_check = sub.add_parser("check")
    p_check.add_argument("--data-dir", default="tools/pi/data")
    p_check.add_argument("--manifest-dir", default="install")
    p_check.add_argument("--include-other", action="store_true")
    p_check.add_argument("--skip-aur", action="store_true")

    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent.parent  # repo root
    data_dir = (root / args.data_dir).resolve() if not Path(args.data_dir).is_absolute() else Path(args.data_dir)
    manifest_dir = root / args.manifest_dir

    if args.cmd == "fetch":
        status = fetch(data_dir)
        for repo, st in status.items():
            print(f"{repo}: {st}")
        return 0

    # ---- report / check share the classification logic ----
    for repo in REPOS:
        if not db_path(data_dir, repo).exists():
            sys.stderr.write(f"error: {db_path(data_dir, repo)} missing; run the fetch subcommand\n")
            return 2

    indexes: dict[str, dict[str, str]] = {}
    provides_index: dict[str, dict[str, list[str]]] = {}
    newest: dict[str, str] = {}
    for repo in REPOS:
        names, provides, builddates = parse_db(db_path(data_dir, repo))
        indexes[repo] = names
        provides_index[repo] = provides
        if builddates:
            newest[repo] = max(builddates.values())

    # Compose the aarch64-pi platform set exactly as omarchy-pkg-defaults
    # does: base + aarch64 (+ the platform list when it exists), minus
    # omarchy-x86_64-only.packages.
    base_names = manifest_names(manifest_dir / "omarchy-base.packages")
    aarch64_names = manifest_names(manifest_dir / "omarchy-aarch64.packages")
    x86_only = set(manifest_names(manifest_dir / "omarchy-x86_64-only.packages"))
    pi_names = []
    pi_manifest = manifest_dir / "omarchy-aarch64-pi.packages"
    if pi_manifest.exists():
        pi_names = manifest_names(pi_manifest)

    def compose(platform: str) -> list[tuple[str, str]]:
        if platform == "x86":
            names = base_names
        elif platform == "aarch64":
            names = [n for n in base_names if n not in x86_only] + aarch64_names
        else:  # aarch64-pi
            names = ([n for n in base_names if n not in x86_only]
                     + aarch64_names + pi_names)
        return [("composed:" + platform, n) for n in names]

    entries = compose("x86") + compose("aarch64") + compose("aarch64-pi")
    if args.include_other:
        entries += [("omarchy-other.packages", n)
                    for n in manifest_names(manifest_dir / "omarchy-other.packages")]

    rows = []  # (manifest, package, repo-or-aur-or-missing, version, note)
    missing: list[str] = []
    seen_composed: set[tuple[str, str]] = set()
    for mf, name in entries:
        if mf.startswith("composed:") and (mf, name) in seen_composed:
            continue
        seen_composed.add((mf, name))
        repo, provider = resolve(name, indexes, provides_index)
        if repo:
            version = indexes[repo][provider]
            note = "" if provider == name else f"provided by `{provider}`"
            rows.append((mf, name, repo, version, note))
        else:
            missing.append((mf, name))

    if missing and not args.skip_aur:
        aur = aur_info([n for _, n in missing])
        for mf, name in missing:
            item = aur.get(name)
            if item:
                archline = aur_pkgbuild_arch(name)
                note = f"AUR v{item['Version']}; PKGBUILD {archline or 'arch unknown (fetch failed)'}"
                rows.append((mf, name, "aur-build", "AUR", note))
            else:
                rows.append((mf, name, "missing", "-", "not in any configured repo or the AUR"))
    elif missing:
        for mf, name in missing:
            rows.append((mf, name, "missing", "-", "AUR query skipped (--skip-aur)"))

    # ---- output ----
    out_md = Path(args.out_md) if args.out_md else root / "docs/pi/package-compatibility.md"
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = []
    lines.append("# Pi package compatibility (generated, verified against live repo databases)")
    lines.append("")
    lines.append(f"Generated by `tools/pi/package-audit.py` at {stamp}.")
    lines.append("")
    lines.append("Platform sets are composed exactly as `omarchy-pkg-defaults` composes them:")
    lines.append("`composed:x86` = base; `composed:aarch64` = base + aarch64 lists minus")
    lines.append("`omarchy-x86_64-only.packages`; `composed:aarch64-pi` = the aarch64 set plus")
    lines.append("`omarchy-aarch64-pi.packages`. Names resolve first by exact package name, then")
    lines.append("by `%PROVIDES%` (mirroring pacman), in repository priority order")
    lines.append("[omarchy] > [core] > [extra] > [alarm] > [aur].")
    lines.append("")
    lines.append("Repository database snapshots:")
    for repo in REPO_ORDER:
        when = "unknown date"
        if newest.get(repo):
            try:
                when = datetime.datetime.fromtimestamp(
                    int(newest[repo]), tz=datetime.timezone.utc
                ).strftime("%Y-%m-%d")
            except (ValueError, OSError):
                pass
        lines.append(f"- [{repo}]: {len(indexes[repo])} packages, newest build {when}")
    lines.append("")
    total = len(rows)
    by_repo: dict[str, int] = {}
    for r in rows:
        by_repo[r[2]] = by_repo.get(r[2], 0) + 1
    lines.append(f"Classified {total} manifest entries: " +
                 ", ".join(f"{k}={v}" for k, v in sorted(by_repo.items())))
    lines.append("")
    lines.append("| Manifest | Package | Found in | Version | Note |")
    lines.append("|---|---|---|---|---|")
    for mf, name, repo, version, note in rows:
        lines.append(f"| {Path(mf).name} | `{name}` | {repo} | {version} | {note} |")
    lines.append("")
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text("\n".join(lines) + "\n")
    print(f"wrote {out_md}")

    # machine-readable copy next to the tool
    json_out = data_dir / "classification.json"
    data_dir.mkdir(parents=True, exist_ok=True)
    json_out.write_text(json.dumps(
        {"generated": stamp,
         "repos": {r: {"count": len(indexes[r]), "newest_builddate": newest.get(r)} for r in REPO_ORDER},
         "rows": [dict(zip(("manifest", "package", "found_in", "version", "note"), r)) for r in rows]},
        indent=2))
    print(f"wrote {json_out}")

    if args.cmd == "check":
        # The Pi platform set is what an install would actually resolve:
        # only unresolved aarch64-pi entries fail the check. x86-only
        # unavailability (superwhisper-bin and friends) is expected and
        # handled by the composition itself.
        unresolved = [r for r in rows
                      if r[2] == "missing" and r[0] == "composed:aarch64-pi"]
        if unresolved:
            for r in unresolved:
                sys.stderr.write(f"UNRESOLVED: {r[1]} (aarch64-pi platform set)\n")
            sys.stderr.write(f"{len(unresolved)} aarch64-pi packages unresolved\n")
            return 1
        print("all aarch64-pi platform packages resolved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
