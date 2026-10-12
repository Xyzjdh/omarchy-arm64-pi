# Building the bootable Raspberry Pi 5 image

Status: **experimental source port, statically validated.** The image
pipeline is real and its checks run on every build, but nothing here has
booted on a physical Raspberry Pi 5 yet. Until the hardware list at the
bottom passes on a real board, the image is not hardware-validated, and no
release should say otherwise.

## What the image is

A single flashable file containing a complete, preinstalled Omarchy
aarch64-pi system: an Arch Linux ARM aarch64 root filesystem with the whole
desktop (the port's 166-package platform set), the Raspberry Pi firmware,
kernel (`linux-rpi`), device trees and overlays on a FAT boot partition,
and the first-boot owner provisioning armed. Flashing it is the entire
install -- no manual Arch Linux ARM setup, no installer run.

The system inside is installed by the port's own tested installer
(`tools/pi/omarchy-pi-install`) running in a chroot during the build, on
the platform identity the image-target manifest declares
(`/var/lib/omarchy/image/target`, `platform=aarch64-pi`), which the
platform detector reads while a root is being built rather than booted.
The builder adds only the image layer: boot files, the first-boot resize
service, a deterministic root password, and an empty machine-id.

## Layout and first boot

| Region | Content |
|---|---|
| sector 0 | MBR, fixed label-id `0x4f4d5049` (PARTUUID `4f4d5049-01/-02`) |
| partition 1, 4 MiB offset, 1 GiB, FAT32 | firmware (`start4.elf`, `fixup4.dat`), `kernel8.img`, `initramfs-linux.img`, Pi 5 DTBs (`bcm2712-rpi-5-b.dtb`), overlays, `config.txt`, `cmdline.txt` |
| partition 2, starts at 4 MiB + 1 GiB, 12 GiB, ext4 | the root filesystem, ~170 packages |

The image is sized to fit 16 GB cards (13 GiB total, 12 GiB root). On the
first boot:

1. `omarchy-pi-resize.service` (`ConditionFirstBoot=yes`, empty machine-id)
   grows partition 2 to the card's full size and calls `resize2fs`.
2. `omarchy-provision-owner.service` runs the owner form on tty1: keyboard,
   username, password, hostname, timezone -- it creates your user.
3. SDDM starts and the session reaches the Hyprland desktop, with zram and
   the reduced-effects defaults the 4 GB board uses.

Until the owner form creates a user, `root` has ALARM's documented password
`alarm` (set deterministically by the builder). Change it if you use it:
`passwd` as root on tty2.

`cmdline.txt` is explicit: `root=/dev/mmcblk0p2 rootwait
console=serial0,115200 console=tty1`. The kernel is `linux-rpi`, the
Raspberry Pi downstream kernel; installing it replaces the ALARM base's
generic `linux-aarch64` and its u-boot through pacman's own conflict
resolution (linux-rpi conflicts with both), and the bootloader, overlays
and VideoCore firmware come from the `raspberrypi-*`/`firmware-raspberrypi`
packages. The builder's cleanup only removes what no installed package
owns in `/boot` and `/usr/lib/modules`; `config.txt` and `cmdline.txt` are
always preserved. The ALARM rootfs is extracted with bsdtar because the
tarball carries `security.capability` xattrs that GNU tar drops, and the
initramfs hook filter is in place before the first kernel transaction so
`mkinitcpio` cannot fail on hooks without an aarch64 build.

## Building

The reference build environment is a GitHub arm64 runner
(`ubuntu-24.04-arm`): root, loop devices and native aarch64, so the chroot
runs at full speed. The workflow is **dispatch-only**
(`.github/workflows/build-pi-image.yml`): no build happens on push, and the
workflow never attaches the image to a release or publishes it. Artifacts
stay on the run page for 30 days.

Inputs: `ref` (what to build), `alarm_sha256` (pin the ALARM rootfs
tarball; the default pins the tarball the port verified at
`f10903be472e2662e110f0f7bae2750a30914ce3dc0fcd38ec85d3405d8c8967`,
850,215,189 bytes),
`root_gib` (default 12; 16 GB cards need <= 13), `validate_mode` (deep or
shallow).

The workflow gates on `tools/pi/package-audit.py check` (the package set
must still resolve against the live repositories), builds the `omarchy-dev`
package with `tools/pi/build-package.py`, then runs
`tools/pi/build-image.sh`, which:

1. downloads and checksum-verifies the ALARM rootfs tarball (pin enforced),
2. partitions a sparse image file (the only "disk" it ever touches),
3. extracts the root filesystem and chroots into it,
4. brings up the ALARM trust chain exactly as the ALARM setup instructions
   do (`pacman-key --init` / `--populate archlinuxarm`), refreshing pacman
   itself so the `[omarchy]` template's `DownloadUser = alpm` user exists,
5. runs the port's installer -- the same tested phases as on a real Pi,
6. applies the image layer (boot files, resize service, `root:alarm`,
   empty machine-id, untracked-kernel cleanup, cache cleanup, `ldconfig`),
7. copies `/boot` to the FAT partition and empties the ext4 `/boot`
   (its mountpoint role),
8. unmounts, runs `e2fsck`/`fsck.vfat`, validates, compresses with xz and
   writes `SHA256SUMS` plus a build report recording every input.

To build locally you need root and the same tools (mtools, dosfstools,
e2fsprogs, xz, curl); on an x86_64 host also `--qemu` with
`qemu-aarch64-static` and binfmt_misc registered (scriptlets exec other
binaries, so plain qemu without binfmt will not finish a transaction).

Reproducibility, honestly: the ALARM tarball and the `omarchy-dev` package
are pinned by sha256 in the build report, the partition table and ext4
hash seed are fixed, and the filesystem is built deterministically -- but
the package *versions* inside come from the live repositories at build
time, so two builds days apart differ by updates. A rebuild from the same
pins on the same day produces the same package versions; timestamps in
filesystems are not normalized. The report records everything needed to
judge a rebuild.

## Validation

`tools/pi/validate-image.sh` runs on every build and works unprivileged on
files only -- no loop mounts, no root, streaming out of the .img.xz:

- shallow (default): xz integrity, sha256 against `SHA256SUMS`, the MBR
  parsed field by field (types, alignment, adjacency, image end), the FAT
  boot partition through mtools (kernel, initramfs, firmware, Pi 5 DTB,
  overlays, `config.txt`/`cmdline.txt` contents), and the ext4 superblock
  (features, state, size matching the partition)
- deep (the workflow default): the full ext4 partition is carved and
  inspected through debugfs -- the image-target manifest, the armed
  owner provisioning, `/etc/fstab`, the empty machine-id, the `[omarchy]`
  repository, the pacman database (package count and the key packages),
  the resize unit and its enablement, SDDM enablement, and `ld.so.cache`

`test/shell.d/pi-image-validator-test.sh` proves the validator itself: it
builds fixture images without privileges and checks that a well-formed
fixture passes deep and a broken one (kernel removed from the FAT) fails.

## Flashing the image

You need a card of at least 16 GB and the `omarchy-arm64-pi-*.img.xz`
artifact plus its `SHA256SUMS`. Verify first:

```bash
sha256sum -c SHA256SUMS
```

Raspberry Pi Imager: *Choose OS -> Use custom ->* pick the `.img.xz` (any
Imager that accepts xz; if yours refuses, `xz -d` it first and pick the
`.img`), choose the SD card, write. balenaEtcher works the same way.

Command line:

```bash
xzcat omarchy-arm64-pi-<label>-aarch64.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Put the card in the Pi 5 and power it on. Expect the resize + owner form
within a minute or two on the display (or on the serial console at 115200
baud).

## What only hardware can validate

The validator prints this list on every run; none of it is claimed:

- the EEPROM bootloader chain: card -> `start4.elf` -> `kernel8.img`
- the Pi 5 device tree and overlays applying, DRM/KMS display bring-up
- Mesa v3d / VideoCore VII rendering the Hyprland/Quickshell desktop
- USB, network, HDMI audio, the serial console
- the first-boot resize actually running (check
  `journalctl -u omarchy-pi-resize`), the owner form on tty1, SDDM, zram
- thermals and power behavior of the 4 GB board

When a board passes that list, record it in
`docs/pi/hardware-validation.md` and only then change the release label.

## Publication policy

The image is not pushed, attached to a release, or published anywhere
without the owner's explicit decision. The workflow uploads nothing but a
run artifact; deleting the run removes it. This document is the contract
that keeps the honest labels of the rest of the port.

## Where things live

| File | Role |
|---|---|
| `tools/pi/build-image.sh` | the builder (root; chroot; reuses the installer) |
| `tools/pi/validate-image.sh` | unprivileged artifact validation |
| `tools/pi/image/resize-root.sh` | in-image first-boot partition grow |
| `tools/pi/image/omarchy-pi-resize.service` | its unit (ConditionFirstBoot) |
| `test/shell.d/pi-image-validator-test.sh` | the validator's own test |
| `.github/workflows/build-pi-image.yml` | dispatch-only CI build |
