#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Real Docker restore: the archive is mode 0600 and owned by a non-root user,
# and a container running as UID 10001 cannot read that file from a bind
# mount. Restore streams it on stdin, and a bad archive leaves the volume
# byte-identical.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

if ! command -v docker >/dev/null 2>&1 || ! sudo docker info >/dev/null 2>&1; then
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        fail "docker is required in CI"
    fi
    printf 'backup docker tests skipped: docker is not available\n'
    exit 0
fi
command -v sudo >/dev/null 2>&1 || fail "sudo is required"
sudo -n true || fail "passwordless sudo is required"

USER_NAME="csbk126"
VOL="cs-server-state-dockertest"
STAGING="${VOL}-restore-staging"
WORK=$(mktemp -d)
chmod 755 "${WORK}"
PROOF="${WORK}/proof.tar.gz"

cleanup() {
    sudo docker volume rm -f "${VOL}" "${STAGING}" >/dev/null 2>&1 || true
    if id "${USER_NAME}" >/dev/null 2>&1; then
        sudo userdel -r "${USER_NAME}" >/dev/null 2>&1 || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

sudo docker pull busybox >/dev/null
if id "${USER_NAME}" >/dev/null 2>&1; then
    sudo userdel -r "${USER_NAME}" >/dev/null 2>&1 || true
fi
sudo useradd --create-home --shell /bin/bash "${USER_NAME}"
sudo usermod -aG docker "${USER_NAME}"
HOME_DIR=$(getent passwd "${USER_NAME}" | cut -d: -f6)
OWNER=$(id -u "${USER_NAME}")
sudo -u "${USER_NAME}" mkdir -p "${HOME_DIR}/backups"
# The checkout may not be traversable by another uid (GitHub's /home/runner is not).
sudo cp "${ROOT}/ops/backup-state.sh" "${HOME_DIR}/cs-server-backup"
sudo chown "${USER_NAME}" "${HOME_DIR}/cs-server-backup"
sudo chmod 755 "${HOME_DIR}/cs-server-backup"
SCRIPT="${HOME_DIR}/cs-server-backup"

sudo docker volume rm -f "${VOL}" >/dev/null 2>&1 || true
sudo docker volume create "${VOL}" >/dev/null
sudo docker run --rm -v "${VOL}:/data" busybox chmod 777 /data
sudo docker run --rm --user 10001 -v "${VOL}:/data" busybox \
    sh -c 'printf "%s\n" "secret-bytes" > /data/banned.cfg'

vol_sum() {
    sudo docker run --rm -v "${VOL}:/data:ro" busybox sha256sum /data/banned.cfg
}

original=$(vol_sum)
printf 'seeded volume checksum (uid 10001 file): %s\n' "${original}"

sudo -u "${USER_NAME}" env HOME="${HOME_DIR}" CS_RUNTIME=docker CS_SERVER_IMAGE=busybox \
    CS_STATE_VOLUME="${VOL}" CS_BACKUP_DIR="${HOME_DIR}/backups" \
    bash "${SCRIPT}"
archive=$(sudo find "${HOME_DIR}/backups" -maxdepth 1 -type f -name "${VOL}-*.tar.gz" | head -n 1)
[[ -n "${archive}" ]] || fail "no archive was written"
mode_owner=$(sudo stat -c '%u %a' "${archive}")
assert_eq "archive owner and mode" "${OWNER} 600" "${mode_owner}"
printf 'archive %s is uid %s mode 600\n' "${archive}" "${OWNER}"

# The bind-mounted file is unreadable by UID 10001. That is the bug streaming avoids.
sudo cp "${archive}" "${PROOF}"
sudo chown "${USER_NAME}" "${PROOF}"
sudo chmod 600 "${PROOF}"
if sudo docker run --rm --user 10001 -v "${PROOF}:/archive:ro" busybox cat /archive >/dev/null 2>&1; then
    fail "UID 10001 could read the mode-0600 archive through a bind mount"
fi
printf 'uid 10001 bind-mount read of the 0600 archive: denied\n'

sudo docker run --rm --user 10001 -v "${VOL}:/data" busybox \
    sh -c 'printf "%s\n" "replaced" > /data/banned.cfg'
changed=$(vol_sum)
printf 'checksum after clobber: %s\n' "${changed}"
[[ "${changed}" != "${original}" ]] || fail "clobber did not change the volume"

sudo -u "${USER_NAME}" env HOME="${HOME_DIR}" CS_RUNTIME=docker CS_SERVER_IMAGE=busybox \
    CS_STATE_VOLUME="${VOL}" CS_BACKUP_DIR="${HOME_DIR}/backups" \
    bash "${SCRIPT}" --restore "${archive}"
restored=$(vol_sum)
printf 'checksum after restore: %s\n' "${restored}"
assert_eq "restore puts the original bytes back" "${original}" "${restored}"
body=$(sudo docker run --rm -v "${VOL}:/data:ro" busybox cat /data/banned.cfg)
assert_eq "restored file text" "secret-bytes" "${body}"

# Malformed, then truncated. Each must leave the restored bytes in place.
bad_before=$(vol_sum)
bad_archive="${HOME_DIR}/cs-server-state-20200101T000000Z.tar.gz"
printf 'not an archive\n' | sudo -u "${USER_NAME}" tee "${bad_archive}" >/dev/null
set +e
bad_out=$(sudo -u "${USER_NAME}" env HOME="${HOME_DIR}" CS_RUNTIME=docker CS_SERVER_IMAGE=busybox \
    CS_STATE_VOLUME="${VOL}" \
    bash "${SCRIPT}" --restore "${bad_archive}" 2>&1)
bad_status=$?
set -e
[[ "${bad_status}" -ne 0 ]] || fail "malformed archive restore succeeded: ${bad_out}"
bad_after=$(vol_sum)
printf 'checksum before malformed restore: %s\n' "${bad_before}"
printf 'checksum after malformed restore:  %s\n' "${bad_after}"
assert_eq "malformed archive leaves the volume byte-identical" "${bad_before}" "${bad_after}"

trunc="${HOME_DIR}/cs-server-state-20200102T000000Z.tar.gz"
sudo -u "${USER_NAME}" cp "${archive}" "${trunc}"
sudo -u "${USER_NAME}" truncate -s 24 "${trunc}" || sudo -u "${USER_NAME}" sh -c "head -c 24 '${archive}' > '${trunc}'"
trunc_before=$(vol_sum)
set +e
trunc_out=$(sudo -u "${USER_NAME}" env HOME="${HOME_DIR}" CS_RUNTIME=docker CS_SERVER_IMAGE=busybox \
    CS_STATE_VOLUME="${VOL}" \
    bash "${SCRIPT}" --restore "${trunc}" 2>&1)
trunc_status=$?
set -e
[[ "${trunc_status}" -ne 0 ]] || fail "truncated archive restore succeeded: ${trunc_out}"
trunc_after=$(vol_sum)
printf 'checksum before truncated restore: %s\n' "${trunc_before}"
printf 'checksum after truncated restore:  %s\n' "${trunc_after}"
assert_eq "truncated archive leaves the volume byte-identical" "${trunc_before}" "${trunc_after}"

printf 'backup docker tests passed\n'
