# Recovery

The installer is designed so that failure at any phase leaves a bootable
system with a documented recovery path. The boot chain is never touched,
so a Pi that fails mid-install still boots the way it did before.

## Recovery catalogue

| Symptom | Recovery |
|---|---|
| Installer failed, want the old pacman configuration back | `sudo tools/pi/omarchy-pi-install --restore-pacman` (restores `/etc/pacman.conf` and `/etc/pacman.d/mirrorlist` from `/var/lib/omarchy-pi-install/`) |
| Installer failed mid-packages | Fix the reported package problem, re-run `sudo tools/pi/omarchy-pi-install`; phases already recorded are skipped. `--force` reruns everything |
| Packages installed, system setup failed | `sudo omarchy-apply-system --defer-provisioning --first-install` (or `sudo omarchy apply hardware --install-user <user>` post-user-creation); log: `/var/log/omarchy-install.log` |
| First boot never showed the owner form | Check `systemctl status omarchy-provision-owner` and `journalctl -u omarchy-provision-owner`; re-arm: `sudo touch /var/lib/omarchy/provisioning/pending && sudo systemctl start omarchy-provision-owner` |
| Desktop installed, want it gone | `sudo pacman -Rns omarchy-dev` removes the fork's package; remove the rest with `sudo pacman -Rns $(pacman -Qq | grep -E 'hyprland|quickshell|sddm')` or restore the ALARM image |
| Everything broken, start over | Re-flash the official Arch Linux ARM Raspberry Pi image; the installer changed nothing outside the OS |
| `omarchy-dev` upgraded to upstream's and lost the Pi platform | Rebuild from a current port checkout (`python3 tools/pi/build-package.py`) and `sudo pacman -U dist/omarchy-dev-*.pkg.tar.zst` |

## The state directory

`/var/lib/omarchy-pi-install/` records:

- `state` — completed phases (`phase=<name> done`)
- `pacman.conf.bak`, `mirrorlist.bak` — your pre-Omarchy configuration
- `backup.sums` — checksums of the originals as backed up

Verify a backup is intact:

```bash
sha256sum -c /var/lib/omarchy-pi-install/backup.sums
```

## What the installer never does

- Formats, repartitions or overwrites any disk or partition
- Writes `/boot/firmware` or anything in the Pi's boot chain
- Updates the EEPROM (the `rpi5-eeprom` package only installs tooling)
- Replaces your pacman configuration without keeping a backup
- Runs any unreviewed script from the network as root (the one thing
  downloaded and run is `omarchy-keyring`, over HTTPS, checksum-verified
  against the repository database fetched over HTTPS, and installed as a
  regular pacman package)

## Logs

- `/var/log/omarchy-pi-install.log` — the installer's own log
- `/var/log/omarchy-install.log` — `omarchy-apply-system`'s log
- `/var/log/pacman.log` — package transactions
