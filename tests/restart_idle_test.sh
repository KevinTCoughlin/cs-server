#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# ops/restart-idle.sh: A2S_INFO player counts, and the decision to restart
# only when the human count is 0. Queries are captured packets, except for
# one live localhost exchange when python3 is available.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

SCRIPT="${ROOT}/ops/restart-idle.sh"
WORK=$(mktemp -d)
peer_pid=""
cleanup() {
    if [[ -n "${peer_pid}" ]]; then
        kill "${peer_pid}" 2>/dev/null || true
        wait "${peer_pid}" 2>/dev/null || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

QUAD="${WORK}/quadlet"
INFO="${WORK}/info"
STATE="${WORK}/state"
UNITS="${WORK}/units"
ACTIVE="${WORK}/active"
FAIL="${WORK}/fail"
STUBS="${WORK}/stubs"
CALLS="${WORK}/calls"
RESTARTS="${WORK}/restarts"
mkdir -p "${QUAD}" "${INFO}" "${STATE}" "${UNITS}" "${ACTIVE}" "${FAIL}" "${STUBS}" "${WORK}/home"

cat > "${STUBS}/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CALLS}"
[[ "$1" == "--user" ]] || exit 1
shift
cmd=$1
shift
case "${cmd}" in
    cat)
        unit=${1%.service}
        [[ -f "${UNITS}/${unit}" ]]
        ;;
    is-active)
        [[ "$1" == "--quiet" ]] && shift
        unit=${1%.service}
        [[ -f "${ACTIVE}/${unit}" ]]
        ;;
    restart)
        unit=${1%.service}
        if [[ -f "${FAIL}/${unit}" ]]; then
            exit 1
        fi
        printf '%s\n' "${unit}" >> "${RESTARTS}"
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat > "${STUBS}/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CALLS}"
case "$1" in
    inspect)
        name=$4
        if [[ -f "${ACTIVE}/${name}" ]]; then
            printf 'true\n'
        else
            printf 'false\n'
        fi
        ;;
    restart)
        printf '%s\n' "$*" >> "${RESTARTS}"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "${STUBS}/systemctl" "${STUBS}/docker"

export PATH="${STUBS}:${PATH}"
export HOME="${WORK}/home"
export CS_QUADLET_DIR="${QUAD}"
export CS_RESTART_STATE_DIR="${STATE}"
export CS_RESTART_DAY=2026-11-24
export CALLS RESTARTS UNITS ACTIVE FAIL

# Source A2S_INFO: header, protocol, four strings, app id, players, max, bots.
write_info() {
    local dest="$1" players="$2" bots="$3" max="${4:-32}" name="${5:-Test Server}"
    {
        printf '\377\377\377\377I'
        printf '\030'
        printf '%s\000%s\000%s\000%s\000' "${name}" "de_dust2" "cstrike" "Counter-Strike"
        printf '\012\000'
        printf '%b' "\\$(printf '%03o' "${players}")"
        printf '%b' "\\$(printf '%03o' "${max}")"
        printf '%b' "\\$(printf '%03o' "${bots}")"
        printf 'dln1.1.2.7\000'
    } > "${dest}"
}

write_quadlet() {
    local name="$1" port="$2" host="${3:-}"
    {
        printf '[Container]\n'
        printf 'HealthCmd=/healthcheck.sh\n'
        printf 'Environment=PORT=%s\n' "${port}"
        if [[ -n "${host}" ]]; then
            printf 'Environment=SERVER_IP=%s\n' "${host}"
        fi
    } > "${QUAD}/${name}.container"
}

reset_case() {
    rm -rf "${QUAD}" "${INFO}" "${STATE}" "${UNITS}" "${ACTIVE}" "${FAIL}"
    mkdir -p "${QUAD}" "${INFO}" "${STATE}" "${UNITS}" "${ACTIVE}" "${FAIL}"
    : > "${CALLS}"
    : > "${RESTARTS}"
    export CS_RESTART_NOW=0500
    unset CS_RESTART_FORCE
    unset CS_RUNTIME
    unset CS_RESTART_TARGETS
    export CS_RESTART_INFO_DIR="${INFO}"
}

invoke() {
    set +e
    output=$(bash "${SCRIPT}" "$@" 2>&1)
    status=$?
    set -e
}

# --- Packet parser -----------------------------------------------------------

write_info "${WORK}/humans.pkt" 6 5 16 "Weekend server"
invoke --parse "${WORK}/humans.pkt"
[[ "${status}" -eq 0 ]] || fail "parse humans: ${output}"
assert_eq "one human is players minus bots" "info 6 5 1" "${output}"

write_info "${WORK}/bots.pkt" 8 8 16 "AAAA"
invoke --parse "${WORK}/bots.pkt"
assert_eq "bots only" "info 8 8 0" "${output}"

write_info "${WORK}/empty.pkt" 0 0
invoke --parse "${WORK}/empty.pkt"
assert_eq "empty server" "info 0 0 0" "${output}"

printf '\377\377\377\377A\000\001\377\000' > "${WORK}/challenge.pkt"
invoke --parse "${WORK}/challenge.pkt"
assert_eq "challenge reply" "challenge" "${output}"

printf '\000\000\000\000I' > "${WORK}/bad-header.pkt"
invoke --parse "${WORK}/bad-header.pkt"
[[ "${status}" -ne 0 ]] || fail "bad header was accepted: ${output}"
assert_contains "bad header" "${output}" "not an A2S packet"

printf '\377\377\377\377I\030only\000' > "${WORK}/short.pkt"
invoke --parse "${WORK}/short.pkt"
[[ "${status}" -ne 0 ]] || fail "short packet was accepted: ${output}"

write_info "${WORK}/odd.pkt" 1 3
invoke --parse "${WORK}/odd.pkt"
[[ "${status}" -ne 0 ]] || fail "bots greater than players was accepted: ${output}"
assert_contains "bots exceed players" "${output}" "bots 3 exceed players 1"

# --- Timer unit --------------------------------------------------------------

timer="${ROOT}/ops/systemd/cs-server-restart.timer"
service="${ROOT}/ops/systemd/cs-server-restart.service"
assert_contains "timer starts at 05:00 Los Angeles" "$(cat "${timer}")" "OnCalendar=*-*-* 05,06,07:00,20,40:00 America/Los_Angeles"
assert_contains "timer's last pass is 08:00" "$(cat "${timer}")" "OnCalendar=*-*-* 08:00:00 America/Los_Angeles"
assert_contains "timer is not persistent" "$(cat "${timer}")" "Persistent=false"
assert_contains "timer delay is small" "$(cat "${timer}")" "RandomizedDelaySec=90s"
assert_contains "timer accuracy stays tight" "$(cat "${timer}")" "AccuracySec=1s"
assert_contains "service runs the script" "$(cat "${service}")" "ExecStart=%h/.local/bin/cs-server-restart"
assert_contains "service is a oneshot" "$(cat "${service}")" "Type=oneshot"
assert_not_contains "service does not restart itself" "$(cat "${service}")" $'\nRestart='
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar -- '*-*-* 05,06,07:00,20,40:00 America/Los_Angeles' >/dev/null
    systemd-analyze calendar -- '*-*-* 08:00:00 America/Los_Angeles' >/dev/null
fi

# --- Decisions ---------------------------------------------------------------

reset_case
write_quadlet scoutzknivez 27015
write_quadlet dod-server 27016 "203.0.113.10"
printf '[Container]\nPodmanArgs=--entrypoint /fastdl.sh\nHealthCmd=/fastdl.sh check\nEnvironment=FASTDL_PORT=27080\n' \
    > "${QUAD}/scoutzknivez-fastdl.container"
printf 'Environment=PORT=27999\n' > "${QUAD}/other.container"
write_info "${INFO}/27015" 8 8
write_info "${INFO}/27016" 4 1
touch "${UNITS}/scoutzknivez" "${UNITS}/dod-server" "${ACTIVE}/scoutzknivez" "${ACTIVE}/dod-server"
invoke
[[ "${status}" -eq 0 ]] || fail "mixed servers: ${output}"
assert_contains "bots-only server restarts" "$(cat "${RESTARTS}")" "scoutzknivez"
assert_not_contains "humans keep DoD up" "$(cat "${RESTARTS}")" "dod-server"
assert_contains "DoD skip names the bound address" "${output}" "dod-server 203.0.113.10:27016: 3 humans (4 players, 1 bots); skipping until the next try"
assert_contains "CS restart is logged" "${output}" "scoutzknivez 127.0.0.1:27015: 0 humans (8 players, 8 bots); restarted"
assert_not_contains "FastDL is not a game server" "${output}" "fastdl"
assert_not_contains "unrelated unit is ignored" "${output}" "27999"
[[ -f "${STATE}/scoutzknivez-2026-11-24" ]] || fail "restart did not record the day"
[[ ! -f "${STATE}/dod-server-2026-11-24" ]] || fail "a skipped server was stamped"

# The same morning does not restart CS again. DoD is still occupied.
: > "${RESTARTS}"
invoke
assert_contains "second pass skips CS" "${output}" "scoutzknivez: already restarted on 2026-11-24; skipping"
assert_eq "second pass restarts nothing" "" "$(cat "${RESTARTS}")"

# Humans leaving means the next pass restarts that server.
write_info "${INFO}/27016" 2 2
: > "${RESTARTS}"
invoke
assert_contains "DoD restarts once it is empty" "$(cat "${RESTARTS}")" "dod-server"
assert_contains "CS stays stamped" "${output}" "already restarted on 2026-11-24"

# Last slot, humans still online: stop trying today.
reset_case
export CS_RESTART_NOW=0800
write_quadlet scoutzknivez 27015
write_info "${INFO}/27015" 2 0
touch "${UNITS}/scoutzknivez" "${ACTIVE}/scoutzknivez"
invoke
assert_contains "08:00 gives up" "${output}" "giving up until tomorrow"
assert_eq "give-up does not restart" "" "$(cat "${RESTARTS}")"

# Outside the window, an empty server stays up.
reset_case
export CS_RESTART_NOW=1200
write_quadlet scoutzknivez 27015
write_info "${INFO}/27015" 0 0
touch "${UNITS}/scoutzknivez" "${ACTIVE}/scoutzknivez"
invoke
assert_contains "afternoon is outside the window" "${output}" "outside 0500-0800 America/Los_Angeles"
assert_eq "outside the window does not restart" "" "$(cat "${RESTARTS}")"

# --now checks anyway, and still leaves humans alone.
export CS_RESTART_NOW=1200
write_info "${INFO}/27015" 1 0
invoke --now
assert_contains "manual run leaves humans" "${output}" "leaving it up"
assert_eq "manual run does not restart humans" "" "$(cat "${RESTARTS}")"
write_info "${INFO}/27015" 0 0
invoke --now
assert_contains "manual run restarts an empty server" "$(cat "${RESTARTS}")" "scoutzknivez"

# A stopped unit is not started.
reset_case
write_quadlet scoutzknivez 27015
write_info "${INFO}/27015" 0 0
touch "${UNITS}/scoutzknivez"
invoke
assert_contains "stopped unit" "${output}" "scoutzknivez: not running; skipping"
assert_eq "stopped unit is not started" "" "$(cat "${RESTARTS}")"

# No reply: do not restart. A bad count does not restart either.
reset_case
write_quadlet scoutzknivez 27015
write_quadlet dod-server 27016
write_info "${INFO}/27016" 1 4
touch "${UNITS}/scoutzknivez" "${UNITS}/dod-server" "${ACTIVE}/scoutzknivez" "${ACTIVE}/dod-server"
invoke
assert_contains "missing reply" "${output}" "scoutzknivez 127.0.0.1:27015: no A2S_INFO reply"
assert_contains "bad counts" "${output}" "dod-server 127.0.0.1:27016: could not read player counts"
assert_eq "query trouble does not restart" "" "$(cat "${RESTARTS}")"

# Quadlet port replaces the targets file. The targets port has no packet.
reset_case
printf 'scoutzknivez 27015\n' > "${WORK}/targets"
export CS_RESTART_TARGETS="${WORK}/targets"
write_quadlet scoutzknivez 27017
write_info "${INFO}/27017" 0 0
touch "${UNITS}/scoutzknivez" "${ACTIVE}/scoutzknivez"
invoke
assert_contains "quadlet port is queried" "${output}" "scoutzknivez 127.0.0.1:27017: 0 humans"
assert_contains "quadlet port restarts" "$(cat "${RESTARTS}")" "scoutzknivez"

# Docker, no systemd unit: restart the container, with time for the countdown.
reset_case
unset CS_RESTART_TARGETS
printf 'scoutzknivez 27015\n' > "${WORK}/targets"
export CS_RESTART_TARGETS="${WORK}/targets"
export CS_RUNTIME=docker
write_info "${INFO}/27015" 3 3
touch "${ACTIVE}/scoutzknivez"
invoke
assert_contains "docker restart waits out the countdown" "$(cat "${RESTARTS}")" "restart --time 45 scoutzknivez"
unset CS_RUNTIME

# A failed restart is not stamped, so a later pass can try again.
reset_case
write_quadlet scoutzknivez 27015
write_info "${INFO}/27015" 0 0
touch "${UNITS}/scoutzknivez" "${ACTIVE}/scoutzknivez" "${FAIL}/scoutzknivez"
invoke
[[ "${status}" -ne 0 ]] || fail "a failed restart should be visible: ${output}"
assert_contains "restart failure is logged" "${output}" "scoutzknivez 127.0.0.1:27015: 0 humans (0 players, 0 bots); restart failed"
[[ ! -f "${STATE}/scoutzknivez-2026-11-24" ]] || fail "a failed restart was stamped"
rm -f "${FAIL}/scoutzknivez"
invoke
[[ "${status}" -eq 0 ]] || fail "retry after a failed restart: ${output}"
assert_contains "retry restarts" "$(cat "${RESTARTS}")" "scoutzknivez"

# --- Live query, including a challenge that contains NUL ---------------------

if command -v python3 >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    write_info "${WORK}/live.pkt" 5 5 20 "Live"
    cat > "${WORK}/a2s_peer.py" <<'PY'
import socket
import sys
import time

mode = sys.argv[1]
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 0))
sys.stdout.write(str(sock.getsockname()[1]) + "\n")
sys.stdout.flush()
if mode == "blackhole":
    time.sleep(30)
    sys.exit(0)
data, addr = sock.recvfrom(2048)
chal = b"\x00\x01\xff\x00"
if data != b"\xff\xff\xff\xffTSource Engine Query\x00":
    sys.stderr.write("first query was %r\n" % (data,))
    sys.exit(2)
sock.sendto(b"\xff\xff\xff\xffA" + chal, addr)
data, addr = sock.recvfrom(2048)
if not data.endswith(chal):
    sys.stderr.write("challenge was dropped: %r\n" % (data,))
    sys.exit(2)
with open(sys.argv[2], "rb") as handle:
    sock.sendto(handle.read(), addr)
PY
    python3 "${WORK}/a2s_peer.py" challenge "${WORK}/live.pkt" > "${WORK}/peer.port" &
    peer_pid=$!
    port=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if [[ -s "${WORK}/peer.port" ]]; then
            port=$(cat "${WORK}/peer.port")
            break
        fi
        sleep 0.05
    done
    [[ -n "${port}" ]] || fail "A2S peer did not bind"
    invoke --exchange 127.0.0.1 "${port}" "${WORK}/live.reply"
    wait "${peer_pid}" || fail "A2S peer rejected the exchange"
    [[ "${status}" -eq 0 ]] || fail "exchange failed: ${output}"
    invoke --parse "${WORK}/live.reply"
    assert_eq "live reply survives a NUL challenge" "info 5 5 0" "${output}"

    : > "${WORK}/peer.port"
    python3 "${WORK}/a2s_peer.py" blackhole > "${WORK}/peer.port" &
    peer_pid=$!
    port=""
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if [[ -s "${WORK}/peer.port" ]]; then
            port=$(cat "${WORK}/peer.port")
            break
        fi
        sleep 0.05
    done
    [[ -n "${port}" ]] || fail "blackhole peer did not bind"
    reset_case
    unset CS_RESTART_INFO_DIR
    export CS_RESTART_QUERY_TIMEOUT=1
    write_quadlet scoutzknivez "${port}"
    touch "${UNITS}/scoutzknivez" "${ACTIVE}/scoutzknivez"
    started=$(date +%s)
    set +e
    output=$(timeout 8 bash "${SCRIPT}" 2>&1)
    status=$?
    set -e
    finished=$(date +%s)
    kill "${peer_pid}" 2>/dev/null || true
    wait "${peer_pid}" 2>/dev/null || true
    [[ "${status}" -eq 0 ]] || fail "hung query should be a skip, got ${status}: ${output}"
    elapsed=$((finished - started))
    ((elapsed >= 1 && elapsed <= 6)) || fail "query timeout was ${elapsed}s (wanted about 1s): ${output}"
    assert_contains "hung query is a skip" "${output}" "no A2S_INFO reply"
    assert_eq "hung query does not restart" "" "$(cat "${RESTARTS}")"
    unset CS_RESTART_QUERY_TIMEOUT
fi

printf 'restart-idle tests passed\n'
