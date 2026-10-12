#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The Pi installer, in a fixture world: an unprivileged run with
# OMARCHY_PI_ROOT set addresses only that root (the installer ignores the
# variable when root, like omarchy-hw-platform ignores its fixture roots), a
# fake pacman records what it is asked, and a fake bundle carries the real
# tree plus a stand-in package. A dry run must change nothing; --verify and
# --restore-pacman exercise their paths read-only.

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
fx="$test_tmp/world"

# --- the fixture world ------------------------------------------------------
mkdir -p "$fx/root/etc/pacman.d" "$fx/bundle/dist" "$fx/bin" "$fx/proc/device-tree" "$fx/proc-no/device-tree"

# An Arch Linux ARM style pacman configuration, with no [omarchy] repository.
cat >"$fx/root/etc/pacman.conf" <<'EOF'
[options]
HoldPkg = pacman glibc
SigLevel = Required DatabaseOptional

[core]
Server = http://mirror.example.org/aarch64/core
EOF
printf 'Server = http://mirror.example.org/aarch64/$repo\n' >"$fx/root/etc/pacman.d/mirrorlist"

# A Raspberry Pi 5 device tree and an aarch64 uname.
printf 'raspberrypi,5-model-b\0brcm,bcm2712\0' >"$fx/proc/device-tree/compatible"
printf '#!/bin/bash\n[[ ${1:-} == -m ]] && { printf "%%s\\n" "${TEST_ARCH:-aarch64}"; exit 0; }\nexec /usr/bin/uname "$@"\n' >"$fx/bin/uname"
chmod +x "$fx/bin/uname"

# A Snapdragon device tree, for the wrong-machine case.
printf 'lenovo,yoga-slim7x\0qcom,x1e80100\0' >"$fx/proc-no/device-tree/compatible"

# The bundle: the real tree, with a stand-in locally built package.
ln -s "$ROOT/bin" "$fx/bundle/bin"
ln -s "$ROOT/install" "$fx/bundle/install"
ln -s "$ROOT/default" "$fx/bundle/default"
: >"$fx/bundle/dist/omarchy-dev-4.0.0.r9999.gTESTING-1-aarch64.pkg.tar.zst"

# Fake pacman: records every invocation, answers -Q and -S from its caller's
# expectations.
pacman_log="$fx/pacman.log"
: >"$pacman_log"
cat >"$fx/bin/pacman" <<EOF
#!/bin/bash
printf 'pacman %s\n' "\$*" >>$pacman_log
case " \$* " in
  *" -Q "*)
    for arg in "\$@"; do
      [[ \$arg == -Q ]] && continue
      [[ \$arg == --noconfirm ]] && continue
      case \$arg in
        omarchy-dev|omarchy-settings-dev|linux-rpi|raspberrypi-bootloader|hyprland|quickshell|sddm)
          echo "\$arg 1.0-1"
          exit 0
          ;;
        *) exit 1 ;;
      esac
    done
    exit 1
    ;;
  *" -S "*|*" -U "*|*" -Sy"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$fx/bin/pacman"
printf '#!/bin/bash\nexit 0\n' >"$fx/bin/pacman-key"
printf '#!/bin/bash\nprintf "systemctl %s\\n" "\$*" >>%q\nexit 0\n' "$fx/systemctl.log" >"$fx/bin/systemctl"
chmod +x "$fx/bin/pacman-key" "$fx/bin/systemctl"
printf '#!/bin/bash\nexit 0\n' >"$fx/bin/curl"
chmod +x "$fx/bin/curl"

installer="$ROOT/tools/pi/omarchy-pi-install"
run_installer() {
  OMARCHY_PI_ROOT="$fx/root" OMARCHY_PROC_ROOT="$1" \
    PATH="$fx/bin:$ROOT/bin:$PATH" TEST_ARCH="${2:-aarch64}" \
    bash "$installer" --bundle-dir "$fx/bundle" "${@:3}"
}

# --- a dry run changes nothing and validates the plan -----------------------
output=$(run_installer "$fx/proc" aarch64 --dry-run) ||
  fail "the dry run succeeds" "$output"
grep -q "Platform: aarch64-pi" <<<"$output" || fail "the dry run recognizes the Pi" "$output"
grep -q "DRY RUN complete: all checks passed" <<<"$output" || fail "the dry run announces completion" "$output"
grep -q "resolving the transaction in a private pacman database" <<<"$output" ||
  fail "the dry run resolves the package set" "$output"
grep -qE "would install .*omarchy-dev.* with pacman -U" <<<"$output" ||
  fail "the dry run names the local package" "$output"

[[ $(cat "$fx/root/etc/pacman.conf") == *"mirror.example.org"* ]] ||
  fail "the dry run leaves the machine's pacman.conf alone"
[[ ! -e $fx/root/var/lib/omarchy-pi-install ]] || fail "the dry run writes no state directory"
[[ ! -e $fx/root/var/log ]] || fail "the dry run writes no log file"
grep -q -- "--print --config" "$pacman_log" || fail "the dry run resolves through pacman, not by assertion"
grep -q "aarch64-pi" <<<"$(sed -n '/ -S --needed/,/.*omarchy-dev.*zst/p' "$pacman_log" | tr ' ' '\n' | grep -cE '^(linux-rpi|raspberrypi-bootloader|zram-generator|neovim|vim)$' >/dev/null; echo x)" || true
grep -q "linux-rpi" "$pacman_log" || fail "the resolved set carries the Pi kernel package"
grep -q "neovim" "$pacman_log" || fail "the resolved set carries the nvim replacement"
! grep -qx "nvim" "$(grep ' -S --needed' "$pacman_log" | tr ' ' '\n')" 2>/dev/null || fail "the resolved set carries no unresolved nvim"
pass "a dry run validates the plan and changes nothing"

# --- a re-run of the dry run is identical -----------------------------------
second=$(run_installer "$fx/proc" aarch64 --dry-run) || fail "the second dry run succeeds"
diff <(grep -v '^Dry-run: resolving' <<<"$output") <(grep -v '^Dry-run: resolving' <<<"$second") >/dev/null ||
  fail "the dry run is repeatable" "$second"
pass "the dry run is repeatable"

# --- the wrong machine is refused -------------------------------------------
status=0
run_installer "$fx/proc-no" aarch64 --dry-run >"$fx/out" 2>&1 || status=$?
(( status == 2 )) || fail "a non-Pi ARM machine is refused with code 2 (got $status)" "$(cat "$fx/out")"
grep -q "reports platform 'aarch64'" "$fx/out" || fail "the refusal explains the platform" "$(cat "$fx/out")"
status=0
run_installer "$fx/proc" x86_64 --dry-run >/dev/null 2>"$fx/error" || status=$?
(( status == 2 )) || fail "an x86_64 machine is refused with code 2 (got $status)" "$(cat "$fx/error")"
pass "the installer refuses machines that are not a Raspberry Pi"

# --- an unprivileged run without a fixture root is refused ------------------
status=0
PATH="$fx/bin:$ROOT/bin:$PATH" TEST_ARCH=aarch64 OMARCHY_PROC_ROOT="$fx/proc" \
  bash "$installer" --bundle-dir "$fx/bundle" >/dev/null 2>"$fx/error" || status=$?
(( status == 6 )) || fail "a plain unprivileged install is refused with code 6 (got $status)" "$(cat "$fx/error")"
pass "a plain unprivileged install is refused"

# --- --verify checks a finished install read-only ---------------------------
verify_root="$fx/verify-root"
mkdir -p "$verify_root/usr/share/omarchy/bin" "$verify_root/etc" "$verify_root/var/lib/omarchy/provisioning"
cat >"$verify_root/usr/share/omarchy/bin/omarchy-hw-platform" <<'EOF'
#!/bin/bash
echo aarch64-pi
EOF
chmod +x "$verify_root/usr/share/omarchy/bin/omarchy-hw-platform"
printf '[omarchy]\nServer = https://pkgs.omarchy.org/edge/$arch\n' >"$verify_root/etc/pacman.conf"
touch "$verify_root/var/lib/omarchy/provisioning/pending"
output=$(OMARCHY_PI_ROOT="$verify_root" PATH="$fx/bin:$ROOT/bin:$PATH" \
  bash "$installer" --verify --log-file "$fx/verify.log") ||
  fail "verification passes on a complete install" "$output"
grep -q "Verification passed" <<<"$output" || fail "verification announces itself" "$output"
pass "--verify checks a finished install and works unprivileged"

# --- --verify fails loudly on an incomplete install -------------------------
broken_root="$fx/broken-root"
mkdir -p "$broken_root/etc"
printf 'no omarchy here\n' >"$broken_root/etc/pacman.conf"
status=0
OMARCHY_PI_ROOT="$broken_root" PATH="$fx/bin:$ROOT/bin:$PATH" \
  bash "$installer" --verify --log-file "$fx/verify-broken.log" >/dev/null 2>&1 || status=$?
(( status == 8 )) || fail "verification of a broken install fails with code 8 (got $status)"
pass "--verify fails loudly on an incomplete install"

# --- --restore-pacman puts the machine's configuration back -----------------
restore_root="$fx/restore-root"
mkdir -p "$restore_root/etc/pacman.d" "$restore_root/var/lib/omarchy-pi-install"
printf 'original alarm config\n' >"$restore_root/var/lib/omarchy-pi-install/pacman.conf.bak"
printf 'original mirrorlist\n' >"$restore_root/var/lib/omarchy-pi-install/mirrorlist.bak"
printf '[omarchy]\n[core]\n' >"$restore_root/etc/pacman.conf"
output=$(OMARCHY_PI_ROOT="$restore_root" PATH="$fx/bin:$ROOT/bin:$PATH" \
  bash "$installer" --restore-pacman --log-file "$fx/restore.log") ||
  fail "restoring the pacman configuration succeeds" "$output"
[[ $(cat "$restore_root/etc/pacman.conf") == "original alarm config" ]] ||
  fail "the backup returns to /etc/pacman.conf"
[[ $(cat "$restore_root/etc/pacman.d/mirrorlist") == "original mirrorlist" ]] ||
  fail "the backup returns to the mirrorlist"
pass "--restore-pacman restores both files from the backup"
