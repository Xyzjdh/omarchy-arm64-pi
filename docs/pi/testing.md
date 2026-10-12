# Testing

The port's tests live in upstream's harness (`test/shell.d/*-test.sh`,
run by `./test/shell`), so they run with — and are counted with —
upstream's own suite. Pi-specific files:

| File | Covers |
|---|---|
| `test/shell.d/hw-platform-test.sh` | (upstream, extended) Pi 4/5/CM5 device trees → `aarch64-pi`; vendor-prefix anchoring; `brcm` contradictions; the Pi predicate; root ignoring fixtures |
| `test/shell.d/platform-packages-test.sh` | (upstream, extended) the aarch64-pi composition: base − x86_64-only − aarch64-missing + aarch64 + pi lists; Pi additions only on Pi; replacements on every aarch64 set |
| `test/shell.d/pacman-templates-test.sh` | (upstream, extended) `aarch64-pi` reuses the aarch64 templates, defaults to edge, resolves the same repositories |
| `test/shell.d/pi-low-graphics-test.sh` | the user overlay places upstream's toggle assets on a Pi and nowhere else |
| `test/shell.d/pi-hardware-leaf-test.sh` | the hardware leaf gates on the predicate, probes the stack, writes the mkinitcpio hook filter, filters by availability, and is idempotent |
| `test/shell.d/pi-installer-test.sh` | the installer in a fixture world: dry run changes nothing and resolves the transaction through a private pacman database; wrong machines and unprivileged runs are refused; `--verify` passes/fails correctly; `--restore-pacman` restores |
| `test/shell.d/pi-package-audit-test.sh` | the audit tool's units + the cached-repository check for the whole aarch64-pi set |
| `tools/pi/test-package-audit.py` | offline units: repo-db parsing, manifest parsing, name/provides resolution, composition agreement |

## Running

```bash
./test/shell                                   # upstream's aggregate runner
bash test/shell.d/pi-installer-test.sh         # one file
python3 tools/pi/test-package-audit.py         # the audit tool's units
tools/pi/bin/shellcheck -S style bin/omarchy-hw-aarch64-pi tools/pi/omarchy-pi-install
python3 -m py_compile tools/pi/*.py
```

On a host without `pacman-conf` (any non-Arch dev box), prepend the
faithful stub to run the pacman-template tests:

```bash
PATH="$PWD/tools/pi/test-bin:$PATH" bash test/shell.d/pacman-templates-test.sh
```

## Static checks

- `bash -n` on every new or modified script
- `shellcheck` (0.10.0, vendored as a static binary in
  `tools/pi/bin/` on the dev container because the host has no package
  manager access; on an Arch host use the distribution's shellcheck)
  at `-S style`, clean on every new `bin/` script and installer
- `python3 -m py_compile` on the tools
- Install-tree scripts intentionally omit shebangs (upstream convention
  for sourced scripts, per AGENTS.md)

## Package verification

`tools/pi/build-package.py` self-verifies every build: metadata order,
`.PKGINFO` correctness, mtree digests for every payload file, root
ownership everywhere, no debug helpers shipped, the Pi manifest and
hardware leaf present. The builder was additionally diffed entry-by-entry
against the unpacked upstream `omarchy` 4.0.4-2 aarch64 package during
development; the only structural differences were source drift between
upstream's release commit and this port's baseline. Rebuilding from the
same commit produces byte-identical archives (verified).

## What automated tests cannot cover

Everything marked **[HW]** in `docs/pi/troubleshooting.md`:
actual DRM/KMS output, v3d rendering under Hyprland, first boot on the
metal, Wi-Fi/BT firmware loading, audio, thermal behavior at 4 GB, and
real pacman transactions. The honest checklist is
`docs/pi/hardware-validation.md`.
