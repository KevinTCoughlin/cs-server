#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# ops/firewall/cs-server.nft: loads (twice, it replaces itself), drops a
# burst of query packets from one source and leaves in-game packets alone.
#
# Runs in a private network namespace, so it touches no host rule: an
# unprivileged one (unshare -rn) where the host allows it, otherwise one made
# with passwordless sudo. Skips when nft, unshare or python3 is missing or
# neither kind of namespace is available.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RULES="${ROOT}/ops/firewall/cs-server.nft"

skip() {
    printf 'firewall tests skipped: %s\n' "$1"
    exit 0
}

if [[ "${1:-}" != "--inside" ]]; then
    for tool in nft unshare python3; do
        command -v "${tool}" >/dev/null 2>&1 || skip "${tool} not installed"
    done
    if unshare -rn nft list tables >/dev/null 2>&1; then
        exec unshare -rn bash "${BASH_SOURCE[0]}" --inside
    fi
    # Hosts that forbid unprivileged namespaces (GitHub's runners): a root
    # network namespace, when sudo needs no password.
    if sudo -n true 2>/dev/null; then
        exec sudo -n env "PATH=${PATH}" unshare -n bash "${BASH_SOURCE[0]}" --inside
    fi
    skip "no network namespace available (unprivileged namespaces are off and sudo needs a password)"
fi

# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

nft -f "${RULES}" || fail "the rules do not load"
nft -f "${RULES}" || fail "the rules do not load a second time (they must replace themselves)"
listing=$(nft list table inet cs_server)
assert_contains "hooks before NAT" "${listing}" "hook prerouting priority raw"
assert_contains "limits per source address" "${listing}" "ip saddr limit rate over 10/second burst 20 packets"

# 200 query packets and 200 in-game packets from one address, as fast as they
# go, to a listener on the game port. Prints "<queries> <game>" received.
counts=$(python3 -I - <<'PY'
import socket, subprocess, time
subprocess.run(["ip", "link", "set", "lo", "up"], check=False)
server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
server.bind(("127.0.0.1", 27015))
server.settimeout(0.5)
client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for _ in range(200):
    client.sendto(b"\xff\xff\xff\xffTSource Engine Query\x00", ("127.0.0.1", 27015))
    client.sendto(b"\x01\x00\x00\x80game", ("127.0.0.1", 27015))
queries = game = 0
try:
    while True:
        data, _ = server.recvfrom(64)
        if data.startswith(b"\xff\xff\xff\xff"):
            queries += 1
        else:
            game += 1
except socket.timeout:
    pass
print(queries, game)
PY
)
queries="${counts% *}"
game="${counts#* }"
assert_eq "in-game packets are never dropped" 200 "${game}"
if [[ "${queries}" -lt 1 || "${queries}" -gt 40 ]]; then
    fail "expected the burst of 200 queries to be cut to about 20, ${queries} got through"
fi
dropped=$(nft list table inet cs_server | sed -n 's/.*counter packets \([0-9]*\).*/\1/p')
assert_eq "the counter shows what was dropped" "$((200 - queries))" "${dropped}"

nft delete table inet cs_server || fail "the table cannot be removed"

# The VPS input policy: its own table, default drop, SSH and the game port.
INPUT="${ROOT}/ops/firewall/cs-server-input.nft"
nft -f "${INPUT}" || fail "the input rules do not load"
nft -f "${INPUT}" || fail "the input rules do not load a second time"
listing=$(nft list table inet cs_server_input)
assert_contains "input policy drops" "${listing}" "policy drop"
assert_contains "loopback is accepted" "${listing}" "iif \"lo\" accept"
assert_contains "ssh is allowed" "${listing}" "tcp dport 22"
assert_contains "the game port is allowed" "${listing}" "27015"
assert_contains "the movement port is allowed" "${listing}" "27016"
assert_contains "fastdl uses add on the dynamic sets" "${listing}" "add @fastdl_new"
assert_contains "fastdl new connections are limited per source" "${listing}" "limit rate over 40/second burst 80 packets"
assert_contains "fastdl concurrency is limited per source" "${listing}" "ct count over 60"
assert_contains "fastdl port is accepted after the limits" "${listing}" "tcp dport 27080 accept"
nft delete table inet cs_server_input || fail "the input table cannot be removed"

# Bootstrap rewrites `define game_port` into a set when Day of Defeat is
# installed beside Counter-Strike. The same rule must still load.
both=$(mktemp)
awk -v game="{ 27015, 27016 }" '
    /^define game_port/ { print "define game_port = " game; next }
    { print }
' "${RULES}" > "${both}"
nft -f "${both}" || fail "a two-port query rule does not load"
listing=$(nft list table inet cs_server)
assert_contains "both game ports are limited" "${listing}" "27016"
nft delete table inet cs_server
awk -v game="{ 27015, 27016 }" '
    /^define game_port/ { print "define game_port = " game; next }
    { print }
' "${INPUT}" > "${both}"
nft -f "${both}" || fail "a two-port input rule does not load"
listing=$(nft list table inet cs_server_input)
assert_contains "27016 is allowed" "${listing}" "27016"
nft delete table inet cs_server_input
rm -f "${both}"

# Bootstrap keeps the three FastDL rules when CS_FASTDL=1 and deletes them
# otherwise. This is the awk in ops/bootstrap-vps.sh apply_firewall.
render_input() {
    local enable="$1" port="$2"
    awk -v ssh="22" -v game="27015" -v port="${port}" -v enable="${enable}" '
        /^define ssh_port/ { print "define ssh_port = " ssh; next }
        /^define game_port/ { print "define game_port = " game; next }
        /^define fastdl_port/ {
            if (enable == "1") print "define fastdl_port = " port
            next
        }
        /^[[:space:]]*set fastdl_(new|ct) / { if (enable != "1") { skip = 1; next } }
        skip && /^[[:space:]]*}/ { skip = 0; next }
        skip { next }
        /^[[:space:]]*# FASTDL_RULE/ { if (enable != "1") next }
        /\$fastdl_port/ { if (enable != "1") next }
        { print }
    ' "${INPUT}"
}
kept=$(render_input 1 27081)
assert_contains "enabled FastDL uses the configured port" "${kept}" "define fastdl_port = 27081"
assert_contains "enabled FastDL keeps the rate limit" "${kept}" "limit rate over 40/second burst 80 packets"
assert_not_contains "enabled FastDL is not a bare accept only" "${kept}" "tcp dport 27081 accept"$'\n'"        tcp dport"
off=$(render_input 0 27080)
assert_not_contains "disabled FastDL drops the port define" "${off}" $'\ndefine fastdl_port'
# shellcheck disable=SC2016 # $fastdl_port is nft syntax, not a shell variable
assert_not_contains "disabled FastDL drops the rules" "${off}" 'tcp dport $fastdl_port'
nft -f - <<EOF || fail "rendered FastDL rules do not load"
$(render_input 1 27080)
EOF
nft delete table inet cs_server_input

printf 'firewall tests passed (%s of 200 queries allowed, 200 of 200 game packets)\n' "${queries}"
