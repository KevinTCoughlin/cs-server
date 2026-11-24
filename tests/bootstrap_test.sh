#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# ops/bootstrap-vps.sh --dry-run: the plan for Debian 13, Debian 12 and
# Ubuntu 24.04, with the host's package manager and sshd hidden. A dry run
# that exits 0 has not called apt-get or useradd (they are not on PATH).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}"

os_file() {
    local id="$1" version="$2" path="${WORK}/${1}-${2}"
    printf 'ID=%s\nVERSION_ID="%s"\n' "${id}" "${version}" > "${path}"
    printf '%s\n' "${path}"
}

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

BASH_BIN=$(command -v bash)
DEBIAN13=$(os_file debian 13)
DEBIAN12=$(os_file debian 12)
UBUNTU=$(os_file ubuntu 24.04)
UNKNOWN=$(os_file arch 1)
KEY_DIR="${WORK}/keys"
mkdir -p "${KEY_DIR}"
ssh-keygen -t ed25519 -f "${KEY_DIR}/id_ed25519" -N "" -q
KEY=$(cat "${KEY_DIR}/id_ed25519.pub")
SSH_KEYGEN=$(command -v ssh-keygen)
MKTEMP=$(command -v mktemp)

# PATH hides the host's sshd, ufw, podman and apt so the plan is the distro's.
run_boot() {
    local os="$1"
    shift
    set +e
    output=$(env -i PATH="/var/empty" CS_OS_RELEASE="${os}" CS_SSH_PORT=22 \
        "${BASH_BIN}" "${ROOT}/ops/bootstrap-vps.sh" "$@" 2>&1)
    status=$?
    set -e
}

run_boot "${DEBIAN13}" --help
expect_ok "--help"
assert_contains "--help mentions dry-run" "${output}" "--dry-run"
assert_contains "--help mentions the key flag" "${output}" "--ssh-key"

run_boot "${DEBIAN13}" --not-a-flag
expect_die "unknown option" "Unknown option"

run_boot "${DEBIAN13}" --user root --dry-run
expect_die "root is not a deploy user" "not root"

run_boot "${DEBIAN13}" --user BadName --dry-run
expect_die "uppercase user" "Invalid deploy user"

run_boot "${DEBIAN13}" --ssh-key $'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnlyForTheDryRun\nPermitRootLogin yes' --dry-run
expect_die "key with a newline" "single line"

run_boot "${UNKNOWN}" --user cstest193c --dry-run
expect_die "unsupported distro" "Debian 13"

run_boot "${DEBIAN13}" --user cstest193c --dry-run
expect_ok "debian 13 dry-run"
assert_contains "debian 13 user" "${output}" "Deploy user: cstest193c (will create)"
assert_contains "debian 13 engine" "${output}" "Engine: podman (Debian 13 ships Podman 5)"
assert_contains "debian 13 packages" "${output}" "podman uidmap"
assert_not_contains "debian 13 is not Docker" "${output}" "docker.io"
assert_contains "debian 13 leaves sshd" "${output}" "authentication unchanged"
assert_contains "debian 13 firewall" "${output}" "Firewall: nftables, SSH 22/tcp, game 27015/udp, query-flood unit"
assert_contains "debian 13 linger" "${output}" "Linger: loginctl enable-linger cstest193c"
assert_contains "debian 13 backups" "${output}" "Backups: on, daily, keep 14"
assert_contains "debian 13 install command" "${output}" "runuser -u cstest193c"
assert_contains "debian 13 pins the runtime" "${output}" "CS_RUNTIME=podman"
assert_contains "debian 13 turns backups on" "${output}" "CS_BACKUP=1"
assert_contains "debian 13 uses the checkout installer" "${output}" "${ROOT}/install.sh"
assert_contains "debian 13 changed nothing" "${output}" "Dry run: nothing was changed"
if id cstest193c >/dev/null 2>&1; then
    fail "dry-run created the deploy user"
fi

run_boot "${DEBIAN12}" --user cstest193c --dry-run
expect_ok "debian 12 dry-run"
assert_contains "debian 12 engine" "${output}" "Engine: docker (Debian 12's Podman is 4.3, older than Quadlet (4.4))"
assert_contains "debian 12 packages" "${output}" "docker.io"
assert_not_contains "debian 12 does not install podman" "${output}" "podman uidmap"

run_boot "${UBUNTU}" --user cstest193c --dry-run
expect_ok "ubuntu 24.04 dry-run"
assert_contains "ubuntu engine" "${output}" "Engine: podman (Ubuntu 24.04 ships Podman 4.9; health-gated auto-update rollback needs Podman 5)"
assert_contains "ubuntu packages" "${output}" "podman uidmap"

# ssh-keygen and mktemp, and nothing else the host firewall would add.
SSH_TOOLS="${WORK}/ssh-tools"
mkdir -p "${SSH_TOOLS}"
ln -s "${SSH_KEYGEN}" "${SSH_TOOLS}/ssh-keygen"
ln -s "${MKTEMP}" "${SSH_TOOLS}/mktemp"
ln -s "$(command -v chmod)" "${SSH_TOOLS}/chmod"
ln -s "$(command -v rm)" "${SSH_TOOLS}/rm"
output=$(env -i PATH="${SSH_TOOLS}" CS_OS_RELEASE="${DEBIAN13}" CS_SSH_PORT=22 \
    "${BASH_BIN}" "${ROOT}/ops/bootstrap-vps.sh" --user cstest193c --dry-run --ssh-key "${KEY}" 2>&1)
status=$?
expect_ok "dry-run with a real key"
assert_contains "a key does not harden ssh" "${output}" "authentication unchanged"
assert_not_contains "a key does not disable passwords" "${output}" "will disable root login"

printf '%s\n\n# comment\n%s extra\n' "${KEY}" "${KEY}" > "${WORK}/keyfile"
output=$(env -i PATH="${SSH_TOOLS}" CS_OS_RELEASE="${DEBIAN13}" CS_SSH_PORT=22 \
    "${BASH_BIN}" "${ROOT}/ops/bootstrap-vps.sh" --user cstest193c --dry-run --ssh-key-file "${WORK}/keyfile" 2>&1)
status=$?
expect_ok "key file"
assert_contains "key file leaves sshd" "${output}" "authentication unchanged"

output=$(env -i PATH="${SSH_TOOLS}" CS_OS_RELEASE="${DEBIAN13}" CS_SSH_PORT=22 \
    "${BASH_BIN}" "${ROOT}/ops/bootstrap-vps.sh" --user cstest193c --dry-run --ssh-key "ssh-ed25519 AAAA not-a-key" 2>&1) && status=0 || status=$?
if [[ "${status}" -eq 0 ]]; then
    fail "malformed key was accepted: ${output}"
fi
assert_contains "ssh-keygen rejects a bad key" "${output}" "ssh-keygen rejected it"

run_boot "${DEBIAN13}" --user cstest193c --harden-ssh --dry-run
expect_die "harden without a key" "no valid authorized key"

# A piped script has no checkout beside it. The printed command must be a
# path that a later shell can still run, not a temp file.
cp "${ROOT}/ops/bootstrap-vps.sh" "${WORK}/bootstrap-vps.sh"
output=$(env -i PATH="/var/empty" CS_OS_RELEASE="${DEBIAN13}" CS_SSH_PORT=22 \
    "${BASH_BIN}" "${WORK}/bootstrap-vps.sh" --user cstest193c --dry-run --no-install 2>&1)
status=$?
expect_ok "piped dry-run"
assert_contains "piped installer is persistent" "${output}" "/usr/local/lib/cs-server/install.sh"
assert_not_contains "piped installer is not a temp file" "${output}" "/tmp/"

run_boot "${DEBIAN13}" --user cstest193c --dry-run
# CS_BACKUP is in the environment of run_boot only if we pass it. The default
# inside the script is 1. Override by calling the script with the variable.
output=$(env -i PATH="/var/empty" CS_OS_RELEASE="${DEBIAN13}" CS_SSH_PORT=22 CS_BACKUP=0 \
    "${BASH_BIN}" "${ROOT}/ops/bootstrap-vps.sh" --user cstest193c --dry-run 2>&1)
assert_contains "CS_BACKUP=0" "${output}" "Backups: off (CS_BACKUP=0)"

output=$(env -i PATH="/var/empty" CS_OS_RELEASE="${DEBIAN13}" CS_SSH_PORT=22 CS_FASTDL=1 \
    "${BASH_BIN}" "${ROOT}/ops/bootstrap-vps.sh" --user cstest193c --dry-run 2>&1)
assert_contains "FastDL opens its port" "${output}" "fastdl 27080/tcp"

# firewalld that is already running wins over a ufw binary.
cat > "${STUBS}/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
    *firewalld*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "${STUBS}/ufw"
chmod +x "${STUBS}/systemctl" "${STUBS}/ufw"
output=$(env -i PATH="${STUBS}" CS_OS_RELEASE="${DEBIAN13}" CS_SSH_PORT=22 \
    "${BASH_BIN}" "${ROOT}/ops/bootstrap-vps.sh" --user cstest193c --dry-run 2>&1)
assert_contains "running firewalld is left in place" "${output}" "Firewall: firewalld, SSH 22/tcp"

# ufw, when firewalld is not running, is used instead of a second filter.
cat > "${STUBS}/systemctl" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${STUBS}/systemctl"
output=$(env -i PATH="${STUBS}" CS_OS_RELEASE="${UBUNTU}" CS_SSH_PORT=22 \
    "${BASH_BIN}" "${ROOT}/ops/bootstrap-vps.sh" --user cstest193c --dry-run 2>&1)
assert_contains "ufw is used when it is installed" "${output}" "Firewall: ufw, SSH 22/tcp"
assert_not_contains "ufw does not also install the drop policy" "${output}" "Firewall: nftables"

printf 'bootstrap tests passed\n'
