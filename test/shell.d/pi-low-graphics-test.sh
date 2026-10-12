#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The Pi's default-effects overlay: the same mechanism vm-no-animations.sh
# uses, gated on omarchy-hw-aarch64-pi instead of omarchy-hw-vm.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

for virt in pi not-pi; do
  test_home="$test_tmp/home-$virt"
  mkdir -p "$test_home"
  printf '#!/bin/bash\n[[ %s == pi ]]\n' "$virt" >"$stub_bin/omarchy-hw-aarch64-pi"
  chmod +x "$stub_bin/omarchy-hw-aarch64-pi"
  flags="$test_home/.local/state/omarchy/toggles/hypr"
  HOME="$test_home" OMARCHY_PATH="$ROOT" PATH="$stub_bin:$PATH" \
    bash "$ROOT/install/user/hardware/pi-low-graphics.sh" >/dev/null
  if [[ $virt == pi ]]; then
    [[ -f $flags/no-animations.lua ]] || fail "a Pi install turns animations off"
    [[ -f $flags/window-opaque.lua ]] || fail "a Pi install starts with opaque windows"
  else
    [[ ! -f $flags/no-animations.lua ]] || fail "a machine that is not a Pi keeps its animations"
    [[ ! -f $flags/window-opaque.lua ]] || fail "a machine that is not a Pi keeps transparent windows"
  fi
done
pass "a Pi install starts without animations and with opaque windows"

# The flags are upstream's own toggle assets, so the user can undo the default
# with omarchy-toggle-animations; nothing here invents new toggle files.
[[ -f $ROOT/default/hypr/toggles/no-animations.lua ]] || fail "upstream ships the no-animations toggle"
[[ -f $ROOT/default/hypr/toggles/window-opaque.lua ]] || fail "upstream ships the window-opaque toggle"
pass "the overlay places upstream's own toggle assets"
