#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# cs-server-update against stubbed curl, podman, and systemctl. No network
# and no running server.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
QUAD="${WORK}/quadlet"
STATE="${WORK}/state"
LOCK="${WORK}/lock"
mkdir -p "${STUBS}" "${QUAD}" "${STATE}" "${WORK}/home"
REV=0123456789abcdef0123456789abcdef01234567
SHORT=${REV:0:7}
NEW=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

cat > "${STUBS}/curl" <<'EOF'
#!/bin/bash
dest="" hdr="" url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) dest=$2; shift 2 ;;
        -D) hdr=$2; shift 2 ;;
        -H | -w | --max-time) shift 2 ;;
        -sS) shift ;;
        http*) url=$1; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "${url}" >> "${CURL_LOG}"
printf 'HTTP/1.1 200\r\nETag: "t1"\r\n\r\n' > "${hdr}"
case "${url}" in
    */check-runs*) cp "${FIX}/checks.json" "${dest}" ;;
    */status) cp "${FIX}/status.json" "${dest}" ;;
    */releases/latest) cp "${FIX}/release.json" "${dest}" ;;
    */commits/*) cp "${FIX}/commit.json" "${dest}" ;;
    *) printf 'no fixture for %s\n' "${url}" >&2; exit 1 ;;
esac
printf '200\n'
EOF

cat > "${STUBS}/podman" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${PODMAN_LOG}"
case "$1" in
    pull) [[ "${FAIL_PULL:-0}" == 1 ]] && exit 1; exit 0 ;;
    image)
        if [[ "$*" == *revision* ]]; then
            printf '%s\n' "${FAKE_REV}"
        else
            printf '%s\n' "${FAKE_DIGEST}"
        fi
        ;;
    *) exit 1 ;;
esac
EOF

cat > "${STUBS}/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
exit 0
EOF

cat > "${STUBS}/cs-players" <<'EOF'
#!/bin/bash
n=0
[[ -f "${PLAYER_COUNT}" ]] && n=$(cat "${PLAYER_COUNT}")
n=$((n + 1))
printf '%s\n' "${n}" > "${PLAYER_COUNT}"
if [[ "${PLAYER_MODE:-ok}" == "busy" ]]; then
    printf 'humans=2 players=2 bots=0 map=de_dust2\n'
    exit 0
fi
if [[ "${PLAYER_MODE:-ok}" == "down" && "${n}" -ge 3 ]]; then
    printf 'unknown\n' >&2
    exit 2
fi
printf 'humans=0 players=0 bots=0 map=de_dust2\n'
EOF

cat > "${STUBS}/flock" <<'EOF'
#!/bin/bash
# Real flock, so two holders of one file still exclude each other.
exec /usr/bin/flock "$@"
EOF
chmod +x "${STUBS}/"*

FIX="${WORK}/fix"
mkdir -p "${FIX}"
printf '{"sha":"%s","commit":{"message":"feat: roll the servers\\n\\nNotes."}}\n' "${REV}" > "${FIX}/commit.json"
printf '{"check_runs":[{"name":"CI","status":"completed","conclusion":"success"}]}\n' > "${FIX}/checks.json"
printf '{"state":"success","statuses":[{"state":"success"}]}\n' > "${FIX}/status.json"
printf '{"tag_name":"v9.9.9","body":"Bug fixes only."}\n' > "${FIX}/release.json"

unit_file() {
    local digest="${1:-${OLD}}"
    cat > "${QUAD}/scoutzknivez.container" <<EOF
[Container]
Image=ghcr.io/kevintcoughlin/cs-server:old@${digest}
ContainerName=scoutzknivez
EOF
}

run_update() {
    local -a extra=("$@")
    : > "${WORK}/curl.log"
    : > "${WORK}/podman.log"
    : > "${WORK}/systemctl.log"
    rm -f "${WORK}/players.n"
    rm -rf "${STATE}"
    mkdir -p "${STATE}"
    set +e
    output=$(env -i PATH="${STUBS}:/usr/bin:/bin" HOME="${WORK}/home" \
        CURL_LOG="${WORK}/curl.log" PODMAN_LOG="${WORK}/podman.log" \
        SYSTEMCTL_LOG="${WORK}/systemctl.log" FIX="${FIX}" \
        FAKE_REV="${REV}" FAKE_DIGEST="${NEW}" \
        PLAYER_COUNT="${WORK}/players.n" PLAYER_MODE="${PLAYER_MODE:-ok}" \
        FAIL_PULL="${FAIL_PULL:-0}" \
        CS_QUADLET_DIR="${QUAD}" CS_UPDATE_STATE_DIR="${STATE}" \
        CS_UPDATE_ENV="${WORK}/no-env" CS_UPDATE_UNITS="${WORK}/units" \
        CS_UPDATE_TOKEN_FILE="${WORK}/no-token" \
        CS_PLAYERS="${STUBS}/cs-players" CS_MAINTENANCE_LOCK="${LOCK}" \
        CS_UPDATE_HEALTH_TRIES=1 CS_UPDATE_HEALTH_SLEEP=0 \
        CHANNEL="${CHANNEL:-main}" \
        bash "${ROOT}/ops/cs-server-update" "${extra[@]}" 2>&1)
    status=$?
    set -e
}

printf 'scoutzknivez 27015\n' > "${WORK}/units"
unit_file
CHANNEL=main PLAYER_MODE=ok FAIL_PULL=0 run_update --dry-run
[[ "${status}" -eq 0 ]] || fail "dry-run main: ${output}"
assert_contains "dry-run names the sha tag" "${output}" "sha-${SHORT}"
assert_contains "dry-run names the new digest" "${output}" "${NEW}"
assert_contains "dry-run does not apply" "${output}" "would set"
assert_not_contains "dry-run does not restart" "$(cat "${WORK}/systemctl.log")" "restart"
assert_eq "dry-run leaves the unit" "ghcr.io/kevintcoughlin/cs-server:old@${OLD}" \
    "$(sed -n 's/^Image=//p' "${QUAD}/scoutzknivez.container")"

unit_file "${NEW}"
run_update --dry-run
assert_contains "same digest is a no-op" "${output}" "already pinned to ${NEW}"

printf '{"check_runs":[{"name":"CI","status":"in_progress","conclusion":null}]}\n' > "${FIX}/checks.json"
printf '{"state":"pending","statuses":[{"state":"pending"}]}\n' > "${FIX}/status.json"
unit_file
run_update --dry-run
assert_contains "pending CI waits" "${output}" "still running"

printf '{"check_runs":[{"name":"CI","status":"completed","conclusion":"failure"}]}\n' > "${FIX}/checks.json"
printf '{"state":"failure","statuses":[{"state":"failure"}]}\n' > "${FIX}/status.json"
run_update --dry-run
assert_contains "failed CI does not roll" "${output}" "CI for ${SHORT} failed"

printf '{"sha":"%s","commit":{"message":"docs: note [skip deploy]"}}\n' "${REV}" > "${FIX}/commit.json"
printf '{"check_runs":[{"name":"CI","status":"completed","conclusion":"success"}]}\n' > "${FIX}/checks.json"
printf '{"state":"success","statuses":[{"state":"success"}]}\n' > "${FIX}/status.json"
run_update --dry-run
assert_contains "skip deploy is honored" "${output}" "marked manual"
assert_contains "skip deploy does not open an issue without a token" "${output}" "journal only"

printf '{"sha":"%s","commit":{"message":"feat: roll the servers"}}\n' "${REV}" > "${FIX}/commit.json"
CHANNEL=release
printf '{"tag_name":"v9.9.9","body":"This is BREAKING"}\n' > "${FIX}/release.json"
run_update --dry-run
assert_contains "breaking release is skipped" "${output}" "needs a human"

printf '{"tag_name":"v9.9.9","body":"Bug fixes only."}\n' > "${FIX}/release.json"
run_update --dry-run
assert_contains "release channel uses the version tag" "${output}" "cs-server:9.9.9@${NEW}"

CHANNEL=main PLAYER_MODE=busy
run_update --now
assert_contains "humans block a manual run" "${output}" "human player"
assert_not_contains "humans do not restart" "$(cat "${WORK}/systemctl.log")" "restart"

PLAYER_MODE=down
unit_file
run_update --now
[[ "${status}" -ne 0 ]] || fail "health failure should be non-zero: ${output}"
assert_contains "health failure rolls back" "${output}" "ROLLING BACK"
assert_contains "rollback is loud" "${output}" "ROLLBACK FAILED"
assert_eq "unit is restored" "ghcr.io/kevintcoughlin/cs-server:old@${OLD}" \
    "$(sed -n 's/^Image=//p' "${QUAD}/scoutzknivez.container")"
assert_contains "backup ran first" "$(cat "${WORK}/systemctl.log")" "start cs-server-backup.service"

PLAYER_MODE=ok
exec 8>>"${LOCK}"
/usr/bin/flock -n 8
run_update --now
/usr/bin/flock -u 8
exec 8>&-
assert_contains "shared lock skips the run" "${output}" "another maintenance job"
[[ "${status}" -eq 0 ]] || fail "lock contention should not fail the unit: ${output}"

printf 'cs-server-movement 27016 localhost/cs-server:movement-local\n' >> "${WORK}/units"
run_update --dry-run
assert_contains "local movement image is not rolled" "${output}" "local image"

if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar -- '*-*-* 04..07:15/20:00 America/Los_Angeles' >/dev/null
fi
assert_contains "workflow publishes the sha tag" \
    "$(sed -n '/tags: |/,/type=raw/p' "${ROOT}/.github/workflows/docker.yml")" \
    "type=sha,format=short,prefix=sha-"
assert_contains "workflow publishes the main branch tag" \
    "$(sed -n '/tags: |/,/type=raw/p' "${ROOT}/.github/workflows/docker.yml")" \
    "type=ref,event=branch"

printf 'update tests passed\n'
