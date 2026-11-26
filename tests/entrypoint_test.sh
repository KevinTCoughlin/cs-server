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
expect_invalid "INSECURE must be 0 or 1" INSECURE=yes
expect_invalid "LAN_MODE must be 0 or 1" LAN_MODE=-1
expect_invalid "GSLT must be a 32-character hex" GSLT=not-a-token
expect_invalid "GSLT must be a 32-character hex" GSLT=00112233445566778899AABBCCDDEEF
expect_invalid "DOD_PASSWORD must be" "DOD_PASSWORD=has space"
expect_invalid "MAXPLAYERS must be an integer from 1 to 32" MAXPLAYERS=33
expect_invalid "MAXPLAYERS must be an integer from 1 to 32" MAXPLAYERS=999999999999999999999999999999999999
expect_invalid "PORT must be an integer from 1 to 65535" PORT=0
expect_invalid "METRICS_PORT must be an integer from 1024 to 65535" METRICS_PORT=80
expect_invalid "METRICS_PORT must be an integer from 1024 to 65535" "METRICS_PORT=9137;quit"
expect_invalid "METRICS_BIND must be an IPv4 address" METRICS_PORT=9137 METRICS_BIND=localhost
expect_invalid "PORT must be an integer from 1 to 65535" PORT=18446744073709551616
expect_invalid "MAP must be a filename" "MAP=scoutzknivez;quit"
expect_invalid "MAPCYCLE must be a filename" MAPCYCLE=../server.cfg
expect_invalid "MODE must be scoutz, knife, vanilla, match, climb or surf" MODE=nipper
expect_invalid "MODE must be scoutz, knife, vanilla, match, climb or surf" "MODE=knife;quit"
expect_invalid "FASTDL_URL must be an http(s) URL" FASTDL_URL=ftp://example.com/cstrike/
expect_invalid "FASTDL_URL must be an http(s) URL" FASTDL_URL=example.com/cstrike/
expect_invalid "FASTDL_URL must be an http(s) URL" "FASTDL_URL=https://example.com/;quit"
expect_invalid "FASTDL_URL must be an http(s) URL" 'FASTDL_URL=https://example.com/";quit'
expect_invalid "FASTDL_URL must be an http(s) URL" "FASTDL_URL=https://example.com/a b"
expect_invalid "FASTDL_URL must be an http(s) URL" "FASTDL_URL=https://example.com/$(printf 'a%.0s' {1..120})"

expect_invalid "SERVER_IP must be an IPv4 address" SERVER_IP=example.com
expect_invalid "SERVER_IP_WAIT must be an integer from 0 to 600" SERVER_IP=192.168.1.5 SERVER_IP_WAIT=forever
expect_invalid "SERVER_IP must be an IPv4 address" SERVER_IP=192.168.1.256
expect_invalid "SERVER_IP must be an IPv4 address" SERVER_IP=192.168.1
expect_invalid "SERVER_IP must be an IPv4 address" "SERVER_IP=192.168.1.5;quit"

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

# A Day of Defeat image: its own game directory and default map, and none of
# the ScoutzKnivez mode or bot arguments.
bash "${ROOT}/scripts/game-env.sh" dod > "${WORK_DIR}/game.env"
run_stub HLDS_GAME_ENV="${WORK_DIR}/game.env"
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    "-game dod +map dod_anzio "*) ;;
    *) printf 'Expected a Day of Defeat image to start -game dod on dod_anzio, got: %s\n' "${args}" >&2; exit 1 ;;
esac
case "${args}" in
    *"+maxplayers 16 "*"+exec server.cfg +localinfo dod_mode pub +exec pub.cfg +exec banned.cfg"*) ;;
    *) printf 'Expected Day of Defeat pub defaults (16 slots, exec pub.cfg), got: %s\n' "${args}" >&2; exit 1 ;;
esac
case "${args}" in
    *sk_mode* | *bot_quota* | *sv_setsteamaccount* | *sv_password* | *-insecure*)
        printf 'Day of Defeat pub must not get mode, bot, token, password or -insecure, got: %s\n' "${args}" >&2
        exit 1
        ;;
esac
expect_invalid "DOD_MODE must be pub or match" HLDS_GAME_ENV="${WORK_DIR}/game.env" DOD_MODE=knife
run_stub HLDS_GAME_ENV="${WORK_DIR}/game.env" DOD_MODE=match
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+maxplayers 12 "*"+localinfo dod_mode match +exec match.cfg "*) ;;
    *) printf 'Expected DOD_MODE=match to be 12 slots exec match.cfg, got: %s\n' "${args}" >&2; exit 1 ;;
esac
run_stub HLDS_GAME_ENV="${WORK_DIR}/game.env" MODE=match
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+exec match.cfg "*) ;;
    *) printf 'Expected MODE=match on Day of Defeat to exec match.cfg, got: %s\n' "${args}" >&2; exit 1 ;;
esac
run_stub HLDS_GAME_ENV="${WORK_DIR}/game.env" DOD_MODE=match MAXPLAYERS=20
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+maxplayers 20 "*) ;;
    *) printf 'Expected an explicit MAXPLAYERS to win, got: %s\n' "${args}" >&2; exit 1 ;;
esac
run_stub HLDS_GAME_ENV="${WORK_DIR}/game.env" DOD_PASSWORD=scrim
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *" +sv_password scrim") ;;
    *) printf 'Expected DOD_PASSWORD on the command line, got: %s\n' "${args}" >&2; exit 1 ;;
esac
run_stub HLDS_GAME_ENV="${WORK_DIR}/game.env" GSLT=00112233445566778899AABBCCDDEEFF INSECURE=1
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"-insecure "*"+sv_setsteamaccount 00112233445566778899AABBCCDDEEFF") ;;
    *) printf 'Expected -insecure and the GSLT, got: %s\n' "${args}" >&2; exit 1 ;;
esac
case "${args}" in
    *-nomaster*) printf 'INSECURE=1 must not pass -nomaster, got: %s\n' "${args}" >&2; exit 1 ;;
esac

# Condition Zero has ReGameDLL's bots but not the ScoutzKnivez plugin.
bash "${ROOT}/scripts/game-env.sh" czero > "${WORK_DIR}/game.env"
run_stub HLDS_GAME_ENV="${WORK_DIR}/game.env" BOTS=0
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    "-game czero +map de_dust2_cz "*"+bot_quota 0"*) ;;
    *) printf 'Expected Condition Zero with BOTS=0 to pass +bot_quota 0, got: %s\n' "${args}" >&2; exit 1 ;;
esac
case "${args}" in
    *sk_mode* | *sk_bots*) printf 'Condition Zero must not get ScoutzKnivez arguments, got: %s\n' "${args}" >&2; exit 1 ;;
esac
if bash "${ROOT}/scripts/game-env.sh" quake >/dev/null 2>&1; then
    printf 'game-env.sh accepted an unknown game\n' >&2
    exit 1
fi

run_stub
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    "-game cstrike +map scoutzknivez "*"+localinfo sk_mode scoutz +exec server.cfg"*"+bot_quota 10"*) ;;
    *) printf 'Expected the Counter-Strike defaults, got: %s\n' "${args}" >&2; exit 1 ;;
esac

# Metrics: nothing listens unless METRICS_PORT is set; then the endpoint gets
# the port, the address and the file the plugin writes.
cat > "${WORK_DIR}/metrics-stub" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "${0%/*}/metrics-args"
EOF
chmod +x "${WORK_DIR}/metrics-stub"
run_stub HLDS_METRICS_SERVER="${WORK_DIR}/metrics-stub"
[[ ! -e "${WORK_DIR}/metrics-args" ]] || { printf 'The metrics endpoint started without METRICS_PORT\n' >&2; exit 1; }
run_stub HLDS_METRICS_SERVER="${WORK_DIR}/metrics-stub" METRICS_PORT=09137 METRICS_BIND=127.0.0.1
metrics_args=$(cat "${WORK_DIR}/metrics-args")
if [[ "${metrics_args}" != "9137 127.0.0.1 ${WORK_DIR}/runtime/metrics.prom" ]]; then
    printf 'Unexpected metrics endpoint arguments: %s\n' "${metrics_args}" >&2
    exit 1
fi

# Vanilla: a stock map and rotation by default, and the mode's plugin list
# when the image has one.
run_stub MODE=vanilla
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *amxx_plugins*) printf 'No plugin list without a modes/vanilla.ini, got: %s\n' "${args}" >&2; exit 1 ;;
    *"+map de_dust2 "*"+mapcyclefile mapcycle-dust2.txt "*"+localinfo sk_mode vanilla"*) ;;
    *) printf 'Expected the vanilla defaults, got: %s\n' "${args}" >&2; exit 1 ;;
esac
mkdir -p "${WORK_DIR}/cstrike/addons/amxmodx/configs/modes"
: > "${WORK_DIR}/cstrike/addons/amxmodx/configs/modes/vanilla.ini"
run_stub MODE=vanilla MAP=de_inferno MAPCYCLE=mapcycle.txt
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+map de_inferno "*"+mapcyclefile mapcycle.txt "*"+localinfo sk_mode vanilla +localinfo amxx_plugins addons/amxmodx/configs/modes/vanilla.ini"*) ;;
    *) printf 'Expected MAP, MAPCYCLE and the vanilla plugin list, got: %s\n' "${args}" >&2; exit 1 ;;
esac
run_stub MODE=knife
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *amxx_plugins*) printf 'A mode without its own list uses plugins.ini, got: %s\n' "${args}" >&2; exit 1 ;;
esac

# Climb: its own rotation, the rotation's first map, and no bots unless asked.
printf '; a comment\n\n// another\nkz_absent\nkz_first extra\nkz_second\n' > "${WORK_DIR}/cstrike/mapcycle-climb.txt"
run_stub MODE=climb
if [[ "${status}" -eq 0 ]] || ! grep -q "has none of the maps in mapcycle-climb.txt" "${WORK_DIR}/output"; then
    printf 'Expected MODE=climb to stop without a climb map, got %d:\n' "${status}" >&2
    cat "${WORK_DIR}/output" >&2
    exit 1
fi
mkdir -p "${WORK_DIR}/cstrike/maps"
: > "${WORK_DIR}/cstrike/maps/kz_first.bsp"
: > "${WORK_DIR}/cstrike/maps/kz_second.bsp"
run_stub MODE=climb
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+map kz_first "*"+mapcyclefile mapcycle-climb.txt "*"+localinfo sk_mode climb"*) ;;
    *) printf 'Expected the climb defaults, got: %s\n' "${args}" >&2; exit 1 ;;
esac
case "${args}" in
    *"+bot_quota 0 +localinfo sk_bots 0"*) ;;
    *) printf 'Expected no bots in climb mode, got: %s\n' "${args}" >&2; exit 1 ;;
esac
run_stub MODE=climb MAP=kz_second BOTS=1
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+map kz_second "*"+bot_quota 10"*) ;;
    *) printf 'Expected MAP and BOTS to override the climb defaults, got: %s\n' "${args}" >&2; exit 1 ;;
esac
printf 'surf_one\n' > "${WORK_DIR}/cstrike/mapcycle-surf.txt"
: > "${WORK_DIR}/cstrike/maps/surf_one.bsp"
run_stub MODE=surf
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *"+map surf_one "*"+mapcyclefile mapcycle-surf.txt "*"+localinfo sk_mode surf"*) ;;
    *) printf 'Expected the surf defaults, got: %s\n' "${args}" >&2; exit 1 ;;
esac
[[ -d "${WORK_DIR}/state/amxmodx/zones" ]] || { printf 'No zones directory in the state volume\n' >&2; exit 1; }
[[ -d "${WORK_DIR}/state/amxmodx/records" ]] || { printf 'No records directory in the state volume\n' >&2; exit 1; }
rm -rf "${WORK_DIR}/cstrike/addons"
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

case "${args}" in
    *"+ip "*) printf 'Expected no +ip without SERVER_IP, got: %s\n' "${args}" >&2; exit 1 ;;
esac

# SERVER_IP: the address must be on an interface before HLDS starts. The
# check is stubbed: this machine does not have that address.
cat > "${WORK_DIR}/bind-ok" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "${WORK_DIR}/bind-later" <<'EOF'
#!/bin/sh
count=$(cat "${0%/*}/bind-count" 2>/dev/null || echo 0)
echo $((count + 1)) > "${0%/*}/bind-count"
[ "${count}" -ge 2 ]
EOF
cat > "${WORK_DIR}/bind-never" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${WORK_DIR}"/bind-*
run_stub SERVER_IP=192.168.1.5 HLDS_BIND_CHECK="${WORK_DIR}/bind-later"
output=$(cat "${WORK_DIR}/output")
if [[ "${status}" -ne 17 || "${output}" != *"Waiting up to 30s for 192.168.1.5"* || "${output}" == *"starting anyway"* ]]; then
    printf 'Expected a wait for SERVER_IP and then a start, got %d: %s\n' "${status}" "${output}" >&2
    exit 1
fi
if [[ "$(cat "${WORK_DIR}/bind-count")" -ne 3 ]]; then
    printf 'Expected the address to be tried until it was there (3 checks)\n' >&2
    exit 1
fi
run_stub SERVER_IP=192.168.1.5 SERVER_IP_WAIT=1 HLDS_BIND_CHECK="${WORK_DIR}/bind-never"
output=$(cat "${WORK_DIR}/output")
if [[ "${status}" -ne 17 || "${output}" != *"192.168.1.5 is still not on any interface; starting anyway"* ]]; then
    printf 'Expected a warning and a start after SERVER_IP_WAIT, got %d: %s\n' "${status}" "${output}" >&2
    exit 1
fi
run_stub SERVER_IP=192.168.1.5 SERVER_IP_WAIT=0 HLDS_BIND_CHECK="${WORK_DIR}/bind-never"
output=$(cat "${WORK_DIR}/output")
if [[ "${status}" -ne 17 || "${output}" == *"Waiting"* ]]; then
    printf 'Expected no wait with SERVER_IP_WAIT=0, got %d: %s\n' "${status}" "${output}" >&2
    exit 1
fi

run_stub SERVER_IP=192.168.1.5 HLDS_BIND_CHECK="${WORK_DIR}/bind-ok"
args=$(cat "${WORK_DIR}/args")
case "${args}" in
    *" +port 27015 +ip 192.168.1.5 "*) ;;
    *) printf 'Expected SERVER_IP as +ip after +port, got: %s\n' "${args}" >&2; exit 1 ;;
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
for path in logs nav amxmodx/logs amxmodx/vault; do
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
touch -d '40 days ago' "${state}/logs/old.log" "${state}/amxmodx/logs/old.log" "${state}/logs/old.txt"
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
touch -d '40 days ago' "${state}/logs/old.log"
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
