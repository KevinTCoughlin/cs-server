#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# ops/scripts/cs-records-push against a local bare repo: it stays quiet with
# no deploy key, skips an empty or invalid records.json, pushes a real one to
# the records-data branch only, skips an unchanged one, and honours the
# minimum interval. No network, no game server.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

BIN="${ROOT}/ops/scripts/cs-records-push"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
export HOME="${WORK}/home"
mkdir -p "${HOME}"
git init -q --bare "${WORK}/remote.git"

export CS_RECORDS_OUT="${WORK}/records.json"
export CS_RECORDS_DEPLOY_KEY="${WORK}/key"
export CS_RECORDS_REMOTE="${WORK}/remote.git"
export CS_RECORDS_PUSH_STATE="${WORK}/state"
export CS_RECORDS_MIN_INTERVAL=0

branches() { git -C "${WORK}/remote.git" for-each-ref --format='%(refname:short)'; }
commits() { git -C "${WORK}/remote.git" rev-list --count records-data; }

printf '{"maps":{"kz_a":{"pro":[],"cp":[]}}}\n' >"${CS_RECORDS_OUT}"

out=$("${BIN}")
assert_contains "no key: quiet" "${out}" "push not configured"
[[ -z "$(branches)" ]] || fail "no key: nothing pushed"

: >"${CS_RECORDS_DEPLOY_KEY}"
printf '{"maps":{}}\n' >"${CS_RECORDS_OUT}"
out=$("${BIN}")
assert_contains "empty maps skipped" "${out}" "no maps"
printf 'not json' >"${CS_RECORDS_OUT}"
out=$("${BIN}")
assert_contains "invalid JSON skipped" "${out}" "invalid or has no maps"
[[ -z "$(branches)" ]] || fail "skipped runs pushed nothing"

printf '{"updated_at":"t1","maps":{"kz_a":{"pro":[],"cp":[]}}}\n' >"${CS_RECORDS_OUT}"
out=$("${BIN}")
assert_contains "first push" "${out}" "pushed docs/records/records.json to records-data"
[[ "$(branches)" == "records-data" ]] || fail "only records-data exists, got: $(branches)"
git -C "${WORK}/remote.git" show records-data:docs/records/records.json | python3 -c 'import json,sys; json.load(sys.stdin)' \
    || fail "pushed file is valid JSON"

printf '{"updated_at":"t2","maps":{"kz_a":{"pro":[],"cp":[]}}}\n' >"${CS_RECORDS_OUT}"
out=$("${BIN}")
assert_contains "only updated_at changed" "${out}" "unchanged"
[[ "$(commits)" == 1 ]] || fail "unchanged lists made no commit"

printf '{"updated_at":"t3","maps":{"kz_b":{"pro":[],"cp":[]}}}\n' >"${CS_RECORDS_OUT}"
out=$(CS_RECORDS_MIN_INTERVAL=3600 "${BIN}")
assert_contains "interval honoured" "${out}" "waiting for 3600s"
out=$("${BIN}")
assert_contains "second push" "${out}" "pushed"
[[ "$(commits)" == 2 ]] || fail "second push added one commit"

printf 'ok: cs-records-push\n'
