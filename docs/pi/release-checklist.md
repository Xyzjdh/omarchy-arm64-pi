# Release checklist

Honest labels, in order (pick the one the evidence supports):

1. **Experimental source port** — automated tests pass; no hardware runs
2. **Installable development build** — 1. plus at least one successful
   full install on a real Pi 5
3. **Hardware-validated release candidate** — 2. plus the full
   `docs/pi/hardware-validation.md` checklist passed
4. **Stable release** — 3. plus recovery drills and an update cycle on
   hardware

## Current status: experimental source port

## Before any release

- [ ] `git status` clean; the branch is `arm64-pi`; `upstream-quattro`
      untouched
- [ ] `./test/shell` — no regressions in the platform subset
      (16 platform+Pi files pass; record the numbers)
- [ ] `python3 tools/pi/package-audit.py fetch &&
      python3 tools/pi/package-audit.py check` — the whole aarch64-pi
      set resolves against the live repositories
- [ ] `python3 tools/pi/build-package.py` — builds, self-verifies, and
      a second build produces the identical sha256
- [ ] `bash tools/pi/omarchy-pi-install --dry-run` in the fixture world
      (the test does this; re-run it)
- [ ] Shellcheck clean: `tools/pi/bin/shellcheck -S style
      bin/omarchy-hw-platform bin/omarchy-hw-aarch64-pi
      bin/omarchy-pkg-defaults tools/pi/omarchy-pi-install
      tools/pi/test-bin/pacman-conf`
- [ ] No secrets, tokens, keys or personal data in the tree:
      `git log -p | grep -iE 'token|secret|password|BEGIN.*PRIVATE'`
      finds nothing real
- [ ] `docs/pi/*` matches the implementation (manifests, exit codes,
      file names)
- [ ] The upstream baseline commit is recorded in
      `docs/pi/upstream-audit.md` and `git merge-base`

## Artifacts

- [ ] Release bundle: `git archive` of `arm64-pi` (or a tarball of the
      checkout) plus `dist/omarchy-dev-<ver>-aarch64.pkg.tar.zst` and
      its `.sha256`
- [ ] `SHA256SUMS` covering every artifact, `sha256sum -c` passes
- [ ] Release notes naming: the label, the upstream commit, the built
      package version, the open hardware items
- [ ] SD-card image (dispatch `build-pi-image.yml` with `publish=true`):
      deep validation passed in the run, `build-report.txt` uploaded, parts
      joined and `SHA256SUMS.image` verified locally before announcing

## Publishing (requires explicit authorization — never done by an agent
without it)

- [ ] Push branch / tag, upload bundle, announce — only with the
  owner's sign-off
- [ ] Image publication happens through the owner's `publish=true`
      dispatch (first authorized 2026-10-12); record every such dispatch
      in the release notes
