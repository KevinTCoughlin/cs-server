#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Shared helpers for the script tests. Source it; it runs nothing itself.

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# assert_eq <description> <expected> <actual>
assert_eq() {
    if [[ "$2" != "$3" ]]; then
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3" >&2
        exit 1
    fi
}

# assert_contains <description> <haystack> <needle>
assert_contains() {
    if [[ "$2" != *"$3"* ]]; then
        printf 'FAIL: %s\n  expected to contain: %s\n  actual:\n%s\n' "$1" "$3" "$2" >&2
        exit 1
    fi
}

# assert_not_contains <description> <haystack> <needle>
assert_not_contains() {
    if [[ "$2" == *"$3"* ]]; then
        printf 'FAIL: %s\n  expected not to contain: %s\n  actual:\n%s\n' "$1" "$3" "$2" >&2
        exit 1
    fi
}

# Octal permission bits of a path (GNU and BSD stat).
mode_of() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# Number of lines in <file> matching the fixed string <needle>.
count_lines() {
    local count
    count=$(grep -cF -- "$2" "$1" 2>/dev/null) || true
    printf '%s\n' "${count:-0}"
}
