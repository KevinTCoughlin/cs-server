#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Fail if a build-context directory or a built image contains a pinned map
# that scripts/cleared-maps.sh does not list. Stock Half-Life maps and this
# project's own maps are not rows of maps/manifest.tsv, so they are allowed.
#
#   scripts/check-published-maps.sh maps docs/cstrike/maps
#   scripts/check-published-maps.sh --from-image docker local/cs-server:ci
#
# Prints the allowlist and the map names it found. A rejected file is named
# on stderr and the exit status is 1.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

engine=""
image=""
dirs=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-image)
            [[ $# -ge 3 ]] || { echo "usage: ${0##*/} --from-image ENGINE IMAGE [DIR...]" >&2; exit 2; }
            engine=$2
            image=$3
            shift 3
            ;;
        -h | --help)
            echo "usage: ${0##*/} [--from-image ENGINE IMAGE] DIR..."
            exit 0
            ;;
        --)
            shift
            dirs+=("$@")
            break
            ;;
        -*)
            echo "[check-published-maps] unknown option: $1" >&2
            exit 2
            ;;
        *)
            dirs+=("$1")
            shift
            ;;
    esac
done

if [[ -z "${image}" && ${#dirs[@]} -eq 0 ]]; then
    echo "usage: ${0##*/} [--from-image ENGINE IMAGE] DIR..." >&2
    exit 2
fi

blocked=" "
allowlist=""
while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    blocked+="${name} "
done < <(bash "${HERE}/cleared-maps.sh" --uncleared)
while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    allowlist+="${name}"$'\n'
done < <(bash "${HERE}/cleared-maps.sh")

printf 'allowlist:\n'
if [[ -z "${allowlist}" ]]; then
    printf '(none)\n'
else
    printf '%s' "${allowlist}"
fi

map_of() {
    local base=$1
    base=${base%.bz2}
    printf '%s\n' "${base%.*}"
}

rejected=0
consider() {
    local label=$1 base=$2 name
    name=$(map_of "${base}")
    if [[ -n "${name}" && "${blocked}" == *" ${name} "* ]]; then
        printf '%s/%s: not on the redistribution allowlist\n' "${label}" "${base}" >&2
        rejected=1
    fi
}

report_names() {
    local label=$1
    shift
    printf '%s:\n' "${label}"
    if [[ $# -eq 0 ]]; then
        printf '(none)\n'
        return
    fi
    printf '%s\n' "$@" | LC_ALL=C sort -u
}

shopt -s nullglob dotglob

check_dir() {
    local dir=$1 label=$2 path base
    local -a found=()
    [[ -d "${dir}" ]] || { echo "[check-published-maps] ${dir} is not a directory" >&2; exit 1; }
    for path in "${dir}"/*; do
        [[ -f "${path}" || -L "${path}" ]] || continue
        base=${path##*/}
        consider "${label}" "${base}"
        case "${base}" in
            *.bsp | *.bsp.bz2) found+=("$(map_of "${base}")") ;;
        esac
    done
    if [[ ${#found[@]} -eq 0 ]]; then
        report_names "${label}"
    else
        report_names "${label}" "${found[@]}"
    fi
}

if [[ ${#dirs[@]} -gt 0 ]]; then
    for dir in "${dirs[@]}"; do
        check_dir "${dir}" "${dir}"
    done
fi

flush_image_section() {
    [[ -n "${label}" ]] || return 0
    if [[ ${#names[@]} -eq 0 ]]; then
        report_names "${label}"
    else
        report_names "${label}" "${names[@]}"
    fi
    label=""
    names=()
}

if [[ -n "${image}" ]]; then
    # shellcheck disable=SC2016 # quoted program runs in the image, not here
    listing=$("${engine}" run --rm --entrypoint bash "${image}" -c '
set -euo pipefail
shopt -s nullglob dotglob
emit() {
    dir=$1
    label=$2
    if [ -d "$dir" ]; then
        printf "# %s\n" "$label"
        for f in "$dir"/*; do
            if [ -e "$f" ] || [ -L "$f" ]; then
                printf "%s\n" "${f##*/}"
            fi
        done
    else
        printf "# missing %s\n" "$label"
    fi
}
emit /hlds/cstrike/maps "game maps"
emit /usr/local/share/cs-server/fastdl/cstrike/maps "fastdl maps"
')
    label=""
    names=()
    while IFS= read -r line || [[ -n "${line}" ]]; do
        case "${line}" in
            "# missing "*)
                flush_image_section
                printf '%s:\n(none)\n' "${line#\# missing }"
                ;;
            "# "*)
                flush_image_section
                label=${line#\# }
                names=()
                ;;
            "") ;;
            *)
                consider "${label:-image}" "${line}"
                case "${line}" in
                    *.bsp | *.bsp.bz2) names+=("$(map_of "${line}")") ;;
                esac
                ;;
        esac
    done <<< "${listing}"
    flush_image_section
fi

if [[ "${rejected}" -ne 0 ]]; then
    echo "[check-published-maps] a pinned map that is not cleared must not be published" >&2
    exit 1
fi
printf 'ok\n'
