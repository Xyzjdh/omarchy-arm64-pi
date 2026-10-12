#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The package audit tool's own units: synthetic repo databases, manifest
# parsing and resolution, all offline. The live-repository report it
# generates is docs/pi/package-compatibility.md.

require_command python3
python3 "$ROOT/tools/pi/test-package-audit.py" >/dev/null || fail "the package audit tool's unit tests pass"
pass "the package audit tool parses repo databases and resolves providers"

# The generated report stays in sync with the manifests: re-generating with
# the cached databases must classify every composed aarch64-pi entry, and the
# check subcommand must pass against the cached data.
if [[ ! -f $ROOT/tools/pi/data/omarchy.db ]]; then
  skip "no cached repository databases; run: python3 tools/pi/package-audit.py fetch"
  exit 0
fi
python3 "$ROOT/tools/pi/package-audit.py" check --skip-aur >/dev/null ||
  fail "every aarch64-pi package resolves against the cached repositories"
pass "the audit check passes for the aarch64-pi platform set"
