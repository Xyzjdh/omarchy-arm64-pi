# Build environment (Phase 0 record)

Recorded at port start, before any implementation work.

## Host machine

The development host is a container, **not** a Raspberry Pi 5. No target
hardware is attached; every hardware-dependent result is reported as
"requires physical verification".

| Property | Value (verified by command) |
|---|---|
| OS | Debian GNU/Linux 13 (trixie) (`/etc/os-release`) |
| Kernel | 5.10.134-013.15.kangaroo.al8.x86_64 (`uname -a`) |
| Architecture | x86_64 (`uname -m`) |
| Cores | 2 (`nproc`) |
| RAM | 4.1 GiB total, 3.6 GiB available (`free -h`) |
| Swap | none |
| Disk | 9.9 GiB root filesystem, 9.3 GiB available (`df -h /`) |
| User | `z`, uid 1001, non-root, **no passwordless sudo** (`id`, `sudo -n true` → password required) |

## Toolchain

Present: git 2.47.3, GNU bash 5.2.37, Python 3.12.15 (+ venv with
`zstandard` 0.25.0 installed via pip), gcc/g++ 13, make, curl, wget, tar,
xz, jq, rsync.

Absent from the host (worked around):

| Tool | Workaround used |
|---|---|
| `pacman` / `makepkg` | packages analyzed by parsing repository databases directly; local package built by `tools/pi/build-package.py`, a builder reproducing the upstream PKGBUILD's `package()` logic deterministically (see `docs/pi/porting-decisions.md`) |
| `shellcheck` | downloaded the official static v0.10.0 binary into `tools/pi/bin/` (no host install possible without sudo) |
| `zstd` CLI | Python `zstandard` module (repo DB decompression, package compression) |
| Docker/Podman/qemu | no container or ARM emulation; integration tests use fixture roots (upstream's `OMARCHY_PROC_ROOT` etc.) and a fake `pacman` shim |
| `bats` | upstream uses its own `test/shell.d/*-test.sh` bash harness; Pi tests follow it |

## Network

Outbound HTTPS verified working to: github.com, raw.githubusercontent.com,
aur.archlinux.org (cgit reachable; RPC JSON API is protected by an
anti-bot challenge — see `docs/pi/package-compatibility.md`),
archlinuxarm.org, pkgs.omarchy.org, arm-mirror.omarchy.org.

## Target

Raspberry Pi 5, 4 GB RAM, AArch64. The reference Pi 5 port
(sam-bee/omarchy-raspberrypi) targets 8 GB and requires an NVMe/SD target
of 32 GB+; this port must fit the desktop in 4 GB (zram, reduced default
effects — see `docs/pi/porting-decisions.md`).

## Repository clones under `/home/z/my-project/omarchy-arm64/repos/`

| Repo | Commit | Purpose |
|---|---|---|
| `omacom/omarchy` (branch `quattro`) | `defbf90e893e741067e48f4a27d2ec694c71358e` (HEAD, 6912 commits, tag v4.0.0 latest) | upstream baseline; the port branches from here |
| `sam-bee/omarchy-raspberrypi` | `d30100df3be5da953b1f5e8fca0437f10b713454` (single squashed commit, based on an older quattro-era snapshot ~`947e2fc0`) | reference (research only) |
| `omacom/omarchy-pkgs` | shallow | upstream packaging recipes (read-only reference) |
| `omacom/omarchy-iso` | shallow | upstream ISO builder (read-only reference) |
| `alexisraitano-myffu/omarchy` (arm64 branch) | **not cloneable: repository does not exist publicly (404)** | reference unavailable; not used |

Branches created in the upstream clone (this is the working repo):

- `quattro` — as cloned, default upstream branch
- `upstream-quattro` — explicit upstream-tracking branch (never committed to)
- `arm64-pi` — **the port's development branch** (all port commits land here)
