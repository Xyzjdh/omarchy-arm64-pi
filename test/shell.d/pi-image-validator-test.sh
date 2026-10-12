#!/bin/bash

set -euo pipefail

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The image artifact validator on fixture images, built without privileges:
# a micro FAT and a sparse ext4 are assembled into a partitioned image with
# exactly the layout the builder writes (and the minimum sizes the validator
# demands), carrying every file the deep checks look for. The validator must
# deep-pass the well-formed image and reject one whose FAT lost its kernel.
#
# Needs mtools, dosfstools and e2fsprogs; without them the test skips, which
# also documents where the tooling has to be installed for a local run.

for tool in mkfs.vfat mtype mcopy mke2fs dumpe2fs debugfs; do
  command -v "$tool" >/dev/null 2>&1 ||
    { echo "ok - image validator test skipped ($tool not installed) # SKIP"; exit 0; }
done

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
fx="$test_tmp/fixture"

# --- the fixture root filesystem ----------------------------------------------
# Exactly the paths validate-image.sh --deep inspects, at the minimum sizes
# its partition checks accept (FAT 256 MiB, ext4 5 GiB -- sparse on disk).
BOOT_SECTORS=524288
ROOT_SECTORS=10485760
P1_START=8192
P2_START=$((P1_START + BOOT_SECTORS))
TOTAL_SECTORS=$((P2_START + ROOT_SECTORS))

mkdir -p "$fx/root/var/lib/omarchy/image" "$fx/root/var/lib/omarchy/provisioning"
printf 'format=1\nplatform=aarch64-pi\n' >"$fx/root/var/lib/omarchy/image/target"
chmod 0644 "$fx/root/var/lib/omarchy/image/target"
: >"$fx/root/var/lib/omarchy/provisioning/pending"
mkdir -p "$fx/root/etc/systemd/system/multi-user.target.wants"
printf '/dev/mmcblk0p1  /boot   vfat    defaults        0       0\n' >"$fx/root/etc/fstab"
: >"$fx/root/etc/machine-id"
# shellcheck disable=SC2016
# (the literal $arch is the pacman.conf content being written)
printf '[options]\n\n[omarchy]\nServer = https://pkgs.example.org/edge/$arch\n' >"$fx/root/etc/pacman.conf"
printf 'built by the image validator test\n' >"$fx/root/etc/ld.so.cache"
mkdir -p "$fx/root/var/lib/pacman/local"
for i in $(seq 1 160); do mkdir -p "$fx/root/var/lib/pacman/local/pkg$i-1-1"; done
for pkg in omarchy-dev-9.9.9-1 linux-rpi-9.9.9-1 hyprland-9.9.9-1 quickshell-9.9.9-1 sddm-9.9.9-1 raspberrypi-bootloader-9.9.9-1; do
  mkdir -p "$fx/root/var/lib/pacman/local/$pkg"
done
mkdir -p "$fx/root/usr/lib/omarchy-pi" "$fx/root/usr/lib/systemd/system"
printf '#!/bin/bash\nexit 0\n' >"$fx/root/usr/lib/omarchy-pi/resize-root.sh"
chmod 0755 "$fx/root/usr/lib/omarchy-pi/resize-root.sh"
printf '[Unit]\n' >"$fx/root/usr/lib/systemd/system/omarchy-pi-resize.service"
ln -s /usr/lib/systemd/system/omarchy-pi-resize.service \
  "$fx/root/etc/systemd/system/multi-user.target.wants/omarchy-pi-resize.service"
ln -s /usr/lib/systemd/system/omarchy-provision-owner.service \
  "$fx/root/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
ln -s /usr/lib/systemd/system/sddm.service \
  "$fx/root/etc/systemd/system/display-manager.service"

mke2fs -q -t ext4 -b 4096 -d "$fx/root" -E hash_seed=4f4d5049-4152-4d36-3430-303030303031 \
  "$fx/root.img" $((ROOT_SECTORS / 8)) ||
  fail "mke2fs builds the fixture ext4" "mke2fs failed"
[[ $(stat -c %s "$fx/root.img") -eq $((ROOT_SECTORS * 512)) ]] ||
  fail "mke2fs builds the fixture ext4" "unexpected root image size $(stat -c %s "$fx/root.img")"

# --- the fixture boot partition -------------------------------------------------
mkdir -p "$fx/boot"
dd if=/dev/zero of="$fx/boot/kernel8.img" bs=1M count=1 status=none
dd if=/dev/zero of="$fx/boot/initramfs-linux.img" bs=512 count=2048 status=none
printf 'firmware\n' >"$fx/boot/start4.elf"
printf 'firmware\n' >"$fx/boot/fixup4.dat"
printf 'dtb\n' >"$fx/boot/bcm2712-rpi-5-b.dtb"
printf 'enable_uart=1\n' >"$fx/boot/config.txt"
printf 'root=/dev/mmcblk0p2 rootwait console=serial0,115200 console=tty1\n' >"$fx/boot/cmdline.txt"
mkdir -p "$fx/boot/overlays"
for i in $(seq 1 12); do printf 'overlay\n' >"$fx/boot/overlays/overlay$i.dtbo"; done

mkfs.vfat -C -F 32 -n OMARCHYBOOT "$fx/boot.img" $((BOOT_SECTORS / 2)) ||
  fail "mkfs.vfat builds the fixture FAT" "mkfs.vfat failed"
mcopy -i "$fx/boot.img" -s "$fx/boot"/* ::/ ||
  fail "mkfs.vfat builds the fixture FAT" "mcopy failed"

# --- assemble the image -----------------------------------------------------------
assemble() {
  local out=$1 fat=$2
  truncate -s $((TOTAL_SECTORS * 512)) "$out"
  sfdisk --quiet --no-reread -- "$out" <<EOF
label: dos
label-id: 0x4f4d5049
unit: sectors

$P1_START, $BOOT_SECTORS, 0x0C
$P2_START, $ROOT_SECTORS, 0x83
EOF
  dd if="$fat" of="$out" bs=512 seek="$P1_START" conv=notrunc status=none
  dd if="$fx/root.img" of="$out" bs=512 seek="$P2_START" conv=notrunc,sparse status=none
}

assemble "$fx/good.img" "$fx/boot.img"

validator="$ROOT/tools/pi/validate-image.sh"
output=$("$validator" --deep "$fx/good.img" 2>&1) ||
  fail "the validator deep-passes a well-formed image" "$output"
grep -q "RESULT: PASSED" <<<"$output" ||
  fail "the validator announces PASSED" "$output"
grep -q "HARDWARE" <<<"$output" ||
  fail "the validator lists the hardware-only items" "$output"
grep -q "manifest names format=1 platform=aarch64-pi" <<<"$output" ||
  fail "the validator reads the image manifest in deep mode" "$output"

# --- a boot file lost from the FAT must fail the validator ------------------------
mkdir -p "$fx/boot-bad"
cp -r "$fx/boot"/* "$fx/boot-bad/"
rm "$fx/boot-bad/kernel8.img"
mkfs.vfat -C -F 32 -n OMARCHYBOOT "$fx/boot-bad.img" $((BOOT_SECTORS / 2)) >/dev/null
mcopy -i "$fx/boot-bad.img" -s "$fx/boot-bad"/* ::/
assemble "$fx/bad.img" "$fx/boot-bad.img"

if output=$("$validator" "$fx/bad.img" 2>&1); then
  fail "the validator rejects an image whose kernel8.img is missing" "$output"
fi
grep -q "kernel8.img missing" <<<"$output" ||
  fail "the rejection names the missing file" "$output"

echo "ok - the image validator passes a well-formed fixture and rejects a broken one"
