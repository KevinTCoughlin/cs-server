#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Print the CHANGELOG.md section of one release, for the GitHub release notes.
#
#   scripts/release-notes.sh <version> [changelog]
#
# <version> is 1.2.3 or v1.2.3. Fails when the changelog has no
# `## [1.2.3]` heading or the section is empty, so a tag pushed without a
# changelog entry stops the release instead of publishing empty notes.
set -euo pipefail

version="${1:-}"
changelog="${2:-CHANGELOG.md}"
version="${version#v}"

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: ${0##*/} <version> [changelog]   (version: 1.2.3 or v1.2.3)" >&2
    exit 2
fi
[[ -r "${changelog}" ]] || { echo "error: cannot read ${changelog}" >&2; exit 1; }

# From the line after `## [version]` up to the next `## [` heading or the
# link definitions at the end of the file.
notes=$(awk -v heading="## [${version}]" '
    index($0, heading) == 1 { found = 1; next }
    found && (/^## \[/ || /^\[[^]]+\]: /) { exit }
    found { print }
' "${changelog}")

# Trim leading and trailing blank lines.
notes=$(printf '%s\n' "${notes}" | sed -e '/./,$!d')
if [[ -z "${notes//[[:space:]]/}" ]]; then
    echo "error: ${changelog} has no notes under '## [${version}]'" >&2
    exit 1
fi
printf '%s\n' "${notes}"
