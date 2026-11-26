#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# The redistribution allowlist. maps/manifest.tsv is the table; this script
# is the only reader just fastdl, the image build and the publish check use.
#
#   scripts/cleared-maps.sh             one cleared name per line
#   scripts/cleared-maps.sh --uncleared pinned maps that are not cleared
#
# A row is cleared only when its fastdl column is exactly yes. A missing
# column, or any other value, is not cleared. MAPS_MANIFEST overrides the
# manifest path (the image build and the tests).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "${HERE}/.." && pwd)
MANIFEST="${MAPS_MANIFEST:-${ROOT}/maps/manifest.tsv}"

mode=cleared
if [[ "${1:-}" == "--uncleared" ]]; then
    mode=uncleared
elif [[ $# -gt 0 ]]; then
    echo "usage: ${0##*/} [--uncleared]" >&2
    exit 2
fi

[[ -f "${MANIFEST}" ]] || { echo "[cleared-maps] missing ${MANIFEST}" >&2; exit 1; }

while IFS= read -r row || [[ -n "${row}" ]]; do
    # A non-whitespace separator: IFS=tab would fold an empty column away.
    IFS=$'\037' read -r name _url _sum _license _attribution _extras fastdl <<< "${row//$'\t'/$'\037'}"
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
        echo "[cleared-maps] bad map name in ${MANIFEST}: ${name}" >&2
        exit 1
    fi
    if [[ "${fastdl:-no}" == yes ]]; then
        if [[ "${mode}" == cleared ]]; then
            printf '%s\n' "${name}"
        fi
    elif [[ "${mode}" == uncleared ]]; then
        printf '%s\n' "${name}"
    fi
done < "${MANIFEST}"
