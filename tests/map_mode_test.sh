#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# The same rules scoutzknivez.sma uses for MODE=auto, applied to
# config/modes/map-modes.ini. exact wins, then the longest prefix (? is one
# character), then the last default.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

TABLE="${ROOT}/config/modes/map-modes.ini"
CYCLE="${ROOT}/config/mapcycle-movement.txt"

prefix_match() {
    local map="$1" pat="$2" i c
    local mlen=${#map} plen=${#pat}
    [[ "${plen}" -gt 0 && "${plen}" -le "${mlen}" ]] || return 1
    for ((i = 0; i < plen; i++)); do
        c="${pat:i:1}"
        [[ "${c}" == "?" || "${c}" == "${map:i:1}" ]] || return 1
    done
}

# resolve <map> [file]
resolve() {
    local map file="${2:-${TABLE}}" line kind name mode
    local fallback=climb best="" bestlen=0 exact=""
    map=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        line=$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')
        [[ -z "${line}" || "${line}" == \;* || "${line}" == //* ]] && continue
        read -r kind name mode _ <<< "${line}"
        case "${kind}" in
            default)
                [[ "${name}" == "climb" || "${name}" == "surf" ]] && fallback="${name}"
                ;;
            exact)
                if [[ -z "${exact}" && "${name}" == "${map}" && ( "${mode}" == "climb" || "${mode}" == "surf" ) ]]; then
                    exact="${mode}"
                fi
                ;;
            prefix)
                if [[ -z "${exact}" && ( "${mode}" == "climb" || "${mode}" == "surf" ) ]] && prefix_match "${map}" "${name}"; then
                    if [[ "${#name}" -gt "${bestlen}" ]]; then
                        bestlen=${#name}
                        best="${mode}"
                    fi
                fi
                ;;
        esac
    done < "${file}"
    if [[ -n "${exact}" ]]; then
        printf '%s\n' "${exact}"
    elif [[ -n "${best}" ]]; then
        printf '%s\n' "${best}"
    else
        printf '%s\n' "${fallback}"
    fi
}

expect_mode() {
    local map="$1" want="$2" got file="${3:-}"
    if [[ -n "${file}" ]]; then
        got=$(resolve "${map}" "${file}")
    else
        got=$(resolve "${map}")
    fi
    assert_eq "${map}" "${want}" "${got}"
}

expect_mode kz_man_everest climb
expect_mode bkz_goldbhop climb
expect_mode bkz_toonworld climb
expect_mode kz_climbers_b01 climb
expect_mode surf_ski_5 surf
expect_mode surf_nice_fly_4 surf
expect_mode SURF_SRVENTER surf
expect_mode kzru_longjumps climb
expect_mode kz2a_block climb
expect_mode hb_d2block climb
expect_mode bhop_easy climb
expect_mode de_dust2 climb
# kz_ is three characters and must not swallow a kz??_ map, or the reverse.
expect_mode kz_longjumps climb
[[ "$(resolve kzru_longjumps)" == "climb" ]] || fail "kz??_ did not match"

while IFS= read -r map || [[ -n "${map}" ]]; do
    map="${map%%[[:space:]]*}"
    [[ -z "${map}" || "${map}" == \;* || "${map}" == /* ]] && continue
    case "${map}" in
        surf_*) expect_mode "${map}" surf ;;
        kz_* | bkz_*) expect_mode "${map}" climb ;;
        *) fail "mapcycle-movement.txt has an unexpected name: ${map}" ;;
    esac
done < "${CYCLE}"

fixture=$(mktemp)
trap 'rm -f "${fixture}"' EXIT
cat > "${fixture}" <<'EOF'
default surf
prefix surf_ surf
prefix kz_ climb
exact surf_ski_5 climb
exact kz_man_everest surf
prefix kz??_ climb
default climb
EOF
expect_mode surf_ski_5 climb "${fixture}"
expect_mode kz_man_everest surf "${fixture}"
expect_mode surf_other surf "${fixture}"
expect_mode kzru_block climb "${fixture}"
expect_mode de_dust2 climb "${fixture}"

assert_contains "the plugin reads the table" \
    "$(cat "${ROOT}/plugins/amxmodx/scripting/scoutzknivez.sma")" "modes/map-modes.ini"
assert_contains "auto sets the map mode for movement.amxx" \
    "$(cat "${ROOT}/plugins/amxmodx/scripting/scoutzknivez.sma")" 'set_localinfo("sk_mapmode"'
assert_contains "movement.amxx follows the resolved mode" \
    "$(cat "${ROOT}/plugins/amxmodx/scripting/movement.sma")" 'equal(szSkMode, "auto")'
assert_contains "auto loads the shared plugin list" \
    "$(cat "${ROOT}/plugins/amxmodx/modes/auto.ini")" "movement.amxx"
assert_contains "rtv is on the shared list" \
    "$(cat "${ROOT}/plugins/amxmodx/modes/auto.ini")" "rtv.amxx"
# scoutzknivez.amxx has to run first so sk_mapmode exists when movement starts.
sk=$(grep -n '^scoutzknivez.amxx$' "${ROOT}/plugins/amxmodx/modes/auto.ini" | cut -d: -f1)
mv=$(grep -n '^movement.amxx$' "${ROOT}/plugins/amxmodx/modes/auto.ini" | cut -d: -f1)
[[ -n "${sk}" && -n "${mv}" && "${sk}" -lt "${mv}" ]] || fail "scoutzknivez.amxx must be listed before movement.amxx"

printf 'map mode tests passed\n'
