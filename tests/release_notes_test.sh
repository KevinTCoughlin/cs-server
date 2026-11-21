#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# scripts/release-notes.sh: the section it cuts out of a changelog, and that a
# release without one fails. Also checks the real CHANGELOG.md is well formed.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
NOTES="${ROOT}/scripts/release-notes.sh"

cat > "${WORK}/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [1.1.0] - 2027-01-02

### Added
- second release

## [1.0.0] - 2026-12-01

### Changed
- first release
- [a link](https://example.com) at the start of a line

## [0.9.0] - 2026-11-01

[Unreleased]: https://example.com/compare/v1.1.0...HEAD
[1.1.0]: https://example.com/compare/v1.0.0...v1.1.0
EOF

run() {
    set +e
    output=$(bash "${NOTES}" "$@" 2>&1)
    status=$?
    set -e
}

run 1.0.0 "${WORK}/CHANGELOG.md"
assert_eq "1.0.0: exit status" 0 "${status}"
assert_eq "1.0.0: only its own section, blank edges trimmed" '### Changed
- first release
- [a link](https://example.com) at the start of a line' "${output}"

run v1.1.0 "${WORK}/CHANGELOG.md"
assert_eq "a leading v is accepted" '### Added
- second release' "${output}"

run 0.9.0 "${WORK}/CHANGELOG.md"
assert_eq "empty section: exit status" 1 "${status}"
assert_contains "empty section: says why" "${output}" "no notes under '## [0.9.0]'"

run 2.0.0 "${WORK}/CHANGELOG.md"
assert_eq "missing section: exit status" 1 "${status}"

run 1.0 "${WORK}/CHANGELOG.md"
assert_eq "partial version: exit status" 2 "${status}"
run
assert_eq "no version: exit status" 2 "${status}"

# The real changelog: an [Unreleased] heading first, and every released
# version has notes this script can cut out.
first=$(grep -m1 '^## \[' "${ROOT}/CHANGELOG.md")
assert_eq "CHANGELOG.md starts with [Unreleased]" "## [Unreleased]" "${first}"
while IFS= read -r version; do
    run "${version}" "${ROOT}/CHANGELOG.md"
    assert_eq "CHANGELOG.md has notes for ${version}" 0 "${status}"
done < <(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "${ROOT}/CHANGELOG.md")

printf 'release-notes tests passed\n'
