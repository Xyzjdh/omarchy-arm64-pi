# Contributing to Omarchy ARM64 (Pi port)

This port deliberately stays a thin platform layer on upstream Omarchy.
Before contributing, read:

- Upstream's `AGENTS.md` — style, naming, platforms, test conventions
- `docs/pi/porting-decisions.md` — every existing deviation and its
  rationale
- `docs/pi/upstream-sync.md` — the ARM-only patch list and what belongs
  upstream instead

## Ground rules

1. **Divergence is a cost.** A change that upstream could carry belongs
   upstream (propose it there, and only carry it here while waiting).
   A change only a Raspberry Pi needs belongs here, in the smallest
   form: a gated leaf, a manifest entry, one platform case.
2. **No invented facts.** Package availability claims must come from
   `tools/pi/package-audit.py` against the live repositories. Hardware
   behavior claims must come from the evidence log
   (`docs/pi/hardware-log-*.md`) or carry **[HW]**.
3. **Tests come with the change.** `test/shell.d/pi-*-test.sh` for
   behavior, fixture worlds for the installer, offline units for the
   tools. `./test/shell` must stay green.
4. **Never break the neighbors.** x86 and generic-aarch64 behavior stays
   byte-identical except the documented aarch64-wide manifest additions;
   upstream's test files change only where the platform semantics
   genuinely moved (see the fake_platform Snapdragon change).
5. **Safety invariants hold.** The installer never formats,
   repartitions, writes boot firmware, updates the EEPROM, or replaces
   the pacman configuration without a backup. A dry run changes
   nothing, and the tests prove it.
6. **Bash style is upstream's**: `[[ ]]`/`(( ))`, two-space indent, no
   tabs, `#!/bin/bash` shebangs in `bin/`, sourced install scripts
   without shebangs, shellcheck clean at `-S style`.

## Checklist for a change

- [ ] One logical change, one commit, upstream's message style
- [ ] `bash -n` + shellcheck on touched scripts
- [ ] `./test/shell` (or the focused subset) green
- [ ] Docs updated (`docs/pi/*`) if behavior, manifests or decisions
      changed
- [ ] Package audit re-run if manifests changed:
      `python3 tools/pi/package-audit.py fetch && python3 tools/pi/package-audit.py check`
- [ ] If the `omarchy` package content changed:
      `python3 tools/pi/build-package.py` builds, verifies and is
      byte-reproducible
