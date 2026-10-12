# Upstream audit (Phase 1)

Upstream: `omacom/omarchy`, branch `quattro`, commit
`defbf90e893e741067e48f4a27d2ec694c71358e` (6912 commits; latest tag
v4.0.0; the released `omarchy` 4.0.4-2 / `omarchy-settings` 4.0.4-6
packages in the `[omarchy]` repositories are cut from the earlier commit
`c668141e`). All statements below were verified by reading the tree at
`defbf90e` and by downloading the live repository databases and packages
(see `docs/pi/package-compatibility.md`).

## How upstream already supports aarch64 (before this port)

Quattro is **not** x86-only. It ships an explicit platform model:

- `bin/omarchy-hw-platform` — the single architecture/hardware detector.
  Prints `x86`, `aarch64` (every ARM machine without a family of its own —
  which upstream's AGENTS.md says includes Raspberry Pis today) or
  `aarch64-apple`. Detection: CPU architecture from `uname -m`, hardware
  family from the device-tree root `compatible` tokens (`apple,*` →
  Apple Silicon, `qcom,*` → plain aarch64), or, in an image build, from a
  root-owned manifest at `/var/lib/omarchy/image/target`. Privileged runs
  use `bash -p` and a clean environment; unprivileged tests can fake the
  device tree through `OMARCHY_PROC_ROOT` / `OMARCHY_SYS_ROOT` /
  `OMARCHY_IMAGE_ROOT` fixture roots.
- Package manifests are split by platform and composed by
  `bin/omarchy-pkg-defaults`: `install/omarchy-base.packages` (165
  entries) + `install/omarchy-aarch64.packages` (zram-generator)
  + `install/omarchy-<platform>.packages` (per family), minus
  `install/omarchy-x86_64-only.packages` (`gliff`,
  `superwhisper-bin`).
- Pacman repository templates per platform:
  `default/pacman/` (x86), `default/pacman/aarch64/`,
  `default/pacman/aarch64-apple/`. All aarch64 platforms get the **edge**
  channel only: `[omarchy] https://pkgs.omarchy.org/edge/$arch` on top of
  Arch Linux ARM's `[core] [extra] [alarm] [aur]` via Omarchy's ALARM
  mirror `https://arm-mirror.omarchy.org/$arch/$repo`.
  `install/helpers/pacman.sh` maps platform → template directory and
  default channel; `install/post-install/pacman.sh` installs
  `archlinuxarm-keyring` on non-Apple aarch64, initializes
  `pacman-key` and finally copies the platform's templates into
  `/etc/pacman.conf` + `/etc/pacman.d/mirrorlist`.
- A live **aarch64 build of the whole Omarchy stack exists today** in
  `https://pkgs.omarchy.org/edge/aarch64` (verified by downloading
  `omarchy.db`, 155 packages): `hyprland` 0.56.2, `quickshell` 0.3.2,
  `aquamarine`, `hyprtoolkit`, `yay`, `walker`, all `oma*` applications,
  `obsidian`, `omarchy-keyring`, and dev-channel packages
  `omarchy-dev` + `omarchy-settings-dev`
  (`4.0.0.r6912.gdefbf90-1`) built from exactly this port's baseline
  commit. The `omarchy` 4.0.4-2 aarch64 package (120 MB) was downloaded,
  SHA256-verified against the repo DB
  (`c315500c…eba0b8`) and unpacked to confirm layout and dependency set.
- Hardware dispatch: `install/hardware/all.sh` runs vendor-quirk leaves,
  each self-gated by a predicate (`omarchy-hw-nvidia` greps lspci, the
  Apple leaves gate on `omarchy-hw-aarch64-apple`, …). Nothing dispatches
  on bare `uname -m` in feature code.
- Boot chains that Omarchy cannot drive generically (Apple Silicon) are
  delegated through `bin/omarchy-lifecycle-dispatch` to platform packages
  (`omarchy-mac`, `omarchy-mac-boot`). Platforms that boot a generic chain
  (x86 and aarch64 today) register nothing.
- First boot: a deferred-provisioning install leaves
  `/var/lib/omarchy/provisioning/pending`;
  `omarchy-provision-owner.service` asks the owner form on tty1, creates
  the user, and hands off to SDDM. This is the same flow an ISO install
  uses.
- Runtime-profile files in `default/` decide platform-specific behavior
  at runtime (`default/settings-runtime-profile`): zram drop-in applies
  on every architecture (zram-generator arrives via
  `omarchy-aarch64.packages` on ARM), the Superwhisper dictation preset
  is removed on aarch64 by `install/user/dictation-default.sh`, oomd /
  mkinitcpio / limine drop-ins apply only where their packages exist.

## x86_64 / vendor assumptions found (with status)

| # | Location | Finding | Status for Pi 5 |
|---|---|---|---|
| 1 | `install/omarchy-base.packages` | `nvim` (Arch renamed the package; ALARM still ships `neovim` with no `provides=nvim`) | **Requires modification** (aarch64-wide replacement) |
| 2 | same | `vi` (no aarch64 build in any configured repo; nothing in Omarchy invokes `/usr/bin/vi`) | **Requires modification** (replacement `vim`) |
| 3 | same | `dotnet-runtime` | **Compatible** via `[omarchy]` aarch64 `dotnet-runtime-bin` (provides it) |
| 4 | same | `superwhisper-bin`, `gliff` | `gliff` **compatible** (upstream built it for aarch64 anyway); `superwhisper-bin` **unsupported on aarch64**, already excluded by `omarchy-x86_64-only.packages` — no change needed |
| 5 | `bin/omarchy-hw-x86`-gated code (windows-vm, multilib) | x86-only features gate on `omarchy-hw-x86` | **Compatible** (fails closed on ARM) |
| 6 | `install/hardware/nvidia.sh`, `vulkan.sh`, Intel/ASUS/Dell/Framework leaves | all gated by lspci/DMI predicates that cannot match on a Pi | **Compatible** (no-ops) |
| 7 | `default/pacman/` stable/rc templates | x86-only channels | **Compatible** (aarch64 platforms get edge templates; the Pi reuses the aarch64 ones) |
| 8 | `install/omarchy-other.packages` | x86 vendor packages (nvidia dkms, intel, T2, framework, broadcom-wl …) plus `limine`, `linux-omarchy`, `linux-firmware` | Not part of any platform set; the Pi needs none of them — the ALARM base provides `linux-rpi` + `raspberrypi-*` (see the Pi manifest) |
| 9 | `etc/mkinitcpio.conf.d/*`, limine drop-ins | generic boot chain pieces read only where their packages exist | **Compatible** (Pi keeps ALARM's firmware→kernel boot chain; Omarchy installs neither limine nor linux-omarchy there) |
| 10 | `bin/omarchy-pkg-defaults`, `install/helpers/pacman.sh`, `bin/omarchy-hw-platform` | platform switch statements enumerate `x86 | aarch64 | aarch64-apple` only | **Requires modification** (add `aarch64-pi`; this is the port's core patch) |
| 11 | `omarchy-dev` depends on `omarchy-security-functions` | not yet published in `[omarchy]` edge aarch64 (upstream packaging WIP; verified absent from the live repo DB) | Documented; the Pi build ships the script from `bin/` per the release recipe and omits the unsatisfiable dependency |

## Reference projects (research inputs, not copied)

- `sam-bee/omarchy-raspberrypi` (`d30100d`, squashed fork of an older
  quattro snapshot): a full-ISO approach — its own
  `install/arm64/` Python pipeline building a desktop payload, custom
  packages and a USB installer image, with a package policy that defers
  or excludes most of the desktop. That snapshot predates upstream's
  aarch64 platform framework and the `[omarchy]` aarch64 repository, so
  its heavy divergence (own payload builder, own update pipeline, RDP
  bootstrap) is not warranted anymore for a source port; this port
  instead adds one platform family to upstream's own machinery. Its Pi
  facts that remain valuable: DTB names for CM5 variants, the
  EEPROM-boot-order caution, and 16 GB installer-image sizing.
- `alexisraitano-myffu/omarchy` arm64 branch: repository does not exist
  publicly (clone fails, GitHub 404). Not usable; noted for honesty.

## Baseline branches

`quattro`/`upstream-quattro` track upstream untouched; every port change
commits to `arm64-pi` (branch created from `defbf90e`). The patch list
against upstream is enumerated in
`docs/pi/porting-decisions.md` and `docs/pi/upstream-sync.md`.
