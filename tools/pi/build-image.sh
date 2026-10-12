#!/bin/bash

# Build the Omarchy aarch64-pi bootable SD-card image for the Raspberry Pi 5.
#
# The image carries a complete Arch Linux ARM aarch64 root filesystem with the
# whole Omarchy desktop preinstalled, a FAT boot partition holding the Pi
# firmware, kernel, device trees and overlays, and first-boot owner
# provisioning armed -- so flashing it is the whole install.
#
# How it stays honest about what it is:
#   * the system in the image is installed by the port's own tested installer
#     (tools/pi/omarchy-pi-install) running in a chroot, not by an ad-hoc
#     script; the platform is declared through the image-target manifest the
#     platform detector reads while a root is being built
#   * the image is never claimed validated on hardware: tools/pi/validate-image.sh
#     checks what is statically provable and lists the hardware-only items
#
# Safety: everything happens inside WORK-DIR. The only block devices touched
# are the loop device attached to the image file this script creates, and the
# chroot is confined to the mounted image. Physical disks are never opened.
#
# Environment: runs as root on an aarch64 host (a GitHub arm64 runner is the
# reference), or with --qemu on an x86_64 host with qemu-aarch64-static and
# binfmt_misc registered (scriptlets exec other binaries, so binfmt is
# required on emulated hosts). Requires: sfdisk, losetup, mkfs.vfat (dosfstools),
# mtools, mkfs.ext4/e2fsck (e2fsprogs), fsck.vfat, xz, curl, tar.
#
# Usage: build-image.sh [options]
#   --work-dir DIR     scratch directory (default: ./build/work; needs ~25 GiB)
#   --out-dir DIR      artifact directory (default: ./build/out)
#   --label TEXT       image name suffix (default: <date>-g<short commit>)
#   --alarm-tarball F  use this ALARM rootfs tarball instead of downloading
#   --alarm-url URL    rootfs tarball URL (default: os.archlinuxarm.org rpi-aarch64)
#   --alarm-sha256 S   enforce this checksum for the rootfs (pin)
#   --root-gib N       root partition size (default: 12)
#   --boot-gib N       boot partition size (default: 1)
#   --dist-package F   omarchy-dev aarch64 package (default: bundle's dist/)
#   --qemu             emulate aarch64 on an x86_64 host
#   --validate MODE    artifact validation: deep (default) or shallow
#   --clean            remove the work directory on success
#   -h, --help
#
# Exit codes: 0 built; 1 usage; 2 missing tools/privileges/space; 3 rootfs
# tarball problem; 4 image creation/partitioning failure; 5 chroot bootstrap
# failure; 6 the Omarchy installer failed; 7 finalization or validation failed.

set -euo pipefail

ALARM_URL_DEFAULT=http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz
ROOT_GIB_DEFAULT=12
BOOT_GIB_DEFAULT=1
LABEL_ID=0x4f4d5049 # fixed MBR disk signature: PARTUUID stays 4f4d5049-0X
HASH_SEED=4f4d5049-4152-4d36-3430-303030303031

WORK_DIR=""; OUT_DIR=""; LABEL=""; ALARM_TARBALL=""; ALARM_URL=""
ALARM_SHA256=""; DIST_PACKAGE=""; ROOT_GIB=$ROOT_GIB_DEFAULT; BOOT_GIB=$BOOT_GIB_DEFAULT
EMULATE=0; VALIDATE_MODE=deep; CLEAN=0

usage() {
  cat <<USAGE
Usage: build-image.sh [options]

Options:
  --work-dir DIR     scratch directory (default: ./build/work; needs ~26 GiB)
  --out-dir DIR      artifact directory (default: ./build/out)
  --label TEXT       image name suffix (default: <date>-g<short commit>)
  --alarm-tarball F  use this ALARM rootfs tarball instead of downloading
  --alarm-url URL    rootfs tarball URL (default: os.archlinuxarm.org rpi-aarch64)
  --alarm-sha256 S   enforce this checksum for the rootfs (pin)
  --root-gib N       root partition size in GiB (default: 12)
  --boot-gib N       boot partition size in GiB (default: 1)
  --dist-package F   omarchy-dev aarch64 package (default: bundle's dist/)
  --qemu             emulate aarch64 on an x86_64 host
  --validate MODE    artifact validation: deep (default) or shallow
  --clean            remove the work directory on success
  -h, --help         this help

Exit codes: 0 built; 1 usage; 2 missing tools/privileges/space; 3 rootfs
 tarball problem; 4 image creation/partitioning failure; 5 chroot bootstrap
 failure; 6 the Omarchy installer failed; 7 finalization or validation failed.
USAGE
}

die() { local code=$1; shift; echo "build-image: ERROR: $*" >&2; echo "build-image: exiting with code $code" >&2; exit "$code"; }
log() { echo "build-image: $*"; }

while (($#)); do
  case $1 in
    --work-dir) WORK_DIR=${2:-}; shift ;;
    --out-dir) OUT_DIR=${2:-}; shift ;;
    --label) LABEL=${2:-}; shift ;;
    --alarm-tarball) ALARM_TARBALL=${2:-}; shift ;;
    --alarm-url) ALARM_URL=${2:-}; shift ;;
    --alarm-sha256) ALARM_SHA256=${2:-}; shift ;;
    --root-gib) ROOT_GIB=${2:-}; shift ;;
    --boot-gib) BOOT_GIB=${2:-}; shift ;;
    --dist-package) DIST_PACKAGE=${2:-}; shift ;;
    --qemu) EMULATE=1 ;;
    --validate) VALIDATE_MODE=${2:-deep}; shift ;;
    --clean) CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# --- prerequisites ------------------------------------------------------------
[[ $(id -u) -eq 0 ]] || die 2 "must run as root (loop devices and chroot are needed); only -h runs unprivileged"

for tool in sfdisk losetup mkfs.vfat fsck.vfat mtype mkfs.ext4 e2fsck xz curl sha256sum dd bsdtar; do
  command -v "$tool" >/dev/null 2>&1 || die 2 "required tool '$tool' is not installed"
done

if [[ $(uname -m) != "aarch64" && $EMULATE -eq 0 ]]; then
  die 2 "this host is $(uname -m): use --qemu with qemu-aarch64-static, or build on an aarch64 host"
fi
if (( EMULATE )); then
  QEMU_BIN=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
  [[ -n $QEMU_BIN ]] || die 2 "--qemu needs qemu-aarch64-static in PATH"
  if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    log "WARNING: binfmt_misc has no qemu-aarch64 entry; package scriptlets exec other"
    log "binaries and will fail unless binfmt is registered (update-binfmts --enable)."
  fi
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUNDLE_DIR=$(cd -- "$script_dir/../.." && pwd)
[[ -f $BUNDLE_DIR/bin/omarchy-hw-platform && -d $BUNDLE_DIR/install ]] ||
  die 1 "bundle incomplete at $BUNDLE_DIR (bin/, install/, default/, dist/)"

ALARM_URL=${ALARM_URL:-$ALARM_URL_DEFAULT}
WORK_DIR=${WORK_DIR:-$BUNDLE_DIR/build/work}
OUT_DIR=${OUT_DIR:-$BUNDLE_DIR/build/out}
mkdir -p "$WORK_DIR" "$OUT_DIR"
case "$WORK_DIR" in /dev/*|/proc/*|/sys/*) die 2 "refusing to use $WORK_DIR as the work directory" ;; esac

LABEL=${LABEL:-$(date -u +%Y.%m.%d)-g$(git -C "$BUNDLE_DIR" rev-parse --short HEAD 2>/dev/null || echo image)}
IMG="$WORK_DIR/omarchy-arm64-pi-$LABEL-aarch64.img"

# --- the port's package -------------------------------------------------------
if [[ -n $DIST_PACKAGE ]]; then
  [[ -f $DIST_PACKAGE ]] || die 1 "--dist-package $DIST_PACKAGE does not exist"
  mkdir -p "$BUNDLE_DIR/dist"
  cp -f -- "$DIST_PACKAGE" "$BUNDLE_DIR/dist/"
fi
mapfile -t dist_pkgs < <(compgen -G "$BUNDLE_DIR/dist/omarchy-dev-*-aarch64.pkg.tar.zst")
((${#dist_pkgs[@]} == 1)) || die 1 "expected exactly one omarchy-dev-*-aarch64.pkg.tar.zst in $BUNDLE_DIR/dist/ (build it: python3 tools/pi/build-package.py)"
DIST_PACKAGE=${dist_pkgs[0]}
DIST_SHA256=$(sha256sum "$DIST_PACKAGE" | awk '{print $1}')
log "port package: $(basename "$DIST_PACKAGE") (sha256 $DIST_SHA256)"

# --- 1. the Arch Linux ARM root filesystem ------------------------------------
if [[ -z $ALARM_TARBALL ]]; then
  ALARM_TARBALL="$WORK_DIR/$(basename "$ALARM_URL")"
  [[ -f $ALARM_TARBALL ]] || {
    log "downloading the ALARM rootfs: $ALARM_URL"
    curl -fL --retry 3 -o "$ALARM_TARBALL" "$ALARM_URL" || die 3 "could not download the ALARM rootfs"
  }
fi
ACTUAL_SHA256=$(sha256sum "$ALARM_TARBALL" | awk '{print $1}')
log "ALARM rootfs: $(basename "$ALARM_TARBALL") (sha256 $ACTUAL_SHA256)"
if [[ -n $ALARM_SHA256 && $ALARM_SHA256 != "$ACTUAL_SHA256" ]]; then
  die 3 "rootfs checksum mismatch: pinned $ALARM_SHA256, got $ACTUAL_SHA256"
fi

# --- 2. image file and partitions ---------------------------------------------
BOOT_SECTORS=$((BOOT_GIB * 2097152))
ROOT_SECTORS=$((ROOT_GIB * 2097152))
P1_START=8192
P2_START=$((P1_START + BOOT_SECTORS))
TOTAL_SECTORS=$((P2_START + ROOT_SECTORS))

need_bytes=$(( (TOTAL_SECTORS * 512) + $(stat -c %s "$ALARM_TARBALL") + 3221225472 ))
[[ $VALIDATE_MODE == deep ]] && need_bytes=$(( need_bytes + ROOT_GIB * 1073741824 + 536870912 ))
avail_bytes=$(df -B1 --output=avail "$WORK_DIR" | tail -1 | tr -dc '0-9')
(( avail_bytes > need_bytes )) ||
  die 2 "work dir $WORK_DIR has $((avail_bytes / 1073741824)) GiB free; this build needs ~$((need_bytes / 1073741824)) GiB (image + tarball + validation + compression)"

rm -f -- "$IMG"
truncate -s $((TOTAL_SECTORS * 512)) "$IMG"
sfdisk --quiet --no-reread -- "$IMG" <<EOF
label: dos
label-id: $LABEL_ID
unit: sectors

$P1_START, $BOOT_SECTORS, 0x0C
$P2_START, $ROOT_SECTORS, 0x83
EOF
[[ -s $IMG ]] || die 4 "could not write the partition table"

LOOP=$(losetup --find --partscan --show "$IMG") || die 4 "no loop device available for $IMG"
log "image: $IMG ($((TOTAL_SECTORS / 2097152)) GiB) on $LOOP (p1 FAT $BOOT_GIB GiB, p2 ext4 $ROOT_GIB GiB)"
ROOTFS="$WORK_DIR/rootfs"
BOOTFS="$WORK_DIR/boot-fs"
# Daemons started inside the chroot (gpg-agent from pacman-key above all)
# keep the rootfs busy after the installer exits; they must be stopped before
# the image can be unmounted and checked.
kill_rootfs_processes() {
  local proc pid root signal=$1
  for proc in /proc/[0-9]*; do
    pid=${proc#/proc/}
    root=$(readlink "$proc/root" 2>/dev/null) || continue
    [[ $root == "$ROOTFS" || $root == "$ROOTFS"/* ]] || continue
    kill -"$signal" "$pid" 2>/dev/null || true
  done
}
cleanup() {
  set +e
  kill_rootfs_processes TERM 2>/dev/null
  sleep 1
  kill_rootfs_processes KILL 2>/dev/null
  local mounted
  for mounted in \
    "$(mount | awk -v r="$ROOTFS" '$3 ~ "^" r "/" {print $3}' | sort -r)" \
    "$ROOTFS/opt/omarchy-port" "$ROOTFS"; do
    [[ -n $mounted ]] || continue
    umount -R "$mounted" 2>/dev/null || umount -l "$mounted" 2>/dev/null
  done
  losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

mkfs.vfat -F 32 -n OMARCHYBOOT "${LOOP}p1" || die 4 "could not format the boot partition"
mkfs.ext4 -F -q -b 4096 -E "hash_seed=$HASH_SEED,lazy_itable_init=0,lazy_journal_init=0" -L omarchy-root "${LOOP}p2" ||
  die 4 "could not format the root partition"

# --- 3. base root filesystem ---------------------------------------------------
mkdir -p "$ROOTFS"
mount "${LOOP}p2" "$ROOTFS" || die 4 "could not mount the root partition"
log "extracting the ALARM rootfs with bsdtar (it preserves the tarball's security.capability xattrs, which GNU tar would drop)"
bsdtar -xpf "$ALARM_TARBALL" -C "$ROOTFS"

mkdir -p "$ROOTFS/opt/omarchy-port"
mount --bind "$BUNDLE_DIR" "$ROOTFS/opt/omarchy-port" || die 5 "could not bind the bundle into the chroot"
# The pacman download cache lives on the work filesystem, not in the image:
# the platform transaction's 1.6 GiB of downloads then needs none of the
# root partition's space, and the image ships an empty package cache.
mkdir -p "$WORK_DIR/pacman-cache" "$ROOTFS/var/cache/pacman/pkg"
mount --bind "$WORK_DIR/pacman-cache" "$ROOTFS/var/cache/pacman/pkg" ||
  die 5 "could not bind the pacman cache outside the image"
for sub in proc sys dev; do
  mount --rbind /$sub "$ROOTFS/$sub" || die 5 "could not bind $sub into the chroot"
  mount --make-rslave "$ROOTFS/$sub" || true
done
install -m 0644 /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null ||
  echo "nameserver 1.1.1.1" >"$ROOTFS/etc/resolv.conf"

chroot_run() {
  if (( EMULATE )); then
    chroot "$ROOTFS" "$QEMU_BIN" "$@"
  else
    chroot "$ROOTFS" "$@"
  fi
}

# --- 4. chroot bootstrap -------------------------------------------------------
# The image-target manifest: while this root is being built rather than booted,
# omarchy-hw-platform reads the platform from here, cross-checked against the
# CPU. Written before anything consults the detector.
install -D -m 0644 -o root -g root /dev/null "$ROOTFS/var/lib/omarchy/image/target"
printf 'format=1\nplatform=aarch64-pi\n# written by tools/pi/build-image.sh\n' >"$ROOTFS/var/lib/omarchy/image/target"

# The ALARM tarball ships a populated pacman database but no initialized
# keyring: bring the trust chain up exactly the way the ALARM setup
# instructions do, then refresh pacman itself so the [omarchy] template's
# DownloadUser=alpm user exists (created by pacman's sysusers hook) before
# the installer relies on it.
log "chroot: initializing the pacman keyring (archlinuxarm)"
chroot_run /bin/bash -e -c 'pacman-key --init && pacman-key --populate archlinuxarm' ||
  die 5 "pacman-key --init/--populate archlinuxarm failed in the chroot"
log "chroot: refreshing pacman and zstd (needed by the installer's keyring phase)"
chroot_run /bin/bash -e -c 'pacman -Sy --noconfirm --needed pacman zstd' ||
  die 5 "pacman -Sy pacman zstd failed in the chroot"

# --- 5. the port's own installer, in the chroot --------------------------------
log "chroot: running the Omarchy Pi installer (the port's tested path)"
if ! chroot_run /bin/bash -e /opt/omarchy-port/tools/pi/omarchy-pi-install \
  --bundle-dir /opt/omarchy-port \
  --log-file /var/log/omarchy-pi-image-install.log; then
  echo "build-image: installer failed; its log tail:" >&2
  tail -n 40 "$ROOTFS/var/log/omarchy-pi-image-install.log" >&2 2>/dev/null || true
  echo "build-image: omarchy-apply-system's log tail (if it ran):" >&2
  tail -n 60 "$ROOTFS/var/log/omarchy-install.log" >&2 2>/dev/null || true
  cp -f "$ROOTFS/var/log/omarchy-install.log" "$OUT_DIR/" 2>/dev/null || true
  die 6 "the Omarchy installer failed inside the chroot (log: $WORK_DIR/installer.log)"
fi

# --- 6. image layer on top of the installed system -----------------------------
log "chroot: applying the image layer (boot files, first-boot resize, identity)"

# Deterministic boot files: these are the firmware's inputs, and they are the
# ones the ALARM flow keeps on the FAT partition (copied there in step 7).
cat >"$ROOTFS/boot/cmdline.txt" <<'EOF'
root=/dev/mmcblk0p2 rootwait console=serial0,115200 console=tty1
EOF
cat >"$ROOTFS/boot/config.txt" <<'EOF'
# Omarchy aarch64-pi image (Raspberry Pi 5). The firmware defaults boot the
# kernel and apply the device tree; only the serial console is enabled here.
enable_uart=1
EOF

# First-boot resize: grow partition 2 to the card, before the owner form runs.
install -D -m 0755 "$BUNDLE_DIR/tools/pi/image/resize-root.sh" "$ROOTFS/usr/lib/omarchy-pi/resize-root.sh"
install -D -m 0644 "$BUNDLE_DIR/tools/pi/image/omarchy-pi-resize.service" \
  "$ROOTFS/usr/lib/systemd/system/omarchy-pi-resize.service"
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/omarchy-pi-resize.service \
  "$ROOTFS/etc/systemd/system/multi-user.target.wants/omarchy-pi-resize.service"

# Deterministic first-boot identity: ALARM's documented root password, an
# empty machine-id (ConditionFirstBoot semantics, fresh host identity), and
# no carried-over entropy seeds.
chroot_run /bin/bash -e -c "printf 'root:alarm\n' | chpasswd" || die 7 "could not set the root password"
: >"$ROOTFS/etc/machine-id"
rm -f "$ROOTFS/var/lib/systemd/random-seed"

# Remove what no installed package owns in /boot and /usr/lib/modules: the
# ALARM tarball's generic aarch64 kernel (Image, dtbs/, 7.x modules) is
# untracked and would otherwise ride along to the boot partition.
chroot_run /bin/bash -s <<'CLEANUP' || die 7 "the untracked-boot cleanup failed"
set -e
for f in /boot/*; do
  [[ -e "$f" ]] || continue
  case "$(basename "$f")" in config.txt | cmdline.txt) continue ;; esac
  if ! pacman -Qo -- "$f" >/dev/null 2>&1; then
    echo "omarchy-image: removing untracked boot file: $f"
    rm -rf -- "$f"
  fi
done
for d in /usr/lib/modules/*; do
  [[ -d "$d" ]] || continue
  if ! pacman -Qo -- "$d" >/dev/null 2>&1; then
    echo "omarchy-image: removing untracked modules directory: $d"
    rm -rf -- "$d"
  fi
done
rm -f /var/cache/pacman/pkg/*.pkg.tar.zst /var/cache/pacman/pkg/*.pkg.tar.zst.sig
ldconfig
CLEANUP

cp -f "$ROOTFS/var/log/omarchy-pi-image-install.log" "$OUT_DIR/" 2>/dev/null || true
cp -f "$ROOTFS/var/log/pacman.log" "$OUT_DIR/pacman-image.log" 2>/dev/null || true
cp -f "$ROOTFS/var/log/omarchy-install.log" "$OUT_DIR/" 2>/dev/null || true
chroot_run /bin/bash -c 'pacman -Q | sort' >"$WORK_DIR/image-packages.txt" 2>/dev/null || true

# --- 7. populate the boot partition, then leave /boot as its mountpoint --------
mkdir -p "$BOOTFS"
mount "${LOOP}p1" "$BOOTFS" || die 7 "could not mount the boot partition"
log "copying the boot files to the FAT partition"
cp -a "$ROOTFS/boot/." "$BOOTFS/" || die 7 "could not populate the boot partition"
sync
log "leaving /boot empty in the root filesystem (the FAT partition mounts there)"
find "$ROOTFS/boot" -mindepth 1 -delete
umount "$BOOTFS"

# --- 8. teardown and filesystem checks -----------------------------------------
log "stopping chroot daemons and unmounting the image filesystems"
kill_rootfs_processes TERM
sleep 2
kill_rootfs_processes KILL
set +e
for sub in proc sys dev; do umount -R "$ROOTFS/$sub" 2>/dev/null || umount -l "$ROOTFS/$sub" 2>/dev/null; done
umount -R "$ROOTFS/opt/omarchy-port" 2>/dev/null || umount -l "$ROOTFS/opt/omarchy-port" 2>/dev/null
umount "$ROOTFS/var/cache/pacman/pkg" 2>/dev/null || umount -l "$ROOTFS/var/cache/pacman/pkg" 2>/dev/null
umount "$ROOTFS" 2>/dev/null || umount -l "$ROOTFS" 2>/dev/null
mount | grep -q " $ROOTFS" && { umount -R "$ROOTFS" 2>/dev/null; mount | grep -q " $ROOTFS" && die 7 "$ROOTFS could not be unmounted"; }
mount | grep -q " $BOOTFS" && { umount -R "$BOOTFS" 2>/dev/null || true; }
set -e
log "checking filesystems (e2fsck, fsck.vfat)"
rc=0; e2fsck -fy "${LOOP}p2" || rc=$?
(( rc <= 1 )) || die 7 "e2fsck failed on the root partition (exit $rc)"
rc=0; fsck.vfat -p "${LOOP}p1" || rc=$?
(( rc <= 1 )) || die 7 "fsck.vfat failed on the boot partition (exit $rc)"

# --- 9. validation --------------------------------------------------------------
log "validating the image ($VALIDATE_MODE)"
if [[ $VALIDATE_MODE == "deep" ]]; then
  "$BUNDLE_DIR/tools/pi/validate-image.sh" --deep "$IMG" || die 7 "image validation failed"
else
  "$BUNDLE_DIR/tools/pi/validate-image.sh" "$IMG" || die 7 "image validation failed"
fi

# --- 10. artifact ---------------------------------------------------------------
log "compressing the image (xz -6, threaded)"
xz -T0 -6 -- "$IMG"
IMG_XZ="$IMG.xz"
IMG_SHA256=$(sha256sum "$IMG_XZ" | awk '{print $1}')
ARTIFACT="$OUT_DIR/$(basename "$IMG_XZ")"
mv -f -- "$IMG_XZ" "$ARTIFACT"

{
  echo "Omarchy aarch64-pi image build report"
  echo "===================================="
  echo "built:        $(date -u +'%Y-%m-%d %H:%M UTC') on $(uname -sr) ($(uname -m)$( ((EMULATE)) && echo ', emulated'))"
  echo "bundle:       $BUNDLE_DIR at $(git -C "$BUNDLE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "artifact:     $(basename "$ARTIFACT")"
  echo "image size:   $((TOTAL_SECTORS * 512 / 1073741824)) GiB raw ($(( TOTAL_SECTORS / 2097152 )) GiB), $(stat -c %s "$ARTIFACT") bytes compressed"
  echo "sha256:       $IMG_SHA256"
  echo
  echo "pins:"
  echo "  alarm-rootfs: $ALARM_URL"
  echo "    sha256: $ACTUAL_SHA256"
  echo "  omarchy-dev:  $(basename "$DIST_PACKAGE")"
  echo "    sha256: $DIST_SHA256"
  echo
  echo "partitions: p1 start $P1_START size $BOOT_SECTORS sectors (0x0C, FAT32, $BOOT_GIB GiB);"
  echo "             p2 start $P2_START size $ROOT_SECTORS sectors (0x83, Linux, $ROOT_GIB GiB)"
  echo "             MBR label-id $LABEL_ID (PARTUUID 4f4d5049-01/-02), image $TOTAL_SECTORS sectors"
  echo
  echo "installed packages: $(wc -l <"$WORK_DIR/image-packages.txt") (list in image-packages.txt)"
  echo "first boot: root:alarm until the owner form creates your user; machine-id empty;"
  echo "            omarchy-pi-resize grows partition 2; omarchy-provision-owner runs on tty1."
  echo
  echo "Validation: static checks passed ($VALIDATE_MODE mode). NOT validated on"
  echo "hardware: see the HARDWARE list tools/pi/validate-image.sh prints."
} >"$OUT_DIR/build-report.txt"
cp -f "$WORK_DIR/image-packages.txt" "$OUT_DIR/" 2>/dev/null || true
(cd "$OUT_DIR" && sha256sum "$(basename "$ARTIFACT")" build-report.txt >SHA256SUMS)

losetup -d "$LOOP"
trap - EXIT
(( CLEAN )) && rm -rf -- "$WORK_DIR"

log "done: $ARTIFACT"
log "sha256: $IMG_SHA256"
log "flash with Raspberry Pi Imager (choose OS -> Use custom -> the .img.xz) or: xzcat '$ARTIFACT' | dd of=/dev/sdX bs=4M conv=fsync status=progress"
