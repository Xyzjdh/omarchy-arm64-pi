# Architecture compatibility (Phase 1)

How the port separates x86 PCs, generic ARM64, and Raspberry Pi 5 —
following the platform conventions upstream already established
(`AGENTS.md` → "Platforms"): a platform name is the CPU architecture,
then a hardware family only when that family needs code of its own.

## Platform names

| Platform | Meaning | Chosen by |
|---|---|---|
| `x86` | every x86_64 machine | upstream, unchanged |
| `aarch64` | every ARM machine without a family of its own | upstream, unchanged |
| `aarch64-apple` | Apple Silicon Macs | upstream, unchanged |
| `aarch64-pi` | **Raspberry Pi (BCM2711/BCM2712 family) — new in this port** | new |

`aarch64-pi` is added exactly the way AGENTS.md prescribes for a new
family ("added only once it needs code of its own"): the Pi needs kernel,
boot firmware and EEPROM packages from `[alarm]`/`[core]`, its own
hardware-setup leaf, and memory-conscious desktop defaults — that is code
of its own, so it gets a family. Every other ARM machine keeps the plain
`aarch64` behavior bit-for-bit.

## Detection (the compatibility layer)

Only `bin/omarchy-hw-platform` decides the platform — feature code asks
helpers, never `uname -m` or the device tree directly (upstream rule,
kept). The port extends the existing detector in place:

1. **Architecture**: `uname -m` (`aarch64` / `x86_64`), as upstream.
2. **Hardware family**: device-tree root `compatible` tokens, NUL
   separated, by vendor prefix — upstream already maps `apple,*` and
   `qcom,*`; the port adds `brcm,*` → Raspberry Pi family (Pi 4's root
   is `brcm,bcm2711`, Pi 5's is `brcm,bcm2712`, CM5 variants share the
   `brcm,bcm2712` root with board-specific suffixes). Contradictory
   tokens (e.g. both `apple,` and `brcm,`) fail closed exactly like
   upstream's Apple/Qualiforn contradiction check.
3. **Image builds**: the manifest at `/var/lib/omarchy/image/target`
   learns the new `aarch64-pi` value (format=1 unchanged); a manifest
   naming `aarch64-pi` on a non-aarch64 CPU is refused, as upstream
   refuses the others.
4. **Root caller hardening**: unchanged (`bash -p`, clean environment,
   fixture roots honored only for unprivileged tests).

A new predicate `bin/omarchy-hw-aarch64-pi` (mirroring
`omarchy-hw-aarch64-apple`) answers "is this a Raspberry Pi family
machine" for conditionals in hardware/user setup.

Exit codes of the detector are upstream's: 0 with the platform name on
stdout; 1 on contradictory identity or unreadable architecture; 126 if
launched without `-p` hardening.

## What each layer owns

| Concern | Owner | Pi behavior |
|---|---|---|
| Architecture identification | `omarchy-hw-platform` (+ `omarchy-hw-x86`, `omarchy-hw-aarch64`) | `aarch64` |
| Hardware identification | `omarchy-hw-platform`, `omarchy-hw-aarch64-pi` (new) | `aarch64-pi` |
| Package resolution | `omarchy-pkg-defaults` composition + pacman repo order `[omarchy] > [core] > [extra] > [alarm] > [aur]` | base + aarch64 + `omarchy-aarch64-pi.packages` minus x86_64-only minus `omarchy-aarch64-missing.packages` replacements |
| Package install/remove | upstream `omarchy-pkg-*` helpers, unchanged | unchanged |
| Platform system configuration | `install/hardware/pi/*` leafs (new), self-gated | kernel/firmware/EEPROM packages, audio, GPU notes |
| Platform user configuration | `install/user/hardware/pi-low-graphics.sh` (new), gated | reduced default effects |
| Boot chain | the ALARM base's firmware → `linux-rpi` chain, untouched | Omarchy installs no bootloader on the Pi and registers nothing in `omarchy-lifecycle-dispatch` — the generic aarch64 path, like Snapdragon laptops |
| Safe install/rollback | `tools/pi/omarchy-pi-install` (new, see `docs/pi/installation.md`) | dry-run, backups, idempotent steps |
| Diagnostics | install log + `--verify` mode + `tools/pi/package-audit.py check` | documented exit codes |

## Guarantees

- No ARM run ever executes an x86-specific bootloader, firmware or GPU
  operation: every such leaf in `install/hardware/all.sh` is predicate
  gated (`omarchy-hw-nvidia`, lspci, DMI — none can match on a Pi), and
  the Pi's own leafs run only under `omarchy-hw-aarch64-pi`.
- The Pi installer never formats, repartitions, or overwrites the boot
  chain: it changes no bootloader files and leaves
  `/boot/firmware` (ALARM's boot partition mount) alone.
- Upstream's x86 and generic-aarch64 behavior is untouched except for
  the two-line package rename below, which is aarch64-wide and
  documented.
