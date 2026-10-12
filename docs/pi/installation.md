# Installing Omarchy on a Raspberry Pi 5

Status: **experimental source port** — automated tests pass, hardware
bring-up on a real Pi 5 is documented in `docs/pi/hardware-validation.md`
and still to be completed. Read that before relying on this.

## What you need

- A Raspberry Pi 5 (4 GB or more). 4 GB is the configuration this port
  tunes for (zram + animations off by default).
- A working **Arch Linux ARM** aarch64 install for the Raspberry Pi,
  booted from microSD or NVMe with its firmware boot chain working:
  <https://archlinuxarm.org/platforms/armv8/broadcom/raspberry-pi-5>.
  Start from the official ALARM image, complete its setup, and make sure
  `pacman -Syu` works before you begin.
- Ethernet or Wi-Fi, and at least 8 GiB free on `/`.
- Root access (ALARM ships a root account; the installer must run as
  root).

The installer **never** formats, repartitions, writes the boot firmware,
or updates the EEPROM. Your existing boot chain, kernel command line and
data are untouched.

## Get the port

Either download the release bundle (a tarball of this repository at the
release commit, plus `dist/omarchy-dev-*.pkg.tar.zst` and its checksum)
or clone the branch:

```bash
git clone -b arm64-pi https://github.com/omacom/omarchy omarchy-pi
cd omarchy-pi
```

From a checkout without `dist/`, build the package first (needs `git`,
`python3` and the Python `zstandard` module; ~2 minutes):

```bash
python3 tools/pi/build-package.py
```

## Preview what will happen (dry run)

```bash
sudo tools/pi/omarchy-pi-install --dry-run
```

The dry run checks the platform, disk, network and bundle, resolves the
complete package transaction in a **private pacman database** (so
nothing on your system changes), and prints the plan. It exits non-zero
with a specific code if anything is wrong:

| Code | Meaning |
|---|---|
| 1 | usage / bundle problem |
| 2 | not a Raspberry Pi (or not aarch64) |
| 3 | unsupported base or unreachable repositories |
| 5 | insufficient disk space |
| 7 | the package set does not resolve |
| 8 | system setup or verification failed |

## Install

```bash
sudo tools/pi/omarchy-pi-install
```

Phases (each idempotent, recorded in `/var/lib/omarchy-pi-install/state`;
re-run continues where it stopped):

1. **env-check** — platform `aarch64-pi` (device-tree `brcm,` family),
   pacman present, ≥ 8 GiB free, repositories reachable.
2. **backup** — `/etc/pacman.conf` and `/etc/pacman.d/mirrorlist` are
   copied into the state directory (only if not already Omarchy's).
3. **repos** — the upstream aarch64 **edge** pacman configuration
   (`[omarchy]` + Arch Linux ARM `core extra alarm aur`), the
   `omarchy-keyring` package downloaded over HTTPS, checksum-verified
   against the repository database, installed and populated; `pacman -Sy`.
4. **packages** — the locally built `omarchy-dev` package
   (`pacman -U`), then the 166-package `aarch64-pi` set from
   `omarchy-pkg-defaults` (base + aarch64 replacements + Pi kernel,
   firmware, overlays, EEPROM tooling).
5. **system** — upstream's `omarchy-apply-system --defer-provisioning
   --first-install` (configuration, hardware leaves including the Pi
   checks, SDDM, services, pacman finalization). Its log:
   `/var/log/omarchy-install.log`.
6. **provisioning** — first-boot owner setup armed
   (`omarchy-provision-owner.service` + `pending` marker).
7. **verify** — checks the platform, packages, repository configuration,
   provisioning state and login manager.

Reboot when it finishes. The Omarchy owner form runs on tty1: it asks
for keyboard, username, password, hostname and timezone, creates your
user, and hands you to SDDM and the desktop.

## After installation

```bash
sudo tools/pi/omarchy-pi-install --verify   # read-only health check
omarchy                                     # the desktop CLI
```

The desktop starts with animations and transparency off
(VideoCore VII + 4 GB defaults); `omarchy-toggle-animations` and
Appearance → Window Transparency turn them back on. Swap is on zram
(upstream's `zram-generator` configuration, sized to RAM).

## Rolling back

Nothing in the boot chain changed, so rebooting into a previous state
only involves packages:

```bash
sudo tools/pi/omarchy-pi-install --restore-pacman   # pacman.conf + mirrorlist back
sudo pacman -Rns omarchy-dev                        # remove the fork's package
# or restore the full Arch Linux ARM image to the card
```

`docs/pi/recovery.md` has the complete recovery catalogue.

## Updating

`sudo pacman -Syu` keeps everything current from `[omarchy]` edge and
Arch Linux ARM. Two caveats:

- When upstream publishes a newer `omarchy-dev` than this fork's build
  (their `r<commit-count>` version grows past ours), the update replaces
  the Pi platform code with upstream's tree. Re-run the port's
  `build-package.py` from a rebased checkout to take the platform back
  (see `docs/pi/upstream-sync.md`).
- Kernel updates rebuild the initramfs through upstream's
  mkinitcpio drop-ins; the Pi leaf's `pi-hooks.conf` filters hooks with
  no aarch64 build so those updates succeed.

## What is different from upstream

See `docs/pi/porting-decisions.md` for the complete, revertible list:
the `aarch64-pi` platform family, the Pi package manifest, the
`nvim`→`neovim` and `vi`→`vim` aarch64-wide replacements, the Pi
hardware checks, the reduced default effects, and this installer.
Everything else — the whole desktop, shell, themes, CLI, update flow —
is upstream's, from upstream's own aarch64 repository.
