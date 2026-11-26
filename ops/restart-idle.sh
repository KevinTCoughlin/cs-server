#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Restart installed game servers when nobody is playing.
#
# The systemd user timer (ops/systemd/cs-server-restart.timer) runs this at
# 05:00 America/Los_Angeles and every 20 minutes through 08:00. Each game
# server is queried with A2S_INFO on its own port. Human players are the
# Source reply's players byte minus its bots byte. A server is restarted
# only when that number is 0. A query that fails, including a server started
# with NOMASTER=1 (A2S_INFO stays silent), is left running. A server is
# restarted at most once per Los Angeles day; later passes skip it.
#
# Game servers are Quadlet units whose unit file has HealthCmd=/healthcheck.sh
# (FastDL uses a different health command) plus any name/port lines in
# ~/.config/cs-server/restart.targets. A Quadlet port wins over the file.
# When the process has no systemd user unit, CS_RUNTIME=podman|docker
# (or that line in ~/.config/cs-server/restart.env) restarts the container.
#
#   cs-server-restart           check, inside the morning window
#   cs-server-restart --now     check outside that window
#   cs-server-restart --parse FILE
#
# Tests inject CS_RESTART_NOW (HHMM), CS_RESTART_DAY, CS_RESTART_INFO_DIR
# (a directory of captured A2S payloads named by port), CS_QUADLET_DIR,
# CS_RESTART_TARGETS, CS_RESTART_STATE_DIR and CS_RESTART_FORCE=1.
set -euo pipefail
LC_ALL=C

START_HHMM="${CS_RESTART_START:-0500}"
DEADLINE_HHMM="${CS_RESTART_DEADLINE:-0800}"
WINDOW_GRACE_MIN=10
FORCE=0

usage() {
    cat <<EOF
Usage:
  cs-server-restart [--now]
  cs-server-restart --parse FILE
  cs-server-restart --help

Restart each installed game server when an A2S_INFO query reports no human
players (players minus bots). The timer runs this from 05:00 through 08:00
America/Los_Angeles, every 20 minutes. A server that does not answer is left
running. Each server is restarted at most once per day.

--now    Check even outside that window. A server with human players is still
         left running, and a server already restarted today is still skipped.

CS_RESTART_QUERY_TIMEOUT   Seconds to wait for one query (default 5)
CS_RUNTIME                 podman or docker, if the server has no systemd unit
EOF
}

error() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

log() {
    printf '%s\n' "$*"
}

valid_hhmm() {
    [[ "$1" =~ ^([01][0-9]|2[0-3])[0-5][0-9]$ ]]
}

hhmm_minutes() {
    local v="$1" hh mm
    hh="${v:0:2}"
    mm="${v:2:2}"
    printf '%s\n' $((10#$hh * 60 + 10#$mm))
}

query_timeout() {
    local t="${CS_RESTART_QUERY_TIMEOUT:-5}"
    if [[ ! "${t}" =~ ^[1-9][0-9]?$ ]]; then
        t=5
    fi
    printf '%s\n' "${t}"
}

clock_hhmm() {
    if [[ -n "${CS_RESTART_NOW:-}" ]]; then
        valid_hhmm "${CS_RESTART_NOW}" || error "Invalid CS_RESTART_NOW: ${CS_RESTART_NOW}"
        printf '%s\n' "${CS_RESTART_NOW}"
        return 0
    fi
    TZ=America/Los_Angeles date +%H%M
}

clock_day() {
    if [[ -n "${CS_RESTART_DAY:-}" ]]; then
        [[ "${CS_RESTART_DAY}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
            error "Invalid CS_RESTART_DAY: ${CS_RESTART_DAY}"
        printf '%s\n' "${CS_RESTART_DAY}"
        return 0
    fi
    TZ=America/Los_Angeles date +%Y-%m-%d
}

in_window() {
    local now start deadline end
    valid_hhmm "${START_HHMM}" || START_HHMM=0500
    valid_hhmm "${DEADLINE_HHMM}" || DEADLINE_HHMM=0800
    now=$(hhmm_minutes "$(clock_hhmm)")
    start=$(hhmm_minutes "${START_HHMM}")
    deadline=$(hhmm_minutes "${DEADLINE_HHMM}")
    end=$((deadline + WINDOW_GRACE_MIN))
    ((now >= start && now <= end))
}

# The 08:00 pass is the last one. Later timer slots do not exist.
is_final_pass() {
    local now deadline
    valid_hhmm "${DEADLINE_HHMM}" || DEADLINE_HHMM=0800
    now=$(hhmm_minutes "$(clock_hhmm)")
    deadline=$(hhmm_minutes "${DEADLINE_HHMM}")
    ((now >= deadline))
}

state_dir() {
    if [[ -n "${CS_RESTART_STATE_DIR:-}" ]]; then
        printf '%s\n' "${CS_RESTART_STATE_DIR}"
        return 0
    fi
    printf '%s\n' "${XDG_STATE_HOME:-${HOME:?HOME is not set}/.local/state}/cs-server-restart"
}

# Source A2S_INFO (type byte 'I', 0x49). players includes bots.
# Prints "info <players> <bots> <humans>" or "challenge".
# Returns 1, with a reason on stderr, when the payload is not usable.
parse_a2s_info() {
    local file="$1"
    local -a bytes=()
    local n i strings=0 players bots humans
    mapfile -t bytes < <(od -An -v -tu1 "${file}" | awk '{ for (i = 1; i <= NF; i++) print $i }')
    n=${#bytes[@]}
    if ((n < 5)) || ((bytes[0] != 255 || bytes[1] != 255 || bytes[2] != 255 || bytes[3] != 255)); then
        printf 'error: not an A2S packet\n' >&2
        return 1
    fi
    # 0x41, S2C_CHALLENGE. The query has to be repeated with these 4 bytes.
    if ((bytes[4] == 65)); then
        printf 'challenge\n'
        return 0
    fi
    # 0x49, S2C_INFO.
    if ((bytes[4] != 73)); then
        printf 'error: unsupported A2S reply type\n' >&2
        return 1
    fi
    if ((n < 7)); then
        printf 'error: short A2S_INFO reply\n' >&2
        return 1
    fi
    # protocol byte, then name, map, folder, game.
    i=6
    while ((strings < 4)); do
        if ((i >= n)); then
            printf 'error: short A2S_INFO reply\n' >&2
            return 1
        fi
        if ((bytes[i] == 0)); then
            strings=$((strings + 1))
        fi
        i=$((i + 1))
    done
    # app id (2), players, max players, bots.
    if ((i + 4 >= n)); then
        printf 'error: short A2S_INFO reply\n' >&2
        return 1
    fi
    players=${bytes[i + 2]}
    bots=${bytes[i + 4]}
    if ((bots > players)); then
        printf 'error: bots %s exceed players %s\n' "${bots}" "${players}" >&2
        return 1
    fi
    humans=$((players - bots))
    printf 'info %s %s %s\n' "${players}" "${bots}" "${humans}"
}

packet_type() {
    # Fifth byte: 73 info, 65 challenge. Empty when the datagram is shorter.
    od -An -v -tu1 -N 5 "$1" | awk 'NF { print $5; exit }'
}

do_exchange() {
    local host="${1:-}" port="${2:-}" dest="${3:-}" kind t req
    [[ -n "${host}" && -n "${port}" && -n "${dest}" ]] || return 1
    [[ "${host}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "${port}" =~ ^[0-9]+$ ]] || return 1
    t=$(query_timeout)
    exec 3<>"/dev/udp/${host}/${port}" || return 1
    printf '\377\377\377\377TSource Engine Query\000' >&3 || return 1
    if ! timeout "${t}" dd bs=2048 count=1 status=none <&3 >"${dest}"; then
        exec 3>&- || true
        return 1
    fi
    kind=$(packet_type "${dest}")
    if [[ "${kind}" == "65" ]]; then
        # One write is one UDP datagram. printf and dd as two writes would
        # send the challenge in a second packet, and a bash variable would
        # drop a 0x00 inside it. Servers do send those.
        req=$(mktemp)
        {
            printf '\377\377\377\377TSource Engine Query\000'
            dd bs=1 skip=5 count=4 status=none <"${dest}"
        } >"${req}" || {
            rm -f "${req}"
            exec 3>&- || true
            return 1
        }
        if ! dd bs=2048 count=1 status=none <"${req}" >&3; then
            rm -f "${req}"
            exec 3>&- || true
            return 1
        fi
        rm -f "${req}"
        if ! timeout "${t}" dd bs=2048 count=1 status=none <&3 >"${dest}"; then
            exec 3>&- || true
            return 1
        fi
    fi
    exec 3>&- || true
}

fetch_info() {
    local host="$1" port="$2" dest="$3" src
    if [[ -n "${CS_RESTART_INFO_DIR:-}" ]]; then
        src="${CS_RESTART_INFO_DIR}/${port}"
        [[ -s "${src}" ]] || return 1
        cp "${src}" "${dest}"
        return 0
    fi
    bash "$0" --exchange "${host}" "${port}" "${dest}"
}

valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]
}

valid_host() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

# PORT_OF and HOST_OF are filled by list_servers and read there.
declare -gA PORT_OF=()
declare -gA HOST_OF=()

remember_server() {
    local name="$1" port="$2" host="${3:-127.0.0.1}"
    valid_name "${name}" || return 0
    [[ "${port}" =~ ^[0-9]+$ ]] || return 0
    port=$((10#$port))
    ((port >= 1 && port <= 65535)) || return 0
    valid_host "${host}" || return 0
    PORT_OF["${name}"]=${port}
    HOST_OF["${name}"]=${host}
}

forget_server() {
    unset "PORT_OF[$1]" "HOST_OF[$1]"
}

read_targets() {
    local file="$1" line name port host
    [[ -f "${file}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        case "${line}" in
            '' | \#*) continue ;;
        esac
        name=""
        port=""
        host=""
        read -r name port host _ <<<"${line}"
        [[ -n "${host}" ]] || host=127.0.0.1
        remember_server "${name}" "${port}" "${host}"
    done <"${file}"
}

read_quadlet() {
    local file="$1" line name port="" host="" game=0
    name=$(basename "${file}")
    name="${name%.container}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        case "${line}" in
            HealthCmd=/healthcheck.sh | HealthCmd=/healthcheck.sh[[:space:]]*)
                game=1
                ;;
            Environment=PORT=*)
                port="${line#Environment=PORT=}"
                port="${port%%[[:space:]]*}"
                ;;
            Environment=SERVER_IP=*)
                host="${line#Environment=SERVER_IP=}"
                host="${host%%[[:space:]]*}"
                ;;
        esac
    done <"${file}"
    [[ "${game}" == "1" ]] || return 0
    if [[ -z "${port}" ]]; then
        forget_server "${name}"
        return 0
    fi
    [[ -n "${host}" ]] || host=127.0.0.1
    if ! valid_host "${host}" || ! [[ "${port}" =~ ^[0-9]+$ ]]; then
        forget_server "${name}"
        return 0
    fi
    remember_server "${name}" "${port}" "${host}"
}

list_servers() {
    local file name
    local -a names=()
    local targets="${CS_RESTART_TARGETS:-${HOME:?HOME is not set}/.config/cs-server/restart.targets}"
    local quadlet="${CS_QUADLET_DIR:-${HOME}/.config/containers/systemd}"
    unset PORT_OF HOST_OF
    declare -gA PORT_OF=()
    declare -gA HOST_OF=()
    # The file first, then Quadlet files overwrite the same name.
    read_targets "${targets}"
    if [[ -d "${quadlet}" ]]; then
        shopt -s nullglob
        for file in "${quadlet}/"*.container; do
            read_quadlet "${file}"
        done
        shopt -u nullglob
    fi
    if ((${#PORT_OF[@]} == 0)); then
        return 0
    fi
    mapfile -t names < <(printf '%s\n' "${!PORT_OF[@]}" | sort)
    for name in "${names[@]}"; do
        printf '%s %s %s\n' "${name}" "${PORT_OF[${name}]}" "${HOST_OF[${name}]}"
    done
}

load_runtime() {
    local f line
    [[ -z "${CS_RUNTIME:-}" ]] || return 0
    f="${CS_RESTART_ENV:-${HOME:-}/.config/cs-server/restart.env}"
    [[ -n "${f}" && -f "${f}" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        case "${line}" in
            CS_RUNTIME=podman | CS_RUNTIME=docker)
                CS_RUNTIME="${line#CS_RUNTIME=}"
                ;;
        esac
    done <"${f}"
}

# 0 restarted, 2 not running (or no unit), 1 restart command failed.
restart_server() {
    local name="$1" state runtime
    if systemctl --user cat "${name}.service" >/dev/null 2>&1; then
        if ! systemctl --user is-active --quiet "${name}.service"; then
            return 2
        fi
        systemctl --user restart "${name}.service" || return 1
        return 0
    fi
    load_runtime
    runtime="${CS_RUNTIME:-}"
    case "${runtime}" in
        podman | docker) ;;
        *) return 2 ;;
    esac
    command -v "${runtime}" >/dev/null 2>&1 || return 2
    state=$("${runtime}" inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)
    [[ "${state}" == "true" ]] || return 2
    # The entrypoint's countdown is about 35s. The engine default of 10s
    # would kill the process in the middle of it.
    "${runtime}" restart --time 45 "${name}" || return 1
    return 0
}

stamp_path() {
    local dir
    dir=$(state_dir)
    printf '%s/%s-%s\n' "${dir}" "$1" "$(clock_day)"
}

# Shared with cs-reboot-if-idle and cs-server-update so a rollout, an idle
# restart, and an idle reboot cannot run at the same time. CS_MAINTENANCE_LOCK
# overrides the path (tests).
take_lock() {
    local path="${CS_MAINTENANCE_LOCK:-/run/lock/cs-server-maintenance.lock}" dir
    dir=$(dirname "${path}")
    if [[ ! -e "${path}" && -d "${dir}" && -w "${dir}" ]]; then
        (umask 000; : >> "${path}") || true
    fi
    if [[ ! -w "${path}" ]]; then
        path="${HOME}/.local/state/cs-server/maintenance.lock"
        mkdir -p "$(dirname "${path}")"
        (umask 000; : >> "${path}") || true
    fi
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>>"${path}"
    if ! flock -n 9; then
        log "another maintenance job is running; not restarting"
        exit 0
    fi
}

defer_word() {
    if [[ "${FORCE}" == "1" ]]; then
        printf 'leaving it up\n'
    elif is_final_pass; then
        printf 'giving up until tomorrow\n'
    else
        printf 'skipping until the next try\n'
    fi
}

run_checks() {
    local now day line name port host pkt parsed players bots humans rc failed=0
    local -a rows=()
    now=$(clock_hhmm)
    day=$(clock_day)
    if [[ "${FORCE}" != "1" ]] && ! in_window; then
        log "outside ${START_HHMM}-${DEADLINE_HHMM} America/Los_Angeles (${now}); not restarting"
        return 0
    fi
    take_lock
    mapfile -t rows < <(list_servers)
    if ((${#rows[@]} == 0)); then
        log "no game servers to check"
        return 0
    fi
    if ((${#rows[@]} == 1)); then
        log "${now} America/Los_Angeles: checking 1 game server"
    else
        log "${now} America/Los_Angeles: checking ${#rows[@]} game servers"
    fi
    for line in "${rows[@]}"; do
        name=""
        port=""
        host=""
        read -r name port host <<<"${line}"
        if [[ -f "$(stamp_path "${name}")" ]]; then
            log "${name}: already restarted on ${day}; skipping"
            continue
        fi
        pkt=$(mktemp)
        if ! fetch_info "${host}" "${port}" "${pkt}"; then
            log "${name} ${host}:${port}: no A2S_INFO reply within $(query_timeout)s; $(defer_word)"
            rm -f "${pkt}"
            continue
        fi
        parsed=$(parse_a2s_info "${pkt}" 2>/dev/null) || parsed=""
        rm -f "${pkt}"
        case "${parsed}" in
            info\ [0-9]*\ [0-9]*\ [0-9]*)
                read -r _ players bots humans <<<"${parsed}"
                ;;
            *)
                log "${name} ${host}:${port}: could not read player counts; $(defer_word)"
                continue
                ;;
        esac
        if ((humans > 0)); then
            log "${name} ${host}:${port}: ${humans} humans (${players} players, ${bots} bots); $(defer_word)"
            continue
        fi
        rc=0
        restart_server "${name}" || rc=$?
        case "${rc}" in
            0)
                printf 'restarted %s\n' "${now}" >"$(stamp_path "${name}")"
                log "${name} ${host}:${port}: 0 humans (${players} players, ${bots} bots); restarted"
                ;;
            2)
                log "${name}: not running; skipping"
                ;;
            *)
                log "${name} ${host}:${port}: 0 humans (${players} players, ${bots} bots); restart failed"
                failed=1
                ;;
        esac
    done
    return "${failed}"
}

main() {
    case "${1:-}" in
        --help | -h)
            usage
            exit 0
            ;;
        --parse)
            [[ -n "${2:-}" && -f "${2}" ]] || error "Usage: cs-server-restart --parse FILE"
            parse_a2s_info "$2"
            ;;
        --exchange)
            do_exchange "${2:-}" "${3:-}" "${4:-}"
            ;;
        --now)
            FORCE=1
            run_checks
            ;;
        "")
            [[ "${CS_RESTART_FORCE:-0}" == "1" ]] && FORCE=1
            run_checks
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
}

main "$@"
