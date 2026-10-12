# Hardware validation checklist (Raspberry Pi 5, 4 GB)

Automated tests verified everything software-verifiable. The items below
require a physical Raspberry Pi 5 and are **not yet executed**; until
they are, this port's release label stays "experimental source port".
Perform them in order, recording evidence (commands + output) for each;
any failure goes to `docs/pi/troubleshooting.md` and blocks the
"hardware-validated release candidate" label.

## 0. Base image (before Omarchy)

- [ ] Official ALARM Raspberry Pi 5 image boots to a root shell
- [ ] `pacman -Syu` succeeds; `uname -m` = aarch64;
      `tr '\0' '\n' </proc/device-tree/compatible` shows
      `raspberrypi,5-model-b` and `brcm,bcm2712`
- [ ] `omarchy-hw-platform` (from the bundle) prints `aarch64-pi`
- [ ] Ethernet works; Wi-Fi associates; Bluetooth enumerates

## 1. Installer

- [ ] `tools/pi/omarchy-pi-install --dry-run` exits 0 and changes
      nothing (diff `/etc` before/after)
- [ ] Full install completes, all phases in
      `/var/lib/omarchy-pi-install/state`
- [ ] `/etc/pacman.conf` backup exists and matches
      `backup.sums` checksums
- [ ] Reboot lands on the tty1 owner form; a user is created; SDDM
      shows the Omarchy session
- [ ] Re-running the installer after success is a no-op (all phases
      already done), and `--verify` passes

## 2. Kernel, boot, DRM

- [ ] `uname -r` shows the `linux-rpi` version from the manifest;
      `pacman -Q linux-rpi raspberrypi-bootloader
      raspberrypi-overlays firmware-raspberrypi rpi5-eeprom` all present
- [ ] `/dev/dri` has card/render nodes; `dmesg | grep -iE 'v3d|vc4'`
      shows binding; no firmware errors in `dmesg`
- [ ] `/sys/class/drm` lists the connected connector with a mode
- [ ] A **kernel update** (`pacman -Syu` with a new `linux-rpi`)
      rebuilds the initramfs successfully (the `pi-hooks.conf` filter
      holds) and the machine reboots

## 3. GPU / compositor

- [ ] `eglinfo` / `glinfo` (mesa-utils) reports the v3d renderer, not
      llvmpipe
- [ ] Hyprland starts from SDDM; `hyprctl` answers; quickshell draws
      the bar and panels
- [ ] Screen recording: `gpu-screen-recorder` captures (or fails
      gracefully — record which)
- [ ] Frame rate feels interactive; document `hyprctl` FPS where
      measurable
- [ ] 4 GB memory pressure: `zramctl` shows the compressed device;
      `free -h` under desktop load stays out of thrashing; idle RSS
      recorded

## 4. Thermal / power

- [ ] `vcgencmd measure_temp` idle and under load (10 min compile or
      `stress`); no throttling line in `dmesg` (or recorded)
- [ ] Idle power at the wall (if measurable)

## 5. Desktop functionality

- [ ] Terminal (foot) opens and renders the prompt and powerline
- [ ] Launcher/menu opens, searches, launches an app
- [ ] Notifications, screenshots, clipboard history work
- [ ] Audio: `wpctl status` lists HDMI sink; playback audible
- [ ] Keyboard layout and timezone from the owner form applied
- [ ] `omarchy` CLI help; a theme switch; `omarchy update --check`
      (no reboot needed)
- [ ] Wi-Fi reconnect after suspend/reboot

## 6. Recovery drills

- [ ] `--restore-pacman` restores the original configuration and
      checksums verify
- [ ] After `pacman -Rns omarchy-dev`, the system still boots (to the
      ALARM base) and the port reinstalls cleanly

## Evidence log format

For each item record: date, Pi 5 variant (4 GB), firmware version
(`rpi-eeprom-update`), image version, command, output, pass/fail. Keep
the log as `docs/pi/hardware-log-<date>.md` and reference it from the
release notes before claiming any higher release label.
