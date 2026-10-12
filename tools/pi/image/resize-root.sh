#!/bin/bash

# Grow the Omarchy Pi root partition to fill the card it was written to.
#
# omarchy-pi-image: the image ships a root partition sized to its contents so
# it fits on 16 GB cards; omarchy-pi-resize.service runs this once on the
# first boot, grows the LAST partition on the root device to the end of its
# disk and resizes the ext4 filesystem online. Anything it cannot prove safe
# is skipped with a logged error: a failed resize never blocks the boot.
#
# Only the root partition is touched, and only by growing it in place from
# its own start sector: the boot partition, the partition table of any other
# disk, and all data stay as they are. Re-running is a no-op.

set -uo pipefail

log() {
  local line
  line="omarchy-pi-resize: $*"
  echo "$line"
  echo "$line" >>/var/log/omarchy-pi-resize.log 2>/dev/null || true
}

skip() {
  log "SKIP: $*"
  log "The root filesystem was not resized; booting continues unchanged."
  exit 0
}

[[ $(id -u) -eq 0 ]] || skip "not running as root"

root_dev=$(findmnt -n -o SOURCE /) || skip "cannot find the root device"
root_dev=$(readlink -f "$root_dev")
[[ -b $root_dev ]] || skip "root device $root_dev is not a block device"

# /dev/mmcblk0p2 and /dev/nvme0n1p2 carry a p before the partition number,
# /dev/sda2 does not.
disk=""
part=""
if [[ $root_dev =~ ^(.+[^0-9])p([0-9]+)$ ]]; then
  disk=${BASH_REMATCH[1]}
  part=${BASH_REMATCH[2]}
elif [[ $root_dev =~ ^(.*/[^0-9/]+)([0-9]+)$ ]]; then
  disk=${BASH_REMATCH[1]}
  part=${BASH_REMATCH[2]}
else
  skip "cannot parse the root device name $root_dev"
fi
[[ -b $disk ]] || skip "root sits on $root_dev but $disk is not a block device"

# Partition numbers beyond our own mean data follows the root partition:
# resizing the last partition is only safe when ours IS the last one.
last_part=$(sfdisk -l "$disk" 2>/dev/null | awk '/^\/dev/ {print $1}' | sed 's/.*[^0-9]//' | sort -n | tail -1)
[[ $last_part == "$part" ]] ||
  skip "partition $part is not the last one on $disk (last is ${last_part:-none}); a partition behind the root would be overwritten"

total_sectors=$(blockdev --getsz "$disk") || skip "cannot read the size of $disk"
start_sector=$(sfdisk -o Start --noheadings -n "$part" "$disk" 2>/dev/null | tr -dc '0-9')
end_sector=$(sfdisk -o End --noheadings -n "$part" "$disk" 2>/dev/null | tr -dc '0-9')
[[ -n $start_sector && -n $end_sector ]] || skip "cannot read partition $part of $disk"
(( start_sector > 0 && end_sector >= start_sector )) || skip "implausible partition $part: start $start_sector end $end_sector"

part_type=$(sfdisk -o Type --noheadings -n "$part" "$disk" 2>/dev/null | tr -dc '0-9A-Fa-fxX' | tr 'a-f' 'A-F')
[[ $part_type == 83 || $part_type == 0X83 ]] || skip "partition $part is not a Linux partition (type ${part_type:-unknown})"

if (( end_sector >= total_sectors - 1 )); then
  log "partition $part already reaches the end of $disk"
else
  new_size=$((total_sectors - start_sector))
  log "growing $root_dev from sector $start_sector, size $((end_sector - start_sector + 1)) to $new_size sectors"
  printf 'start=%s, size=%s, type=83\n' "$start_sector" "$new_size" |
    sfdisk --no-reread --force -n "$part" "$disk" >>/var/log/omarchy-pi-resize.log 2>&1 ||
    skip "sfdisk refused to rewrite partition $part on $disk"
  partx --update "$disk" >>/var/log/omarchy-pi-resize.log 2>&1 ||
    log "partx could not refresh the partition sizes; trying resize2fs anyway"
fi

resize2fs "$root_dev" >>/var/log/omarchy-pi-resize.log 2>&1 ||
  skip "resize2fs failed on $root_dev (it may already be at the partition size)"

log "root filesystem resized: $(findmnt -n -o SIZE /) on $root_dev"
exit 0
