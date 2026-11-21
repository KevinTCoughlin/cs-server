#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# entrypoint.sh graceful shutdown: on SIGTERM the server gets the in-game
# countdown and `quit` through the FIFO, and the container exits 0 so
# on-failure restart policies leave it stopped.
#
# hlds_run is a stub that records its stdin, and `sleep` is shortened on the
# entrypoint's PATH, so the ~33 s countdown takes about 3 s. Needs util-linux
# `script` (Linux); `just test` runs it in a Debian container on macOS.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK="${ROOT}/tests/.shutdown-work.$$"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
RUNTIME="${WORK}/runtime"
RECORD="${WORK}/stdin-record"
mkdir -p "${BIN}"

REAL_SLEEP=$(command -v sleep)
printf '#!/bin/sh\nexec %s 0.5\n' "${REAL_SLEEP}" > "${BIN}/sleep"

# Stands in for HLDS: logs every console line it is sent, exits on `quit`
# unless told to hang (a server that ignores the command).
cat > "${WORK}/hlds_run" <<'EOF'
#!/bin/sh
: > "${RECORD}.ready"
while IFS= read -r line; do
    printf '%s\n' "${line}" >> "${RECORD}"
    if [ "${line}" = quit ] && [ "${IGNORE_QUIT:-0}" != 1 ]; then
        exit 0
    fi
done
EOF
chmod +x "${BIN}/sleep" "${WORK}/hlds_run"

# Start entrypoint.sh in the background and wait until the stub is reading.
start_entrypoint() {
    rm -f "${RECORD}" "${RECORD}.ready"
    (
        cd "${WORK}"
        exec env PATH="${BIN}:${PATH}" HLDS_RUNTIME_DIR="${RUNTIME}" \
            HLDS_EMULATOR="${WORK}/missing" RECORD="${RECORD}" "$@" \
            bash "${ROOT}/entrypoint.sh"
    ) > "${WORK}/output" 2>&1 &
    pid=$!

    local _
    for _ in $(seq 100); do
        [[ -e "${RECORD}.ready" ]] && return
        "${REAL_SLEEP}" 0.1
    done
    cat "${WORK}/output" >&2
    fail "the stub server never started"
}

# stop_entrypoint <signal>: send it and collect the exit status.
stop_entrypoint() {
    kill "-$1" "${pid}"
    set +e
    wait "${pid}"
    status=$?
    set -e
    output=$(cat "${WORK}/output")
}

EXPECTED='say [SERVER] Shutting down in 30 seconds...
say [SERVER] Shutting down in 10 seconds...
say [SERVER] Shutting down in 5 seconds...
say [SERVER] Shutting down in 2 seconds...
say [SERVER] Goodbye!
quit'

# --- The control FIFO is private while the server runs ----------------------
start_entrypoint
[[ -p "${RUNTIME}/hlds-input" ]] || fail "no control FIFO at ${RUNTIME}/hlds-input"
perms=$(mode_of "${RUNTIME}")
assert_eq "runtime dir permissions" 700 "${perms}"
perms=$(mode_of "${RUNTIME}/hlds-input")
assert_eq "FIFO permissions" 600 "${perms}"

# A command written to the FIFO reaches the server's stdin.
printf 'status\n' > "${RUNTIME}/hlds-input"
for _ in $(seq 50); do
    [[ -s "${RECORD}" ]] && break
    "${REAL_SLEEP}" 0.1
done
sent=$(cat "${RECORD}" 2>/dev/null || true)
assert_eq "FIFO command reaches the server" "status" "${sent}"

# --- SIGTERM: countdown, quit, exit 0 ---------------------------------------
stop_entrypoint TERM
assert_eq "SIGTERM: exit status" 0 "${status}"
sent=$(tail -n +2 "${RECORD}")
assert_eq "SIGTERM: console commands, in order" "${EXPECTED}" "${sent}"
assert_contains "SIGTERM: logs the shutdown" "${output}" "Caught shutdown signal"
assert_contains "SIGTERM: logs the quit" "${output}" "Sending quit command to HLDS"
[[ ! -e "${RUNTIME}/hlds-input" ]] || fail "the FIFO was left behind after shutdown"

# --- SIGINT behaves the same ------------------------------------------------
start_entrypoint
stop_entrypoint INT
assert_eq "SIGINT: exit status" 0 "${status}"
sent=$(cat "${RECORD}")
assert_eq "SIGINT: console commands, in order" "${EXPECTED}" "${sent}"

# --- A server that ignores `quit` is killed, and it still counts as clean ---
start_entrypoint IGNORE_QUIT=1
stop_entrypoint TERM
assert_eq "hung server: exit status" 0 "${status}"
sent=$(cat "${RECORD}")
assert_eq "hung server: was still asked to quit" "${EXPECTED}" "${sent}"

printf 'shutdown tests passed\n'
