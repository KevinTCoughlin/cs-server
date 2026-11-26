#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Populate ~/cs-maps for the movement server. The files are the movement
# rotation (config/mapcycle-climb.txt and config/mapcycle-surf.txt) unless
# names are given. Downloads are the rows in maps/manifest.tsv; each one is
# checked against its pinned SHA-256 before anything is written, the same as
# scripts/fetch-maps.sh. Passing the names makes a later run re-extract from
# that checked archive, so a changed file on disk is put back.
#
#   scripts/fetch-maps-host.sh
#   scripts/fetch-maps-host.sh kz_man_everest
#   MAPS_HOST=/var/lib/cs-maps scripts/fetch-maps-host.sh
#
# The directory is mode 755/644 so the rootless container user can read it.
# fastdl=no maps are written here too: the game server mounts them, and the
# FastDL sidecar does not publish them.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAPS_HOST=${MAPS_HOST:-${HOME:?HOME is not set}/cs-maps}

die() { echo "[fetch-maps-host] error: $*" >&2; exit 1; }
log() { echo "[fetch-maps-host] $*"; }

for tool in curl unzip; do
    command -v "${tool}" >/dev/null 2>&1 || die "need ${tool} on PATH"
done
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    die "need sha256sum or shasum on PATH"
fi

names=()
if [[ $# -gt 0 ]]; then
    names=("$@")
else
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        names+=("${name}")
    done < <(bash "${ROOT}/scripts/movement-maps.sh")
fi
[[ ${#names[@]} -gt 0 ]] || die "no map names (scripts/movement-maps.sh printed nothing)"

mkdir -p "${MAPS_HOST}/maps"
log "fetching ${#names[@]} map(s) into ${MAPS_HOST}"
FETCH_MAPS_DEST="${MAPS_HOST}/maps" \
    FETCH_MAPS_ROOT="${MAPS_HOST}" \
    bash "${ROOT}/scripts/fetch-maps.sh" "${names[@]}"

find "${MAPS_HOST}" -type d -exec chmod 755 {} +
find "${MAPS_HOST}" -type f -exec chmod 644 {} +

missing=0
for name in "${names[@]}"; do
    if [[ ! -f "${MAPS_HOST}/maps/${name}.bsp" ]]; then
        echo "[fetch-maps-host] error: ${name}.bsp is missing after fetch" >&2
        missing=1
    fi
done
[[ "${missing}" -eq 0 ]] || exit 1

block=$(bash "${ROOT}/scripts/overlay-host-maps.sh" quadlet-block)
scanned=$(bash "${ROOT}/scripts/overlay-host-maps.sh" volumes --host "${MAPS_HOST}" --prefix '%h/cs-maps')
extra=0
while IFS= read -r line; do
    [[ "${line}" == Volume=* ]] || continue
    if ! grep -Fxq "${line}" <<< "${block}"; then
        if [[ "${extra}" -eq 0 ]]; then
            log "the game unit does not mount these host files yet. Add them inside the maps-local block of cs-server-movement.container only. Do not add them to the FastDL unit."
            extra=1
        fi
        printf '%s\n' "${line}"
    fi
done <<< "${scanned}"

log "${#names[@]} map(s) in ${MAPS_HOST} (download checksums verified)"
log "next: bash scripts/overlay-host-maps.sh install-unit ~/.config/containers/systemd/cs-server-movement.container"
log "      bash scripts/overlay-host-maps.sh install-unit --fastdl ~/.config/containers/systemd/cs-fastdl-movement.container"
