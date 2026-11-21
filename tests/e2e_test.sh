#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# End-to-end test of a built image: boots the real server (bots on, no Steam
# master, no published ports), drives it through the console FIFO the way
# `just rcon` and scripts/mode.sh do, and asserts on what it prints.
#
#   tests/e2e_test.sh [engine] [image]
#
# engine: docker | podman | container (default: CONTAINER_ENGINE, else the
# first one installed). image: default CS_E2E_IMAGE, else
# localhost/cs-server:latest. `just e2e` builds the image first.
#
# Covers: every Metamod and AMX Mod X plugin loads and runs, the health check,
# bots join, mode switching at round end in both directions (cvars, mapcycle
# and `localinfo sk_mode` surviving the changelevel), the sk_switchmode error
# paths, every mapcycle map present in the image loads, no AMX Mod X run-time
# errors, and a graceful SIGTERM shutdown.
#
# Not covered (needs a real game client): spawn loadouts, buy and pickup
# blocking, RTV votes, AFK and high-ping kicks.
#
# CS_E2E_TIMEOUT_SCALE multiplies every wait (default 1; raise it on slow
# emulated hosts). CS_E2E_SKIP_MAPS=1 skips the map sweep. CS_E2E_KEEP=1
# leaves the container behind for inspection.
# The wait/ask helpers are predicates used in conditions.
# shellcheck disable=SC2310
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

ENGINE="${1:-${CONTAINER_ENGINE:-}}"
IMAGE="${2:-${CS_E2E_IMAGE:-localhost/cs-server:latest}}"
SCALE="${CS_E2E_TIMEOUT_SCALE:-1}"
NAME="cs-e2e-$$"
FIFO="/hlds/.runtime/hlds-input"

if [[ -z "${ENGINE}" ]]; then
    for candidate in docker podman container; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            ENGINE="${candidate}"
            break
        fi
    done
fi

# Same hardening as the deployment paths. Docker needs seccomp=unconfined for
# the i386 binary's socket() (see compose.yml).
case "${ENGINE}" in
    docker) RUN_FLAGS=(--cap-drop ALL --security-opt no-new-privileges:true --security-opt seccomp=unconfined) ;;
    podman) RUN_FLAGS=(--cap-drop ALL --security-opt no-new-privileges) ;;
    container) RUN_FLAGS=(--cap-drop ALL -m "${CS_MEMORY:-640M}" -c "${CS_CPUS:-2}") ;;
    *) fail "usage: ${0##*/} [docker|podman|container] [image]" ;;
esac

LOG=$(mktemp)
LOG_PID=""
MARK=0
step() { printf '[e2e] %s\n' "$*"; }

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    local status=$?
    if [[ "${status}" -ne 0 ]]; then
        printf '\n[e2e] FAILED; last server output:\n' >&2
        tr -d '\r' < "${LOG}" | tail -n 60 >&2
    fi
    if [[ -n "${LOG_PID}" ]]; then
        kill "${LOG_PID}" 2>/dev/null || true
    fi
    if [[ "${CS_E2E_KEEP:-0}" == "1" ]]; then
        printf '[e2e] container %s kept; log at %s\n' "${NAME}" "${LOG}" >&2
    else
        "${ENGINE}" rm -f "${NAME}" >/dev/null 2>&1 || true
        rm -f "${LOG}"
    fi
    exit "${status}"
}
trap cleanup EXIT

# Send one console command through the FIFO.
send() {
    # shellcheck disable=SC2016 # $1 expands inside the container's sh
    "${ENGINE}" exec "${NAME}" sh -c 'printf "%s\n" "$1" > "$2"' sh "$1" "${FIFO}"
}

# Only output after the mark counts, so an old line can't satisfy a new wait.
mark() {
    MARK=$(wc -l < "${LOG}")
    MARK=$((MARK))
}

# Lines printed since the mark matching <ERE>; the PTY's CRs are dropped.
since_mark() {
    tail -n "+$((MARK + 1))" "${LOG}" | tr -d '\r' | grep -aE -- "$1"
}

# wait_log <ERE> <seconds> [command to re-send every 5 s]: print the first
# matching line. The console echo can interleave with output, so never match
# on a command's own echo.
wait_log() {
    local pattern="$1" seconds=$(($2 * SCALE)) poke="${3:-}" waited=0 line
    while [[ "${waited}" -lt "${seconds}" ]]; do
        if line=$(since_mark "${pattern}"); then
            printf '%s\n' "${line}" | head -n 1
            return 0
        fi
        if [[ -n "${poke}" && "${waited}" -gt 0 && $((waited % 5)) -eq 0 ]]; then
            send "${poke}"
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# ask <command> <ERE> [seconds]: send it and return the reply line.
ask() {
    local command="$1" pattern="$2" seconds="${3:-20}" line
    mark
    send "${command}"
    line=$(wait_log "${pattern}" "${seconds}" "${command}") ||
        fail "no reply matching /${pattern}/ to '${command}' within $((seconds * SCALE))s"
    printf '%s\n' "${line}"
}

# cvar <name>: its current value.
cvar() {
    local line
    line=$(ask "$1" "^\"$1\" is \"")
    line="${line#*\" is \"}"
    printf '%s\n' "${line%%\"*}"
}

# expect_cvar <name> <value> <why>
expect_cvar() {
    local value
    value=$(cvar "$1")
    assert_eq "$3 ($1)" "$2" "${value}"
}

current_map() {
    local line
    line=$(ask status '^map +: +[^ ]+ ')
    line="${line#map*: }"
    line="${line#"${line%%[! ]*}"}"
    printf '%s\n' "${line%% *}"
}

# all_running <command> <minimum>: "<n> plugins, <n> running" with n >= minimum.
all_running() {
    local line total running
    line=$(ask "$1" '^[0-9]+ plugins, [0-9]+ running')
    total="${line%% *}"
    running="${line#*, }"
    running="${running%% *}"
    assert_eq "$1: every plugin is running (${line})" "${total}" "${running}"
    if [[ "${total}" -lt "$2" ]]; then
        fail "$1: expected at least $2 plugins, found ${total}"
    fi
    printf '%s\n' "${total}"
}

# switch_mode <mode> <mapcycle> <expected map> [map]: queue the switch, end
# the round, and wait for the plugin to come back up in the new mode.
switch_mode() {
    local mode="$1" cycle="$2" map="$3" explicit="${4:-}" line
    line=$(ask "sk_switchmode ${mode} ${cycle}${explicit:+ ${explicit}}" '\[SK\] switch to ')
    assert_contains "switch is queued, not immediate" "${line}" "switch to ${mode} (${cycle}, ${map}) queued for round end"
    mark
    send endround
    wait_log "\[SK\] switching to ${mode} \(${cycle}, ${map}\)" 60 endround >/dev/null ||
        fail "the queued switch to ${mode} did not run after the round ended"
    wait_log "\[SK\] mode: ${mode}" 90 >/dev/null ||
        fail "the server did not come back in ${mode} mode on ${map}"
}

map_in_image() {
    "${ENGINE}" exec "${NAME}" test -f "/hlds/cstrike/maps/$1.bsp"
}

# --- Boot -------------------------------------------------------------------
step "starting ${IMAGE} with ${ENGINE} as ${NAME}"
# NOMASTER and LAN mode keep the run off the Steam master list. NOMASTER is
# also the configuration where Steam's layer stops answering A2S_INFO, so the
# health check below has to pass on the engine's own ping reply.
"${ENGINE}" run -d --name "${NAME}" "${RUN_FLAGS[@]}" \
    -e NOMASTER=1 -e LAN_MODE=1 -e BOTS=1 "${IMAGE}" >/dev/null
"${ENGINE}" logs -f "${NAME}" > "${LOG}" 2>&1 &
LOG_PID=$!

wait_log '\[SK\] mode: scoutz' 240 >/dev/null || fail "the server did not finish loading its first map"
step "server is up"

healthy=0
for _ in $(seq $((30 * SCALE))); do
    if "${ENGINE}" exec "${NAME}" /healthcheck.sh; then
        healthy=1
        break
    fi
    sleep 1
done
assert_eq "health check passes with NOMASTER=1 (server answers a ping)" 1 "${healthy}"

# --- Plugins ----------------------------------------------------------------
# Every plugin listed in plugins.ini must have loaded.
listed=$(grep -cE '^[A-Za-z0-9_]+\.amxx' "${ROOT}/plugins/amxmodx/plugins.ini" || true)
modules=$(all_running "meta list" 1)
plugins=$(all_running "amxx plugins" "${listed}")
step "${modules} Metamod plugins and ${plugins} AMX Mod X plugins running"

# --- Startup state ----------------------------------------------------------
gravity=$(sed -n 's/^sv_gravity[[:space:]]*"\{0,1\}\([0-9]*\).*/\1/p' "${ROOT}/config/server.cfg")
knife_gravity=$(sed -n 's/^sv_gravity[[:space:]]*"\{0,1\}\([0-9]*\).*/\1/p' "${ROOT}/config/modes/knife.cfg")
[[ -n "${gravity}" && -n "${knife_gravity}" && "${gravity}" != "${knife_gravity}" ]] ||
    fail "expected different sv_gravity values in config/server.cfg and config/modes/knife.cfg"

expect_cvar sv_gravity "${gravity}" "scoutz gravity from server.cfg"
expect_cvar mapcyclefile mapcycle.txt "default mapcycle"
map=$(current_map)
assert_eq "starting map" scoutzknivez "${map}"

bots=0
for _ in $(seq $((12 * SCALE))); do
    line=$(ask status '^players +: +[0-9]+ active')
    bots="${line#*: }"
    bots="${bots#"${bots%%[! ]*}"}"
    bots="${bots%% *}"
    [[ "${bots}" -ge 2 ]] && break
    sleep 5
done
if [[ "${bots}" -lt 2 ]]; then
    fail "bots did not join (players: ${bots})"
fi
step "scoutz mode on ${map}, ${bots} players (bots)"

# --- sk_switchmode rejects bad input ----------------------------------------
line=$(ask "sk_switchmode" 'usage: sk_switchmode')
line=$(ask "sk_switchmode bogus mapcycle.txt" '\[SK\] ')
assert_contains "unknown mode" "${line}" "unknown mode 'bogus'"
line=$(ask "sk_switchmode knife nope.txt" '\[SK\] ')
assert_contains "missing mapcycle" "${line}" "mapcycle 'nope.txt' not found"
line=$(ask "sk_switchmode knife ../server.cfg" '\[SK\] ')
assert_contains "mapcycle outside the game dir" "${line}" "not found"
line=$(ask "sk_switchmode knife mapcycle-dust2.txt no_such_map" '\[SK\] ')
assert_contains "missing map" "${line}" "map 'no_such_map' not found"
line=$(ask "sk_switchmode scoutz mapcycle.txt" '\[SK\] ')
assert_contains "same mode and mapcycle is a no-op" "${line}" "already in mode scoutz (mapcycle.txt)"
step "sk_switchmode error paths ok"

# --- scoutz -> knife -> scoutz ----------------------------------------------
# Stay on scoutzknivez for the knife leg: it is bundled with a .nav, so bots
# join and rounds end. (On a map without one, e.g. stock de_dust2, bots never
# spawn and the switch only happens at the plugin's 180 s deadline.)
switch_mode knife mapcycle-dust2.txt scoutzknivez scoutzknivez
expect_cvar sv_gravity "${knife_gravity}" "knife gravity from modes/knife.cfg"
expect_cvar mapcyclefile mapcycle-dust2.txt "mapcycle follows the switch"
line=$(ask localinfo 'sk_mode')
assert_contains "mode survives the changelevel" "${line}" "knife"
line=$(ask "sk_switchmode knife mapcycle-dust2.txt" '\[SK\] ')
assert_contains "same mode and mapcycle is a no-op in knife too" "${line}" "already in mode knife (mapcycle-dust2.txt)"
step "switched to knife"

switch_mode scoutz mapcycle.txt scoutzknivez
expect_cvar sv_gravity "${gravity}" "knife settings do not leak back into scoutz"
expect_cvar mapcyclefile mapcycle.txt "mapcycle follows the switch back"
map=$(current_map)
assert_eq "map after switching back" scoutzknivez "${map}"
step "switched back to scoutz"

# Grenade maps: only when the he_ map is in this image (local builds with maps/).
if map_in_image he_dodgeball2; then
    mark
    send "sk_switchmode knife mapcycle-nipper.txt he_dodgeball2"
    wait_log '\[SK\] switch to knife' 20 >/dev/null || fail "grenade-map switch was not queued"
    send endround
    wait_log '\[SK\] mode: knife \(grenade pickups on\)' 120 endround >/dev/null ||
        fail "knife mode on he_dodgeball2 did not enable grenade pickups"
    step "knife mode on he_dodgeball2 enables grenade pickups"
fi

# --- Every mapcycle map in the image loads ----------------------------------
if [[ "${CS_E2E_SKIP_MAPS:-0}" != "1" ]]; then
    swept=0
    skipped=""
    maps=$(sed -e 's/[[:space:]].*$//' -e '/^[;\/]/d' -e '/^$/d' "${ROOT}"/config/mapcycle*.txt | LC_ALL=C sort -u)
    for name in ${maps}; do
        if ! map_in_image "${name}"; then
            skipped+=" ${name}"
            continue
        fi
        mark
        send "changelevel ${name}"
        wait_log '\[SK\] mode: ' 90 >/dev/null || fail "changelevel ${name}: the map did not load"
        map=$(current_map)
        assert_eq "changelevel ${name}" "${name}" "${map}"
        swept=$((swept + 1))
    done
    if [[ "${swept}" -lt 1 ]]; then
        fail "no mapcycle map is present in the image"
    fi
    step "loaded ${swept} mapcycle maps${skipped:+; not in this image:${skipped}}"
fi

# --- Nothing went wrong along the way ---------------------------------------
if errors=$(tr -d '\r' < "${LOG}" | grep -aiE 'run time error|bad load|plugin file open error|Segmentation fault'); then
    fail "the server log has plugin or engine errors:
${errors}"
fi

# --- Graceful shutdown ------------------------------------------------------
step "stopping (in-game countdown, about 35 s)"
mark
started=${SECONDS}
"${ENGINE}" stop -t 60 "${NAME}" >/dev/null
elapsed=$((SECONDS - started))
wait_log '\[SERVER\] Goodbye!' 10 >/dev/null || fail "the shutdown countdown was not announced in game"
MARK=0
wait_log '\[entrypoint\] Sending quit command to HLDS' 10 >/dev/null || fail "the entrypoint did not send quit"
if [[ "${elapsed}" -ge 58 ]]; then
    fail "shutdown took ${elapsed}s: the server was killed at the stop timeout instead of quitting"
fi
if [[ "${ENGINE}" != "container" ]]; then
    code=$("${ENGINE}" inspect -f '{{.State.ExitCode}}' "${NAME}")
    assert_eq "exit code after a graceful stop" 0 "${code}"
fi
step "graceful shutdown in ${elapsed}s"

printf 'e2e tests passed\n'
