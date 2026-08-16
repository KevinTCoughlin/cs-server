#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR="${ROOT}/tests/.entrypoint-work.$$"
trap 'rm -rf "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}"

expect_invalid() {
    local expected="$1"
    shift

    local output status
    set +e
    output=$(env HLDS_RUNTIME_DIR="${WORK_DIR}/runtime" "$@" bash "${ROOT}/entrypoint.sh" 2>&1)
    status=$?
    set -e

    if [[ "${status}" -eq 0 ]] || [[ "${output}" != *"${expected}"* ]]; then
        printf 'Expected failure containing %q, got status %d:\n%s\n' "${expected}" "${status}" "${output}" >&2
        exit 1
    fi
}

expect_invalid "BOTS must be 0 or 1" BOTS=2
expect_invalid "NOMASTER must be 0 or 1" NOMASTER=yes
expect_invalid "LAN_MODE must be 0 or 1" LAN_MODE=-1
expect_invalid "MAXPLAYERS must be an integer from 1 to 32" MAXPLAYERS=33
expect_invalid "MAXPLAYERS must be an integer from 1 to 32" MAXPLAYERS=999999999999999999999999999999999999
expect_invalid "PORT must be an integer from 1 to 65535" PORT=0
expect_invalid "PORT must be an integer from 1 to 65535" PORT=18446744073709551616
expect_invalid "MAP must be a filename" "MAP=scoutzknivez;quit"
expect_invalid "MAPCYCLE must be a filename" MAPCYCLE=../server.cfg

cat > "${WORK_DIR}/hlds_run" <<'EOF'
#!/bin/sh
exit 17
EOF
chmod +x "${WORK_DIR}/hlds_run"

run_stub() {
    set +e
    (
        cd "${WORK_DIR}"
        env HLDS_RUNTIME_DIR="${WORK_DIR}/runtime" "$@" bash "${ROOT}/entrypoint.sh"
    ) >/dev/null 2>&1
    status=$?
    set -e
}

run_stub MAXPLAYERS=00020 PORT=027015
if [[ "${status}" -ne 17 ]]; then
    printf 'Expected leading-zero values to reach HLDS, got %d\n' "${status}" >&2
    exit 1
fi

run_stub

if [[ "${status}" -ne 17 ]]; then
    printf 'Expected HLDS exit status 17, got %d\n' "${status}" >&2
    exit 1
fi

printf 'entrypoint tests passed\n'
