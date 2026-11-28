#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Fetch the third-party maps pinned in maps/manifest.tsv into maps/ (and their
# custom sounds into sound/). Both overlays are gitignored. A private image
# build (MAP_POLICY=local) bakes maps/ in. A published build copies only the
# maps scripts/cleared-maps.sh lists.
#
#   scripts/fetch-maps.sh            fetch every row whose .bsp is missing
#   scripts/fetch-maps.sh <name>...  (re)fetch only these maps
#
# FETCH_MAPS_DEST is the directory for .bsp/.nav/.res/.txt (default maps/).
# FETCH_MAPS_ROOT is where a row's sound extras are copied (default repo root).
# scripts/fetch-maps-host.sh sets both to ~/cs-maps.
#
# Each download must match its pinned SHA-256 and be a .zip or a GoldSrc .bsp.
# Verified downloads are cached by hash in .cache/maps/ (FETCH_MAPS_CACHE), so
# a pack shared by several rows is downloaded once. From a zip only
# <name>.bsp/.nav/.res/.txt (matched by basename) and the row's listed extras
# are extracted; nothing in it is executed. An extra is sound/<path>.wav or a
# <name>.wad that belongs in the game directory. A repo fetch writes that wad
# under maps/wads/ (install-maps.sh copies it on a local image). A host
# populate writes it beside maps/. When the zip has no <name>.res, a wad extra
# gets one so clients download the wad with the map.
# wanted() is a predicate used in conditions.
# shellcheck disable=SC2310
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="${ROOT}/maps/manifest.tsv"
# FETCH_MAPS_DEST / FETCH_MAPS_ROOT point a host populate (fetch-maps-host.sh)
# at ~/cs-maps. The default is still this repo: maps/ and the repo root.
DEST="${FETCH_MAPS_DEST:-${ROOT}/maps}"
EXTRA_ROOT="${FETCH_MAPS_ROOT:-${ROOT}}"
CACHE="${FETCH_MAPS_CACHE:-${ROOT}/.cache/maps}"
ALLOWED_EXT=(bsp nav res txt)
MAX_BYTES=314572800 # 300 MiB
# sound/<path>.wav, or a wad that sits in the game directory (no subdirectory).
is_sound_extra() {
    [[ "$1" =~ ^sound/[A-Za-z0-9_][A-Za-z0-9_/-]*\.wav$ && "$1" != *..* ]]
}

is_wad_extra() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*\.wad$ && "$1" != *..* ]]
}

# Where a wad extra is written. Host populates keep it next to maps/ so a
# file mount is <host>/<name>.wad. A repo fetch keeps it under maps/wads/,
# out of the maps/ file list install-maps.sh copies one name at a time.
wad_dir() {
    if [[ "${EXTRA_ROOT}" != "${ROOT}" ]]; then
        printf '%s\n' "${EXTRA_ROOT}"
    else
        printf '%s\n' "${DEST}/wads"
    fi
}

die() { echo "[fetch-maps] error: $*" >&2; exit 1; }
log() { echo "[fetch-maps] $*"; }

# First four bytes as hex, e.g. 504b0304 for a zip.
magic() {
    local bytes
    bytes=$(od -An -tx1 -N4 "$1")
    printf '%s' "${bytes//[[:space:]]/}"
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

wanted() {
    local name="$1"
    shift
    [[ "$#" -eq 0 ]] && return 0
    local w
    for w in "$@"; do
        [[ "${w}" == "${name}" ]] && return 0
    done
    return 1
}

# Print the path of the verified download for url+sum, downloading it if it
# isn't cached yet.
download() {
    local name="$1" url="$2" sum="$3"
    local cached="${CACHE}/${sum}" partial actual

    if [[ -f "${cached}" ]]; then
        printf '%s\n' "${cached}"
        return
    fi
    mkdir -p "${CACHE}"
    partial=$(mktemp "${CACHE}/.partial.XXXXXX")
    log "${name}: downloading ${url}" >&2
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --max-filesize "${MAX_BYTES}" -o "${partial}" "${url}"; then
        rm -f "${partial}"
        die "${name}: download failed"
    fi
    actual=$(sha256 "${partial}")
    if [[ "${actual}" != "${sum}" ]]; then
        rm -f "${partial}"
        die "${name}: sha256 mismatch (got ${actual})"
    fi
    mv "${partial}" "${cached}"
    printf '%s\n' "${cached}"
}

fetch_one() {
    local name="$1" url="$2" sum="$3" extras="$4"
    local file work ext entry base kind entries extra found
    local -a extra_list=()

    [[ "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || die "bad map name '${name}'"
    [[ "${url}" == https://* ]] || die "${name}: only https URLs are allowed"
    [[ "${sum}" =~ ^[0-9a-f]{64}$ ]] || die "${name}: sha256 must be 64 lowercase hex chars"
    if [[ -n "${extras}" && "${extras}" != "-" ]]; then
        IFS=',' read -r -a extra_list <<< "${extras}"
    fi
    for extra in ${extra_list[@]+"${extra_list[@]}"}; do
        if ! is_sound_extra "${extra}" && ! is_wad_extra "${extra}"; then
            die "${name}: extra '${extra}' must be sound/<path>.wav or <name>.wad"
        fi
    done

    file=$(download "${name}" "${url}" "${sum}")
    work=$(mktemp -d)
    # shellcheck disable=SC2064 # expand now: work is local
    trap "rm -rf '${work}'" RETURN

    kind=$(magic "${file}")
    if [[ "${kind}" == "504b0304" ]]; then
        mkdir "${work}/out"
        entries=$(unzip -Z1 "${file}")
        while IFS= read -r entry; do
            [[ "${entry}" == */ ]] && continue
            base="${entry##*/}"
            for ext in "${ALLOWED_EXT[@]}"; do
                if [[ "${base}" == "${name}.${ext}" ]]; then
                    unzip -p "${file}" "${entry}" > "${work}/out/${base}"
                fi
            done
        done <<< "${entries}"
        [[ -f "${work}/out/${name}.bsp" ]] || die "${name}: zip has no ${name}.bsp"

        local wad_count=0 wad_dest=""
        for extra in ${extra_list[@]+"${extra_list[@]}"}; do
            found=0
            while IFS= read -r entry; do
                if [[ "${entry}" == "${extra}" || "${entry}" == */"${extra}" ]]; then
                    if is_wad_extra "${extra}"; then
                        [[ -n "${wad_dest}" ]] || wad_dest=$(wad_dir)
                        mkdir -p "${wad_dest}"
                        unzip -p "${file}" "${entry}" > "${wad_dest}/${extra}"
                        wad_count=$((wad_count + 1))
                    else
                        mkdir -p "${work}/extra/${extra%/*}"
                        unzip -p "${file}" "${entry}" > "${work}/extra/${extra}"
                    fi
                    found=1
                    break
                fi
            done <<< "${entries}"
            [[ "${found}" -eq 1 ]] || die "${name}: zip has no ${extra}"
        done
        # Clients learn about a wad from the map's .res. The archive often
        # ships the wad and no list; write the list the zip did not.
        if [[ "${wad_count}" -gt 0 && ! -f "${work}/out/${name}.res" ]]; then
            : > "${work}/out/${name}.res"
            for extra in ${extra_list[@]+"${extra_list[@]}"}; do
                if is_wad_extra "${extra}"; then
                    printf '%s\n' "${extra}" >> "${work}/out/${name}.res"
                fi
            done
        fi

        mkdir -p "${DEST}"
        cp "${work}/out/"* "${DEST}/"
        if [[ -d "${work}/extra" ]]; then
            mkdir -p "${EXTRA_ROOT}"
            cp -R "${work}/extra/." "${EXTRA_ROOT}/"
        fi
    else
        # A GoldSrc BSP starts with version 30 (0x1e) as a little-endian int.
        [[ "${kind}" == "1e000000" ]] ||
            die "${name}: download is neither a zip nor a GoldSrc .bsp"
        [[ "${#extra_list[@]}" -eq 0 ]] || die "${name}: extras need a zip download"
        mkdir -p "${DEST}"
        cp "${file}" "${DEST}/${name}.bsp"
    fi
    log "${name}: ok"
}

[[ -f "${MANIFEST}" ]] || die "missing ${MANIFEST}"

count=0
# Split on a non-whitespace separator: with IFS=tab, `read` folds an empty
# column away and shifts the rest of the row left.
while IFS= read -r row; do
    IFS=$'\037' read -r name url sum license _attribution extras _fastdl <<< "${row//$'\t'/$'\037'}"
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    wanted "${name}" "$@" || continue
    [[ -n "${license:-}" ]] || die "${name}: license column is empty"
    if [[ "$#" -eq 0 && -f "${DEST}/${name}.bsp" ]]; then
        log "${name}: present, skipping"
        continue
    fi
    fetch_one "${name}" "${url}" "${sum}" "${extras:-}"
    count=$((count + 1))
done < "${MANIFEST}"

log "fetched ${count} map(s) into ${DEST}"
