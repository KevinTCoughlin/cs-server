#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# The config bind mounts are listed by hand in five places. Every
# config/mapcycle*.txt, server.cfg and config/modes/ must appear in each, or
# edits to that file silently need an image rebuild on that deployment path.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"

failed=0
# expect <file> <min count> <fixed string>
expect() {
    local file="$1" min="$2" needle="$3" count
    count=$(grep -cF -- "${needle}" "${file}" || true)
    if [[ "${count}" -lt "${min}" ]]; then
        printf '%s: expected %s occurrence(s) of %s, found %s\n' "${file}" "${min}" "${needle}" "${count}" >&2
        failed=1
    fi
}

names=(server.cfg)
for f in config/mapcycle*.txt; do
    names+=("${f##*/}")
done

for name in "${names[@]}"; do
    target=":/hlds/cstrike/${name}:ro"
    expect compose.yml 1 "${target}"
    expect quadlet/scoutzknivez.container 1 "${target}"
    expect justfile 1 "${target}"
    # install.sh mounts twice: the Quadlet unit and `docker run`.
    expect install.sh 2 "${target}"
done

# ops/cs-server and install.sh seed from one CONFIG_FILES array each.
for file in ops/cs-server install.sh; do
    line=$(grep -m1 '^CONFIG_FILES=(' "${file}") || line=""
    for name in "${names[@]}"; do
        if [[ " ${line#*(} " != *[\ \(]"${name}"[\ \)]* ]]; then
            printf '%s: CONFIG_FILES is missing %s\n' "${file}" "${name}" >&2
            failed=1
        fi
    done
done

modes=":/hlds/cstrike/modes:ro"
expect compose.yml 1 "${modes}"
expect quadlet/scoutzknivez.container 1 "${modes}"
expect justfile 1 "${modes}"
expect ops/cs-server 1 "${modes}"
expect install.sh 2 "${modes}"

[[ "${failed}" -eq 0 ]] || exit 1
printf 'mount tests passed\n'
