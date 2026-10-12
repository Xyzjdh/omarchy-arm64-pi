# Troubleshooting

Ordered by the phase where symptoms usually appear. Hardware-specific
behavior that could only be verified on a real Pi is marked
**[HW]** — see `docs/pi/hardware-validation.md`.

## Installer

**"this machine reports platform 'aarch64'"** — the device tree has no
`brcm,` vendor token. You are likely on a non-Pi ARM machine, or running
in a container/chroot without the Pi's device tree. Run
`omarchy-hw-platform` and `tr '\0' '\n' </proc/device-tree/compatible`
on the machine itself.

**"the aarch64-pi package set does not resolve"** — a repository is
behind the manifests. Run `python3 tools/pi/package-audit.py check` from
a checkout (needs cached or freshly fetched repo databases) to see the
unresolved names, and re-file the gap per
`docs/pi/package-compatibility.md`.

**"omarchy-keyring failed its checksum"** — do not retry blindly; this
means the HTTPS-fetched database and package disagree. Report it, and
fall back to `--restore-pacman` until it is understood.

**Only 2 packages resolve as missing: nvim, vi** — that is expected on
x86-flavored mirrors; the aarch64 repositories are the ones configured.
Check `grep '^\[' /etc/pacman.conf` for `[omarchy] [core] [extra]
[alarm] [aur]`.

## Boot / display

**No display output after install** **[HW]** — the firmware hands the
framebuffer to the kernel; check `/dev/dri` exists, the running kernel is
`linux-rpi` (`uname -r`), and `dmesg | grep -iE 'v3d|vc4|drm'` shows the
driver binding. The install log's Raspberry Pi section records what the
hardware leaf found.

**Hyprland fails to start / falls back** **[HW]** — Hyprland needs a
GLES-capable Mesa; the Pi's VideoCore VII is driven by Mesa `v3d`. Run
`glinfo`/`eglinfo` (from mesa-utils) and check the renderer string; a
software renderer (llvmpipe) means v3d did not bind — same checks as
above. Hyprland community reports confirm v3d on Pi 5 works with current
Mesa; this port does not claim it verified.

**Boot still works, desktop does not start** — check
`systemctl status sddm` and `journalctl -b -u sddm`.

## Kernel updates

**A kernel update failed rebuilding the initramfs** — upstream's
mkinitcpio baseline names hooks without aarch64 builds; the Pi leaf's
`/etc/mkinitcpio.conf.d/pi-hooks.conf` exists exactly to prevent this.
If it is missing (removed, or the leaf never ran), re-run
`sudo omarchy apply hardware --install-user <user>` to rewrite it.

## Package management

**`pacman -Syu` wants to replace omarchy-dev with upstream's** —
upstream's dev package carries a higher `r<commit-count>` version. That
replaces the Pi platform code; rebuild from a rebased checkout to take
it back (`docs/pi/upstream-sync.md`).

**Chromium or Electron apps feel heavy** — expected on 4 GB; the
defaults trade effects for headroom. Close what you do not use, and let
zram do its work (`zramctl` shows compression).

## Audio

**No sound** **[HW]** — `wpctl status` should list sinks (HDMI audio).
Pi 5's analog jack depends on the board variant. `alsamixer` selects
channels; upstream's audio panel handles the rest.

## Diagnostics to collect before asking

```bash
sudo tools/pi/omarchy-pi-install --verify
omarchy-hw-platform
uname -a
pacman -Q omarchy-dev linux-rpi hyprland quickshell
journalctl -b -p err --no-pager | tail -50
zramctl
```
