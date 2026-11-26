#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# VPS hardening helpers: A2S human counts, the idle reboot decision, the
# off-site upload command, and the sshd drop-in that has to beat a later
# provider file. No server is installed.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
peer_pid=""
cleanup() {
    if [[ -n "${peer_pid}" ]]; then
        kill "${peer_pid}" 2>/dev/null || true
        wait "${peer_pid}" 2>/dev/null || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

# --- Checked-in files -------------------------------------------------------

dropin=$(cat "${ROOT}/ops/ssh/00-cs-server.conf")
assert_contains "drop-in is named for first match" "${dropin}" "Named 00-"
assert_contains "drop-in keeps root keys" "${dropin}" "PermitRootLogin prohibit-password"
assert_contains "drop-in turns passwords off" "${dropin}" "PasswordAuthentication no"
assert_contains "drop-in turns keyboard-interactive off" "${dropin}" "KbdInteractiveAuthentication no"
assert_contains "drop-in limits auth tries" "${dropin}" "MaxAuthTries 3"
assert_contains "drop-in shortens the grace time" "${dropin}" "LoginGraceTime 30"
assert_contains "drop-in turns X11 off" "${dropin}" "X11Forwarding no"
assert_contains "drop-in turns agent forwarding off" "${dropin}" "AllowAgentForwarding no"
assert_not_contains "bootstrap no longer installs a 99- drop-in" \
    "$(grep -n 'sshd_config.d/99-cs-server.conf' "${ROOT}/ops/bootstrap-vps.sh" || true)" \
    "cat > "

sysctl=$(cat "${ROOT}/ops/sysctl/61-cs-hardening.conf")
assert_contains "sysctl drops redirects" "${sysctl}" "net.ipv4.conf.all.send_redirects = 0"
assert_contains "sysctl drops ipv6 redirects" "${sysctl}" "net.ipv6.conf.default.accept_redirects = 0"
assert_contains "sysctl drops source routing" "${sysctl}" "net.ipv4.conf.default.accept_source_route = 0"
assert_contains "sysctl sets ptrace scope" "${sysctl}" "kernel.yama.ptrace_scope = 1"
assert_contains "sysctl hardens bpf jit" "${sysctl}" "net.core.bpf_jit_harden = 2"
if grep -Eq '^[[:space:]]*[^#].*accept_ra' "${ROOT}/ops/sysctl/61-cs-hardening.conf"; then
    fail "sysctl sets accept_ra"
fi

apt=$(cat "${ROOT}/ops/apt/52unattended-upgrades-local")
assert_contains "unattended upgrades do not reboot" "${apt}" 'Unattended-Upgrade::Automatic-Reboot "false";'
assert_contains "unattended upgrades remove unused packages" "${apt}" 'Unattended-Upgrade::Remove-Unused-Dependencies "true";'

timer=$(cat "${ROOT}/ops/systemd/cs-reboot-if-idle.timer")
assert_contains "idle reboot window" "${timer}" "OnCalendar=*-*-* 04..07:05/20:00 America/Los_Angeles"
assert_contains "idle reboot is not persistent" "${timer}" "Persistent=false"
assert_contains "idle reboot delay" "${timer}" "RandomizedDelaySec=60"
service=$(cat "${ROOT}/ops/systemd/cs-reboot-if-idle.service")
assert_contains "idle reboot reads the port file" "${service}" "EnvironmentFile=-/etc/cs-server/reboot.env"
assert_contains "idle reboot runs the script" "${service}" "ExecStart=/usr/local/sbin/cs-reboot-if-idle"
assert_contains "offsite hook runs after the backup" "$(cat "${ROOT}/ops/systemd/offsite.conf")" \
    "ExecStartPost=%h/.local/bin/cs-server-offsite"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar -- '*-*-* 04..07:05/20:00 America/Los_Angeles' >/dev/null
fi

# --- cs-players -------------------------------------------------------------

PLAYERS="${ROOT}/ops/cs-players"
python3 -m py_compile "${PLAYERS}"

source_info() {
    local players="$1" bots="$2" max="${3:-32}"
    {
        printf '\377\377\377\377I'
        printf '\030'
        printf '%s\000%s\000%s\000%s\000' "Test" "de_dust2" "cstrike" "Counter-Strike"
        printf '\012\000'
        printf '%b' "\\$(printf '%03o' "${players}")"
        printf '%b' "\\$(printf '%03o' "${max}")"
        printf '%b' "\\$(printf '%03o' "${bots}")"
        printf 'dln1.1.2.7\000'
    }
}

# GoldSrc 'm' reply: five strings, then players, max, protocol, type, os,
# password, mod=0, secure, bots.
goldsrc_info() {
    local players="$1" bots="$2"
    {
        printf '\377\377\377\377m'
        printf '%s\000%s\000%s\000%s\000%s\000' "192.0.2.10:27015" "Test" "de_dust2" "cstrike" "Counter-Strike"
        printf '%b' "\\$(printf '%03o' "${players}")" # players
        printf '\040' # max
        printf '\060' # protocol
        printf 'd'    # dedicated
        printf 'l'    # linux
        printf '\000' # no password
        printf '\000' # not a mod
        printf '\001' # secure
        printf '%b' "\\$(printf '%03o' "${bots}")"
    }
}

cat > "${WORK}/peer.py" <<'PY'
import socket
import sys

port_file, pkt, mode = sys.argv[1], sys.argv[2], sys.argv[3]
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 0))
with open(port_file, "w", encoding="ascii") as handle:
    handle.write(str(sock.getsockname()[1]))
payload = open(pkt, "rb").read()
data, addr = sock.recvfrom(4096)
if mode == "challenge":
    sock.sendto(b"\xff\xff\xff\xffA" + b"\x01\x02\x03\x04", addr)
    data, addr = sock.recvfrom(4096)
    if not data.endswith(b"\x01\x02\x03\x04"):
        sock.sendto(b"bad-challenge", addr)
        raise SystemExit(0)
sock.sendto(payload, addr)
PY

start_peer() {
    local pkt="$1" mode="$2" i=0
    rm -f "${WORK}/peer.port"
    python3 "${WORK}/peer.py" "${WORK}/peer.port" "${pkt}" "${mode}" &
    peer_pid=$!
    while [[ ! -s "${WORK}/peer.port" && "${i}" -lt 50 ]]; do
        sleep 0.05
        i=$((i + 1))
    done
    [[ -s "${WORK}/peer.port" ]] || fail "A2S peer did not bind"
}

stop_peer() {
    if [[ -n "${peer_pid}" ]]; then
        kill "${peer_pid}" 2>/dev/null || true
        wait "${peer_pid}" 2>/dev/null || true
        peer_pid=""
    fi
}

ask_players() {
    local port="$1"
    set +e
    output=$(python3 "${PLAYERS}" 127.0.0.1 "${port}" 2>"${WORK}/players.err")
    status=$?
    set -e
}

source_info 6 4 > "${WORK}/humans.pkt"
start_peer "${WORK}/humans.pkt" info
ask_players "$(cat "${WORK}/peer.port")"
stop_peer
[[ "${status}" -eq 0 ]] || fail "source info: ${output} $(cat "${WORK}/players.err")"
assert_eq "source humans are players minus bots" "humans=2 players=6 bots=4 map=de_dust2" "${output}"

source_info 8 8 > "${WORK}/bots.pkt"
start_peer "${WORK}/bots.pkt" info
ask_players "$(cat "${WORK}/peer.port")"
stop_peer
assert_eq "source bots only" "humans=0 players=8 bots=8 map=de_dust2" "${output}"

goldsrc_info 5 1 > "${WORK}/gold.pkt"
start_peer "${WORK}/gold.pkt" info
ask_players "$(cat "${WORK}/peer.port")"
stop_peer
[[ "${status}" -eq 0 ]] || fail "goldsrc info: ${output} $(cat "${WORK}/players.err")"
assert_eq "goldsrc humans" "humans=4 players=5 bots=1 map=de_dust2" "${output}"

source_info 3 1 > "${WORK}/challenge.pkt"
start_peer "${WORK}/challenge.pkt" challenge
ask_players "$(cat "${WORK}/peer.port")"
stop_peer
[[ "${status}" -eq 0 ]] || fail "challenge info: ${output} $(cat "${WORK}/players.err")"
assert_eq "challenge then info" "humans=2 players=3 bots=1 map=de_dust2" "${output}"

ask_players 1
[[ "${status}" -eq 2 ]] || fail "closed port should be unknown, got ${status}: ${output}"
assert_contains "closed port says unknown" "$(cat "${WORK}/players.err")" "unknown"

# --- Idle reboot ------------------------------------------------------------

REBOOT="${ROOT}/ops/cs-reboot-if-idle"
STUBS="${WORK}/stubs"
mkdir -p "${STUBS}" "${WORK}/listen" "${WORK}/answers"
cat > "${STUBS}/ss" <<'EOF'
#!/bin/bash
# The reboot script passes one filter argument: sport = :<port>
query="${!#}"
port="${query##*:}"
if [[ -f "${LISTEN_DIR}/${port}" ]]; then
    printf 'UNCONN 0 0 0.0.0.0:%s\n' "${port}"
fi
EOF
cat > "${STUBS}/cs-players" <<'EOF'
#!/bin/bash
port="$2"
if [[ -f "${ANSWER_DIR}/${port}.unknown" ]]; then
    printf 'unknown (timeout)\n' >&2
    exit 2
fi
if [[ ! -f "${ANSWER_DIR}/${port}" ]]; then
    printf 'unknown (no answer)\n' >&2
    exit 2
fi
cat "${ANSWER_DIR}/${port}"
EOF
cat > "${STUBS}/who" <<'EOF'
#!/bin/bash
if [[ -f "${WHO_FILE}" ]]; then
    cat "${WHO_FILE}"
fi
EOF
cat > "${STUBS}/logger" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "${STUBS}/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${REBOOT_CALLS}"
EOF
chmod +x "${STUBS}/"*

reboot_case() {
    local extra="${1:-}"
    shift || true
    rm -f "${WORK}/reboot.out" "${WORK}/calls"
    : > "${WORK}/calls"
    set +e
    # shellcheck disable=SC2086 # optional extra env words are separate assignments
    output=$(env -i PATH="${STUBS}:/usr/bin:/bin" HOME="${WORK}" \
        LISTEN_DIR="${WORK}/listen" ANSWER_DIR="${WORK}/answers" \
        WHO_FILE="${WORK}/who.txt" REBOOT_CALLS="${WORK}/calls" \
        CS_PLAYERS="${STUBS}/cs-players" \
        CS_REBOOT_REQUIRED_FILE="${WORK}/reboot-required" \
        ${extra} \
        bash "${REBOOT}" "$@" 2>&1)
    status=$?
    set -e
}

rm -rf "${WORK}/listen" "${WORK}/answers"
mkdir -p "${WORK}/listen" "${WORK}/answers"
reboot_case
assert_eq "no stamp" 0 "${status}"
assert_contains "no stamp says so" "${output}" "no reboot required"
assert_eq "no stamp does not reboot" "" "$(cat "${WORK}/calls")"

touch "${WORK}/reboot-required"
printf 'humans=0 players=0 bots=0\n' > "${WORK}/answers/27015"
touch "${WORK}/listen/27015"
reboot_case "" --dry-run
assert_contains "listening empty server would reboot" "${output}" "would reboot (dry run)"
assert_eq "dry run does not reboot" "" "$(cat "${WORK}/calls")"

printf 'humans=2 players=4 bots=2\n' > "${WORK}/answers/27015"
reboot_case "" --dry-run
assert_contains "humans block the reboot" "${output}" "port 27015: 2 human player(s); not rebooting"

touch "${WORK}/listen/27016"
printf 'unknown\n' > "${WORK}/answers/27016.unknown"
printf 'humans=0 players=8 bots=8\n' > "${WORK}/answers/27015"
reboot_case "" --dry-run
assert_contains "a silent listener blocks the reboot" "${output}" "port 27016: player count unknown"
assert_not_contains "a silent listener is not a reboot" "${output}" "would reboot"

rm -f "${WORK}/answers/27016.unknown" "${WORK}/listen/27016"
printf 'root     pts/0        2026-11-26 07:30\n' > "${WORK}/who.txt"
reboot_case "" --dry-run
assert_contains "an ssh session blocks the reboot" "${output}" "interactive session(s) logged in"
rm -f "${WORK}/who.txt" "${WORK}/reboot-required"

# No stamp, but the test flag says a reboot is pending. 27015 is empty.
reboot_case "CS_REBOOT_ASSUME_REQUIRED=1" --dry-run
assert_contains "assume-required still checks players" "${output}" "would reboot (dry run)"

touch "${WORK}/reboot-required"
reboot_case
assert_eq "idle reboot exits 0" 0 "${status}"
assert_contains "idle reboot asks systemd" "$(cat "${WORK}/calls")" "reboot"
assert_contains "idle reboot says it is rebooting" "${output}" "rebooting"

# A port that is not listening does not have to answer.
rm "${WORK}/listen/27015"
printf 'humans=9 players=9 bots=0\n' > "${WORK}/answers/27015"
reboot_case "CS_REBOOT_PORTS=27015" --dry-run
assert_contains "a closed port is ignored" "${output}" "would reboot (dry run)"

# --- Off-site backup --------------------------------------------------------

OFFSITE="${ROOT}/ops/cs-server-offsite"
mkdir -p "${WORK}/backups" "${WORK}/remote" "${WORK}/config"
printf 'x' > "${WORK}/backups/cs-server-state-new.tar.gz"
cat > "${STUBS}/rclone" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${RCLONE_CALLS}"
case "$1" in
    copy|delete) exit 0 ;;
    ls) printf '12 kept.tar.gz\n' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "${STUBS}/rclone"

offsite_case() {
    local env_file="${1:-}"
    shift || true
    : > "${WORK}/rclone.calls"
    set +e
    output=$(env -i PATH="${STUBS}:${PATH}" HOME="${WORK}/home-off" \
        CS_BACKUP_DIR="${WORK}/backups" CS_OFFSITE_ENV="${env_file}" \
        RCLONE_CALLS="${WORK}/rclone.calls" \
        "$@" \
        bash "${OFFSITE}" 2>&1)
    status=$?
    set -e
}
mkdir -p "${WORK}/home-off"

offsite_case "${WORK}/missing.env"
[[ "${status}" -ne 0 ]] || fail "missing credentials succeeded: ${output}"
assert_contains "missing credentials" "${output}" "not found"

printf 'OFFSITE_ENDPOINT=https://example.r2.cloudflarestorage.com\nOFFSITE_BUCKET=cs-server-backups\nOFFSITE_ACCESS_KEY_ID=test-key\nOFFSITE_SECRET_ACCESS_KEY=test-secret\n' \
    > "${WORK}/config/offsite.env"
chmod 644 "${WORK}/config/offsite.env"
offsite_case "${WORK}/config/offsite.env"
[[ "${status}" -ne 0 ]] || fail "mode 644 credentials succeeded: ${output}"
assert_contains "mode 644 is rejected" "${output}" "must be mode 600"

chmod 600 "${WORK}/config/offsite.env"
offsite_case "${WORK}/config/offsite.env"
[[ "${status}" -eq 0 ]] || fail "mode 600 credentials: ${output}"
calls=$(cat "${WORK}/rclone.calls")
assert_contains "upload keeps a one-day margin" "${calls}" "copy ${WORK}/backups offsite:cs-server-backups"
assert_contains "upload age is keep-days plus one" "${calls}" "--max-age 15d"
assert_contains "prune uses keep-days" "${calls}" "delete offsite:cs-server-backups"
assert_contains "prune min-age" "${calls}" "--min-age 14d"
assert_contains "lists the remote" "${calls}" "ls offsite:cs-server-backups"
assert_contains "rclone sees the endpoint" "${output}" "offsite: remote now holds:"
# The secret must not be echoed by the script itself.
assert_not_contains "secret stays out of the log" "${output}" "test-secret"

offsite_case "" CS_OFFSITE_REMOTE="${WORK}/remote"
[[ "${status}" -eq 0 ]] || fail "local remote: ${output}"
assert_contains "local remote is the destination" "$(cat "${WORK}/rclone.calls")" "copy ${WORK}/backups ${WORK}/remote"

# --- sshd first match -------------------------------------------------------

if ! command -v sshd >/dev/null 2>&1 || ! sudo -n true >/dev/null 2>&1; then
    printf 'sshd first-match check skipped (sshd or sudo unavailable)\n'
else
    sudo -n mkdir -p /run/sshd
    sudo -n chmod 755 /run/sshd
    sshd_work="${WORK}/sshd"
    mkdir -p "${sshd_work}/sshd_config.d"
    ssh-keygen -q -t ed25519 -f "${sshd_work}/host_ed25519" -N ""
    cat > "${sshd_work}/sshd_config" <<EOF
Include ${sshd_work}/sshd_config.d/*.conf
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
X11Forwarding yes
AllowAgentForwarding yes
MaxAuthTries 6
LoginGraceTime 120
PermitEmptyPasswords yes
PubkeyAuthentication no
Port 22
HostKey ${sshd_work}/host_ed25519
PidFile ${sshd_work}/sshd.pid
UsePAM no
EOF
    cat > "${sshd_work}/sshd_config.d/99-ctrl.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
    cp "${ROOT}/ops/ssh/00-cs-server.conf" "${sshd_work}/sshd_config.d/00-cs-server.conf"
    effective=$(sudo -n sshd -T -f "${sshd_work}/sshd_config")
    assert_contains "effective root login is key only" "${effective}" "permitrootlogin without-password"
    assert_contains "effective passwords are off" "${effective}" "passwordauthentication no"
    assert_contains "effective keyboard-interactive is off" "${effective}" "kbdinteractiveauthentication no"
    assert_contains "effective x11 is off" "${effective}" "x11forwarding no"
    assert_contains "effective agent forwarding is off" "${effective}" "allowagentforwarding no"
    assert_contains "effective auth tries" "${effective}" "maxauthtries 3"
    assert_contains "effective grace time" "${effective}" "logingracetime 30"
    assert_contains "effective empty passwords" "${effective}" "permitemptypasswords no"
    assert_contains "effective pubkey" "${effective}" "pubkeyauthentication yes"
fi

printf 'vps hardening tests passed\n'
