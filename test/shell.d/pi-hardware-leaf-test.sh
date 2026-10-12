#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The Pi hardware leaf: gated by omarchy-hw-aarch64-pi, warning-only on a
# machine that lacks the DRM/v3d stack, and writing an mkinitcpio drop-in that
# filters hooks with no installed implementation.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
calls="$test_tmp/calls"
: >"$calls"

for command in omarchy-hw-aarch64-pi omarchy-pkg-present modinfo; do
  printf '#!/bin/bash\necho "$(basename "$0") $*" >>%q\nexit 0\n' "$calls" >"$stub_bin/$command"
  chmod +x "$stub_bin/$command"
done

# The leaf writes to /etc/mkinitcpio.conf.d by absolute path; a copy with the
# path rewritten to the fixture exercises the same code.
leaf="$test_tmp/pi-setup.sh"
sed "s|/etc/mkinitcpio.conf.d|$test_tmp/etc/mkinitcpio.conf.d|g" \
  "$ROOT/install/hardware/pi/setup.sh" >"$leaf"

# Not a Pi: nothing happens, no drop-in, no predicate calls from the leaf.
rm -rf "$test_tmp/etc" "$calls"
printf '#!/bin/bash\necho "omarchy-hw-aarch64-pi $*" >>%q\nexit 1\n' "$calls" >"$stub_bin/omarchy-hw-aarch64-pi"
chmod +x "$stub_bin/omarchy-hw-aarch64-pi"
PATH="$stub_bin:$ROOT/bin:$PATH" bash "$leaf" >/dev/null
[[ ! -f $test_tmp/etc/mkinitcpio.conf.d/pi-hooks.conf ]] || fail "a non-Pi gets no mkinitcpio drop-in"
[[ $(grep -c '^omarchy-hw-aarch64-pi' "$calls") == 1 ]] || fail "a non-Pi asks the predicate once"
[[ -z $(grep -v '^omarchy-hw-aarch64-pi' "$calls") ]] || fail "a non-Pi runs no other probes"
pass "the hardware leaf runs only on a Raspberry Pi"

# A Pi: the drop-in lands, and the machine probes ran. The directory exists
# wherever omarchy-settings installed the baseline drop-ins.
mkdir -p "$test_tmp/etc/mkinitcpio.conf.d"
printf '#!/bin/bash\necho "omarchy-hw-aarch64-pi $*" >>%q\nexit 0\n' "$calls" >"$stub_bin/omarchy-hw-aarch64-pi"
chmod +x "$stub_bin/omarchy-hw-aarch64-pi"
PATH="$stub_bin:$ROOT/bin:$PATH" bash "$leaf" >/dev/null 2>"$test_tmp/leaf-stderr"
grep -q "no /dev/dri nodes" "$test_tmp/leaf-stderr" || skip "this host has /dev/dri; the warning path is not exercised here"
[[ -f $test_tmp/etc/mkinitcpio.conf.d/pi-hooks.conf ]] || fail "a Pi gets the mkinitcpio drop-in"
grep -q omarchy-hw-aarch64-pi "$calls" || fail "the leaf asked the Pi predicate"
grep -q raspberrypi-bootloader "$calls" || fail "the leaf checked the boot-firmware package"
pass "the hardware leaf checks the Pi stack and writes the drop-in"

# The drop-in filters hooks with no implementation and keeps the rest. The
# fixture rewrites /usr/lib/initcpio into the test root, with base and udev
# implemented and btrfs-overlayfs (no aarch64 build in any repository) absent.
dropin="$test_tmp/etc/mkinitcpio.conf.d/pi-hooks.conf"
filtered="$test_tmp/pi-hooks-filtered.sh"
sed "s|/usr/lib/initcpio|$test_tmp/lib/initcpio|g" "$dropin" >"$filtered"
initcpio="$test_tmp/lib/initcpio"
mkdir -p "$initcpio/install" "$initcpio/hooks"
for hook in base udev keyboard kms; do
  : >"$initcpio/install/$hook"
done
HOOKS=(base udev plymouth btrfs-overlayfs microcode kms)
source "$filtered"
[[ ${HOOKS[*]} == "base udev kms" ]] ||
  fail "the drop-in filters only hooks with no implementation" "HOOKS: ${HOOKS[*]}"
pass "the drop-in keeps installed hooks and drops unavailable ones"

# Every hook Omarchy's baseline names that exists on the machine stays: the
# filter is availability-based, not an allowlist.
HOOKS=(base udev plymouth)
: >"$initcpio/install/plymouth"
source "$filtered"
[[ ${HOOKS[*]} == "base udev plymouth" ]] || fail "an available hook is never dropped"
pass "the filter is by availability, not by name"

# Idempotent: running the leaf again rewrites the same drop-in.
before=$(sha256sum "$dropin" | cut -d' ' -f1)
PATH="$stub_bin:$ROOT/bin:$PATH" bash "$leaf" >/dev/null
after=$(sha256sum "$dropin" | cut -d' ' -f1)
[[ $before == $after ]] || fail "the leaf is idempotent"
pass "the hardware leaf is idempotent"
