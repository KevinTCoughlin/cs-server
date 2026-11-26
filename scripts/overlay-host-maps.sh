#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Host maps for a published image that does not contain them.
#
# The movement rotation is not in ghcr.io/.../cs-server-movement (:main is
# MAP_POLICY=cleared, and none of those rows are fastdl=yes). The VPS keeps
# the files in ~/cs-maps (on the deploy user, /home/cs/cs-maps):
#
#   maps/<name>.bsp          and .nav .res .txt
#   sound/ sprites/ models/ gfx/ overviews/
#   <name>.wad               beside those directories
#
# The container root is read-only, so the entrypoint cannot create files
# under /hlds/cstrike/maps, and mounting the whole maps directory would hide
# the stock maps. The game unit bind-mounts each host file onto its own
# path. The same tree is mounted at /maps-local for both containers.
#
# FastDL does not get those file mounts. fastdl.sh builds a serve tree that
# adds a host file only when maps/manifest.tsv marks it fastdl=yes. The four
# climb maps from that change stay off FastDL, and so does every other
# fastdl=no row.
#
#   overlay-host-maps.sh quadlet-block [--fastdl]
#   overlay-host-maps.sh volumes --host DIR --game NAME --prefix PREFIX
#   overlay-host-maps.sh install-unit FILE [--fastdl]
#   overlay-host-maps.sh apply          # entrypoint: link or require mounts
#   overlay-host-maps.sh stage          # fastdl: print the serve root
#
# MAPS_LOCAL, MAPS_MANIFEST, MAPS_HOST, HLDS_ROOT and MAPS_STAGE_ROOT override
# the defaults. Sourced by entrypoint.sh, fastdl.sh and install.sh; the
# command line is for the host and the tests.
set -euo pipefail

MAPS_UNIT_PREFIX="${MAPS_UNIT_PREFIX:-%h/cs-maps}"
MAPS_CLEARED=" "
MAPS_CLEARED_EXTRAS=" "
MAPS_MANIFEST_LOADED=0

maps_die() {
    echo "[maps] $*" >&2
    return 1
}

maps_here() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# A map name the dedicated server already ships, or that this repo bakes in
# from docs/cstrike/maps. A host file must not be mounted over it.
maps_is_stock() {
    case "$1" in
        scoutzknivez | scoutzknivez_2k | scoutzknivez_bender | \
            de_dust | de_dust2 | de_aztec | de_inferno | de_nuke | de_cbble | \
            de_train | de_prodigy | de_chateau | de_piranesi | \
            cs_assault | cs_italy | cs_office | cs_militia | cs_siege | \
            as_oilrig | as_tundra)
            return 0
            ;;
    esac
    return 1
}

maps_name_of() {
    local base=$1
    base=${base%.bz2}
    case "${base}" in
        *.bsp | *.nav | *.res | *.txt | *.wad) printf '%s\n' "${base%.*}" ;;
        *) printf '\n' ;;
    esac
}

maps_valid_rel() {
    local rel=$1
    [[ -n "${rel}" && "${rel}" != /* ]] || return 1
    case "/${rel}/" in
        */../* | */./*) return 1 ;;
    esac
    case "${rel}" in
        .* | */.*) return 1 ;;
    esac
    case "${rel}" in
        maps/* | sound/* | sprites/* | models/* | gfx/* | overviews/*)
            [[ "${rel}" =~ ^[A-Za-z0-9_./-]+$ ]] || return 1
            ;;
        *.wad)
            [[ "${rel}" != */* && "${rel}" =~ ^[A-Za-z0-9_.-]+\.wad$ ]] || return 1
            ;;
        *) return 1 ;;
    esac
}

maps_load_manifest() {
    [[ "${MAPS_MANIFEST_LOADED}" -eq 1 ]] && return 0
    local manifest="${MAPS_MANIFEST:-}" row name extras fastdl extra
    local -a extra_list=()
    if [[ -z "${manifest}" && -f /usr/local/share/cs-server/maps-manifest.tsv ]]; then
        manifest=/usr/local/share/cs-server/maps-manifest.tsv
    fi
    if [[ -z "${manifest}" ]]; then
        manifest="$(maps_here)/../maps/manifest.tsv"
    fi
    [[ -f "${manifest}" ]] || maps_die "manifest not found: ${manifest}" || return 1
    MAPS_CLEARED=" "
    MAPS_CLEARED_EXTRAS=" "
    while IFS= read -r row || [[ -n "${row}" ]]; do
        # A non-whitespace separator: IFS=tab would fold an empty column away.
        IFS=$'\037' read -r name _url _sum _license _attr extras fastdl <<< "${row//$'\t'/$'\037'}"
        [[ -z "${name}" || "${name}" == \#* ]] && continue
        [[ "${fastdl:-no}" == yes ]] || continue
        MAPS_CLEARED+="${name} "
        [[ -n "${extras}" && "${extras}" != "-" ]] || continue
        extra_list=()
        IFS=',' read -r -a extra_list <<< "${extras}"
        for extra in "${extra_list[@]}"; do
            [[ -n "${extra}" ]] || continue
            MAPS_CLEARED_EXTRAS+="${extra} "
        done
    done < "${manifest}"
    MAPS_MANIFEST_LOADED=1
}

maps_cleared_name() {
    [[ "${MAPS_CLEARED}" == *" ${1} "* ]]
}

# A host file may be published only when its row is fastdl=yes, or it is an
# extra of such a row. Anything else, including a file the manifest does not
# mention, stays off FastDL.
maps_fastdl_allows() {
    local rel=$1 name
    maps_load_manifest || return 1
    case "${rel}" in
        maps/*)
            name=$(maps_name_of "${rel##*/}")
            [[ -n "${name}" ]] || return 1
            maps_cleared_name "${name}"
            return
            ;;
    esac
    [[ "${MAPS_CLEARED_EXTRAS}" == *" ${rel} "* ]]
}

# Print one relative path per line. Symlinks that leave the tree are dropped.
maps_list_host() {
    local host=$1 path rel resolved
    [[ -d "${host}" ]] || return 0
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        rel=${path#"${host}/"}
        if [[ -L "${path}" ]]; then
            resolved=$(readlink -f "${path}" 2>/dev/null || true)
            case "${resolved}" in
                "${host}/"*) ;;
                *) continue ;;
            esac
        fi
        printf '%s\n' "${rel}"
    done < <(find "${host}" -mindepth 1 \( -type f -o -type l \) -print | LC_ALL=C sort)
}

maps_require_host() {
    local host=${1:-${MAPS_LOCAL:-}}
    if [[ -z "${host}" || ! -d "${host}" ]]; then
        maps_die "MAPS_LOCAL=${host:-<unset>} is not a directory. Bind-mount the host maps read-only (Volume=%h/cs-maps:/maps-local:ro,Z). Populate ~/cs-maps with: just fetch-maps-host" || return 1
    fi
    MAPS_LOCAL=$(cd "${host}" && pwd)
}

maps_count_bsps() {
    local host=$1 rel count=0
    while IFS= read -r rel; do
        case "${rel}" in
            maps/*.bsp) count=$((count + 1)) ;;
        esac
    done < <(maps_list_host "${host}")
    printf '%s\n' "${count}"
}

# Game container. Writable destination: symlink the host file in, and never
# replace a file that is already there (stock and baked maps stay). Read-only
# destination: the Quadlet file mount has to have made the file visible.
maps_apply_game() {
    local rel dest parent name bsps=0 linked=0 visible=0
    [[ -n "${MAPS_LOCAL:-}" ]] || return 0
    maps_require_host "${MAPS_LOCAL}" || return 1
    bsps=$(maps_count_bsps "${MAPS_LOCAL}")
    if [[ "${bsps}" -eq 0 ]]; then
        maps_die "${MAPS_LOCAL}/maps has no .bsp files. Populate ~/cs-maps with: just fetch-maps-host" || return 1
    fi
    while IFS= read -r rel; do
        if ! maps_valid_rel "${rel}"; then
            case "/${rel}/" in
                */../*)
                    maps_die "refusing host path ${rel}" || return 1
                    ;;
            esac
            echo "[maps] skipping ${rel}: not a maps/, sound/, sprites/, models/, gfx/, overviews/ or .wad file" >&2
            continue
        fi
        case "${rel}" in
            maps/*)
                name=$(maps_name_of "${rel##*/}")
                if [[ -n "${name}" ]] && maps_is_stock "${name}"; then
                    maps_die "refusing ${rel}: that map is already in the image and a host file must not hide it" || return 1
                fi
                ;;
        esac
        dest="${GAME:-cstrike}/${rel}"
        if [[ -e "${dest}" || -L "${dest}" ]]; then
            visible=$((visible + 1))
            continue
        fi
        parent=${dest%/*}
        if [[ ! -d "${parent}" ]]; then
            mkdir -p "${parent}" 2>/dev/null || true
        fi
        if [[ -d "${parent}" && -w "${parent}" ]]; then
            ln -s "${MAPS_LOCAL}/${rel}" "${dest}"
            linked=$((linked + 1))
            continue
        fi
        maps_die "${rel} is not visible at ${dest} and that directory is not writable. Add a file mount: Volume=${MAPS_UNIT_PREFIX}/${rel}:/hlds/${GAME:-cstrike}/${rel}:ro,Z" || return 1
    done < <(maps_list_host "${MAPS_LOCAL}")
    echo "[maps] ${bsps} host map(s) under ${MAPS_LOCAL} (${visible} already visible, ${linked} linked)"
}

maps_stage_dir() {
    local rel=$1 image dest src sub
    image="${HLDS_ROOT:-/hlds}/${GAME:-cstrike}/${rel}"
    dest="${MAPS_STAGE}/${GAME:-cstrike}/${rel}"
    mkdir -p "${dest}"
    if [[ -d "${image}" ]]; then
        while IFS= read -r src; do
            [[ -n "${src}" ]] || continue
            sub=${src#"${image}/"}
            if [[ "${sub}" == */* ]]; then
                mkdir -p "${dest}/${sub%/*}"
            fi
            ln -s "${src}" "${dest}/${sub}"
        done < <(find "${image}" \( -type f -o -type l \) -print | LC_ALL=C sort)
    fi
}

maps_add_host_file() {
    local rel=$1 dest parent
    dest="${MAPS_STAGE}/${GAME:-cstrike}/${rel}"
    if [[ -e "${dest}" || -L "${dest}" ]]; then
        echo "[fastdl] kept image file ${rel}" >&2
        return 0
    fi
    parent=${dest%/*}
    mkdir -p "${parent}"
    ln -s "${MAPS_LOCAL}/${rel}" "${dest}"
    echo "[fastdl] serving host file ${rel}" >&2
}

# Print the directory busybox httpd should serve. Image files stay. A host
# file is added only when the manifest clears it.
maps_stage_fastdl() {
    local rel name dir needed wad
    local -a dirs=(maps sound sprites models gfx overviews)
    maps_require_host "${MAPS_LOCAL:-}" || return 1
    if [[ "$(maps_count_bsps "${MAPS_LOCAL}")" -eq 0 ]]; then
        maps_die "${MAPS_LOCAL}/maps has no .bsp files. Populate ~/cs-maps with: just fetch-maps-host" || return 1
    fi
    maps_load_manifest || return 1
    MAPS_STAGE=${MAPS_STAGE_ROOT:-/tmp/fastdl-root}
    case "${MAPS_STAGE}" in
        /*/*) ;;
        *) maps_die "MAPS_STAGE_ROOT must be an absolute path with a parent" || return 1 ;;
    esac
    local stage_parent=${MAPS_STAGE%/*}
    if [[ ! -d "${stage_parent}" || ! -w "${stage_parent}" ]]; then
        maps_die "${stage_parent} is not writable. The FastDL unit needs Tmpfs=/tmp so cleared host maps can be added without publishing fastdl=no files." || return 1
    fi
    rm -rf "${MAPS_STAGE}"
    mkdir -p "${MAPS_STAGE}/${GAME:-cstrike}"

    needed=" "
    while IFS= read -r rel; do
        maps_valid_rel "${rel}" || continue
        if maps_fastdl_allows "${rel}"; then
            case "${rel}" in
                */*) needed+="${rel%%/*} " ;;
            esac
            continue
        fi
        case "${rel}" in
            maps/*)
                name=$(maps_name_of "${rel##*/}")
                [[ -n "${name}" ]] || continue
                case "${rel##*/}" in
                    *.bsp | *.bsp.bz2)
                        echo "[fastdl] not serving ${name} (fastdl=no)" >&2
                        ;;
                esac
                ;;
            *)
                echo "[fastdl] not serving ${rel} (not cleared for FastDL)" >&2
                ;;
        esac
    done < <(maps_list_host "${MAPS_LOCAL}")

    for dir in "${dirs[@]}"; do
        if [[ "${needed}" == *" ${dir} "* ]]; then
            maps_stage_dir "${dir}"
        elif [[ -d "${HLDS_ROOT:-/hlds}/${GAME:-cstrike}/${dir}" ]]; then
            ln -s "${HLDS_ROOT:-/hlds}/${GAME:-cstrike}/${dir}" "${MAPS_STAGE}/${GAME:-cstrike}/${dir}"
        fi
    done
    while IFS= read -r rel; do
        maps_valid_rel "${rel}" || continue
        maps_fastdl_allows "${rel}" || continue
        maps_add_host_file "${rel}"
    done < <(maps_list_host "${MAPS_LOCAL}")

    shopt -s nullglob
    for wad in "${HLDS_ROOT:-/hlds}/${GAME:-cstrike}"/*.wad; do
        [[ -e "${wad}" || -L "${wad}" ]] || continue
        ln -s "${wad}" "${MAPS_STAGE}/${GAME:-cstrike}/${wad##*/}"
    done
    shopt -u nullglob
    printf '%s\n' "${MAPS_STAGE}"
}

maps_quadlet_block() {
    local fastdl=${1:-0} name root here
    here=$(maps_here)
    root=$(cd "${here}/.." && pwd)
    printf '%s\n' "# maps-local: begin"
    printf 'Volume=%s:/maps-local:ro,Z\n' "${MAPS_UNIT_PREFIX}"
    if [[ "${fastdl}" -eq 0 ]]; then
        while IFS= read -r name; do
            [[ -n "${name}" ]] || continue
            if maps_is_stock "${name}"; then
                maps_die "rotation map ${name} is already in the image" || return 1
            fi
            printf 'Volume=%s/maps/%s.bsp:/hlds/cstrike/maps/%s.bsp:ro,Z\n' \
                "${MAPS_UNIT_PREFIX}" "${name}" "${name}"
        done < <(bash "${root}/scripts/movement-maps.sh")
    fi
    printf '%s\n' "Environment=MAPS_LOCAL=/maps-local"
    printf '%s\n' "# maps-local: end"
}

# Scan a populated host directory and print the game unit's block. Refuses a
# file that would cover a stock map. Does not print fastdl=no file mounts for
# the sidecar: pass nothing, the sidecar block is quadlet-block --fastdl.
maps_volume_block() {
    local host=$1 game=$2 prefix=$3 rel name bsps=0
    [[ -d "${host}" ]] || maps_die "${host} is not a directory. Populate ~/cs-maps with: just fetch-maps-host" || return 1
    host=$(cd "${host}" && pwd)
    bsps=$(maps_count_bsps "${host}")
    if [[ "${bsps}" -eq 0 ]]; then
        maps_die "${host}/maps has no .bsp files. Populate it with: just fetch-maps-host" || return 1
    fi
    printf '%s\n' "# maps-local: begin"
    printf 'Volume=%s:/maps-local:ro,Z\n' "${prefix}"
    while IFS= read -r rel; do
        if ! maps_valid_rel "${rel}"; then
            case "/${rel}/" in
                */../*) maps_die "refusing host path ${rel}" || return 1 ;;
            esac
            echo "[maps] skipping ${rel}" >&2
            continue
        fi
        case "${rel}" in
            maps/*)
                name=$(maps_name_of "${rel##*/}")
                if [[ -n "${name}" ]] && maps_is_stock "${name}"; then
                    maps_die "refusing ${rel}: that map is already in the image and a host file must not hide it" || return 1
                fi
                ;;
        esac
        printf 'Volume=%s/%s:/hlds/%s/%s:ro,Z\n' "${prefix}" "${rel}" "${game}" "${rel}"
    done < <(maps_list_host "${host}")
    printf '%s\n' "Environment=MAPS_LOCAL=/maps-local"
    printf '%s\n' "# maps-local: end"
}

maps_install_unit() {
    local file=$1 fastdl=${2:-0} block tmp
    [[ -f "${file}" ]] || maps_die "no unit file ${file}" || return 1
    block=$(maps_quadlet_block "${fastdl}") || return 1
    tmp=$(mktemp)
    local blockfile
    blockfile=$(mktemp)
    printf '%s\n' "${block}" > "${blockfile}"
    # shellcheck disable=SC2329 # awk calls this by name
    if grep -q '# maps-local: begin' "${file}"; then
        awk -v blockfile="${blockfile}" '
            $0 == "# maps-local: begin" {
                while ((getline line < blockfile) > 0) print line
                close(blockfile)
                skip = 1
                next
            }
            skip && $0 == "# maps-local: end" { skip = 0; next }
            skip { next }
            { print }
        ' "${file}" > "${tmp}"
    elif [[ "${fastdl}" -eq 0 ]] && grep -q ':/hlds/state' "${file}"; then
        awk -v blockfile="${blockfile}" '
            !done && $0 ~ /Volume=.*:\/hlds\/state/ {
                while ((getline line < blockfile) > 0) print line
                close(blockfile)
                done = 1
            }
            { print }
        ' "${file}" > "${tmp}"
    elif grep -q '^ReadOnly=' "${file}"; then
        awk -v blockfile="${blockfile}" '
            !done && $0 == "ReadOnly=true" {
                while ((getline line < blockfile) > 0) print line
                close(blockfile)
                done = 1
            }
            { print }
        ' "${file}" > "${tmp}"
    else
        rm -f "${tmp}" "${blockfile}"
        rm -f "${tmp}"
        maps_die "${file} has no place to put the maps-local block (wanted Volume=...:/hlds/state or ReadOnly=true)" || return 1
    fi
    rm -f "${blockfile}"
    if cmp -s "${file}" "${tmp}"; then
        rm -f "${tmp}"
        echo "[maps] ${file} already has the maps-local block"
        return 0
    fi
    mv "${tmp}" "${file}"
    echo "[maps] updated ${file}"
}

maps_main() {
    local cmd=${1:-} fastdl=0 host="" game=cstrike prefix="${MAPS_UNIT_PREFIX}"
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fastdl) fastdl=1; shift ;;
            --host)
                host=${2:?--host needs a directory}
                shift 2
                ;;
            --game)
                game=${2:?--game needs a name}
                shift 2
                ;;
            --prefix)
                prefix=${2:?--prefix needs a path}
                shift 2
                ;;
            *)
                if [[ "${cmd}" == "install-unit" && -z "${host}" && "$1" != --* ]]; then
                    host=$1
                    shift
                else
                    echo "usage: ${0##*/} quadlet-block [--fastdl] | volumes --host DIR [--game NAME] [--prefix PATH] | install-unit FILE [--fastdl] | apply | stage" >&2
                    return 2
                fi
                ;;
        esac
    done
    case "${cmd}" in
        quadlet-block) maps_quadlet_block "${fastdl}" ;;
        volumes)
            [[ -n "${host}" ]] || maps_die "volumes needs --host" || return 1
            GAME=${game} maps_volume_block "${host}" "${game}" "${prefix}"
            ;;
        install-unit)
            [[ -n "${host}" ]] || maps_die "install-unit needs a unit file" || return 1
            maps_install_unit "${host}" "${fastdl}"
            ;;
        apply) maps_apply_game ;;
        stage) maps_stage_fastdl ;;
        *)
            echo "usage: ${0##*/} quadlet-block [--fastdl] | volumes --host DIR [--game NAME] [--prefix PATH] | install-unit FILE [--fastdl] | apply | stage" >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    maps_main "$@"
fi
