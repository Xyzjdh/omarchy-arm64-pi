# Upstream synchronization

The port lives on `arm64-pi`, branched from upstream `quattro` at
`defbf90e` (6912 upstream commits). `upstream-quattro` tracks upstream
untouched. The whole port is six commits of small, documented, revertible
changes (see `docs/pi/porting-decisions.md`); nothing upstream owns was
rewritten.

## The ARM-only patch list (files this branch adds or changes)

**Added** (this branch only):

- `bin/omarchy-hw-aarch64-pi` — the Pi predicate
- `install/omarchy-aarch64-pi.packages` — the Pi platform manifest
- `install/omarchy-aarch64-missing.packages` — aarch64 name gaps
  (`nvim`, `vi`)
- `install/hardware/pi/setup.sh` — Pi hardware checks + initramfs hook
  filter
- `install/user/hardware/pi-low-graphics.sh` — default effects overlay
- `tools/pi/*` — installer, package builder, audit tooling, tests
- `test/shell.d/pi-*-test.sh` — the Pi tests
- `docs/pi/*`, `README-PI.md`, `CONTRIBUTING.md`

**Modified** (upstream files; every change is additive):

- `bin/omarchy-hw-platform` — `brcm,` tokens → `aarch64-pi`; manifest
  name accepted (+18/−7 lines)
- `bin/omarchy-pkg-defaults` — the `aarch64-pi` case; the
  aarch64-missing subtraction
- `install/omarchy-aarch64.packages` — the `neovim`/`vim` replacements
- `install/helpers/pacman.sh` — `aarch64-pi` reuses the aarch64
  templates and edge channel
- `install/hardware/all.sh`, `install/user/all.sh` — one `run_logged`
  line each
- `AGENTS.md` — one platform-list line
- `test/shell.d/base-test.sh` — the generic-aarch64 fixture becomes a
  Snapdragon board (its old Pi tokens now mean `aarch64-pi`); the Pi
  fixture added
- `test/shell.d/hw-platform-test.sh`, `platform-packages-test.sh`,
  `pacman-templates-test.sh` — learn the new platform
- `.gitignore` — tooling data and `dist/`

## Rebasing when upstream moves

```bash
git fetch origin
git rebase origin/quattro          # conflicts should be small: the files above
# resolve, then rerun the full suite:
./test/shell
python3 tools/pi/package-audit.py fetch && python3 tools/pi/package-audit.py check
python3 tools/pi/build-package.py  # new version: 4.0.0.r<new-count>.g<sha>-1
```

The rebuilt `omarchy-dev` version (upstream's own dev scheme:
`4.0.0.r<commit-count>.g<sha>`) sorts above upstream's published package
while the fork leads, and below it once upstream moves past — which is
exactly the takeover point for `pacman -Syu`. Deploy the rebased build
with `pacman -U`.

## Upstream contribution candidates

These changes belong upstream and should be proposed (never pushed
without authorization):

1. The `brcm,` device-tree family and the Pi platform split — the
   detector's architecture already supports it.
2. `omarchy-aarch64-missing.packages` + replacements — every aarch64
   platform needs it today (ALARM's `neovim` has no `provides=nvim`).
3. The availability-based initramfs hook filter — upstream's
   `btrfs-overlayfs` hook has no aarch64 build, which breaks kernel
   rebuilds on every non-Apple aarch64 machine.

## Rules kept while syncing

- Never commit to `upstream-quattro` or `quattro`
- One logical change per commit, upstream's style (see AGENTS.md "Git")
- No large upstream file is duplicated where a patch works
- The x86 and generic-aarch64 behavior stays byte-identical except the
  two documented aarch64-wide manifest additions
