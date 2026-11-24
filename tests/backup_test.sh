#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# ops/backup-state.sh against a stubbed podman: it archives cs-server-state*,
# rotates old copies, and restores one archive onto the volume.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
VOLUME="${WORK}/volumes/cs-server-state/_data"
BACKUPS="${WORK}/backups"
mkdir -p "${STUBS}" "${VOLUME}"
printf 'banned\n' > "${VOLUME}/banned.cfg"

cat > "${STUBS}/podman" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${CALLS}"
cmd="$1"
shift
case "${cmd}" in
    volume)
        sub="$1"
        shift
        case "${sub}" in
            ls)
                printf '%s\n' "cs-server-state" "other-volume" "cs-server-state-lan1" \
                    "dod-server-state" "dod-server-two-state"
                ;;
            export)
                tar -C "${FAKE_VOLUME}" -cf - .
                ;;
            inspect)
                printf '%s\n' "${FAKE_VOLUME}"
                ;;
            create | rm)
                exit 0
                ;;
            import)
                tar -C "${FAKE_VOLUME}" -xf "$2"
                ;;
        esac
        ;;
    run)
        # A streamed extract that fails must not be treated as success.
        exit 1
        ;;
    unshare)
        "$@"
        ;;
    ps)
        if [[ "${FAKE_RUNNING:-0}" == "1" ]]; then
            printf '%s\n' abc
        fi
        ;;
    inspect)
        if [[ "${FAKE_RUNNING:-0}" == "1" ]]; then
            printf '%s\n' true
        else
            printf '%s\n' false
        fi
        ;;
esac
EOF
chmod +x "${STUBS}/podman"

expect_ok() {
    if [[ "${status}" -ne 0 ]]; then
        fail "$1: expected success, got ${status}: ${output}"
    fi
}

expect_die() {
    if [[ "${status}" -eq 0 ]]; then
        fail "$1: expected a failure, but it succeeded: ${output}"
    fi
    assert_contains "$1" "${output}" "$2"
}

run_backup() {
    set +e
    output=$(env PATH="${STUBS}:${PATH}" CALLS="${WORK}/calls" FAKE_VOLUME="${VOLUME}" \
        CS_BACKUP_DIR="${BACKUPS}" CS_RUNTIME=podman \
        bash "${ROOT}/ops/backup-state.sh" "$@" 2>&1)
    status=$?
    set -e
}

run_backup --help
expect_ok "--help"
assert_contains "--help mentions restore" "${output}" "--restore"

: > "${WORK}/calls"
run_backup
expect_ok "backup"
[[ -d "${BACKUPS}" ]] || fail "backup directory was not created"
assert_eq "backup directory is private" "700" "$(mode_of "${BACKUPS}")"
maps=$(find "${BACKUPS}" -maxdepth 1 -type f -name 'cs-server-state-[0-9]*T*Z.tar.gz' | wc -l | tr -d ' ')
assert_eq "default volume was archived" "1" "${maps}"
maps=$(find "${BACKUPS}" -maxdepth 1 -type f -name 'cs-server-state-lan1-*.tar.gz' | wc -l | tr -d ' ')
assert_eq "instance volume was archived" "1" "${maps}"
maps=$(find "${BACKUPS}" -maxdepth 1 -type f -name 'dod-server-state-[0-9]*T*Z.tar.gz' | wc -l | tr -d ' ')
assert_eq "Day of Defeat volume was archived" "1" "${maps}"
maps=$(find "${BACKUPS}" -maxdepth 1 -type f -name 'dod-server-two-state-*.tar.gz' | wc -l | tr -d ' ')
assert_eq "Day of Defeat instance volume was archived" "1" "${maps}"
if find "${BACKUPS}" -maxdepth 1 -type f -name 'other-volume-*' | grep -q .; then
    fail "an unrelated volume was archived"
fi
archive=$(find "${BACKUPS}" -maxdepth 1 -type f -name 'cs-server-state-[0-9]*T*Z.tar.gz' | head -n 1)
assert_eq "archive is private" "600" "$(mode_of "${archive}")"
gzip -t -- "${archive}" || fail "archive is not gzip"
listing=$(gzip -dc -- "${archive}" | tar -tf -)
assert_contains "archive contains banned.cfg" "${listing}" "banned.cfg"

# Older than the new archive, so rotation drops the earliest names.
rm -rf "${BACKUPS}"
mkdir -p "${BACKUPS}"
for i in 1 2 3 4 5; do
    printf 'old\n' | gzip -c > "${BACKUPS}/cs-server-state-2020010${i}T000000Z.tar.gz"
done
env PATH="${STUBS}:${PATH}" CALLS="${WORK}/calls" FAKE_VOLUME="${VOLUME}" \
    CS_BACKUP_DIR="${BACKUPS}" CS_RUNTIME=podman CS_BACKUP_KEEP=3 \
    bash "${ROOT}/ops/backup-state.sh" >/dev/null
kept=$(find "${BACKUPS}" -maxdepth 1 -type f -name 'cs-server-state-[0-9]*.tar.gz' ! -name 'cs-server-state-lan1-*' | wc -l | tr -d ' ')
assert_eq "rotation keeps 3 copies of the default volume" "3" "${kept}"
if [[ -f "${BACKUPS}/cs-server-state-20200101T000000Z.tar.gz" ]]; then
    fail "the oldest archive was kept"
fi

# A bad archive must not replace the live bytes. The stubbed engine refuses
# the extract; gzip rejects the file before that when it is not gzip at all.
printf 'changed\n' > "${VOLUME}/banned.cfg"
before=$(sha256sum "${VOLUME}/banned.cfg")
printf 'this is not gzip\n' > "${WORK}/cs-server-state-20200102T000000Z.tar.gz"
run_backup --restore "${WORK}/cs-server-state-20200102T000000Z.tar.gz"
expect_die "malformed archive" "not changed"
assert_eq "malformed archive leaves the volume" "changed" "$(cat "${VOLUME}/banned.cfg")"
# Valid gzip framing around a truncated tar payload.
printf 'banned\n' | gzip -c | head -c 12 > "${WORK}/cs-server-state-20200103T000000Z.tar.gz" || true
run_backup --restore "${WORK}/cs-server-state-20200103T000000Z.tar.gz"
expect_die "truncated archive" "not changed"
assert_eq "truncated archive leaves the volume" "changed" "$(cat "${VOLUME}/banned.cfg")"
after=$(sha256sum "${VOLUME}/banned.cfg")
assert_eq "failed restores keep the same checksum" "${before}" "${after}"
printf 'volume checksum before and after a bad restore: %s\n' "${before}"

run_backup --restore "${WORK}/no-such.tar.gz"
expect_die "missing archive" "Usage:"

output=$(env PATH="${STUBS}:${PATH}" CALLS="${WORK}/calls" FAKE_VOLUME="${VOLUME}" \
    FAKE_RUNNING=1 CS_BACKUP_DIR="${BACKUPS}" CS_RUNTIME=podman \
    bash "${ROOT}/ops/backup-state.sh" --restore "${WORK}/cs-server-state-20200102T000000Z.tar.gz" 2>&1) && status=0 || status=$?
if [[ "${status}" -eq 0 ]]; then
    fail "restore while the server is running should fail: ${output}"
fi
assert_contains "running server blocks restore" "${output}" "Stop the server"

env PATH="${STUBS}:${PATH}" CS_BACKUP_KEEP=0 CS_RUNTIME=podman \
    bash "${ROOT}/ops/backup-state.sh" >/dev/null 2>&1 && status=0 || status=$?
if [[ "${status}" -eq 0 ]]; then
    fail "CS_BACKUP_KEEP=0 should fail"
fi

# Docker hosts the game, and Podman is also on PATH. CS_RUNTIME must win.
BOTH="${WORK}/both"
mkdir -p "${BOTH}" "${WORK}/both-vol/volumes/cs-server-state/_data"
cat > "${BOTH}/podman" <<'EOF'
#!/bin/bash
printf 'podman %s\n' "$*" >> "${CALLS}"
if [[ "$1" == volume && "$2" == ls ]]; then
    printf 'cs-server-state\n'
fi
EOF
cat > "${BOTH}/docker" <<'EOF'
#!/bin/bash
printf 'docker %s\n' "$*" >> "${CALLS}"
if [[ "$1" == volume && "$2" == ls ]]; then
    printf 'cs-server-state\n'
fi
if [[ "$1" == volume && "$2" == export ]]; then
    tar -C "${FAKE_VOLUME}" -cf - .
fi
EOF
chmod +x "${BOTH}/podman" "${BOTH}/docker"
: > "${WORK}/both-calls"
env PATH="${BOTH}:${PATH}" CALLS="${WORK}/both-calls" FAKE_VOLUME="${WORK}/both-vol/volumes/cs-server-state/_data" \
    CS_BACKUP_DIR="${WORK}/both-backups" CS_RUNTIME=docker CS_SERVER_IMAGE=busybox \
    bash "${ROOT}/ops/backup-state.sh" >/dev/null
both_log=$(cat "${WORK}/both-calls")
assert_contains "docker is used when both engines exist" "${both_log}" "docker volume ls"
assert_not_contains "podman is not used when CS_RUNTIME=docker" "${both_log}" "podman "

printf 'backup tests passed\n'
