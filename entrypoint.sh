#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
# shellcheck disable=SC2329 # Signal/EXIT traps invoke these functions indirectly.
set -euo pipefail

MAP="${MAP:-scoutzknivez}"
MAXPLAYERS="${MAXPLAYERS:-20}"
PORT="${PORT:-27015}"
BOTS="${BOTS:-1}"
NOMASTER="${NOMASTER:-0}"
MAPCYCLE="${MAPCYCLE:-mapcycle.txt}"
LAN_MODE="${LAN_MODE:-0}"

validate_boolean() {
    local name="$1" value="$2"
    if [[ ! "${value}" =~ ^[01]$ ]]; then
        echo "[entrypoint] ${name} must be 0 or 1" >&2
        exit 1
    fi
}

validate_integer() {
    local name="$1" value="$2" minimum="$3" maximum="$4"
    local normalized
    local LC_ALL=C

    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "[entrypoint] ${name} must be an integer from ${minimum} to ${maximum}" >&2
        exit 1
    fi

    normalized="${value#"${value%%[!0]*}"}"
    normalized="${normalized:-0}"

    if [[ "${#normalized}" -lt "${#minimum}" ]] ||
       [[ "${#normalized}" -eq "${#minimum}" && "${normalized}" < "${minimum}" ]] ||
       [[ "${#normalized}" -gt "${#maximum}" ]] ||
       [[ "${#normalized}" -eq "${#maximum}" && "${normalized}" > "${maximum}" ]]; then
        echo "[entrypoint] ${name} must be an integer from ${minimum} to ${maximum}" >&2
        exit 1
    fi
}

validate_filename() {
    local name="$1" value="$2"
    if [[ ! "${value}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        echo "[entrypoint] ${name} must be a filename containing only letters, numbers, dot, underscore, or hyphen" >&2
        exit 1
    fi
}

validate_boolean "BOTS" "${BOTS}"
validate_boolean "NOMASTER" "${NOMASTER}"
validate_boolean "LAN_MODE" "${LAN_MODE}"
validate_integer "MAXPLAYERS" "${MAXPLAYERS}" 1 32
validate_integer "PORT" "${PORT}" 1 65535
validate_filename "MAP" "${MAP}"
validate_filename "MAPCYCLE" "${MAPCYCLE}"

# hlds_linux needs libs from its own directory (normally set by hlds_run)
export LD_LIBRARY_PATH=".:${LD_LIBRARY_PATH:-}"

RUNTIME_DIR="${HLDS_RUNTIME_DIR:-/hlds/.runtime}"
FIFO="${RUNTIME_DIR}/hlds-input"
SCRIPT_PID=
SHUTTING_DOWN=0

cleanup() {
    exec 3>&- 3<&- || true
    rm -f "${FIFO}"
}
trap cleanup EXIT

hlds_command() {
    printf '%s\n' "$1" >&3
}

graceful_shutdown() {
    SHUTTING_DOWN=1
    echo "[entrypoint] Caught shutdown signal, starting graceful shutdown..."

    if [[ -n "${SCRIPT_PID}" ]] && kill -0 "${SCRIPT_PID}" 2>/dev/null; then
        hlds_command "say [SERVER] Shutting down in 30 seconds..."
        sleep 20

        hlds_command "say [SERVER] Shutting down in 10 seconds..."
        sleep 5

        hlds_command "say [SERVER] Shutting down in 5 seconds..."
        sleep 3

        hlds_command "say [SERVER] Shutting down in 2 seconds..."
        sleep 2

        hlds_command "say [SERVER] Goodbye!"
        sleep 1

        echo "[entrypoint] Sending quit command to HLDS"
        hlds_command "quit"
        sleep 2

        # hlds_run's restart loop may try to respawn after the quit command.
        kill "${SCRIPT_PID}" 2>/dev/null || true
    fi

    wait "${SCRIPT_PID}" 2>/dev/null || true
}
trap graceful_shutdown SIGTERM SIGINT

mkdir -p "${RUNTIME_DIR}"
chmod 700 "${RUNTIME_DIR}"
rm -f "${FIFO}"
mkfifo "${FIFO}"
chmod 600 "${FIFO}"
exec 3<> "${FIFO}"

if [[ "${BOTS}" = "1" ]]; then
    BOT_QUOTA_ARGS=(+bot_quota 10)
else
    BOT_QUOTA_ARGS=(+bot_quota 0)
fi

if [[ "${NOMASTER}" = "1" ]]; then
    MASTER_ARGS=(-nomaster -insecure)
else
    MASTER_ARGS=()
fi

# Use 'script' to give hlds a PTY — without a PTY, hlds_linux does
# blocking reads on stdin which freezes the game loop.
# hlds_run handles Steam API init (first crash + auto-restart creates
# the IPC state needed for the second run to accept players).
HLDS_ARGS=(
    ./hlds_run
    -game cstrike
    +map "${MAP}"
    +maxplayers "${MAXPLAYERS}"
    +port "${PORT}"
    +sv_lan "${LAN_MODE}"
    -pingboost 2
    +sys_ticrate 1000
    +mapcyclefile "${MAPCYCLE}"
    +exec server.cfg
    "${MASTER_ARGS[@]}"
    "${BOT_QUOTA_ARGS[@]}"
)
printf -v HLDS_COMMAND '%q ' "${HLDS_ARGS[@]}"

script -eqfc "${HLDS_COMMAND}" /dev/null < "${FIFO}" &
SCRIPT_PID=$!

echo "[entrypoint] HLDS started (PID: ${SCRIPT_PID})"

set +e
wait "${SCRIPT_PID}"
STATUS=$?
set -e

if [[ "${SHUTTING_DOWN}" = "1" ]]; then
    exit 0
fi

exit "${STATUS}"
