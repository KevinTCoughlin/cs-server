#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Fetch the third-party maps pinned in maps/manifest.tsv into maps/ (and their
# custom sounds into sound/). Both overlays are gitignored and baked into the
# image by the Containerfile.
#
#   scripts/fetch-maps.sh            fetch every row whose .bsp is missing
#   scripts/fetch-maps.sh <name>...  (re)fetch only these maps
#
# Each download must match its pinned SHA-256 and be a .zip or a GoldSrc .bsp.
# Verified downloads are cached by hash in .cache/maps/ (FETCH_MAPS_CACHE), so
# a pack shared by several rows is downloaded once. From a zip only
# <name>.bsp/.nav/.res/.txt (matched by basename) and the row's listed extras
# are extracted; nothing in it is executed.
# wanted() is a predicate used in conditions.
# shellcheck disable=SC2310
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="${ROOT}/maps/manifest.tsv"
DEST="${ROOT}/maps"
CACHE="${FETCH_MAPS_CACHE:-${ROOT}/.cache/maps}"
ALLOWED_EXT=(bsp nav res txt)
MAX_BYTES=314572800 # 300 MiB
EXTRA_RE='^sound/[A-Za-z0-9_][A-Za-z0-9_/-]*\.wav$'

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
        [[ "${extra}" =~ ${EXTRA_RE} && "${extra}" != *..* ]] ||
            die "${name}: extra '${extra}' must be a sound/<path>.wav"
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

        for extra in ${extra_list[@]+"${extra_list[@]}"}; do
            found=0
            while IFS= read -r entry; do
                if [[ "${entry}" == "${extra}" || "${entry}" == */"${extra}" ]]; then
                    mkdir -p "${work}/extra/${extra%/*}"
                    unzip -p "${file}" "${entry}" > "${work}/extra/${extra}"
                    found=1
                    break
                fi
            done <<< "${entries}"
            [[ "${found}" -eq 1 ]] || die "${name}: zip has no ${extra}"
        done

        cp "${work}/out/"* "${DEST}/"
        if [[ -d "${work}/extra" ]]; then
            cp -R "${work}/extra/." "${ROOT}/"
        fi
    else
        # A GoldSrc BSP starts with version 30 (0x1e) as a little-endian int.
        [[ "${kind}" == "1e000000" ]] ||
            die "${name}: download is neither a zip nor a GoldSrc .bsp"
        [[ "${#extra_list[@]}" -eq 0 ]] || die "${name}: extras need a zip download"
        cp "${file}" "${DEST}/${name}.bsp"
    fi
    log "${name}: ok"
}

[[ -f "${MANIFEST}" ]] || die "missing ${MANIFEST}"

count=0
while IFS=$'\t' read -r name url sum license _attribution extras _fastdl; do
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
