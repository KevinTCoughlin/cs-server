#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Map names baked into the movement image and not into the default image.
# The Containerfile is the same (GAME=cstrike). scripts/fetch-maps.sh
# downloads these rows from maps/manifest.tsv before that build. The list is
# the climb rotation, the surf rotation, and config/mapcycle-movement.txt
# when that file exists. Nipper and stock maps are not included: nipper stays
# out of the published image, and the stock maps are already in it.
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
