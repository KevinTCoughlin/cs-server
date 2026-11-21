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
expect_invalid "MODE must be scoutz or knife" MODE=nipper
expect_invalid "MODE must be scoutz or knife" "MODE=knife;quit"
expect_invalid "FASTDL_URL must be an http(s) URL" FASTDL_URL=ftp://example.com/cstrike/
expect_invalid "FASTDL_URL must be an http(s) URL" FASTDL_URL=example.com/cstrike/
expect_invalid "FASTDL_URL must be an http(s) URL" "FASTDL_URL=https://example.com/;quit"
expect_invalid "FASTDL_URL must be an http(s) URL" 'FASTDL_URL=https://example.com/";quit'
expect_invalid "FASTDL_URL must be an http(s) URL" "FASTDL_URL=https://example.com/a b"
expect_invalid "FASTDL_URL must be an http(s) URL" "FASTDL_URL=https://example.com/$(printf 'a%.0s' {1..120})"

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

run_stub MODE=knife
if [[ "${status}" -ne 17 ]]; then
    printf 'Expected MODE=knife to reach HLDS, got %d\n' "${status}" >&2
    exit 1
fi

run_stub

if [[ "${status}" -ne 17 ]]; then
    printf 'Expected HLDS exit status 17, got %d\n' "${status}" >&2
    exit 1
fi

# arm64 images ship an emulated hlds_linux launcher; entrypoint.sh must hand
# it to hlds_run as -binary, and leave the arguments alone when it's absent.
cat > "${WORK_DIR}/hlds_run" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-binary" ] && [ "$2" = "${EXPECTED_BINARY}" ]; then
        exit 18
    fi
    shift
done
exit 17
EOF
cat > "${WORK_DIR}/emulated_hlds_linux" <<'EOF'
#!/bin/sh
EOF
chmod +x "${WORK_DIR}/hlds_run" "${WORK_DIR}/emulated_hlds_linux"

run_stub HLDS_EMULATOR="${WORK_DIR}/emulated_hlds_linux" EXPECTED_BINARY="${WORK_DIR}/emulated_hlds_linux"
if [[ "${status}" -ne 18 ]]; then
    printf 'Expected the emulated launcher to be passed as -binary, got %d\n' "${status}" >&2
    exit 1
fi

run_stub HLDS_EMULATOR="${WORK_DIR}/missing" EXPECTED_BINARY="${WORK_DIR}/missing"
if [[ "${status}" -ne 17 ]]; then
    printf 'Expected no -binary without an emulated launcher, got %d\n' "${status}" >&2
    exit 1
fi

# FASTDL_URL becomes +sv_downloadurl with the quotes inside the argument (a
# bare URL's `//` would start a console comment); unset, nothing is passed.
cat > "${WORK_DIR}/hlds_run" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = "+sv_downloadurl" ]; then
        if [ "$2" = "\"${EXPECTED_URL}\"" ]; then
            exit 19
        fi
        exit 20
    fi
    shift
done
exit 17
EOF
chmod +x "${WORK_DIR}/hlds_run"

url='https://example.com/cs/cstrike/?a=1&b=%20'
run_stub FASTDL_URL="${url}" EXPECTED_URL="${url}"
if [[ "${status}" -ne 19 ]]; then
    printf 'Expected FASTDL_URL to reach HLDS as a quoted +sv_downloadurl, got %d\n' "${status}" >&2
    exit 1
fi

run_stub FASTDL_URL=
if [[ "${status}" -ne 17 ]]; then
    printf 'Expected no +sv_downloadurl without FASTDL_URL, got %d\n' "${status}" >&2
    exit 1
fi

if grep -q '^sv_downloadurl' "${ROOT}/config/server.cfg"; then
    printf 'config/server.cfg must not set sv_downloadurl: it is re-run on every map and would override FASTDL_URL\n' >&2
    exit 1
fi

printf 'entrypoint tests passed\n'
