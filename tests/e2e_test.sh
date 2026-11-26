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
# a read-only root filesystem, file logs, a ban surviving container
# replacement (state volume), BOTS=0 holding across a map change, no TCP listener on the game port, FASTDL_URL reaching sv_downloadurl and
# surviving map changes, bots join, mode switching at round end in both directions (cvars, mapcycle
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
# Has the characters the console treats specially when unquoted (`//`, `?`).
FASTDL="https://fastdl.example.com/cs/cstrike/?v=1"

if [[ -z "${ENGINE}" ]]; then
    for candidate in docker podman container; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            ENGINE="${candidate}"
            break
        fi
    done
fi

# Same hardening as the deployment paths: read-only root, a tmpfs for the
# console FIFO, a state volume. Docker runs under its built-in seccomp
# profile. Apple container gets a state folder
# and a writable root, as in ops/cs-server.
STATE="cs-e2e-state-$$"
STATE_DIR=""
READ_ONLY=1
case "${ENGINE}" in
    docker) RUN_FLAGS=(--cap-drop ALL --security-opt no-new-privileges:true --read-only --tmpfs /tmp -v "${STATE}:/hlds/state") ;;
    podman) RUN_FLAGS=(--cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp -v "${STATE}:/hlds/state") ;;
    container)
        STATE_DIR=$(mktemp -d)
        READ_ONLY=0
        RUN_FLAGS=(--cap-drop ALL -m "${CS_MEMORY:-640M}" -c "${CS_CPUS:-2}" -v "${STATE_DIR}:/hlds/state")
        ;;
    *) fail "usage: ${0##*/} [docker|podman|container] [image]" ;;
esac

LOG=$(mktemp)
LOG_PID=""
MARK=0
HOST_MAPS=""
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
        "${ENGINE}" rm -f "${NAME}-fastdl" "${NAME}-maps-fastdl" "${NAME}-maps-yes" >/dev/null 2>&1 || true
        [[ -z "${HOST_MAPS}" ]] || rm -rf "${HOST_MAPS}"
        if [[ -n "${STATE_DIR}" ]]; then
            rm -rf "${STATE_DIR}"
        else
            "${ENGINE}" volume rm "${STATE}" >/dev/null 2>&1 || true
        fi
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

# boot [run flags...]: start the container and wait for the first map.
# NOMASTER and LAN mode keep the run off the Steam master list. NOMASTER is
# also the configuration where Steam's layer stops answering A2S_INFO, so the
# health check below has to pass on the engine's own ping reply.
boot() {
    if [[ -n "${LOG_PID}" ]]; then
        kill "${LOG_PID}" 2>/dev/null || true
    fi
    : > "${LOG}"
    MARK=0
    "${ENGINE}" run -d --name "${NAME}" "${RUN_FLAGS[@]}" \
        -e NOMASTER=1 -e LAN_MODE=1 -e FASTDL_URL="${FASTDL}" "$@" "${IMAGE}" >/dev/null
    "${ENGINE}" logs -f "${NAME}" > "${LOG}" 2>&1 &
    LOG_PID=$!
    wait_log "\[SK\] mode: ${BOOT_MODE:-scoutz}" 240 >/dev/null || fail "the server did not finish loading its first map"
}

# --- Boot -------------------------------------------------------------------
step "starting ${IMAGE} with ${ENGINE} as ${NAME}"
boot -e BOTS=1 -e METRICS_PORT=9137
step "server is up"

# --- Metrics ----------------------------------------------------------------
# metrics_body: GET /metrics from inside the container (no port is published).
metrics_body() {
    "${ENGINE}" exec "${NAME}" bash -c 'exec 3<>/dev/tcp/127.0.0.1/9137 && printf "GET /metrics HTTP/1.0\r\n\r\n" >&3 && cat <&3' | tr -d '\r'
}
# This boot has NOMASTER=1, where the server-browser query goes unanswered:
# the numbers come from the game through metrics.amxx.
# wait_metrics [ERE]: poll until the game reports (hlds_up 1; the plugin
# writes a second or so after a map loads) and a line matches; sets $metrics.
wait_metrics() {
    local pattern="${1:-^hlds_up 1\$}"
    metrics=""
    for _ in $(seq $((30 * SCALE))); do
        metrics=$(metrics_body 2>/dev/null) || metrics=""
        if grep -q '^hlds_up 1$' <<< "${metrics}" && grep -qE -- "${pattern}" <<< "${metrics}"; then
            return 0
        fi
        sleep 2
    done
    fail "metrics: the server did not report (waiting for /${pattern}/): ${metrics}"
}
wait_metrics '^hlds_players\{type="bot"\} [1-9]'
assert_contains "metrics: Prometheus content type" "${metrics}" "Content-Type: text/plain; version=0.0.4"
assert_contains "metrics: the running map" "${metrics}" 'hlds_map_info{map="scoutzknivez"} 1'
assert_contains "metrics: slots" "${metrics}" "hlds_max_players 20"
grep -qE '^hlds_players\{type="bot"\} [1-9]' <<< "${metrics}" || fail "metrics: no bots counted: ${metrics}"
grep -qE '^hlds_players\{type="human"\} 0$' <<< "${metrics}" || fail "metrics: expected no human players"
grep -qE '^hlds_server_fps [1-9][0-9]*\.[0-9]$' <<< "${metrics}" || fail "metrics: no server FPS"
grep -qE '^hlds_uptime_seconds [0-9]+$' <<< "${metrics}" || fail "metrics: no uptime"
step "metrics: players, map, uptime and FPS with NOMASTER=1"

if [[ "${READ_ONLY}" == "1" ]]; then
    if "${ENGINE}" exec "${NAME}" sh -c ': > /hlds/cstrike/e2e-probe' 2>/dev/null; then
        fail "the root filesystem is writable; the run flags ask for read-only"
    fi
fi
if warning=$(tr -d '\r' < "${LOG}" | grep -a 'WARNING: .* is not writable'); then
    fail "the state volume is not writable by the server: ${warning}"
fi

healthy=0
for _ in $(seq $((30 * SCALE))); do
    if "${ENGINE}" exec "${NAME}" /healthcheck.sh; then
        healthy=1
        break
    fi
    sleep 1
done
assert_eq "health check passes with NOMASTER=1 (server answers a ping)" 1 "${healthy}"

# GoldSrc is UDP only, so no deployment path publishes the port on TCP. (The
# one TCP socket HLDS opens listens on loopback, on an ephemeral port.)
# /proc/net/tcp: field 2 is ADDR:PORT in hex, field 4 the state (0A = LISTEN).
port_hex=$(printf ':%04X' 27015)
listeners=$("${ENGINE}" exec "${NAME}" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' |
    awk -v port="${port_hex}" '$4 == "0A" && substr($2, length($2) - 4) == port { n++ } END { print n + 0 }')
assert_eq "nothing listens on the game port over TCP" 0 "${listeners}"

# The engine cannot write steam_appid.txt on a read-only root, and with
# another game's id (Half-Life's 70) Steam turns every player away with
# "STEAM validation rejected". Only a real client can test the sign-on itself.
appid=$("${ENGINE}" exec "${NAME}" cat /hlds/steam_appid.txt)
assert_eq "steam_appid.txt is Counter-Strike's Steam app id" 10 "${appid}"

# --- Plugins ----------------------------------------------------------------
# Every plugin listed in plugins.ini must have loaded.
listed=$(grep -cE '^[A-Za-z0-9_]+\.amxx' "${ROOT}/plugins/amxmodx/plugins.ini" || true)
modules=$(all_running "meta list" 1)
plugins=$(all_running "amxx plugins" "${listed}")
step "${modules} Metamod plugins and ${plugins} AMX Mod X plugins running"

# --- Startup state ----------------------------------------------------------
gravity=$(sed -n 's/^sv_gravity[[:space:]]*"\{0,1\}\([0-9]*\).*/\1/p' "${ROOT}/config/modes/scoutz.cfg")
knife_gravity=$(sed -n 's/^sv_gravity[[:space:]]*"\{0,1\}\([0-9]*\).*/\1/p' "${ROOT}/config/modes/knife.cfg")
[[ -n "${gravity}" && -n "${knife_gravity}" && "${gravity}" != "${knife_gravity}" ]] ||
    fail "expected different sv_gravity values in config/modes/scoutz.cfg and config/modes/knife.cfg"

expect_cvar sv_gravity "${gravity}" "scoutz gravity from modes/scoutz.cfg"
expect_cvar sv_maxvelocity 2000 "scoutz keeps the stock speed cap"
expect_cvar mp_forcechasecam 2 "scoutz keeps the first-person deathcam"
expect_cvar mapcyclefile mapcycle.txt "default mapcycle"
expect_cvar sv_downloadurl "${FASTDL}" "FASTDL_URL sets the download URL"
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
# server.cfg and the mode cfg were re-run twice by now.
expect_cvar sv_downloadurl "${FASTDL}" "the download URL survives map changes"
map=$(current_map)
assert_eq "map after switching back" scoutzknivez "${map}"
step "switched back to scoutz"

# --- scoutz -> vanilla -> scoutz --------------------------------------------
# The mode has its own plugin list (plugins/amxmodx/modes/vanilla.ini), read
# on the changelevel. Same map as above, for the same reason.
vanilla_listed=$(grep -cE '^[A-Za-z0-9_]+\.amxx' "${ROOT}/plugins/amxmodx/modes/vanilla.ini" || true)
[[ "${vanilla_listed}" -gt 0 && "${vanilla_listed}" -lt "${listed}" ]] ||
    fail "expected modes/vanilla.ini to list fewer plugins than plugins.ini"
switch_mode vanilla mapcycle-dust2.txt scoutzknivez scoutzknivez
expect_cvar sv_gravity 800 "vanilla gravity from modes/vanilla.cfg"
expect_cvar mp_startmoney 800 "vanilla start money"
vanilla_plugins=$(all_running "amxx plugins" "${vanilla_listed}")
assert_eq "vanilla runs its own plugin list" "${vanilla_listed}" "${vanilla_plugins}"
step "switched to vanilla (${vanilla_plugins} plugins)"

switch_mode scoutz mapcycle.txt scoutzknivez
expect_cvar sv_gravity "${gravity}" "vanilla settings do not leak back into scoutz"
expect_cvar mp_startmoney 16000 "scoutz start money is back"
back=$(all_running "amxx plugins" "${listed}")
assert_eq "plugins.ini is back after vanilla" "${plugins}" "${back}"
step "switched back to scoutz from vanilla"

# --- scoutz -> match -> scoutz ----------------------------------------------
# match.amxx with bots: warmup, a forced start, the knife round, the side
# choice, live, a pause that holds the freeze time. Ready-up needs people.
match_listed=$(grep -cE '^[A-Za-z0-9_]+\.amxx' "${ROOT}/plugins/amxmodx/modes/match.ini" || true)
switch_mode match mapcycle-dust2.txt scoutzknivez scoutzknivez
wait_log '\[MATCH\] state: warmup' 30 >/dev/null || fail "match mode did not start in warmup"
match_plugins=$(all_running "amxx plugins" "${match_listed}")
assert_eq "match runs its own plugin list" "${match_listed}" "${match_plugins}"
expect_cvar mp_round_infinite 1 "warmup rounds do not end"
line=$(ask match_pause '\[MATCH\] pausing')
assert_contains "no pause outside the live match" "${line}" "pausing is for the live match (warmup)"
mark
send match_start
wait_log '\[MATCH\] state: knife' 20 >/dev/null || fail "match_start did not start the knife round"
wait_log '\[MATCH\] state: choose' 300 >/dev/null || fail "the knife round did not produce a winner"
mark
send match_switch
wait_log '\[MATCH\] state: live \(switched\)' 20 >/dev/null || fail "match_switch did not start the match"
expect_cvar mp_round_infinite 0 "live rounds end"
expect_cvar mp_startmoney 800 "live money from modes/match.cfg"
# sv_restart 3, then freeze time (15 s): the pause takes hold in it, and no
# round starts for as long as it lasts.
mark
wait_log 'World triggered "Restart_Round_' 20 >/dev/null || true
sleep $((5 * SCALE))
mark
send match_pause
wait_log '\[MATCH\] paused' 60 >/dev/null || fail "the match did not pause in freeze time"
sleep $((25 * SCALE))
if since_mark 'World triggered "Round_Start"' >/dev/null; then
    fail "a round started while the match was paused"
fi
mark
send match_unpause
wait_log 'World triggered "Round_Start"' 20 >/dev/null || fail "the round did not start after the unpause"
step "match: warmup, knife round, side choice, live, pause (${match_plugins} plugins)"

switch_mode scoutz mapcycle.txt scoutzknivez
expect_cvar sv_gravity "${gravity}" "match settings do not leak back into scoutz"
expect_cvar mp_round_infinite 0 "warmup rules do not leak into scoutz"
expect_cvar mp_maxrounds 0 "the match round limit does not leak into scoutz"
back=$(all_running "amxx plugins" "${listed}")
assert_eq "plugins.ini is back after match" "${plugins}" "${back}"
step "switched back to scoutz from match"

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
    # Not the climb rotation: with bots on, each of its maps would have a
    # navigation mesh generated. The climb section loads those, bots off.
    maps=$(for cycle in "${ROOT}"/config/mapcycle*.txt; do
        [[ "${cycle##*/}" == mapcycle-climb.txt ]] || sed -e 's/[[:space:]].*$//' -e '/^[;\/]/d' -e '/^$/d' "${cycle}"
    done | LC_ALL=C sort -u)
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

# --- State written to the volume --------------------------------------------
# A ban by address (192.0.2.0/24 is reserved for documentation), saved the way
# AMX Mod X's amx_banip does it. Checked again after the container is replaced.
send "addip 0 192.0.2.7"
send writeip
saved=""
for _ in $(seq $((10 * SCALE))); do
    saved=$("${ENGINE}" exec "${NAME}" cat /hlds/state/listip.cfg 2>/dev/null || true)
    [[ "${saved}" == *192.0.2.7* ]] && break
    sleep 1
done
assert_contains "writeip lands in the state volume" "${saved}" "addip 0 192.0.2.7"
"${ENGINE}" exec "${NAME}" sh -c 'ls /hlds/state/logs/L*.log >/dev/null 2>&1' ||
    fail "no server log file in the state volume (LOGS defaults to 1)"
"${ENGINE}" exec "${NAME}" sh -c 'ls /hlds/state/amxmodx/logs/L*.log >/dev/null 2>&1' ||
    fail "no AMX Mod X log file in the state volume"
"${ENGINE}" exec "${NAME}" test -s /hlds/state/amxmodx/users.ini ||
    fail "users.ini was not seeded into the state volume"
step "ban list, logs and users.ini are in the state volume"

# --- Generated navigation meshes are kept -------------------------------------
# A map that ships without a .nav has a link into the state volume. The bots
# analyse it on first load and save the mesh there; the next load must read it
# back instead of analysing again.
# shellcheck disable=SC2016 # expands inside the container's sh
navless=$("${ENGINE}" exec "${NAME}" sh -c 'for n in /hlds/cstrike/maps/scoutzknivez*.nav; do [ -L "$n" ] && basename "$n" .nav && break; done; true')
if [[ -n "${navless}" ]]; then
    mark
    send "changelevel ${navless}"
    wait_log '\[SK\] mode: ' 90 >/dev/null || fail "changelevel ${navless}: the map did not load"
    saved=0
    for _ in $(seq $((120 * SCALE))); do
        if "${ENGINE}" exec "${NAME}" test -s "/hlds/state/nav/${navless}.nav"; then
            saved=1
            break
        fi
        sleep 1
    done
    assert_eq "generated ${navless}.nav is in the state volume" 1 "${saved}"
    sleep $((5 * SCALE))
    mark
    send "changelevel ${navless}"
    wait_log '\[SK\] mode: ' 90 >/dev/null || fail "changelevel ${navless}: the map did not reload"
    sleep $((5 * SCALE))
    if since_mark 'Failed to load .*navigation map|Merging navigation areas' >/dev/null; then
        fail "${navless} was analysed again although its mesh is saved"
    fi
    step "the mesh for ${navless} was generated once and reused"
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

# --- A replaced container keeps its state ------------------------------------
"${ENGINE}" rm -f "${NAME}" >/dev/null
step "replacing the container on the same state volume"
boot -e BOTS=0
# listip pads each octet: "192.  0.  2.  7 : permanent".
line=$(ask listip '^ *192\. *0\. *2\. *7 : ')
assert_contains "the ban survives container replacement" "${line}" "permanent"
step "the ban survived"

# --- BOTS=0 stays off across map changes --------------------------------------
# server.cfg sets bot_quota and is re-run on every map; the plugin must turn
# bots off again each time. This boot is the one with BOTS=0.
if note=$(tr -d '\r' < "${LOG}" | grep -a 'NOTE: .* is not a volume'); then
    fail "the state volume was not recognised as one: ${note}"
fi
mark
send "changelevel scoutzknivez"
wait_log '\[SK\] mode: scoutz' 90 >/dev/null || fail "changelevel with BOTS=0: the map did not load"
players=0
for _ in $(seq 4); do
    sleep 5
    line=$(ask status '^players +: +[0-9]+ active')
    players="${line#*: }"
    players="${players#"${players%%[! ]*}"}"
    players="${players%% *}"
    [[ "${players}" -le 1 ]] || break
done
# websitebot.amxx keeps one fake client of its own in the player list.
if [[ "${players}" -gt 1 ]]; then
    fail "bots joined with BOTS=0 after a map change (players: ${players})"
fi
expect_cvar bot_quota 0 "BOTS=0 survives server.cfg being re-run"
# Not even for a moment: server.cfg sets bot_quota on every map start, and a
# bot that joined before the plugin put the 0 back was kicked half a second
# later. A map change soon after has crashed in that bot's navigation code.
# (websitebot.amxx's spectator is the one fake client allowed.)
if joined=$(tr -d '\r' < "${LOG}" | grep -a '<BOT><>" joined team "\(CT\|TERRORIST\)"'); then
    fail "a bot joined a team with BOTS=0: ${joined}"
fi
# This boot has no METRICS_PORT: nothing listens, the file is still kept.
if "${ENGINE}" exec "${NAME}" bash -c 'exec 3<>/dev/tcp/127.0.0.1/9137' 2>/dev/null; then
    fail "the metrics endpoint listens without METRICS_PORT"
fi
"${ENGINE}" exec "${NAME}" grep -q '^hlds_map_info{map="scoutzknivez"} 1$' /hlds/.runtime/metrics.prom ||
    fail "metrics.prom is not kept without METRICS_PORT"
step "BOTS=0 keeps bots off"

# --- MODE=vanilla from a cold start -------------------------------------------
# The plugin list comes from the command line here, not from a mode switch:
# AMX Mod X must not overwrite it from core.ini.
"${ENGINE}" rm -f "${NAME}" >/dev/null
BOOT_MODE=vanilla boot -e BOTS=0 -e MODE=vanilla
vanilla_plugins=$(all_running "amxx plugins" "${vanilla_listed}")
assert_eq "MODE=vanilla starts with its own plugin list" "${vanilla_listed}" "${vanilla_plugins}"
map=$(current_map)
assert_eq "MODE=vanilla starts on a stock map" de_dust2 "${map}"
expect_cvar mapcyclefile mapcycle-dust2.txt "MODE=vanilla uses the stock rotation"
expect_cvar sv_gravity 800 "vanilla gravity at startup"
step "MODE=vanilla starts in vanilla"

# --- MODE=climb from a cold start ----------------------------------------------
# A KZ map, its own plugin list, no bots, no rounds. Nobody presses the map's
# buttons here, so times go in through mv_record, the console's way to enter
# one; the list has to survive a map change (it is read back from the state
# volume) and the mode's respawn settings must not follow the server out.
# The published image has no third-party maps (they are fetched and built in
# locally), so there this section is skipped, like the NIPPER maps above.
climb_map=$(awk '!/^[[:space:]]*($|;|\/)/ { print $1; exit }' "${ROOT}/config/mapcycle-climb.txt")
if ! map_in_image "${climb_map}"; then
    step "climb mode skipped: ${climb_map} is not in this image"
else
    climb_listed=$(grep -cE '^[A-Za-z0-9_]+\.amxx' "${ROOT}/plugins/amxmodx/modes/climb.ini" || true)
    "${ENGINE}" rm -f "${NAME}" >/dev/null
    BOOT_MODE=climb boot -e MODE=climb -e METRICS_PORT=9137
    climb_plugins=$(all_running "amxx plugins" "${climb_listed}")
    assert_eq "MODE=climb starts with its own plugin list" "${climb_listed}" "${climb_plugins}"
    map=$(current_map)
    assert_eq "MODE=climb starts on the rotation's first map" "${climb_map}" "${map}"
    expect_cvar mapcyclefile mapcycle-climb.txt "MODE=climb uses the climb rotation"
    expect_cvar sv_gravity 800 "climb gravity"
    expect_cvar sv_airaccelerate 10 "climb air acceleration"
    expect_cvar sv_accelerate 5 "climb accelerate"
    expect_cvar sv_friction 4 "climb friction"
    expect_cvar edgefriction 2 "climb edge friction"
    expect_cvar sv_stopspeed 75 "climb stop speed"
    expect_cvar sv_maxvelocity 2000 "climb speed cap"
    expect_cvar sv_maxspeed 320 "climb max speed"
    expect_cvar sv_stepsize 18 "climb step size"
    expect_cvar sv_wateraccelerate 10 "climb water accelerate"
    expect_cvar mp_forcechasecam 0 "free look in climb mode"
    expect_cvar mp_timelimit 60 "climb map clock"
    expect_cvar mp_falldamage 1 "fall damage in climb mode"
    expect_cvar mp_round_infinite 1 "no rounds in climb mode"
    expect_cvar bot_quota 0 "no bots in climb mode"
    tr -d '\r' < "${LOG}" | grep -aqF "[MV] ${climb_map}: timer buttons found" ||
        fail "movement.amxx found no timer buttons on ${climb_map}"
    tr -d '\r' < "${LOG}" | grep -aqF "[MV] ${climb_map}: checkpoints ground, velocity cleared" ||
        fail "climb checkpoints did not stay ground-only"

    line=$(ask 'mv_record "STEAM_0:0:1" "Ada" 12345 0 0' '\[MV\] (not )?recorded')
    assert_contains "a first time tops the pro list" "${line}" "recorded: pro #1"
    line=$(ask 'mv_record "STEAM_0:0:1" "Ada" 20000 0 0' '\[MV\] (not )?recorded')
    assert_contains "a slower time by the same player is not kept" "${line}" "not recorded"
    line=$(ask 'mv_record "STEAM_0:0:2" "Bo" 11000 4 2' '\[MV\] (not )?recorded')
    assert_contains "a run with teleports goes on the cp list" "${line}" "recorded: cp #1"
    line=$(ask 'mv_record "STEAM_0:0:3" "Cy" 9999 0 0' '\[MV\] (not )?recorded')
    assert_contains "a faster time takes first place" "${line}" "recorded: pro #1"
    line=$(ask mv_top '\[MV\] pro 2 ')
    assert_contains "the list is ordered and formatted" "${line}" "pro 2 02:03.45 STEAM_0:0:1 Ada"
    "${ENGINE}" exec "${NAME}" test -s "/hlds/state/amxmodx/records/${climb_map}.tsv" ||
        fail "the top list is not in the state volume"
    mark
    send "changelevel ${climb_map}"
    wait_log '\[SK\] mode: climb' 90 >/dev/null || fail "the server did not reload ${climb_map}"
    line=$(ask mv_top '\[MV\] cp 1 ')
    assert_contains "the list survives a map change" "${line}" "cp 1 01:50.00 STEAM_0:0:2 Bo"
    waited=0
    until "${ENGINE}" exec "${NAME}" grep -q '^hlds_movement_bests_total 3$' /hlds/.runtime/metrics.prom; do
        waited=$((waited + 1))
        [[ "${waited}" -lt $((30 * SCALE)) ]] || fail "metrics.prom does not count the three list entries"
        sleep 1
    done
    if [[ "${CS_E2E_SKIP_MAPS:-0}" != "1" ]]; then
        climbs=0
        while read -r name _; do
            [[ -n "${name}" && "${name}" != \;* && "${name}" != /* ]] || continue
            map_in_image "${name}" || fail "${name} (mapcycle-climb.txt) is not in the image"
            mark
            send "changelevel ${name}"
            wait_log "\[MV\] ${name}: timer buttons found" 90 >/dev/null ||
                fail "changelevel ${name}: the map did not load with its timer buttons"
            wait_log '\[SK\] mode: climb' 90 >/dev/null || fail "changelevel ${name}: the mode did not come back"
            climbs=$((climbs + 1))
        done < "${ROOT}/config/mapcycle-climb.txt"
        step "loaded ${climbs} climb maps, each with timer buttons"
    fi
    step "MODE=climb on ${climb_map}: ${climb_plugins} plugins, top lists kept"

    switch_mode scoutz mapcycle.txt scoutzknivez
    expect_cvar mp_round_infinite 0 "climb's endless round does not leak into scoutz"
    expect_cvar mp_forcerespawn 0 "climb's respawn does not leak into scoutz"
    expect_cvar sv_gravity "${gravity}" "scoutz gravity after climb"
    expect_cvar sv_maxvelocity 2000 "climb's speed cap does not leak into scoutz"
    expect_cvar mp_forcechasecam 2 "free look does not leak into scoutz"
    expect_cvar mp_timelimit 30 "climb's map clock does not leak into scoutz"
    plugins_after=$(all_running "amxx plugins" "${listed}")
    assert_eq "plugins.ini is back after climb" "${plugins}" "${plugins_after}"
    step "switched from climb to scoutz"
fi

# --- MODE=surf from a cold start -----------------------------------------------
# Surf maps have no timer buttons: the start zone is the box around the spawn
# points and the end zone is marked by an admin, here through the console. A
# climb map in the surf rotation gets climb physics from its prefix.
surf_map=$(awk '!/^[[:space:]]*($|;|\/)/ { print $1; exit }' "${ROOT}/config/mapcycle-surf.txt")
if ! map_in_image "${surf_map}"; then
    step "surf mode skipped: ${surf_map} is not in this image"
else
    surf_listed=$(grep -cE '^[A-Za-z0-9_]+\.amxx' "${ROOT}/plugins/amxmodx/modes/surf.ini" || true)
    "${ENGINE}" rm -f "${NAME}" >/dev/null
    BOOT_MODE=surf boot -e MODE=surf
    surf_plugins=$(all_running "amxx plugins" "${surf_listed}")
    assert_eq "MODE=surf starts with its own plugin list" "${surf_listed}" "${surf_plugins}"
    map=$(current_map)
    assert_eq "MODE=surf starts on the rotation's first map" "${surf_map}" "${map}"
    expect_cvar mapcyclefile mapcycle-surf.txt "MODE=surf uses the surf rotation"
    expect_cvar sv_airaccelerate 100 "surf air acceleration"
    expect_cvar sv_accelerate 5 "surf accelerate"
    expect_cvar sv_friction 4 "surf friction"
    expect_cvar edgefriction 2 "surf edge friction"
    expect_cvar sv_stopspeed 75 "surf stop speed"
    expect_cvar sv_maxvelocity 3500 "surf speed cap"
    expect_cvar sv_maxspeed 320 "surf max speed"
    expect_cvar sv_stepsize 18 "surf step size"
    expect_cvar sv_wateraccelerate 10 "surf water accelerate"
    expect_cvar mp_forcechasecam 0 "free look in surf mode"
    expect_cvar mp_timelimit 40 "surf map clock"
    expect_cvar mp_falldamage 0 "no fall damage in surf mode"
    expect_cvar autobhop_enabled 1 "bunny hop in surf mode"
    expect_cvar bot_quota 0 "no bots in surf mode"
    tr -d '\r' < "${LOG}" | grep -aqF "[MV] ${surf_map}: spawn start zone, no end zone" ||
        fail "movement.amxx did not make a start zone from the spawn points on ${surf_map}"
    tr -d '\r' < "${LOG}" | grep -aqF "[MV] ${surf_map}: checkpoints air, velocity restored" ||
        fail "surf checkpoints did not allow an air save"
    line=$(ask "mv_zone_set end 0 0 0 64 64 64" '\[MV\] end zone saved')
    assert_contains "an end zone completes the timer" "${line}" "spawn start zone, end zone"
    "${ENGINE}" exec "${NAME}" grep -q '^end 0 0 0 64 64 128$' "/hlds/state/amxmodx/zones/${surf_map}.txt" ||
        fail "the end zone is not in the state volume (raised to the minimum height)"
    mark
    send "changelevel ${surf_map}"
    wait_log "\[MV\] ${surf_map}: spawn start zone, end zone" 90 >/dev/null ||
        fail "the end zone did not survive a map change"
    wait_log '\[SK\] mode: surf' 90 >/dev/null || fail "the server did not reload ${surf_map}"
    if [[ "${CS_E2E_SKIP_MAPS:-0}" != "1" ]]; then
        surfs=0
        while read -r name _; do
            [[ -n "${name}" && "${name}" != \;* && "${name}" != /* ]] || continue
            map_in_image "${name}" || fail "${name} (mapcycle-surf.txt) is not in the image"
            mark
            send "changelevel ${name}"
            wait_log "\[MV\] ${name}: spawn start zone" 90 >/dev/null ||
                fail "changelevel ${name}: the map did not load with a start zone"
            wait_log '\[SK\] mode: surf' 90 >/dev/null || fail "changelevel ${name}: the mode did not come back"
            surfs=$((surfs + 1))
        done < "${ROOT}/config/mapcycle-surf.txt"
        step "loaded ${surfs} surf maps, each with a start zone"
    fi
    if map_in_image "${climb_map}"; then
        mark
        send "changelevel ${climb_map}"
        wait_log '\[SK\] mode: surf' 90 >/dev/null || fail "changelevel ${climb_map} in surf mode"
        expect_cvar sv_airaccelerate 10 "a climb map in the surf rotation gets climb physics"
        expect_cvar sv_maxvelocity 2000 "and the Kreedz speed cap"
        expect_cvar mp_timelimit 60 "and the climb map clock"
        expect_cvar autobhop_enabled 0 "and no bunny hop"
        expect_cvar mp_falldamage 1 "and fall damage"
        # The climb boot earlier in this log already printed the ground line.
        # Only the lines since this changelevel count.
        wait_log "\\[MV\\] ${climb_map}: checkpoints ground, velocity cleared" 20 >/dev/null ||
            fail "a climb map in the surf rotation kept surf checkpoints"
    fi
    step "MODE=surf on ${surf_map}: ${surf_plugins} plugins, zones kept"
fi

# --- FastDL sidecar -----------------------------------------------------------
# The same image under another entrypoint serves maps and assets over HTTP,
# and nothing else: no settings, no admin files, no directory listings.
if [[ "${ENGINE}" != "container" ]]; then
    FASTDL_NAME="${NAME}-fastdl"
    "${ENGINE}" rm -f "${FASTDL_NAME}" >/dev/null 2>&1 || true
    "${ENGINE}" run -d --name "${FASTDL_NAME}" --entrypoint /fastdl.sh --network none \
        --cap-drop ALL --security-opt no-new-privileges --read-only "${IMAGE}" >/dev/null
    served=0
    for _ in $(seq $((20 * SCALE))); do
        if "${ENGINE}" exec "${FASTDL_NAME}" /fastdl.sh check 2>/dev/null; then
            served=1
            break
        fi
        sleep 1
    done
    assert_eq "the FastDL sidecar serves the default map" 1 "${served}"
    # http_status <path>: the status code the sidecar answers with.
    http_status() {
        # shellcheck disable=SC2016 # expanded by the container's bash
        "${ENGINE}" exec "${FASTDL_NAME}" bash -c 'exec 3<>/dev/tcp/127.0.0.1/27080 && printf "HEAD %s HTTP/1.0\r\n\r\n" "$1" >&3 && read -r -t 3 -u 3 _ code _ && echo "${code}"' bash "$1"
    }
    for path in /cstrike/maps/scoutzknivez.bsp /cstrike/cstrike.wad; do
        code=$(http_status "${path}")
        assert_eq "FastDL serves ${path}" 200 "${code}"
    done
    for path in /cstrike/server.cfg /cstrike/addons/amxmodx/configs/users.ini /cstrike/maps/../server.cfg /cstrike/maps/ /; do
        code=$(http_status "${path}")
        assert_eq "FastDL does not serve ${path}" 404 "${code}"
    done
    started=$(date +%s)
    "${ENGINE}" stop -t 10 "${FASTDL_NAME}" >/dev/null
    took=$(($(date +%s) - started))
    [[ "${took}" -lt 8 ]] || fail "the FastDL sidecar ignored SIGTERM (stopped after ${took}s)"
    "${ENGINE}" rm -f "${FASTDL_NAME}" >/dev/null
    step "FastDL sidecar: serves maps and wads, nothing else, stops on SIGTERM"
fi

# --- Host maps (published image, files from the host) ------------------------
# The movement rotation is not in a cleared image. The game container sees
# each host .bsp through its own file mount, and the stock maps stay. The
# sidecar mounts the tree at /maps-local and must not publish fastdl=no.
if [[ "${ENGINE}" != "container" ]]; then
    HOST_MAPS=$(mktemp -d)
    mkdir -p "${HOST_MAPS}/maps"
    printf 'not a real bsp\n' > "${HOST_MAPS}/maps/kz_man_everest.bsp"

    set +e
    missing=$(
        "${ENGINE}" run --rm "${RUN_FLAGS[@]}" \
            -e MAPS_LOCAL=/maps-local \
            --entrypoint /entrypoint.sh \
            "${IMAGE}" 2>&1
    )
    missing_status=$?
    set -e
    [[ "${missing_status}" -ne 0 ]] || fail "a missing host map directory should stop the entrypoint: ${missing}"
    assert_contains "missing host dir names the populate command" "${missing}" "just fetch-maps-host"
    assert_contains "missing host dir says it is not mounted" "${missing}" "is not a directory"

    set +e
    unmounted=$(
        "${ENGINE}" run --rm "${RUN_FLAGS[@]}" \
            -e MAPS_LOCAL=/maps-local \
            -v "${HOST_MAPS}:/maps-local:ro" \
            --entrypoint /entrypoint.sh \
            "${IMAGE}" 2>&1
    )
    unmounted_status=$?
    set -e
    [[ "${unmounted_status}" -ne 0 ]] || fail "host maps without file mounts should stop the entrypoint: ${unmounted}"
    assert_contains "entrypoint asks for a file mount" "${unmounted}" "is not visible"
    assert_contains "the file mount names the host bsp" "${unmounted}" \
        "kz_man_everest.bsp:/hlds/cstrike/maps/kz_man_everest.bsp:ro,Z"

    "${ENGINE}" run --rm "${RUN_FLAGS[@]}" \
        -e MAPS_LOCAL=/maps-local \
        -v "${HOST_MAPS}:/maps-local:ro" \
        -v "${HOST_MAPS}/maps/kz_man_everest.bsp:/hlds/cstrike/maps/kz_man_everest.bsp:ro" \
        --entrypoint bash "${IMAGE}" -c '
            set -euo pipefail
            test -f /hlds/cstrike/maps/kz_man_everest.bsp
            test -s /hlds/cstrike/maps/scoutzknivez.bsp
            test -s /hlds/cstrike/maps/de_dust2.bsp
            # shellcheck source=/usr/local/share/cs-server/overlay-host-maps.sh
            source /usr/local/share/cs-server/overlay-host-maps.sh
            maps_apply_game >/dev/null
        ' || fail "file-mounted host map hid a stock map or was not visible"

    printf 'not a real bsp\n' > "${HOST_MAPS}/maps/surf_ski_5.bsp"
    printf 'cleared bsp\n' > "${HOST_MAPS}/maps/cleared_one.bsp"
    printf 'cleared_one\thttps://example.invalid/c\t%s\ttest\ttest\t-\tyes\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        > "${HOST_MAPS}/manifest.tsv"
    printf 'kz_man_everest\thttps://example.invalid/k\t%s\ttest\ttest\t-\tno\n' \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        >> "${HOST_MAPS}/manifest.tsv"

    MAPS_FASTDL="${NAME}-maps-fastdl"
    "${ENGINE}" rm -f "${MAPS_FASTDL}" >/dev/null 2>&1 || true
    "${ENGINE}" run -d --name "${MAPS_FASTDL}" --entrypoint /fastdl.sh --network none \
        --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp \
        -e MAPS_LOCAL=/maps-local -e FASTDL_PORT=27081 \
        -v "${HOST_MAPS}:/maps-local:ro" \
        "${IMAGE}" >/dev/null
    served=0
    for _ in $(seq $((20 * SCALE))); do
        if "${ENGINE}" exec "${MAPS_FASTDL}" /fastdl.sh check 2>/dev/null; then
            served=1
            break
        fi
        sleep 1
    done
    assert_eq "host-map FastDL still serves the baked default map" 1 "${served}"
    # http_code <port> <path>
    http_code() {
        # shellcheck disable=SC2016 # expanded by the container's bash
        "${ENGINE}" exec "$3" bash -c 'exec 3<>/dev/tcp/127.0.0.1/"$1" && printf "HEAD %s HTTP/1.0\r\n\r\n" "$2" >&3 && read -r -t 3 -u 3 _ code _ && echo "${code}"' bash "$1" "$2"
    }
    code=$(http_code 27081 /cstrike/maps/kz_man_everest.bsp "${MAPS_FASTDL}")
    assert_eq "FastDL does not serve kz_man_everest" 404 "${code}"
    code=$(http_code 27081 /cstrike/maps/surf_ski_5.bsp "${MAPS_FASTDL}")
    assert_eq "FastDL does not serve surf_ski_5" 404 "${code}"
    code=$(http_code 27081 /cstrike/maps/scoutzknivez.bsp "${MAPS_FASTDL}")
    assert_eq "FastDL still serves the baked map" 200 "${code}"
    "${ENGINE}" rm -f "${MAPS_FASTDL}" >/dev/null

    MAPS_YES="${NAME}-maps-yes"
    "${ENGINE}" rm -f "${MAPS_YES}" >/dev/null 2>&1 || true
    "${ENGINE}" run -d --name "${MAPS_YES}" --entrypoint /fastdl.sh --network none \
        --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp \
        -e MAPS_LOCAL=/maps-local -e FASTDL_PORT=27082 \
        -e MAPS_MANIFEST=/maps-local/manifest.tsv \
        -v "${HOST_MAPS}:/maps-local:ro" \
        "${IMAGE}" >/dev/null
    served=0
    for _ in $(seq $((20 * SCALE))); do
        if "${ENGINE}" exec "${MAPS_YES}" env FASTDL_PORT=27082 /fastdl.sh check 2>/dev/null; then
            served=1
            break
        fi
        sleep 1
    done
    assert_eq "cleared-host FastDL serves the baked default map" 1 "${served}"
    code=$(http_code 27082 /cstrike/maps/cleared_one.bsp "${MAPS_YES}")
    assert_eq "FastDL serves a host map marked fastdl=yes" 200 "${code}"
    code=$(http_code 27082 /cstrike/maps/kz_man_everest.bsp "${MAPS_YES}")
    assert_eq "FastDL still refuses kz_man_everest when another map is cleared" 404 "${code}"
    "${ENGINE}" rm -f "${MAPS_YES}" >/dev/null
    rm -rf "${HOST_MAPS}"
    HOST_MAPS=""
    step "host maps: file mount keeps stock maps, FastDL skips fastdl=no"
fi

# --- Offline LAN server -------------------------------------------------------
# A LAN box may have no uplink: with no network at all the server must come
# up and answer the server-browser query (A2S_INFO), which is how the LAN tab
# finds it. NOMASTER=1 would silence that reply, so it is not set here.
if [[ "${ENGINE}" != "container" ]]; then
    "${ENGINE}" rm -f "${NAME}" >/dev/null
    kill "${LOG_PID}" 2>/dev/null || true
    : > "${LOG}"
    MARK=0
    "${ENGINE}" run -d --name "${NAME}" "${RUN_FLAGS[@]}" --network none \
        -e LAN_MODE=1 -e BOTS=0 -e METRICS_PORT=9137 "${IMAGE}" >/dev/null
    "${ENGINE}" logs -f "${NAME}" > "${LOG}" 2>&1 &
    LOG_PID=$!
    wait_log '\[SK\] mode: scoutz' 240 >/dev/null || fail "the server did not load its first map with no network"
    "${ENGINE}" exec "${NAME}" /healthcheck.sh || fail "health check failed with no network"
    # Reply type: I (info) or A (challenge). Either means the query is served.
    # shellcheck disable=SC2016 # runs inside the container
    reply=$("${ENGINE}" exec "${NAME}" bash -c '
        exec 3<>/dev/udp/127.0.0.1/27015
        printf "\377\377\377\377TSource Engine Query\0" >&3
        LC_ALL=C IFS= read -r -t 5 -N 5 -u 3 head 2>/dev/null
        printf %s "${head:4:1}"') || true
    case "${reply}" in
        I | A) ;;
        *) fail "no A2S_INFO reply offline with LAN_MODE=1 (got: '${reply}')" ;;
    esac
    # The same endpoint without NOMASTER (and without a network).
    wait_metrics
    assert_contains "metrics without NOMASTER: the running map" "${metrics}" 'hlds_map_info{map="scoutzknivez"} 1'
    step "offline: boots, answers the server-browser query and reports metrics"
fi

printf 'e2e tests passed\n'
