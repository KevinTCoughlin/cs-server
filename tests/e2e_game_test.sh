#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# End-to-end test of an image built for another game (GAME=czero, dod, tfc,
# valve, gearbox, dmc or ricochet):
#
#   tests/e2e_game_test.sh [docker|podman] [image]
#
# The image says which game it holds. The server boots on the read-only root
# with a state volume on the game's default map, answers the health check,
# runs Metamod and AMX Mod X (and bots, where the game has them), changes map through the console FIFO, saves a
# ban to the state volume and shuts down gracefully. tests/e2e_test.sh covers
# the Counter-Strike image and its plugins.
#
# CS_E2E_TIMEOUT_SCALE multiplies every wait (default 1).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

ENGINE="${1:-${CONTAINER_ENGINE:-podman}}"
IMAGE="${2:-${CS_E2E_IMAGE:-localhost/cs-server:dod}}"
GAME_ENV=/usr/local/share/cs-server/game.env
SCALE="${CS_E2E_TIMEOUT_SCALE:-1}"
NAME="game-e2e-$$"
STATE="game-e2e-state-$$"
FIFO="/hlds/.runtime/hlds-input"

case "${ENGINE}" in
    docker) RUN_FLAGS=(--cap-drop ALL --security-opt no-new-privileges:true --security-opt "seccomp=${ROOT}/ops/seccomp/docker-default.json" --read-only --tmpfs /tmp -v "${STATE}:/hlds/state") ;;
    podman) RUN_FLAGS=(--cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp -v "${STATE}:/hlds/state") ;;
    *) fail "usage: ${0##*/} [docker|podman] [image]" ;;
esac

step() { printf '[e2e-game] %s\n' "$*"; }

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    local status=$?
    if [[ "${status}" -ne 0 ]]; then
        printf '\n[e2e-game] FAILED; last server output:\n' >&2
        "${ENGINE}" logs "${NAME}" 2>&1 | tr -d '\r' | tail -n 60 >&2 || true
    fi
    "${ENGINE}" rm -f "${NAME}" >/dev/null 2>&1 || true
    "${ENGINE}" volume rm "${STATE}" >/dev/null 2>&1 || true
    exit "${status}"
}
trap cleanup EXIT

logs() { "${ENGINE}" logs "${NAME}" 2>&1 | tr -d '\r'; }

# wait_for <ERE> <seconds>: the pattern shows up in the server's output.
wait_for() {
    local waited=0 seconds=$(($2 * SCALE)) output
    while [[ "${waited}" -lt "${seconds}" ]]; do
        # Captured first: grep -q leaving early would fail the pipe (pipefail).
        output=$(logs)
        if grep -aqE -- "$1" <<< "${output}"; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

send() {
    # shellcheck disable=SC2016 # $1 expands inside the container's sh
    "${ENGINE}" exec "${NAME}" sh -c 'printf "%s\n" "$1" > "$2"' sh "$1" "${FIFO}"
}

# The image's row of scripts/game-env.sh.
row=$("${ENGINE}" run --rm --entrypoint cat "${IMAGE}" "${GAME_ENV}")
GAME="" GAME_MAP="" GAME_STATS="" GAME_BOTS=0 GAME_APPID=""
eval "$(grep -E '^GAME(_MAP|_STATS|_BOTS|_APPID)?=[A-Za-z0-9_.-]*$' <<< "${row}")"
[[ -n "${GAME}" && -n "${GAME_MAP}" ]] || fail "the image has no usable ${GAME_ENV}"
label=$("${ENGINE}" image inspect -f '{{index .Config.Labels "io.github.kevintcoughlin.cs-server.game"}}' "${IMAGE}")
assert_eq "the image label names its game" "${GAME}" "${label}"
expected=$(bash "${ROOT}/scripts/game-env.sh" "${GAME}")
assert_eq "game.env in the image matches scripts/game-env.sh" "${expected}" "${row}"
# The engine cannot write this on a read-only root, and with another game's
# id Steam turns every player away ("STEAM validation rejected").
appid=$("${ENGINE}" run --rm --network none --entrypoint cat "${IMAGE}" /hlds/steam_appid.txt)
assert_eq "steam_appid.txt is ${GAME}'s Steam app id" "${GAME_APPID}" "${appid}"

step "starting ${IMAGE} with ${ENGINE} as ${NAME}"
"${ENGINE}" run -d --name "${NAME}" "${RUN_FLAGS[@]}" -e NOMASTER=1 -e LAN_MODE=1 "${IMAGE}" >/dev/null
wait_for "Started map \"${GAME_MAP}\"" 240 || fail "the server did not load ${GAME_MAP}"

healthy=0
for _ in $(seq $((60 * SCALE))); do
    if "${ENGINE}" exec "${NAME}" /healthcheck.sh; then
        healthy=1
        break
    fi
    sleep 1
done
assert_eq "the health check passes" 1 "${healthy}"
# metrics.amxx is in every game's plugin list and writes this file.
reported=0
for _ in $(seq $((20 * SCALE))); do
    if "${ENGINE}" exec "${NAME}" grep -q "^hlds_map_info{map=\"${GAME_MAP}\"} 1\$" /hlds/.runtime/metrics.prom 2>/dev/null; then
        reported=1
        break
    fi
    sleep 1
done
assert_eq "metrics.amxx reports the running map" 1 "${reported}"
step "${GAME} server is up on ${GAME_MAP}"

wait_for "\[META\] Recognized game '${GAME}'" 10 || fail "Metamod did not recognise the game"
wait_for "Loaded plugin 'AMX Mod X'" 10 || fail "AMX Mod X did not load"
if [[ "${GAME}" == "dod" ]]; then
    wait_for "Loaded plugin 'DoDX'" 10 || fail "the DoD stats module did not load"
fi
if [[ -n "${GAME_STATS}" ]]; then
    "${ENGINE}" exec "${NAME}" test -L "/hlds/${GAME}/addons/amxmodx/data/${GAME_STATS}" ||
        fail "the stats file ${GAME_STATS} is not linked into the state volume"
fi
if logs | grep -aE "couldn't exec (server|banned|listip)\.cfg"; then
    fail "a config file was not found"
fi
step "Metamod and AMX Mod X are loaded"

if [[ "${GAME_BOTS}" == "1" ]]; then
    wait_for '<BOT><[A-Z]*>" entered the game' 60 || fail "no bot joined (BOTS defaults to 1)"
    step "bots joined"
fi

# The first map of the cycle that is not the one already running.
# shellcheck disable=SC2016 # expands inside the container's sh
next=$("${ENGINE}" exec "${NAME}" sh -c 'tr -d "\r" < "/hlds/$1/mapcycle.txt" | while read -r m _; do case "$m" in ""|//*|"$2") ;; *) [ -f "/hlds/$1/maps/$m.bsp" ] && echo "$m" && break ;; esac; done' sh "${GAME}" "${GAME_MAP}")
if [[ -n "${next}" ]]; then
    send "changelevel ${next}"
    wait_for "Started map \"${next}\"" 90 || fail "changelevel ${next}: the map did not load"
    step "changed map to ${next}"
else
    step "the map cycle has no second map; map change not tested"
fi

# 192.0.2.0/24 is reserved for documentation.
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
    fail "no server log file in the state volume"
step "ban list and logs are in the state volume"

if errors=$(logs | grep -aiE 'run time error|bad load|plugin file open error|Segmentation fault|Read-only file system'); then
    fail "the server log has plugin or engine errors:
${errors}"
fi

step "stopping (in-game countdown, about 35 s)"
started=${SECONDS}
"${ENGINE}" stop -t 60 "${NAME}" >/dev/null
elapsed=$((SECONDS - started))
wait_for '\[entrypoint\] Sending quit command to HLDS' 10 || fail "the entrypoint did not send quit"
if [[ "${elapsed}" -ge 58 ]]; then
    fail "shutdown took ${elapsed}s: the server was killed at the stop timeout"
fi
code=$("${ENGINE}" inspect -f '{{.State.ExitCode}}' "${NAME}")
assert_eq "exit code after a graceful stop" 0 "${code}"
step "graceful shutdown in ${elapsed}s"

printf '%s e2e tests passed\n' "${GAME}"
