# Porting decisions (Phase 1)

Every intentional deviation from upstream `quattro` @ `defbf90e`,
with rationale and revert path. Rule applied throughout: minimal modular
patches over rewrite; keep x86 and generic aarch64 behavior intact.

## D1 — New platform family `aarch64-pi` (device-tree `brcm,*`)

**Change**: `bin/omarchy-hw-platform` maps `brcm,` vendor tokens to
`aarch64-pi` (Pi 4/5/CM5 roots: `brcm,bcm2711`, `brcm,bcm2712`), accepts
`aarch64-pi` in image manifests, keeps the fail-closed contradiction
checks. New predicate `bin/omarchy-hw-aarch64-pi`.
**Rationale**: upstream's own naming/placement convention
(AGENTS.md "Platforms"); the Pi needs kernel/firmware/EEPROM packages and
memory-conscious defaults that generic aarch64 must not get.
**Revert**: delete the added token mapping + predicate.

## D2 — Pi platform manifest `install/omarchy-aarch64-pi.packages`

```
linux-rpi            # [core] 6.18.55 — Pi kernel, 4k pages (16k variant deliberately not used)
raspberrypi-bootloader  # [alarm] firmware + boot files (firmware owns the boot chain; we never write it)
raspberrypi-overlays   # [alarm] device-tree overlays
raspberrypi-utils      # [alarm] vcgencmd etc.
firmware-raspberrypi   # [alarm] VideoCore VII firmware
rpi5-eeprom            # [alarm] Pi 5 bootloader EEPROM update tooling (opt-in to run, never automatic)
```
**Rationale**: availability verified against live `[core]`/`[alarm]`
databases (see `docs/pi/package-compatibility.md`). `linux-rpi` (4k
pages) over `linux-rpi-16k`: 16k pages break assorted userspace (some
Electron builds, Wine, box64 targets) and offer no benefit at 4 GB RAM.
The EEPROM package installs *tooling only*; nothing in this port updates
the Pi's EEPROM automatically.
**Revert**: delete the file + the `omarchy-pkg-defaults` case line.

## D3 — `omarchy-pkg-defaults` learns `aarch64-pi` and the aarch64-missing filter

**Change**: platform case `aarch64-pi) lists=(base aarch64 pi)`; the
non-x86 composition now also subtracts a new
`install/omarchy-aarch64-missing.packages` list.
**Rationale**: composition stays upstream's algorithm (first occurrence
kept, in list order), extended by one input.
**Revert**: remove the case line and the subtraction.

## D4 — aarch64-wide package renames: `nvim`→`neovim`, `vi`→`vim`

**Change**: new `install/omarchy-aarch64-missing.packages` (nvim, vi,
each with reason); `neovim` + `vim` added to
`install/omarchy-aarch64.packages`.
**Rationale**: verified against live repo DBs — ALARM `[extra]` still
ships `neovim` 0.12.6 with **no** `provides=nvim`, and no repo ships
`vi`; pacman would fail on both names for every aarch64 platform
(upstream's own `bin/omarchy-default-editor` already maps `nvim` →
`omarchy-pkg-add neovim`). Upstream's stated preference is fixing gaps
at the source; the honest interim is a visible, documented replacement
list that dies the day ALARM syncs the rename (delete the two entries
then). This is the only change that touches a generic-aarch64 manifest,
and it is deliberately aarch64-wide, not Pi-only.
**Revert**: remove the two names from `omarchy-aarch64-missing.packages`
and the two additions in `omarchy-aarch64.packages`.

## D5 — Pi reuses the generic aarch64 pacman templates

**Change**: `install/helpers/pacman.sh` maps `aarch64-pi` to
`default/pacman/aarch64` templates and the `edge` default channel.
**Rationale**: the Pi needs exactly the aarch64 repository set
(`[omarchy]` edge + ALARM `[core] [extra] [alarm] [aur]`); a separate
`default/pacman/aarch64-pi/` directory would be a byte-identical copy
owned by `omarchy-settings`, forcing a settings rebuild for zero
behavioral difference. Mapping keeps the whole port inside the `omarchy`
package's files.
**Revert**: remove the two case additions.

## D6 — Pi hardware leaf under `install/hardware/pi/`

**Change**: `install/hardware/all.sh` gains `run_logged
"$OMARCHY_INSTALL/hardware/pi/all.sh"`; the leaf self-gates on
`omarchy-hw-aarch64-pi` and (a) installs nothing extra beyond D2's
packages, (b) records the platform's renderer/driver expectations in the
install log, (c) notes the EEPROM tooling opt-in. GPU driver itself is
Mesa `v3d` (VideoCore VII), pulled in by the compositor's Mesa
dependency — no vendor driver install exists or is needed.
**Rationale**: hardware truth belongs in the hardware dispatch, gated by
a predicate, not in platform switches scattered in scripts.
**Revert**: remove the leaf + its `all.sh` line.

## D7 — Pi default desktop effects overlay

**Change**: `install/user/all.sh` gains
`run_logged "$OMARCHY_INSTALL/user/hardware/pi-low-graphics.sh"`;
gated on `omarchy-hw-aarch64-pi`, it places upstream's own
`no-animations.lua` + `window-opaque.lua` toggle files in
`~/.local/state/omarchy/toggles/hypr/` — exactly the mechanism
`vm-no-animations.sh` uses for VMs, and reversible by the user via
upstream toggles (Appearance/Appearance menu).
**Rationale**: 4 GB shared RAM + VideoCore VII fill-rate: starting
without animations/blur is the sensible default; nothing is removed, the
user can re-enable both. Uses upstream toggle assets — no fork of the
desktop config.
**Revert**: remove the leaf + its line.

## D8 — Local build of the `omarchy` package from this fork

**Change**: `tools/pi/build-package.py` builds an `omarchy-dev`-style
package (name `omarchy-dev`, version `4.0.0.r<commit-count>.g<sha>-1`,
`provides=omarchy`, `conflicts=omarchy`) from the fork tree, reproducing
upstream's released PKGBUILD `package()` logic (bin/ minus debug helpers
→ `/usr/bin` + symlink into `/usr/share/omarchy/bin`; `install/`,
`themes/`, `migrations/`, `shell/`, `version` → `/usr/share/omarchy`;
alpm hooks; `/etc/skel` migration markers). Dependencies mirror the
upstream dev pair, minus `omarchy-security-functions` (not published in
`[omarchy]` edge aarch64 at audit time — the script itself ships in
`bin/` per the release recipe; see `docs/pi/upstream-audit.md` item 11).
`omarchy-settings-dev` is **not** rebuilt: the fork changes no `default/`
file, so upstream's published settings-dev (same baseline commit)
remains authoritative.
**Rationale**: installing from the fork requires a package that carries
the Pi platform code; naming/versioning exactly like upstream's dev
channel keeps `pacman -Syu` semantics honest (upstream's next r-bump
upgrades over ours, ours upgrades over upstream's when rebased+rebuilt).
**Revert**: install upstream's `omarchy`/`omarchy-dev` instead; nothing
else depends on the local build.

## D9 — Standalone installer `tools/pi/omarchy-pi-install`

**Change**: a single-entry installer for an already-booted ALARM aarch64
system (the supported path: an Arch Linux ARM Raspberry Pi image).
Phases: environment validation → repo/keyring setup (HTTPS +
SHA256-verified keyring package, `pacman-key --populate omarchy`) →
install local `omarchy-dev` (`pacman -U`, LocalFileSigLevel=Optional per
upstream template) → install the composed aarch64-pi package set via
upstream's `omarchy-pkg-defaults` → run upstream's
`omarchy-apply-system --defer-provisioning --first-install` → arm
first-boot owner provisioning → verify. Supports `--dry-run`, `--verify`,
`--log-file`, `--bundle-dir`; idempotent; never formats/partitions or
touches boot files; backs up `/etc/pacman.conf` and the mirrorlist with
restore instructions.
**Rationale**: upstream installs through its ISO; the Pi path needs the
equivalent for an existing base, reusing upstream machinery
(`omarchy-pkg-defaults`, `omarchy-apply-system`, provisioning) instead
of reimplementing setup.
**Revert**: the installer is additive; nothing upstream calls it.

## D10 — Documentation under `docs/pi/`, README-PI.md, no clobber

Upstream already has `docs/` files (testing.md, …). To keep rebase
conflicts near zero, the port's docs live in `docs/pi/*` and
`README-PI.md`; only AGENTS.md gains one platform-table line. The
user-requested doc names map 1:1 (`docs/build-environment.md` →
`docs/pi/build-environment.md`, etc.).

## Verification status of each decision

- D2 package existence: **verified against live repo DBs** (Phase 4
  tooling, `tools/pi/package-audit.py check` exits 0).
- D4 gaps: **verified** (live DBs; `neovim` has no `provides=nvim`).
- D1, D3, D5–D7: **tested by fixture-based unit tests** in
  `test/shell.d/` (fake device tree, fake pacman) plus upstream's own
  suite.
- D8: **structure-verified** against the unpacked upstream package
  (`omarchy-pkg/` reference layout).
- D9: **dry-run verified** in a fixture environment; real-device run
  requires a Pi (see `docs/pi/hardware-validation.md`).
