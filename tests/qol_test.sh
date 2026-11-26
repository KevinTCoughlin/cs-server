#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# QoL files that do not need a live server: journald, the admin helper's
# motd, config-directory backup, and the monthly restore file check.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

assert_contains "journald is persistent" "$(cat "${ROOT}/ops/journald/50-cs-server.conf")" "Storage=persistent"
assert_contains "journald caps size" "$(cat "${ROOT}/ops/journald/50-cs-server.conf")" "SystemMaxUse=200M"
assert_contains "sshd is killed last" "$(cat "${ROOT}/ops/ssh/oom.conf")" "OOMScoreAdjust=-900"
assert_contains "swappiness is lowered" "$(cat "${ROOT}/ops/sysctl/60-cs-server.conf")" "vm.swappiness = 10"
assert_contains "health workflow reads the host variable" \
    "$(cat "${ROOT}/.github/workflows/server-health.yml")" 'vars.CS_HEALTH_HOST'
assert_contains "health workflow can list extra ports" \
    "$(cat "${ROOT}/.github/workflows/server-health.yml")" "CS_HEALTH_EXTRA_PORTS"
assert_contains "health workflow writes issues" \
    "$(cat "${ROOT}/.github/workflows/server-health.yml")" "issues: write"
assert_not_contains "health workflow pins no third-party action" \
    "$(cat "${ROOT}/.github/workflows/server-health.yml")" "uses:"

# motd skips a port nobody listens on and prints the map line.
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}" "${WORK}/quad" "${WORK}/backups" "${WORK}/home"
cat > "${STUBS}/ss" <<'EOF'
#!/bin/bash
query="${!#}"
port="${query##*:}"
[[ -f "${LISTEN}/${port}" ]] && printf 'UNCONN\n'
EOF
cat > "${STUBS}/cs-players" <<'EOF'
#!/bin/bash
printf 'humans=1 players=3 bots=2 map=scoutzknivez\n'
EOF
chmod +x "${STUBS}/ss" "${STUBS}/cs-players"
cat > "${WORK}/quad/scoutzknivez.container" <<'EOF'
[Container]
ContainerName=scoutzknivez
PublishPort=27015:27015/udp
EOF
touch "${LISTEN:-}" 2>/dev/null || true
mkdir -p "${WORK}/listen"
touch "${WORK}/listen/27015"
# A second unit with nothing listening is omitted.
cat > "${WORK}/quad/other.container" <<'EOF'
[Container]
ContainerName=other
PublishPort=27016:27016/udp
EOF
output=$(env -i PATH="${STUBS}:/usr/bin:/bin" HOME="${WORK}/home" \
    CS_ADMIN_HOME="${WORK}/home" CS_QUADLET_DIR="${WORK}/quad" \
    CS_PLAYERS="${STUBS}/cs-players" CS_BACKUP_DIR="${WORK}/backups" \
    CS_REBOOT_REQUIRED_FILE="${WORK}/no-reboot" LISTEN="${WORK}/listen" \
    bash "${ROOT}/ops/cs" motd 2>&1)
assert_contains "motd shows the map" "${output}" "map=scoutzknivez"
assert_contains "motd names the port" "${output}" "27015"
assert_not_contains "motd skips a closed port" "${output}" "27016"

help=$(env -i PATH="/usr/bin:/bin" HOME="${WORK}/home" bash "${ROOT}/ops/cs" help 2>&1)
assert_contains "help lists update" "${help}" "cs update"

# Config backup keeps server.cfg and drops offsite.env.
CFG="${WORK}/cfg"
BAK="${WORK}/bak"
mkdir -p "${CFG}/cs-server-movement" "${STUBS}"
printf 'hostname "movement"\n' > "${CFG}/cs-server-movement/server.cfg"
printf 'OFFSITE_SECRET_ACCESS_KEY=secret\n' > "${CFG}/cs-server-movement/offsite.env"
cat > "${STUBS}/podman" <<'EOF'
#!/bin/bash
if [[ "$1" == volume && "$2" == ls ]]; then
    exit 0
fi
exit 0
EOF
chmod +x "${STUBS}/podman"
env PATH="${STUBS}:/usr/bin:/bin" HOME="${WORK}/home" CS_CONFIG_ROOT="${CFG}" \
    CS_BACKUP_DIR="${BAK}" CS_RUNTIME=podman \
    bash "${ROOT}/ops/backup-state.sh" >/dev/null
archive=$(find "${BAK}" -maxdepth 1 -type f -name 'config-cs-server-movement-*.tar.gz' | head -1)
[[ -n "${archive}" ]] || fail "movement config was not archived"
listing=$(gzip -dc -- "${archive}" | tar -tf -)
assert_contains "config archive has server.cfg" "${listing}" "server.cfg"
assert_not_contains "config archive omits the off-site secret" "${listing}" "offsite.env"
printf 'OFFSITE_SECRET_ACCESS_KEY=keep-me\n' > "${CFG}/cs-server-movement/offsite.env"
env PATH="${STUBS}:/usr/bin:/bin" HOME="${WORK}/home" CS_CONFIG_ROOT="${CFG}" \
    CS_BACKUP_DIR="${BAK}" CS_RUNTIME=podman \
    bash "${ROOT}/ops/backup-state.sh" --restore "${archive}" >/dev/null
assert_eq "restore leaves the live secret" "OFFSITE_SECRET_ACCESS_KEY=keep-me" \
    "$(cat "${CFG}/cs-server-movement/offsite.env")"
assert_contains "restore puts server.cfg back" "$(cat "${CFG}/cs-server-movement/server.cfg")" "movement"

# Monthly restore: file checks, no engine.
SRC="${WORK}/vol"
mkdir -p "${SRC}/amxmodx" "${WORK}/rback"
printf 'ban\n' > "${SRC}/banned.cfg"
printf 'ip\n' > "${SRC}/listip.cfg"
printf 'admin\n' > "${SRC}/amxmodx/users.ini"
printf 'access\n' > "${SRC}/amxmodx/cmdaccess.ini"
tar -C "${SRC}" -czf "${WORK}/rback/cs-server-state-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" \
    banned.cfg listip.cfg amxmodx
mkdir -p "${WORK}/old"
printf 'old\n' > "${WORK}/old/banned.cfg"
tar -C "${WORK}/old" -czf "${WORK}/rback/cs-server-state-movement-20200101T000000Z.tar.gz" banned.cfg
touch -d '2020-01-01' "${WORK}/rback/cs-server-state-movement-20200101T000000Z.tar.gz"
cat > "${STUBS}/podman" <<'EOF'
#!/bin/bash
exit 0
EOF
out=$(env PATH="${STUBS}:/usr/bin:/bin" HOME="${WORK}/home" \
    CS_BACKUP_DIR="${WORK}/rback" CS_RESTORE_NO_ENGINE=1 \
    bash "${ROOT}/ops/cs-restore-test" 2>&1) || fail "restore file check: ${out}"
assert_contains "restore file check passes" "${out}" "RESULT: PASS"
assert_contains "stale extra archive is a warning" "${out}" "WARN:"

rm -f "${SRC}/amxmodx/users.ini"
rm -f "${WORK}/rback"/cs-server-state-2*.tar.gz
tar -C "${SRC}" -czf "${WORK}/rback/cs-server-state-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" \
    banned.cfg listip.cfg amxmodx
set +e
out=$(env PATH="${STUBS}:/usr/bin:/bin" HOME="${WORK}/home" \
    CS_BACKUP_DIR="${WORK}/rback" CS_RESTORE_NO_ENGINE=1 \
    bash "${ROOT}/ops/cs-restore-test" 2>&1)
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "missing users.ini should fail: ${out}"
assert_contains "missing admin file fails the check" "${out}" "users.ini missing"

game=$(sed -n 's/^Image=//p' "${ROOT}/quadlet/cs-server-movement.container")
side=$(sed -n 's/^Image=//p' "${ROOT}/quadlet/cs-fastdl-movement.container")
assert_eq "movement and its FastDL sidecar use one image" "${game}" "${side}"
[[ -n "${game}" ]] || fail "movement quadlet has no Image="
assert_contains "movement FastDL URL is a host placeholder" \
    "$(cat "${ROOT}/quadlet/cs-server-movement.container")" \
    "Environment=FASTDL_URL=http://HOST:27080/cstrike/"
assert_contains "sidecar publishes 27080" \
    "$(cat "${ROOT}/quadlet/cs-fastdl-movement.container")" "PublishPort=27080:27080/tcp"
assert_contains "sidecar is read-only" \
    "$(cat "${ROOT}/quadlet/cs-fastdl-movement.container")" "ReadOnly=true"
assert_contains "sidecar drops capabilities" \
    "$(cat "${ROOT}/quadlet/cs-fastdl-movement.container")" "DropCapability=ALL"
assert_contains "sidecar memory cap" \
    "$(cat "${ROOT}/quadlet/cs-fastdl-movement.container")" "MemoryMax=64M"
assert_contains "sidecar cpu cap" \
    "$(cat "${ROOT}/quadlet/cs-fastdl-movement.container")" "CPUQuota=50%"
assert_contains "sidecar health check" \
    "$(cat "${ROOT}/quadlet/cs-fastdl-movement.container")" "HealthCmd=/fastdl.sh check"

printf 'qol tests passed\n'
