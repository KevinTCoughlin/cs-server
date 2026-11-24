#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# config/dod: the public and 6v6 files cite published numbers and do not
# list custom KTP maps the dedicated server does not ship.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

DOD="${ROOT}/config/dod"
for name in server.cfg pub.cfg match.cfg match-ot.cfg mapcycle.txt mapcycle-match.txt; do
    [[ -f "${DOD}/${name}" ]] || fail "missing config/dod/${name}"
done

pub=$(cat "${DOD}/pub.cfg")
match=$(cat "${DOD}/match.cfg")
ot=$(cat "${DOD}/match-ot.cfg")
server=$(cat "${DOD}/server.cfg")

assert_contains "pub clock is the published 25 minute default" "${pub}" "mp_timelimit 25"
assert_contains "pub cites dodbits" "${pub}" "dodbits.com"
assert_contains "pub max rate is the low-slot figure" "${pub}" "sv_maxrate 25000"
assert_contains "pub min rate" "${pub}" "sv_minrate 7500"
assert_contains "pub max update rate" "${pub}" "sv_maxupdaterate 66"

assert_contains "match half is 20 minutes" "${match}" "mp_timelimit 20"
assert_contains "match cites the recorded 40:08 game" "${match}" "40:08"
assert_contains "match cites the rules" "${match}" "ktpleague.gg/rules"
assert_contains "match cites the 12-slot server list" "${match}" "ktpleague.gg/servers"
assert_contains "match max rate is the popular good-server figure" "${match}" "sv_maxrate 100000"
assert_contains "20 is not called a published rule" "${match}" "not a published"
if grep -q '^sv_password' "${DOD}/match.cfg"; then
    fail "match.cfg must not set sv_password (it would clear DOD_PASSWORD)"
fi

assert_contains "overtime is the published 10 minutes" "${ot}" "mp_timelimit 10"
assert_contains "overtime cites section 1.10" "${ot}" "1.10"

assert_contains "shared tick rate leaves room for Counter-Strike" "${server}" "sys_ticrate 300"
assert_contains "classes stay unlimited" "${server}" "mp_alliesclasses -1"
if grep -q '^mp_limit' "${DOD}/server.cfg" "${DOD}/pub.cfg" "${DOD}/match.cfg"; then
    fail "a per-class mp_limit would be an unpublished league rule"
fi

# Stock classics only. Custom Season 10 maps are not in dedicated-server app 90.
cycle=$(grep -vE '^[[:space:]]*(//|$)' "${DOD}/mapcycle.txt")
for map in dod_anzio dod_avalanche dod_caen dod_charlie dod_donner dod_flash dod_forest dod_jagd dod_kalt dod_saints; do
    assert_contains "pub rotation includes ${map}" "${cycle}" "${map}"
done
for custom in dod_lennon dod_lennon5_b1 dod_harrington dod_armory_b7 dod_railroad2_s10b \
    dod_saints2_b5e dod_thunder2 dod_anjou_a5 dod_solitude2; do
    if grep -qx "${custom}" <<< "${cycle}"; then
        fail "pub rotation lists ${custom}, which does not ship with the dedicated server"
    fi
done

match_cycle=$(grep -vE '^[[:space:]]*(//|$)' "${DOD}/mapcycle-match.txt")
assert_eq "match rotation is the one stock Season 10 map" "dod_anzio" "${match_cycle}"

printf 'dod config tests passed\n'
