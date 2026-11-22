#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${ROOT}"

if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
elif docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE=(podman-compose)
else
    printf 'No Compose implementation available\n' >&2
    exit 1
fi

assert_nomaster() {
    local expected="$1"
    local output
    output=$(NOMASTER="${expected}" "${COMPOSE[@]}" config)

    if ! grep -Eq "NOMASTER: ['\"]?${expected}['\"]?$" <<<"${output}"; then
        printf 'Expected rendered NOMASTER=%s\n' "${expected}" >&2
        exit 1
    fi
}

assert_nomaster 0
assert_nomaster 1

output=$(FASTDL_URL=https://example.com/cstrike/ "${COMPOSE[@]}" config)
if ! grep -Eq "FASTDL_URL: ['\"]?https://example.com/cstrike/['\"]?$" <<<"${output}"; then
    printf 'Expected rendered FASTDL_URL\n' >&2
    exit 1
fi
if grep -q '/tcp\|protocol: tcp' <<<"${output}"; then
    printf 'compose.yml must not publish a TCP port (GoldSrc is UDP only)\n' >&2
    exit 1
fi

# LAN override: host networking, no published port, sv_lan 1, queries answered.
output=$("${COMPOSE[@]}" -f compose.yml -f compose.lan.yml config)
if ! grep -q 'network_mode: host' <<<"${output}" || grep -q 'published:' <<<"${output}"; then
    printf 'compose.lan.yml must select host networking and publish no port\n' >&2
    exit 1
fi
if ! grep -Eq "LAN_MODE: ['\"]?1['\"]?$" <<<"${output}" || ! grep -Eq "NOMASTER: ['\"]?0['\"]?$" <<<"${output}"; then
    printf 'compose.lan.yml must set LAN_MODE=1 and leave NOMASTER=0\n' >&2
    exit 1
fi

# Windows override: NOMASTER=1 and nothing else; the hardening stays.
output=$("${COMPOSE[@]}" -f compose.yml -f compose.windows.yml config)
if ! grep -Eq "NOMASTER: ['\"]?1['\"]?$" <<<"${output}"; then
    printf 'compose.windows.yml must set NOMASTER=1\n' >&2
    exit 1
fi
for kept in 'read_only: true' 'no-new-privileges:true' 'target: /hlds/state' 'target: /hlds/cstrike/server.cfg'; do
    if ! grep -qF -- "${kept}" <<<"${output}"; then
        printf 'compose.windows.yml must keep "%s" from compose.yml\n' "${kept}" >&2
        exit 1
    fi
done

printf 'compose tests passed\n'
