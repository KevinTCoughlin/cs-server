#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
# shellcheck disable=SC2329 # Signal/EXIT traps invoke these functions indirectly.
set -euo pipefail

# Which game this image runs: its row of scripts/game-env.sh, written at
# build. Not a run-time setting; an image holds one game.
GAME=cstrike
GAME_MAP=scoutzknivez
GAME_BOTS=1
GAME_ENV="${HLDS_GAME_ENV:-/usr/local/share/cs-server/game.env}"
if [[ -f "${GAME_ENV}" ]]; then
    # shellcheck disable=SC1090 # generated at image build
    source "${GAME_ENV}"
fi
MAP="${MAP:-${GAME_MAP}}"
MAXPLAYERS="${MAXPLAYERS:-20}"
PORT="${PORT:-27015}"
BOTS="${BOTS:-1}"
NOMASTER="${NOMASTER:-0}"
MAPCYCLE="${MAPCYCLE:-mapcycle.txt}"
LAN_MODE="${LAN_MODE:-0}"
MODE="${MODE:-scoutz}"
FASTDL_URL="${FASTDL_URL:-}"
LOGS="${LOGS:-1}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
LOGADDRESS="${LOGADDRESS:-}"
SERVER_IP="${SERVER_IP:-}"

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

# The URL reaches the HLDS console, so it may hold nothing the console treats
# as syntax (quotes, semicolons, whitespace). The engine sends clients a URL
# of up to 128 characters and silently drops a longer one.
validate_url() {
    local name="$1" value="$2"
    if [[ -z "${value}" ]]; then
        return 0
    fi
    if [[ "${#value}" -gt 128 || ! "${value}" =~ ^https?://[A-Za-z0-9._~:/?#@!\&=+,%-]+$ ]]; then
        echo "[entrypoint] ${name} must be an http(s) URL of at most 128 characters without spaces, quotes or semicolons" >&2
        exit 1
    fi
}

# host:port of a log receiver (HLstatsX and the like). Reaches the console.
validate_logaddress() {
    local name="$1" value="$2" port
    if [[ -z "${value}" ]]; then
        return 0
    fi
    port="${value##*:}"
    if [[ ! "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252}[A-Za-z0-9])?:[0-9]{1,5}$ ]] ||
       [[ "$((10#${port}))" -lt 1 || "$((10#${port}))" -gt 65535 ]]; then
        echo "[entrypoint] ${name} must be host:port (a hostname or IPv4 address and a port from 1 to 65535)" >&2
        exit 1
    fi
}

# The address HLDS binds and reports to Steam (+ip). Reaches the console.
validate_ipv4() {
    local name="$1" value="$2" octet
    local -a octets
    if [[ -z "${value}" ]]; then
        return 0
    fi
    if [[ "${value}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS=. read -r -a octets <<< "${value}"
        for octet in "${octets[@]}"; do
            [[ "$((10#${octet}))" -le 255 ]] || octets=()
        done
        [[ "${#octets[@]}" -eq 4 ]] && return 0
    fi
    echo "[entrypoint] ${name} must be an IPv4 address" >&2
    exit 1
}

validate_boolean "BOTS" "${BOTS}"
validate_boolean "LOGS" "${LOGS}"
validate_integer "LOG_RETENTION_DAYS" "${LOG_RETENTION_DAYS}" 0 3650
validate_logaddress "LOGADDRESS" "${LOGADDRESS}"
validate_boolean "NOMASTER" "${NOMASTER}"
validate_boolean "LAN_MODE" "${LAN_MODE}"
validate_integer "MAXPLAYERS" "${MAXPLAYERS}" 1 32
validate_integer "PORT" "${PORT}" 1 65535
validate_filename "MAP" "${MAP}"
validate_filename "MAPCYCLE" "${MAPCYCLE}"
validate_url "FASTDL_URL" "${FASTDL_URL}"
validate_ipv4 "SERVER_IP" "${SERVER_IP}"
if [[ -n "${LOGADDRESS}" && "${LOGS}" != "1" ]]; then
    echo "[entrypoint] LOGADDRESS needs LOGS=1" >&2
    exit 1
fi
case "${MODE}" in
    scoutz | knife) ;;
    *)
        echo "[entrypoint] MODE must be scoutz or knife" >&2
        exit 1
        ;;
esac

# hlds_linux needs libs from its own directory (normally set by hlds_run)
export LD_LIBRARY_PATH=".:${LD_LIBRARY_PATH:-}"

# The image links /hlds/.runtime here, so the FIFO keeps its documented path
# and still works on a read-only root filesystem with a tmpfs on /tmp.
RUNTIME_DIR="${HLDS_RUNTIME_DIR:-/tmp/hlds-runtime}"
STATE_DIR="${HLDS_STATE_DIR:-/hlds/state}"
STATE_DEFAULTS="${HLDS_STATE_DEFAULTS:-/usr/local/share/cs-server}"
FIFO="${RUNTIME_DIR}/hlds-input"
SCRIPT_PID=
SHUTTING_DOWN=0

PRUNE_PID=

cleanup() {
    if [[ -n "${PRUNE_PID}" ]]; then
        kill "${PRUNE_PID}" 2>/dev/null || true
    fi
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

# Run-time state (bans, admins, stats, logs): the image's symlinks point into
# STATE_DIR, which is a volume on every deployment path. Create what is
# missing; never overwrite. An unwritable directory is not fatal: the server
# runs, but nothing it writes is kept.
prepare_state() {
    # A unit or command from before 1.1.0 mounts no volume here: the server
    # runs, and what it saves goes with the container.
    if [[ -d "${STATE_DIR}" ]] && command -v mountpoint >/dev/null 2>&1 && ! mountpoint -q "${STATE_DIR}"; then
        echo "[entrypoint] NOTE: ${STATE_DIR} is not a volume, so bans, admins, stats and logs are lost when this container is replaced. Mount one (-v cs-server-state:${STATE_DIR}, or Volume=cs-server-state:${STATE_DIR} in a Quadlet unit), or run the installer again." >&2
    fi
    if ! mkdir -p "${STATE_DIR}/logs" "${STATE_DIR}/nav" "${STATE_DIR}/amxmodx/logs" "${STATE_DIR}/amxmodx/vault" 2>/dev/null ||
       [[ ! -w "${STATE_DIR}" || ! -w "${STATE_DIR}/amxmodx" ]]; then
        echo "[entrypoint] WARNING: ${STATE_DIR} is not writable by uid $(id -u); bans, admins, stats and logs will not be saved" >&2
        return 0
    fi
    local f
    for f in banned.cfg listip.cfg; do
        [[ -e "${STATE_DIR}/${f}" ]] || : > "${STATE_DIR}/${f}"
    done
    if [[ ! -e "${STATE_DIR}/amxmodx/users.ini" && -f "${STATE_DEFAULTS}/users.ini" ]]; then
        cp "${STATE_DEFAULTS}/users.ini" "${STATE_DIR}/amxmodx/users.ini"
        echo "[entrypoint] Seeded ${STATE_DIR}/amxmodx/users.ini"
    fi
}

# Delete server and AMX Mod X log files older than LOG_RETENTION_DAYS.
prune_logs() {
    [[ "${LOG_RETENTION_DAYS}" -gt 0 ]] || return 0
    local dir
    for dir in "${STATE_DIR}/logs" "${STATE_DIR}/amxmodx/logs"; do
        [[ -d "${dir}" ]] || continue
        find "${dir}" -maxdepth 1 -type f -name '*.log' -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
    done
}

prepare_state
prune_logs
# A server can stay up for months: prune once a day as well.
# The sleep runs in the background so the loop can be stopped at once.
(
    nap=
    trap 'kill "${nap}" 2>/dev/null; exit 0' TERM INT
    while :; do
        sleep 86400 &
        nap=$!
        wait "${nap}" || exit 0
        prune_logs
    done
) &
PRUNE_PID=$!

mkdir -p "${RUNTIME_DIR}"
chmod 700 "${RUNTIME_DIR}"
rm -f "${FIFO}"
mkfifo "${FIFO}"
chmod 600 "${FIFO}"
exec 3<> "${FIFO}"

# Modes belong to the ScoutzKnivez plugin (Counter-Strike only) and bots to
# ReGameDLL (GAME_BOTS); elsewhere MODE and BOTS do nothing.
MODE_ARGS=()
if [[ "${GAME}" = "cstrike" ]]; then
    MODE_ARGS=(+localinfo sk_mode "${MODE}")
fi
if [[ "${GAME_BOTS}" != "1" ]]; then
    BOT_QUOTA_ARGS=()
elif [[ "${BOTS}" = "1" ]]; then
    BOT_QUOTA_ARGS=(+bot_quota 10)
elif [[ "${GAME}" != "cstrike" ]]; then
    BOT_QUOTA_ARGS=(+bot_quota 0)
else
    # server.cfg sets bot_quota and scoutzknivez.amxx re-runs it on every
    # map; sk_bots tells the plugin to turn bots off again afterwards.
    BOT_QUOTA_ARGS=(+bot_quota 0 +localinfo sk_bots 0)
fi

if [[ "${NOMASTER}" = "1" ]]; then
    MASTER_ARGS=(-nomaster -insecure)
else
    MASTER_ARGS=()
fi

# FastDL: set on the command line, not in server.cfg, so each deployment names
# its own host. The quotes are part of the argument: the console would read
# the `//` of a bare URL as the start of a comment.
if [[ -n "${FASTDL_URL}" ]]; then
    FASTDL_ARGS=(+sv_downloadurl "\"${FASTDL_URL}\"")
else
    FASTDL_ARGS=()
fi

# Without +ip HLDS takes the address its hostname resolves to. On host
# networking that can be a VPN or bridge address, and Steam then never
# answers; SERVER_IP names the address to bind and report.
if [[ -n "${SERVER_IP}" ]]; then
    IP_ARGS=(+ip "${SERVER_IP}")
else
    IP_ARGS=()
fi

# File logs go to the state volume (<game>/logs is a link into it). `log on`
# must come after server.cfg, whose sv_log_onefile decides how files are cut.
LOG_ARGS=()
if [[ "${LOGS}" = "1" ]]; then
    LOG_ARGS+=(+log on)
    if [[ -n "${LOGADDRESS}" ]]; then
        LOG_ARGS+=(+logaddress_add "${LOGADDRESS%:*}" "${LOGADDRESS##*:}")
    fi
fi

# Use 'script' to give hlds a PTY — without a PTY, hlds_linux does
# blocking reads on stdin which freezes the game loop.
# hlds_run handles Steam API init (first crash + auto-restart creates
# the IPC state needed for the second run to accept players).
HLDS_ARGS=(
    ./hlds_run
    -game "${GAME}"
    +map "${MAP}"
    +maxplayers "${MAXPLAYERS}"
    +port "${PORT}"
    "${IP_ARGS[@]}"
    +sv_lan "${LAN_MODE}"
    -pingboost 2
    +sys_ticrate 1000
    +mapcyclefile "${MAPCYCLE}"
    "${MODE_ARGS[@]}"
    +exec server.cfg
    +exec banned.cfg
    +exec listip.cfg
    "${MASTER_ARGS[@]}"
    "${BOT_QUOTA_ARGS[@]}"
    "${FASTDL_ARGS[@]}"
    "${LOG_ARGS[@]}"
)
# On non-x86 images (arm64), scripts/i386-compat.sh installs a launcher that
# runs the i386 hlds_linux under qemu-i386; hand it to hlds_run as the binary.
HLDS_EMULATOR="${HLDS_EMULATOR:-/usr/local/libexec/cs-server/hlds_linux}"
if [[ -x "${HLDS_EMULATOR}" ]]; then
    echo "[entrypoint] Running hlds_linux under i386 emulation (${HLDS_EMULATOR})"
    HLDS_ARGS+=(-binary "${HLDS_EMULATOR}")
fi
printf -v HLDS_COMMAND '%q ' "${HLDS_ARGS[@]}"

script -eqfc "${HLDS_COMMAND}" /dev/null < "${FIFO}" &
SCRIPT_PID=$!

echo "[entrypoint] HLDS started (PID: ${SCRIPT_PID})"

# Condition Zero ignores bot_quota on the command line; the console takes it
# once the server reads its input, and it then holds across map changes.
# (Counter-Strike's server.cfg and plugin set it on every map instead.)
if [[ "${GAME}" != "cstrike" && "${#BOT_QUOTA_ARGS[@]}" -gt 0 ]]; then
    hlds_command "bot_quota ${BOT_QUOTA_ARGS[1]}"
fi

set +e
wait "${SCRIPT_PID}"
STATUS=$?
set -e

if [[ "${SHUTTING_DOWN}" = "1" ]]; then
    exit 0
fi

exit "${STATUS}"
