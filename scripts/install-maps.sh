#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Copy a maps/ overlay into the image's game maps directory.
#
#   MAP_POLICY=cleared  published images (the Containerfile default).
#       A map named in the manifest is copied only when scripts/cleared-maps.sh
#       lists it. The Containerfile reads the overlay from a bind mount, so a
#       map that is not cleared never enters an image layer. The copy then
#       has to pass scripts/check-published-maps.sh.
#   MAP_POLICY=local    a private server (just build, compose, Apple container).
#       Copy the overlay as it stands, including maps the operator fetched
#       that are not cleared for redistribution.
#
#   install-maps.sh <src> <dest>
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=${1:?source directory}
dest=${2:?destination directory}
policy=${MAP_POLICY:-cleared}

case "${policy}" in
    cleared | local) ;;
    *)
        echo "[install-maps] MAP_POLICY must be cleared or local" >&2
        exit 1
        ;;
esac
[[ -d "${src}" ]] || { echo "[install-maps] ${src} is not a directory" >&2; exit 1; }
[[ -d "${dest}" ]] || { echo "[install-maps] ${dest} is not a directory" >&2; exit 1; }

# Drop one trailing .bz2, then one extension: surf_nice_fly.bsp and
# surf_nice_fly_4.bsp.bz2 stay different maps.
map_of() {
    local base=$1
    base=${base%.bz2}
    printf '%s\n' "${base%.*}"
}

blocked=" "
if [[ "${policy}" == cleared ]]; then
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        blocked+="${name} "
    done < <(bash "${HERE}/cleared-maps.sh" --uncleared)
fi

shopt -s nullglob dotglob
for path in "${src}"/*; do
    base=${path##*/}
    if [[ ! -f "${path}" && ! -L "${path}" ]]; then
        echo "[install-maps] skipping ${base}: not a file" >&2
        continue
    fi
    name=$(map_of "${base}")
    if [[ -n "${name}" && "${blocked}" == *" ${name} "* ]]; then
        echo "[install-maps] not cleared, left out: ${base}"
        continue
    fi
    cp "${path}" "${dest}/${base}"
    if [[ -f "${dest}/${base}" && ! -L "${dest}/${base}" ]]; then
        chmod 644 "${dest}/${base}"
    fi
    if id hlds >/dev/null 2>&1; then
        chown hlds:hlds "${dest}/${base}"
    fi
    echo "[install-maps] copied ${base}"
done

# maps/wads/*.wad is a texture archive the map needs in the game directory
# (cstrike/<name>.wad), not under maps/. A published build copies a wad only
# when a cleared row lists it. Anything else stays out of the image layer.
wad_src="${src}/wads"
if [[ -d "${wad_src}" ]]; then
    game_dir=$(cd "${dest}" && cd .. && pwd)
    wad_allowed=" "
    if [[ "${policy}" == cleared ]]; then
        wad_manifest="${MAPS_MANIFEST:-$(cd "${HERE}/.." && pwd)/maps/manifest.tsv}"
        [[ -f "${wad_manifest}" ]] || { echo "[install-maps] missing ${wad_manifest}" >&2; exit 1; }
        while IFS= read -r wad_row || [[ -n "${wad_row}" ]]; do
            IFS=$'\037' read -r _wad_name _wad_url _wad_sum _wad_license _wad_attr wad_extras wad_fastdl <<< "${wad_row//$'\t'/$'\037'}"
            [[ "${wad_fastdl:-no}" == yes ]] || continue
            [[ -n "${wad_extras}" && "${wad_extras}" != "-" ]] || continue
            wad_extra_list=()
            IFS=',' read -r -a wad_extra_list <<< "${wad_extras}"
            for wad_extra in ${wad_extra_list[@]+"${wad_extra_list[@]}"}; do
                [[ "${wad_extra}" == *.wad && "${wad_extra}" != */* ]] || continue
                wad_allowed+="${wad_extra} "
            done
        done < "${wad_manifest}"
    fi
    for wad_path in "${wad_src}"/*.wad; do
        [[ -f "${wad_path}" ]] || continue
        wad_base=${wad_path##*/}
        if [[ "${policy}" == cleared && "${wad_allowed}" != *" ${wad_base} "* ]]; then
            echo "[install-maps] wad not cleared, left out: ${wad_base}"
            continue
        fi
        cp "${wad_path}" "${game_dir}/${wad_base}"
        chmod 644 "${game_dir}/${wad_base}"
        if id hlds >/dev/null 2>&1; then
            chown hlds:hlds "${game_dir}/${wad_base}"
        fi
        echo "[install-maps] copied ${wad_base} into the game directory"
    done
fi

if [[ "${policy}" == cleared ]]; then
    bash "${HERE}/check-published-maps.sh" "${dest}"
fi
