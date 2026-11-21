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

printf 'compose tests passed\n'
