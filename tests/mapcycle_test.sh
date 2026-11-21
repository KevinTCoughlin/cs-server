#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Every map named in config/mapcycle*.txt must be playable: bundled in
# docs/cstrike/maps/ or maps/, shipped with HLDS, or pinned in
# maps/manifest.tsv (with a license note). A missing map makes changelevel
# fail at map end. Pinned maps also stay off FastDL (docs/cstrike/maps/) unless
# their manifest row says fastdl=yes.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="${ROOT}/maps/manifest.tsv"

# Stock Counter-Strike 1.6 maps installed by HLDS (app 90).
STOCK=" as_oilrig cs_747 cs_assault cs_backalley cs_estate cs_havana cs_italy
cs_militia cs_office cs_siege de_airstrip de_aztec de_cbble de_chateau de_dust
de_dust2 de_inferno de_nuke de_piranesi de_prodigy de_storm de_survivor
de_torn de_train de_vertigo "

pinned=" "
while IFS=$'\t' read -r name _url _sum license _attribution _extras fastdl; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    if [[ -z "${license:-}" ]]; then
        printf 'maps/manifest.tsv: %s has no license note\n' "${name}" >&2
        exit 1
    fi
    case "${fastdl:-no}" in
        yes) ;;
        no)
            # Not cleared for re-hosting: nothing of it may be published.
            for published in "${ROOT}/docs/cstrike/maps/${name}".*; do
                [[ -e "${published}" ]] || continue
                printf '%s is on FastDL but maps/manifest.tsv does not mark %s fastdl=yes\n' "${published#"${ROOT}"/}" "${name}" >&2
                exit 1
            done
            ;;
        *)
            printf 'maps/manifest.tsv: %s fastdl must be yes or no\n' "${name}" >&2
            exit 1
            ;;
    esac
    pinned+="${name} "
done < "${MANIFEST}"

failed=0
for cycle in "${ROOT}"/config/mapcycle*.txt; do
    while IFS= read -r map || [[ -n "${map}" ]]; do
        map="${map%%[[:space:]]*}"
        [[ -z "${map}" || "${map}" == \;* || "${map}" == /* ]] && continue
        if [[ -f "${ROOT}/docs/cstrike/maps/${map}.bsp" || -f "${ROOT}/maps/${map}.bsp" ]] ||
           [[ "${STOCK}" == *[[:space:]]"${map}"[[:space:]]* || "${pinned}" == *" ${map} "* ]]; then
            continue
        fi
        printf '%s: %s is not bundled, stock or pinned in maps/manifest.tsv\n' "${cycle#"${ROOT}"/}" "${map}" >&2
        failed=1
    done < "${cycle}"
done

[[ "${failed}" -eq 0 ]] || exit 1
printf 'mapcycle tests passed\n'
