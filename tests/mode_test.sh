#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# scripts/mode.sh: which sk_switchmode command each mode, weekday, hour and
# date sends to the server. `date` and the container engine are stubbed on
# PATH, so nothing here touches a real server or the real clock.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
CALLS="${WORK}/engine-calls"
mkdir -p "${BIN}"

# Only the fields mode.sh decides on are faked; its log timestamp is real.
cat > "${BIN}/date" <<'EOF'
#!/bin/sh
case "$1" in
    +%u) echo "${FAKE_DOW}" ;;
    +%H) echo "${FAKE_HOUR}" ;;
    +%m) echo "${FAKE_MONTH}" ;;
    +%d) echo "${FAKE_DAY}" ;;
    *) exec /bin/date "$@" ;;
esac
EOF

# `<engine> exec <name> true` is the is-it-running probe; any other exec is
# the FIFO write, whose last argument is the console command.
cat > "${BIN}/podman" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${ENGINE_CALLS}"
if [ "$3" = true ]; then
    [ "${FAKE_RUNNING:-1}" = 1 ]
fi
EOF
chmod +x "${BIN}/date" "${BIN}/podman"

# A Wednesday afternoon in July unless a case says otherwise.
run_mode() {
    local mode="$1"
    shift
    : > "${CALLS}"
    set +e
    output=$(env PATH="${BIN}:${PATH}" ENGINE_CALLS="${CALLS}" \
        FAKE_DOW=3 FAKE_HOUR=15 FAKE_MONTH=07 FAKE_DAY=15 "$@" \
        bash "${ROOT}/scripts/mode.sh" podman "${mode}" 2>&1)
    status=$?
    set -e
}

# expect_command <description> <console command> <mode> [VAR=value...]
expect_command() {
    local description="$1" expected="$2" sent
    shift 2
    run_mode "$@"
    assert_eq "${description}: exit status" 0 "${status}"
    sent=$(tail -n 1 "${CALLS}")
    assert_contains "${description}: writes to the server FIFO" "${sent}" "/hlds/.runtime/hlds-input"
    if [[ "${sent}" != *" sh ${expected}" ]]; then
        fail "${description}: expected '${expected}', engine got: ${sent}"
    fi
}

SCOUTZ="sk_switchmode scoutz mapcycle.txt"
NIPPER="sk_switchmode knife mapcycle-nipper.txt"
XMAS="sk_switchmode knife mapcycle-nipper-xmas.txt"

# --- Explicit modes ---------------------------------------------------------
expect_command "scoutz" "${SCOUTZ}" scoutz
expect_command "vanilla" "sk_switchmode vanilla mapcycle-dust2.txt" vanilla
expect_command "match" "sk_switchmode match mapcycle-dust2.txt" match
expect_command "climb" "sk_switchmode climb mapcycle-climb.txt" climb
expect_command "surf" "sk_switchmode surf mapcycle-surf.txt" surf
expect_command "nipper out of season" "${NIPPER}" nipper
assert_contains "names the queued switch" "${output}" "queued nipper (${NIPPER})"

# --- auto: Friday START_HOUR until Saturday END_HOUR ------------------------
expect_command "Thursday evening" "${SCOUTZ}" auto FAKE_DOW=4 FAKE_HOUR=20
expect_command "Friday 16:xx" "${SCOUTZ}" auto FAKE_DOW=5 FAKE_HOUR=16
expect_command "Friday 17:xx" "${NIPPER}" auto FAKE_DOW=5 FAKE_HOUR=17
expect_command "Friday 23:xx" "${NIPPER}" auto FAKE_DOW=5 FAKE_HOUR=23
expect_command "Saturday 00:xx" "${NIPPER}" auto FAKE_DOW=6 FAKE_HOUR=00
expect_command "Saturday 03:xx" "${NIPPER}" auto FAKE_DOW=6 FAKE_HOUR=03
expect_command "Saturday 04:xx" "${SCOUTZ}" auto FAKE_DOW=6 FAKE_HOUR=04
expect_command "Saturday evening" "${SCOUTZ}" auto FAKE_DOW=6 FAKE_HOUR=20
expect_command "Friday morning" "${SCOUTZ}" auto FAKE_DOW=5 FAKE_HOUR=03
# 08 and 09 are not octal.
expect_command "Friday 08:xx" "${SCOUTZ}" auto FAKE_DOW=5 FAKE_HOUR=08
expect_command "Friday 09:xx" "${SCOUTZ}" auto FAKE_DOW=5 FAKE_HOUR=09
expect_command "custom start hour" "${NIPPER}" auto FAKE_DOW=5 FAKE_HOUR=12 NIPPER_START_HOUR=12
expect_command "custom end hour" "${NIPPER}" auto FAKE_DOW=6 FAKE_HOUR=05 NIPPER_END_HOUR=6

# --- Christmas rotation: Dec 1 through Jan 6 --------------------------------
expect_command "Nov 30" "${NIPPER}" nipper FAKE_MONTH=11 FAKE_DAY=30
expect_command "Dec 1" "${XMAS}" nipper FAKE_MONTH=12 FAKE_DAY=01
expect_command "Dec 31" "${XMAS}" nipper FAKE_MONTH=12 FAKE_DAY=31
expect_command "Jan 6" "${XMAS}" nipper FAKE_MONTH=01 FAKE_DAY=06
expect_command "Jan 7" "${NIPPER}" nipper FAKE_MONTH=01 FAKE_DAY=07
expect_command "Sep 8 (leading zeros)" "${NIPPER}" nipper FAKE_MONTH=09 FAKE_DAY=08
expect_command "forced xmas" "${XMAS}" nipper NIPPER_SEASON=xmas
expect_command "forced off in December" "${NIPPER}" nipper FAKE_MONTH=12 FAKE_DAY=25 NIPPER_SEASON=none
expect_command "the season never touches scoutz" "${SCOUTZ}" scoutz FAKE_MONTH=12 FAKE_DAY=25
expect_command "auto on a December Friday" "${XMAS}" auto FAKE_DOW=5 FAKE_HOUR=18 FAKE_MONTH=12 FAKE_DAY=04

# --- Container name ---------------------------------------------------------
run_mode scoutz CS_CONTAINER_NAME=other
assert_eq "custom container: exit status" 0 "${status}"
probe=$(head -n 1 "${CALLS}")
assert_eq "custom container: probes it" "exec other true" "${probe}"

# --- Server not running: scheduled runs must not fail or start it -----------
run_mode nipper FAKE_RUNNING=0
assert_eq "not running: exit status" 0 "${status}"
assert_contains "not running: says so" "${output}" "scoutzknivez is not running; nothing to do"
calls=$(cat "${CALLS}")
assert_eq "not running: only the probe ran" "exec scoutzknivez true" "${calls}"

# --- Bad input --------------------------------------------------------------
run_mode bogus
assert_eq "unknown mode: exit status" 2 "${status}"
assert_contains "unknown mode: usage" "${output}" "usage:"
calls=$(cat "${CALLS}")
assert_eq "unknown mode: engine untouched" "" "${calls}"

run_mode nipper NIPPER_SEASON=easter
assert_eq "bad season: exit status" 2 "${status}"
assert_contains "bad season: message" "${output}" "NIPPER_SEASON must be xmas or none"
calls=$(cat "${CALLS}")
assert_eq "bad season: engine untouched" "" "${calls}"

set +e
output=$(bash "${ROOT}/scripts/mode.sh" lxc scoutz 2>&1)
status=$?
set -e
assert_eq "unknown engine: exit status" 2 "${status}"
assert_contains "unknown engine: usage" "${output}" "usage:"

# --- The schedules fire at the hours mode.sh defaults to --------------------
# shellcheck disable=SC2016 # literal ${...} text from mode.sh
start=$(sed -n 's/^START_HOUR="${NIPPER_START_HOUR:-\([0-9]*\)}"$/\1/p' "${ROOT}/scripts/mode.sh")
# shellcheck disable=SC2016
end=$(sed -n 's/^END_HOUR="${NIPPER_END_HOUR:-\([0-9]*\)}"$/\1/p' "${ROOT}/scripts/mode.sh")
[[ -n "${start}" && -n "${end}" ]] || fail "could not read the default hours from scripts/mode.sh"

timer="${ROOT}/ops/systemd/cs-server-friday.timer"
printf -v fri 'OnCalendar=Fri *-*-* %02d:00:00' "${start}"
printf -v sat 'OnCalendar=Sat *-*-* %02d:00:00' "${end}"
count=$(count_lines "${timer}" "${fri}")
assert_eq "systemd timer fires at the Friday start hour" 1 "${count}"
count=$(count_lines "${timer}" "${sat}")
assert_eq "systemd timer fires at the Saturday end hour" 1 "${count}"

# launchd: Weekday then Hour, one pair per <dict>.
plist="${ROOT}/ops/launchd/com.kevintcoughlin.cs-server.friday.plist"
pairs=$(awk '
    /<key>Weekday<\/key>/ { getline; gsub(/[^0-9]/, ""); day = $0 }
    /<key>Hour<\/key>/ { getline; gsub(/[^0-9]/, ""); printf "%s@%s ", day, $0 }
' "${plist}")
assert_eq "launchd agent fires at the same hours" "5@${start} 6@${end} " "${pairs}"

printf 'mode tests passed\n'
