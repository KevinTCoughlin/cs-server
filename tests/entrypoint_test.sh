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
    output=$(env HLDS_RUNTIME_DIR="${WORK_DIR}/runtime" HLDS_STATE_DIR="${WORK_DIR}/state" "$@" bash "${ROOT}/entrypoint.sh" 2>&1)
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

expect_invalid "LOGS must be 0 or 1" LOGS=on
expect_invalid "LOG_RETENTION_DAYS must be an integer from 0 to 3650" LOG_RETENTION_DAYS=-1
expect_invalid "LOG_RETENTION_DAYS must be an integer from 0 to 3650" LOG_RETENTION_DAYS=forever
expect_invalid "LOGADDRESS must be host:port" LOGADDRESS=stats.example.com
expect_invalid "LOGADDRESS must be host:port" LOGADDRESS=stats.example.com:0
expect_invalid "LOGADDRESS must be host:port" LOGADDRESS=stats.example.com:65536
expect_invalid "LOGADDRESS must be host:port" "LOGADDRESS=stats.example.com:27500;quit"
expect_invalid "LOGADDRESS must be host:port" "LOGADDRESS=a b:27500"
expect_invalid "LOGADDRESS needs LOGS=1" LOGS=0 LOGADDRESS=192.0.2.5:27500

cat > "${WORK_DIR}/hlds_run" <<'EOF'
#!/bin/sh
exit 17
EOF
chmod +x "${WORK_DIR}/hlds_run"

run_stub() {
    set +e
    (
        cd "${WORK_DIR}"
        env HLDS_RUNTIME_DIR="${WORK_DIR}/runtime" HLDS_STATE_DIR="${WORK_DIR}/state" \
            HLDS_STATE_DEFAULTS="${WORK_DIR}/defaults" "$@" bash "${ROOT}/entrypoint.sh"
    ) > "${WORK_DIR}/output" 2>&1
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

# File logging: on by default, after server.cfg; LOGADDRESS adds a receiver.
cat > "${WORK_DIR}/hlds_run" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > args
exit 17
EOF
chmod +x "${WORK_DIR}/hlds_run"

run_stub
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+exec server.cfg +exec banned.cfg +exec listip.cfg "*" +log on") ;;
    *) printf 'Expected the ban lists to be loaded and +log on by default, got: %s\n' "${args}" >&2; exit 1 ;;
esac

run_stub LOGADDRESS=stats.example.com:27500
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *" +log on +logaddress_add stats.example.com 27500") ;;
    *) printf 'Expected LOGADDRESS as +logaddress_add host port, got: %s\n' "${args}" >&2; exit 1 ;;
esac

run_stub BOTS=0
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *" +bot_quota 0 +localinfo sk_bots 0 "*) ;;
    *) printf 'Expected BOTS=0 to pass +bot_quota 0 and +localinfo sk_bots 0, got: %s\n' "${args}" >&2; exit 1 ;;
esac
if ! grep -q 'NOTE: .* is not a volume' "${WORK_DIR}/output"; then
    printf 'Expected a note when the state directory is not a mounted volume\n' >&2
    exit 1
fi

run_stub
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *sk_bots*) printf 'Expected no sk_bots with bots on, got: %s\n' "${args}" >&2; exit 1 ;;
    *) ;;
esac

run_stub LOGS=0
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+log"*) printf 'Expected no log arguments with LOGS=0, got: %s\n' "${args}" >&2; exit 1 ;;
    *) ;;
esac

# State directory: missing pieces are created, users.ini is seeded from the
# image default, existing files are left alone, old logs are pruned.
state="${WORK_DIR}/state"
rm -rf "${state}"
mkdir -p "${WORK_DIR}/defaults"
printf '; default admins\n' > "${WORK_DIR}/defaults/users.ini"
run_stub
for path in banned.cfg listip.cfg amxmodx/users.ini; do
    if [[ ! -f "${state}/${path}" ]]; then
        printf 'Expected the entrypoint to create %s in the state directory\n' "${path}" >&2
        exit 1
    fi
done
for path in logs amxmodx/logs amxmodx/vault; do
    if [[ ! -d "${state}/${path}" ]]; then
        printf 'Expected the entrypoint to create %s/ in the state directory\n' "${path}" >&2
        exit 1
    fi
done

printf 'addip 0 192.0.2.7\n' > "${state}/listip.cfg"
printf '"admin" "" "abcdefghijklmnopqrstu" "ce"\n' > "${state}/amxmodx/users.ini"
: > "${state}/logs/old.log"
: > "${state}/logs/new.log"
: > "${state}/amxmodx/logs/old.log"
: > "${state}/logs/old.txt"
touch -d '30 days ago' "${state}/logs/old.log" "${state}/amxmodx/logs/old.log" "${state}/logs/old.txt"
run_stub
if [[ "$(cat "${state}/listip.cfg")" != "addip 0 192.0.2.7" ]] || ! grep -q '^"admin"' "${state}/amxmodx/users.ini"; then
    printf 'The entrypoint must not overwrite existing state files\n' >&2
    exit 1
fi
if [[ -e "${state}/logs/old.log" || -e "${state}/amxmodx/logs/old.log" ]]; then
    printf 'Expected log files older than LOG_RETENTION_DAYS to be deleted\n' >&2
    exit 1
fi
if [[ ! -e "${state}/logs/new.log" || ! -e "${state}/logs/old.txt" ]]; then
    printf 'Pruning must only delete old *.log files\n' >&2
    exit 1
fi

: > "${state}/logs/old.log"
touch -d '30 days ago' "${state}/logs/old.log"
run_stub LOG_RETENTION_DAYS=0
if [[ ! -e "${state}/logs/old.log" ]]; then
    printf 'LOG_RETENTION_DAYS=0 must keep every log\n' >&2
    exit 1
fi

# An unwritable state directory is a warning, not a failed start.
if [[ "$(id -u)" -ne 0 ]]; then
    mkdir -p "${WORK_DIR}/locked"
    chmod 500 "${WORK_DIR}/locked"
    run_stub HLDS_STATE_DIR="${WORK_DIR}/locked"
    chmod 700 "${WORK_DIR}/locked"
    if [[ "${status}" -ne 17 ]] || ! grep -q 'WARNING: .* is not writable' "${WORK_DIR}/output"; then
        printf 'Expected a warning and a normal start with an unwritable state directory, got %d\n' "${status}" >&2
        exit 1
    fi
fi

if grep -q '^sv_downloadurl' "${ROOT}/config/server.cfg"; then
    printf 'config/server.cfg must not set sv_downloadurl: it is re-run on every map and would override FASTDL_URL\n' >&2
    exit 1
fi

printf 'entrypoint tests passed\n'
