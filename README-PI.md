# Omarchy ARM64 for Raspberry Pi 5

An ARM64 port of [Omarchy](https://omarchy.org) (upstream:
[omacom/omarchy](https://github.com/omacom/omarchy), branch `quattro`)
for the **Raspberry Pi 5**, built as one new platform family
(`aarch64-pi`) inside upstream's own architecture model — not a fork of
the desktop. The desktop itself, the shell, themes, CLI and update flow
all come from Omarchy's own published aarch64 repository.

**Status: experimental source port.** Automated tests pass and every
package is verified against the live repositories; bring-up on physical
Pi 5 hardware is documented in `docs/pi/hardware-validation.md` and not
yet executed. Nothing here has been run on a real Raspberry Pi by this
port's CI — the release label will change when it has.

Omarchy is created by DHH and the Omarchy project; this port follows
upstream's MIT license and conventions. It is not affiliated with the
upstream project.

## What it is

- `aarch64-pi` — a Raspberry Pi platform family in Omarchy's detector
  (device-tree `brcm,` tokens: Pi 4, Pi 5, CM5), with its own package
  manifest (`linux-rpi`, `raspberrypi-bootloader`, overlays, utils,
  VideoCore firmware, Pi 5 EEPROM tooling)
- An installer for an **already-booted Arch Linux ARM** Pi 5 system:
  dry-run, verified keyring bootstrap, idempotent phases, backups,
  post-install verification, first-boot owner provisioning — and no
  formatting, repartitioning, boot-firmware writes or EEPROM updates,
  ever
- Memory-conscious defaults for the 4 GB board (zram via upstream's
  configuration; animations and transparency off by default, one toggle
  each to re-enable)
- A reproducible package builder that ships the port as an
  `omarchy-dev`-style package, versioned against upstream's own dev
  channel so `pacman -Syu` behaves honestly
- A live-repository package audit: all 166 packages of the Pi platform
  set verified to resolve against `[omarchy]` edge + Arch Linux ARM
  `core extra alarm aur` (see `docs/pi/package-compatibility.md`)

## Quick start

On a working Arch Linux ARM Raspberry Pi 5 system:

```bash
git clone -b arm64-pi <this repository> omarchy-pi
cd omarchy-pi
python3 tools/pi/build-package.py     # or use a release bundle with dist/ included
sudo tools/pi/omarchy-pi-install --dry-run
sudo tools/pi/omarchy-pi-install
```

Full requirements, phases, exit codes and the first-boot flow:
`docs/pi/installation.md`.

## Requirements

- Raspberry Pi 5 (4 GB or more; 4 GB is the tuned target)
- Arch Linux ARM aarch64 already installed and updated on the Pi
- 8 GiB free on `/`, network, root access
- For building from source: `git`, `python3` (with the `zstandard`
  module)

## Known limitations

- No hardware validation yet — see the checklist
- Upstream's `superwhisper-bin` (dictation) has no aarch64 build and is
  excluded (upstream already excludes it); dictation presets are removed
  on aarch64 by upstream's own setup
- `nvim`/`vi` become `neovim`/`vim` on aarch64 (repository naming gap,
  documented and revertible)
- `linux-rpi` is the 4k-page kernel by choice (16k breaks assorted
  userspace)
- Screen recording and GPU behavior on VideoCore VII need on-metal
  verification

## Documentation

| Read | For |
|---|---|
| `docs/pi/installation.md` | installing, dry-run, updates, rollback |
| `docs/pi/recovery.md` | the recovery catalogue |
| `docs/pi/troubleshooting.md` | symptoms → fixes |
| `docs/pi/porting-decisions.md` | every deviation from upstream, with revert paths |
| `docs/pi/package-compatibility.md` | the verified package inventory |
| `docs/pi/upstream-audit.md` | what upstream already supports and where the gaps are |
| `docs/pi/architecture-compatibility.md` | the platform layer design |
| `docs/pi/testing.md` | the test suite and how to run it |
| `docs/pi/upstream-sync.md` | rebasing, the patch list, upstreaming candidates |
| `docs/pi/hardware-validation.md` | the physical checklist and its evidence log |
| `docs/pi/release-checklist.md` | release labels and gates |

## Development

```bash
./test/shell                                  # upstream's suite, Pi tests included
bash test/shell.d/pi-installer-test.sh        # the installer in a fixture world
python3 tools/pi/test-package-audit.py        # the audit tool's units
```

Contributions follow upstream's conventions (`AGENTS.md`, `CONTRIBUTING.md`).
