#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# End-to-end test of a Day of Defeat image (built with GAME=dod):
#
#   tests/e2e_dod_test.sh [docker|podman] [image]
#
# The server boots on the read-only root with a state volume, answers the
# health check, runs Metamod and AMX Mod X with the DoD stats module, changes
# map through the console FIFO, saves a ban to the state volume and shuts
# down gracefully. tests/e2e_test.sh covers the Counter-Strike image.
#
# CS_E2E_TIMEOUT_SCALE multiplies every wait (default 1).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

ENGINE="${1:-${CONTAINER_ENGINE:-podman}}"
IMAGE="${2:-${CS_E2E_IMAGE:-localhost/cs-server:dod}}"
SCALE="${CS_E2E_TIMEOUT_SCALE:-1}"
NAME="dod-e2e-$$"
STATE="dod-e2e-state-$$"
FIFO="/hlds/.runtime/hlds-input"

case "${ENGINE}" in
    docker) RUN_FLAGS=(--cap-drop ALL --security-opt no-new-privileges:true --security-opt "seccomp=${ROOT}/ops/seccomp/docker-default.json" --read-only --tmpfs /tmp -v "${STATE}:/hlds/state") ;;
    podman) RUN_FLAGS=(--cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp -v "${STATE}:/hlds/state") ;;
    *) fail "usage: ${0##*/} [docker|podman] [image]" ;;
esac

step() { printf '[e2e-dod] %s\n' "$*"; }

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    local status=$?
    if [[ "${status}" -ne 0 ]]; then
        printf '\n[e2e-dod] FAILED; last server output:\n' >&2
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

game=$("${ENGINE}" image inspect -f '{{index .Config.Labels "io.github.kevintcoughlin.cs-server.game"}}' "${IMAGE}")
assert_eq "the image is a Day of Defeat build" dod "${game}"

step "starting ${IMAGE} with ${ENGINE} as ${NAME}"
"${ENGINE}" run -d --name "${NAME}" "${RUN_FLAGS[@]}" -e NOMASTER=1 -e LAN_MODE=1 "${IMAGE}" >/dev/null
wait_for 'Started map "dod_anzio"' 240 || fail "the server did not load dod_anzio"

healthy=0
for _ in $(seq $((60 * SCALE))); do
    if "${ENGINE}" exec "${NAME}" /healthcheck.sh; then
        healthy=1
        break
    fi
    sleep 1
done
assert_eq "the health check passes" 1 "${healthy}"
step "server is up on dod_anzio"

wait_for "\[META\] Recognized game 'dod'" 10 || fail "Metamod did not recognise the game"
wait_for "Loaded plugin 'AMX Mod X'" 10 || fail "AMX Mod X did not load"
wait_for "Loaded plugin 'DoDX'" 10 || fail "the DoD stats module did not load"
if logs | grep -aE "couldn't exec (server|banned|listip)\.cfg"; then
    fail "a config file was not found"
fi
step "Metamod, AMX Mod X and DoDX are loaded"

send "changelevel dod_caen"
wait_for 'Started map "dod_caen"' 90 || fail "changelevel dod_caen: the map did not load"
step "changed map to dod_caen"

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

printf 'dod e2e tests passed\n'
