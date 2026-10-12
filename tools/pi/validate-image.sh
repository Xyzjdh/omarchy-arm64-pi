#!/bin/bash

# shellcheck disable=SC2015
# The repeated `cond && ok "msg" || bad "msg"` below is deliberate: ok() and
# bad() are echo-only, so the C branch only ever runs when cond fails -- the
# A-&&-B-||-C caveat does not apply to this shape.

# Validate an Omarchy aarch64-pi Raspberry Pi 5 image artifact without
# privileges: every check works on regular files (the image, or a partition
# carved out of it), so no loop device, mount or root access is involved and
# no physical disk is touched.
#
# Usage: validate-image.sh [--deep] IMAGE
#
# IMAGE is the raw .img or the compressed .img.xz artifact. Shallow mode
# (default) decompresses only what it needs through a pipe: the MBR, the
# whole FAT boot partition, and the head of the ext4 partition. --deep also
# carves the full ext4 partition and inspects files inside it (needs disk
# space for the copy; CI runs it, small fixture images can always afford it).
#
# What this proves: partition layout, boot files, filesystem configuration,
# package-database state and first-boot arming, as static facts of the image.
# What it cannot prove, and only lists: everything that needs a real
# Raspberry Pi 5. Those lines are marked HARDWARE and never count as
# failures, because they have not been tested here and are not claimed.
#
# Requirements: xz (for .img.xz), mtools, e2fsprogs (dumpe2fs, debugfs),
# python3, dd, sha256sum. Exit status: 0 all static checks passed, 1 at
# least one failed.

set -uo pipefail

DEEP=0
case ${1:-} in
  --deep) DEEP=1; shift ;;
esac
IMAGE=${1:-}

if [[ -z $IMAGE || ! -f $IMAGE || -d $IMAGE ]]; then
  echo "Usage: validate-image.sh [--deep] IMAGE (a .img or .img.xz file)" >&2
  exit 1
fi

IMAGE=$(readlink -f "$IMAGE")
failures=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; failures=$((failures + 1)); }
need() { command -v "$1" >/dev/null 2>&1 || { echo "FAIL: required tool '$1' is not available" >&2; exit 1; }; }

for tool in dd sha256sum python3 dumpe2fs; do need "$tool"; done
command -v mtype >/dev/null 2>&1 || { echo "FAIL: mtools is not available (mtype/mdir)" >&2; exit 1; }
(( DEEP )) && need debugfs

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
carve() {
  # carve SKIP_SECTORS COUNT_SECTORS from the image into OUT, streaming
  # through xzcat for compressed artifacts (no full decompression).
  local skip=$1 count=$2 out=$3
  if [[ $IMAGE == *.xz ]]; then
    xzcat -- "$IMAGE" | dd bs=512 skip="$skip" count="$count" of="$out" conv=sparse status=none
  else
    dd bs=512 if="$IMAGE" skip="$skip" count="$count" of="$out" conv=sparse status=none
  fi
}

if (( DEEP )); then
  echo "Validating: $(basename "$IMAGE") (deep mode)"
else
  echo "Validating: $(basename "$IMAGE")"
fi

# --- 1. artifact integrity --------------------------------------------------
[[ $(stat -c %s "$IMAGE") -gt 1048576 ]] ||
  { bad "image file is smaller than 1 MiB"; exit 1; }

if [[ $IMAGE == *.xz ]]; then
  need xz
  xz -t -- "$IMAGE" 2>/dev/null && ok "xz stream passes integrity check" ||
    bad "xz -t failed: the artifact is corrupt"
  total_bytes=$(xz --robot --list -- "$IMAGE" 2>/dev/null | awk -F'\t' '/^totals/ {print $5}')
else
  total_bytes=$(stat -c %s "$IMAGE")
fi
[[ -n $total_bytes && $total_bytes -gt 0 ]] || { bad "cannot determine the uncompressed image size"; total_bytes=0; }
total_sectors=$((total_bytes / 512))
[[ $((total_bytes % 512)) -eq 0 ]] || bad "image size is not a multiple of the 512-byte sector"

sums_file=${IMAGE%/*}/SHA256SUMS
if [[ -f $sums_file ]] && grep -qF "  $(basename "$IMAGE")" "$sums_file"; then
  (cd "${IMAGE%/*}" && sha256sum -c --ignore-missing SHA256SUMS 2>/dev/null) >/dev/null &&
    ok "SHA256SUMS entry for the image verifies" || bad "sha256 mismatch against SHA256SUMS"
else
  echo "note: no SHA256SUMS entry for the image next to it; checksum not re-verified"
fi

# --- 2. partition table -----------------------------------------------------
carve 0 4096 "$work/head.img"
read -r p1_start p1_sectors p1_type p2_start p2_sectors p2_type < <(
  python3 - "$work/head.img" <<'PY'
import struct, sys
with open(sys.argv[1], "rb") as f:
    mbr = f.read(512)
if len(mbr) != 512 or mbr[510:512] != b"\x55\xaa":
    print("0 0 0 0 0 0"); raise SystemExit
rows = []
for i in range(4):
    e = mbr[446 + i * 16:446 + (i + 1) * 16]
    if e[4] == 0:
        continue
    start, size = struct.unpack("<II", e[8:12] + e[12:16])
    rows.append((start, size, e[4]))
if len(rows) == 2:
    print(*rows[0], *rows[1])
else:
    print("0 0 0 0 0 0")
PY
)

if [[ $p1_type == 0 ]]; then
  bad "the MBR is invalid (signature or partition count): not an Omarchy Pi image"
  exit 1
fi
[[ $p1_type == 12 || $p1_type == 0x0c || $p1_type == 14 || $p1_type == 6 ]] &&
  ok "partition 1 is a FAT type partition (type $p1_type)" ||
  bad "partition 1 has type $p1_type, expected a FAT type (0x0c)"
[[ $p1_start -eq 8192 ]] && ok "partition 1 starts at sector 8192 (4 MiB alignment)" ||
  bad "partition 1 starts at sector $p1_start, expected 8192"
[[ $p2_type == 131 || $p2_type == 0x83 ]] && ok "partition 2 is a Linux partition (type $p2_type)" ||
  bad "partition 2 has type $p2_type, expected 0x83 (Linux)"
[[ $p2_start -eq $((p1_start + p1_sectors)) ]] &&
  ok "partition 2 starts exactly where partition 1 ends" ||
  bad "partition 2 (start $p2_start) does not follow partition 1 (ends at $((p1_start + p1_sectors)))"
[[ $p2_sectors -gt 0 ]] || bad "partition 2 has no size"
if (( total_sectors > 0 )); then
  [[ $((p2_start + p2_sectors)) -eq $total_sectors ]] &&
    ok "partition 2 ends exactly at the end of the image" ||
    bad "partition 2 ends at sector $((p2_start + p2_sectors)) but the image ends at $total_sectors"
  [[ $((p1_start + p1_sectors)) -le $total_sectors ]] ||
    bad "partition 1 lies outside the image"
fi
[[ $p1_sectors -ge 524288 ]] && ok "boot partition is at least 256 MiB ($((p1_sectors / 2048)) MiB)" ||
  bad "boot partition is only $((p1_sectors / 2048)) MiB"
[[ $p2_sectors -ge 10485760 ]] && ok "root partition is at least 5 GiB ($((p2_sectors / 2097152)) GiB)" ||
  bad "root partition is only $((p2_sectors / 2097152)) GiB, too small for the desktop"

# --- 3. boot partition contents --------------------------------------------
carve "$p1_start" "$p1_sectors" "$work/boot.img"
fat_file() { mtype -i "$work/boot.img" "::/$1" 2>/dev/null; }
fat_present() { mdir -b -i "$work/boot.img" "::/" 2>/dev/null | grep -qxF "::/$1"; }

for f in kernel8.img initramfs-linux.img start4.elf fixup4.dat bcm2712-rpi-5-b.dtb config.txt cmdline.txt; do
  fat_present "$f" && ok "boot: $f present" || bad "boot: $f missing from the FAT partition"
done
if mdir -b -i "$work/boot.img" "::/overlays" 2>/dev/null | grep -q '^::/overlays/.'; then
  overlay_count=$(mdir -b -i "$work/boot.img" "::/overlays" 2>/dev/null | grep -c '^::/overlays/.')
  [[ $overlay_count -ge 10 ]] && ok "boot: overlays/ carries $overlay_count overlays" ||
    bad "boot: overlays/ has only $overlay_count entries"
else
  bad "boot: overlays/ is missing or empty"
fi

cmdline=$(fat_file "cmdline.txt" 2>/dev/null | tr -d '\r\n')
[[ -n $cmdline ]] && ok "boot: cmdline.txt is non-empty" || bad "boot: cmdline.txt is empty"
[[ $cmdline == *"root="* ]] && ok "boot: cmdline.txt sets root=" || bad "boot: cmdline.txt sets no root="
[[ $cmdline == *"rootwait"* ]] && ok "boot: cmdline.txt waits for the root device" || bad "boot: cmdline.txt lacks rootwait"
[[ $cmdline == *"console="* ]] && ok "boot: cmdline.txt defines a console" || bad "boot: cmdline.txt defines no console"
config=$(fat_file "config.txt" 2>/dev/null | tr -d '\r')
[[ $config == *enable_uart* ]] && ok "boot: config.txt enables the UART console" || bad "boot: config.txt does not enable_uart"

# --- 4. root filesystem head ------------------------------------------------
head_mib=64
head_sectors=$((head_mib * 2048))
carve "$p2_start" "$head_sectors" "$work/root-head.img"
sb_out=$(dumpe2fs -h "$work/root-head.img" 2>/dev/null)
if [[ -z $sb_out ]]; then
  bad "no ext filesystem at the start of partition 2"
else
  fs_blocks=$(awk -F': *' '/^Block count:/ {print $2}' <<<"$sb_out" | tr -d ' ')
  fs_block_size=$(awk -F': *' '/^Block size:/ {print $2}' <<<"$sb_out" | tr -d ' ')
  fs_state=$(awk -F': *' '/^Filesystem state:/ {print $2}' <<<"$sb_out")
  fs_features=$(awk -F': *' '/^Filesystem features:/ {print $2}' <<<"$sb_out")
  [[ $fs_features == *extent* ]] && ok "root: filesystem is ext4 (extent-based)" || bad "root: filesystem features do not include extent: $fs_features"
  [[ $fs_state == *clean* ]] && ok "root: filesystem state is clean" || bad "root: filesystem state is '$fs_state'"
  [[ $fs_block_size == 4096 || $fs_block_size == 1024 ]] || bad "root: unexpected block size $fs_block_size"
  if [[ -n $fs_blocks && -n $fs_block_size ]]; then
    [[ $((fs_blocks * fs_block_size / 512)) -eq $p2_sectors ]] &&
      ok "root: filesystem size matches the partition ($((fs_blocks * fs_block_size / 1048576)) MiB)" ||
      bad "root: filesystem ($((fs_blocks * fs_block_size / 1048576)) MiB) does not match partition 2 ($((p2_sectors / 2048)) MiB)"
  fi
fi

# --- 5. deep: files inside the root filesystem ------------------------------
if (( DEEP )); then
  carve "$p2_start" "$p2_sectors" "$work/root.img"
  dbg() { debugfs -R "$1" "$work/root.img" 2>/dev/null; }
  dbg_text() { debugfs -R "cat $1" "$work/root.img" 2>/dev/null; }
  dbg_mode() { dbg "stat $1" | sed -n '1s/.*Type: \([a-z]*\)[[:space:]]*Mode:[[:space:]]*\([0-7]\{4\}\).*/\1 \2/p'; }

  [[ -n $(dbg "stat /var/lib/omarchy/image/target") ]] &&
    ok "root: the image-target manifest exists" || bad "root: /var/lib/omarchy/image/target is missing"
  manifest=$(dbg_text "/var/lib/omarchy/image/target" | tr -d '\r\n')
  [[ $manifest == *format=1* && $manifest == *platform=aarch64-pi* ]] &&
    ok "root: manifest names format=1 platform=aarch64-pi" || bad "root: image manifest content is wrong: '$manifest'"
  mmode=$(dbg_mode "/var/lib/omarchy/image/target")
  [[ $mmode == "regular 0644" ]] && ok "root: manifest is a regular 0644 file" ||
    bad "root: manifest mode/shape is '$mmode', expected a regular 0644 file"

  [[ -n $(dbg "stat /var/lib/omarchy/provisioning/pending") ]] &&
    ok "root: first-boot owner provisioning is armed (pending marker)" || bad "root: provisioning pending marker is missing"

  fstab=$(dbg_text "/etc/fstab")
  [[ $fstab == *"/boot"*"vfat"* ]] && ok "root: fstab mounts the FAT boot partition at /boot" ||
    bad "root: fstab has no /boot vfat entry: $(head -3 <<<"$fstab" | tr '\n' ' ')"
  mid_size=$(dbg "stat /etc/machine-id" | sed -n 's/^User:.*Size: \([0-9]*\).*/\1/p')
  [[ $mid_size == 0 ]] && ok "root: machine-id is empty (first-boot semantics armed)" ||
    bad "root: /etc/machine-id is not empty ($mid_size bytes)"

  pacman_conf=$(dbg_text "/etc/pacman.conf")
  [[ $pacman_conf == *"[omarchy]"* ]] && ok "root: the [omarchy] repository is configured" ||
    bad "root: /etc/pacman.conf carries no [omarchy] repository"
  pkg_count=$(dbg "ls -p /var/lib/pacman/local" | grep -vc '/\.\.\?//$')
  [[ $pkg_count -ge 150 ]] && ok "root: pacman database lists $pkg_count packages" ||
    bad "root: pacman database lists only $pkg_count packages"
  for pkg_dir in omarchy-dev- linux-rpi- hyprland quickshell sddm raspberrypi-bootloader; do
    dbg "ls -p /var/lib/pacman/local" | grep -q "$pkg_dir" ||
      bad "root: package database lacks an entry matching '$pkg_dir*'"
  done && ok "root: key packages (omarchy-dev, linux-rpi, hyprland, quickshell, sddm, raspberrypi-bootloader) are registered"

  rmode=$(dbg_mode "/usr/lib/omarchy-pi/resize-root.sh")
  [[ $rmode == "regular 0755" ]] && ok "root: the first-boot resize script is executable" ||
    bad "root: resize script mode is '$rmode', expected 0755"
  [[ -n $(dbg "stat /usr/lib/systemd/system/omarchy-pi-resize.service") ]] &&
    ok "root: the resize unit is installed" || bad "root: omarchy-pi-resize.service is missing"
  dbg "ls -l /etc/systemd/system/multi-user.target.wants" 2>/dev/null | grep -q omarchy-pi-resize &&
    ok "root: the resize unit is enabled for the first boot" || bad "root: resize unit is not enabled in multi-user.target.wants"
  dbg "ls -l /etc/systemd/system/multi-user.target.wants" 2>/dev/null | grep -q omarchy-provision-owner &&
    ok "root: the owner-provisioning unit is enabled" || bad "root: provisioning unit is not enabled in multi-user.target.wants"
  dbg "ls -l /etc/systemd/system" 2>/dev/null | grep -q "display-manager.service" &&
    ok "root: a display manager (SDDM) is enabled" || bad "root: no display-manager.service symlink (SDDM not enabled)"
  ldsocache=$(dbg "stat /etc/ld.so.cache" | sed -n 's/^User:.*Size: \([0-9]*\).*/\1/p')
  [[ -n $ldsocache && $ldsocache -gt 0 ]] && ok "root: ld.so.cache was regenerated" ||
    bad "root: /etc/ld.so.cache is missing or empty"
else
  echo "note: shallow mode; in-image file checks (provisioning, pacman database, units) were not run. Use --deep where disk allows."
fi

# --- 6. what only a real Raspberry Pi 5 can prove ----------------------------
cat <<'HWLIST'

HARDWARE (requires a physical Raspberry Pi 5; NOT validated by this script):
  - the EEPROM bootloader picks up the card and start4.elf loads kernel8.img
  - the Pi 5 device tree and overlays apply; DRM/KMS brings up a display
  - Mesa v3d/VideoCore VII renders the Hyprland/Quickshell desktop
  - USB, network, HDMI audio and the serial console come up
  - omarchy-pi-resize grows the root partition on the first boot
  - omarchy-provision-owner presents the owner form on tty1, creates the user
  - SDDM starts and the session reaches the desktop; zram swap activates
Until these pass on hardware, the image is NOT hardware-validated.
HWLIST

if (( failures )); then
  echo "RESULT: FAILED ($failures static check(s) failed)"
  exit 1
fi
echo "RESULT: PASSED (all static checks; hardware items listed above remain unclaimed)"
exit 0
