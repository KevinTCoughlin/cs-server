#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Map names the movement rotations play. The published image bakes in only
# the intersection with scripts/cleared-maps.sh (maps/manifest.tsv rows whose
# fastdl column is yes). A private build (MAP_POLICY=local, `just build`)
# copies whatever scripts/fetch-maps.sh put in maps/. Nipper and stock maps
# are not included: nipper stays out of the published image, and the stock
# maps are already in it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

files=("${ROOT}/config/mapcycle-climb.txt" "${ROOT}/config/mapcycle-surf.txt")
if [[ -f "${ROOT}/config/mapcycle-movement.txt" ]]; then
    files+=("${ROOT}/config/mapcycle-movement.txt")
fi

for file in "${files[@]}"; do
    [[ -f "${file}" ]] || continue
    awk '!/^[[:space:]]*($|;|\/)/ { print $1 }' "${file}"
done | awk '!seen[$0]++'
