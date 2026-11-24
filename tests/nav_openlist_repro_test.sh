#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# The unfixed open list must SIGSEGV when a new area's leftover generation
# matches the next search, and the value-initialized build must survive a
# soak of the same input, including under ASan (the map-change path frees
# areas that are still on the open list and must not read them).
#
#   tests/nav_openlist_repro_test.sh
#   tests/nav_openlist_repro poison          # unfixed binary, expects SIGSEGV
#   tests/nav_openlist_repro zeroed          # unfixed binary, expects success
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

if command -v g++ >/dev/null 2>&1; then
    CXX=g++
elif command -v clang++ >/dev/null 2>&1; then
    CXX=clang++
else
    fail "g++ or clang++ is required to build tests/nav_openlist_repro.cpp"
fi
SRC=${ROOT}/tests/nav_openlist_repro.cpp
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
ulimit -c 0

"${CXX}" -std=c++14 -O0 -Wall -Wextra -o "${WORK}/unfixed" "${SRC}"
"${CXX}" -std=c++14 -O0 -Wall -Wextra -DNAV_OPENLIST_FIX -o "${WORK}/fixed" "${SRC}"
"${CXX}" -std=c++14 -O1 -g -fsanitize=address -DNAV_OPENLIST_FIX -o "${WORK}/fixed-asan" "${SRC}"

set +e
"${WORK}/unfixed" poison
poison_rc=$?
set -e
assert_eq "unfixed poison heap dies with SIGSEGV" "139" "${poison_rc}"

zeroed=$("${WORK}/unfixed" zeroed)
assert_contains "unfixed zeroed heap finishes the search" "${zeroed}" "fix=0"
assert_contains "unfixed zeroed heap reports no crash" "${zeroed}" "crashes=0"

SOAK=10000
fixed=$("${WORK}/fixed" poison "${SOAK}")
assert_contains "fixed poison heap survives the soak" "${fixed}" "fix=1"
assert_contains "fixed soak count" "${fixed}" "searches=${SOAK}"
assert_contains "fixed soak does not crash" "${fixed}" "crashes=0"
assert_contains "map change leaves areas on the open list" "${fixed}" "left_on_list=${SOAK}"

export ASAN_OPTIONS=detect_leaks=0:halt_on_error=1:abort_on_error=1
asan=$("${WORK}/fixed-asan" poison "${SOAK}")
assert_contains "ASan soak survives freeing areas still on the open list" "${asan}" "crashes=0"
assert_contains "ASan soak count" "${asan}" "searches=${SOAK}"

echo "nav_openlist_repro_test: ok"
