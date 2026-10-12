# Raspberry Pi hardware setup, gated by omarchy-hw-aarch64-pi. The platform's
# packages (kernel, boot firmware, overlays, utils, EEPROM tooling) arrive
# through omarchy-aarch64-pi.packages, not here: this leaf only checks the
# machine can actually run the desktop stack and records what it finds in the
# install log, where omarchy-upload-log collects it.
#
# The GPU is VideoCore VII behind Mesa's v3d driver, which Hyprland's Mesa
# dependency pulls in; there is no vendor driver to install or configure. The
# display pipeline is DRM/KMS from the firmware's device tree, so /dev/dri
# nodes and the v3d module are the whole story a bring-up needs to check.
if omarchy-hw-aarch64-pi; then
  echo "Raspberry Pi detected. Checking the display and GPU stack."

  if [[ -d /dev/dri ]]; then
    echo "DRM device nodes present: $(find /dev/dri -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)"
  else
    echo "Warning: no /dev/dri nodes found. The desktop needs the v3d KMS driver:" \
      "check that linux-rpi is the running kernel (uname -r) and vc4_kms_v3d" \
      "is not blacklisted. See docs/pi/troubleshooting.md." >&2
  fi

  if modinfo v3d >/dev/null 2>&1; then
    echo "Mesa v3d kernel module: $(modinfo -F version v3d 2>/dev/null || echo present)"
  else
    echo "Warning: the v3d kernel module was not found for kernel $(uname -r)." \
      "VideoCore VII acceleration needs linux-rpi's module." >&2
  fi

  if omarchy-pkg-present raspberrypi-bootloader; then
    echo "raspberrypi-bootloader installed; the firmware boot chain stays as the Arch Linux ARM image wrote it."
  else
    echo "Warning: raspberrypi-bootloader is not installed; package installation may be incomplete." >&2
  fi

  # The rpi5-eeprom package ships update tooling (rpi-eeprom-update). Nothing
  # here runs it: an EEPROM update is the owner's explicit decision, and the
  # boot order it may change is exactly what this port never touches.
  if omarchy-pkg-present rpi5-eeprom; then
    echo "rpi5-eeprom tooling installed; updates are never run automatically."
  fi

  # omarchy-settings' mkinitcpio baseline adds hooks by name (btrfs-overlayfs
  # among them) that have no aarch64 build in any configured repository. A
  # missing hook file makes the next kernel-package update fail to rebuild the
  # initramfs, so filter the hook list to what is actually installed. This is
  # self-cleaning: a hook that gains an aarch64 build stays in.
  if [[ -d /etc/mkinitcpio.conf.d ]]; then
    cat >/etc/mkinitcpio.conf.d/pi-hooks.conf <<'EOF'
# Raspberry Pi: keep only initramfs hooks whose implementations are installed.
# Sourced after omarchy-settings' 00-omarchy-hooks.conf baseline, which names
# hooks (btrfs-overlayfs) with no aarch64 build today.
_pi_kept_hooks=()
for _pi_hook in "${HOOKS[@]:-}"; do
  if [[ -f /usr/lib/initcpio/install/$_pi_hook || -f /usr/lib/initcpio/hooks/$_pi_hook ]]; then
    _pi_kept_hooks+=("$_pi_hook")
  else
    echo "omarchy-pi: dropping initramfs hook with no aarch64 build: $_pi_hook" >&2
  fi
done
HOOKS=("${_pi_kept_hooks[@]:-}")
unset _pi_kept_hooks _pi_hook
EOF
    echo "Wrote /etc/mkinitcpio.conf.d/pi-hooks.conf (filters unavailable initramfs hooks)."
  fi

  echo "Raspberry Pi hardware checks complete."
fi
