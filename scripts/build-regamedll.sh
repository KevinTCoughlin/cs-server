#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Rebuild ReGameDLL_CS cs.so from a pinned tag with the navigation open-list
# patch and install it over the stock library the release zip already laid
# down.
#
#   scripts/build-regamedll.sh <version> <dest-cs.so> <patch>
#
# The 5.30.0.814 release (still the latest) leaves CNavArea's A* open-list
# fields uninitialized. m_masterMarker starts at 1 and never stays 0, so a
# leftover m_openMarker that equals the live generation makes IsOpen() true
# and UpdateOnOpenList follows a garbage m_prevOpen. The patch value-initializes
# those three fields. rehlds/ReGameDLL_CS#1202 did that and also unlinked in
# the destructor, cleared the list in DestroyNavigationMap, and returned early
# from UpdateOnOpenList. That pull request was closed unmerged. The extra
# three changes are not in this patch: the early return hides a bad call, and
# map teardown does not read the open list (the next search drops the head
# before walking it). tests/nav_openlist_repro.cpp is the deterministic case.
#
# Built with the i686 cross compiler, which exists on amd64 and arm64, and
# with libstdc++ linked in. hlds_run puts HLDS's own, much older libstdc++ on
# LD_LIBRARY_PATH; a dynamically linked cs.so would load that one and fail
# before the server came up. The binary needs glibc 2.38 (Debian 13's i386
# libc). Upstream's Linux CI builds the same tree with the same CMake flags.
set -euo pipefail

die() { echo "[regamedll] error: $*" >&2; exit 1; }
log() { echo "[regamedll] $*"; }

# True when the file is a little-endian ELF32 whose machine is EM_386.
is_i386_elf() {
    local magic class machine
    [[ -f "$1" ]] || return 1
    magic=$(od -An -tx1 -N 4 "$1")
    magic=${magic//[[:space:]]/}
    [[ ${magic} == 7f454c46 ]] || return 1
    class=$(od -An -tu1 -j 4 -N 1 "$1")
    class=${class//[[:space:]]/}
    [[ ${class} == 1 ]] || return 1
    machine=$(od -An -tx1 -j 18 -N 2 "$1")
    machine=${machine//[[:space:]]/}
    [[ ${machine} == 0300 ]]
}

version=${1:?version required}
dest=${2:?destination cs.so required}
patch=${3:?patch required}
[[ -f ${patch} ]] || die "patch not found: ${patch}"

work=
installed=0
cleanup() {
    local status=$?
    if [[ -n ${work} ]]; then
        rm -rf "${work}"
    fi
    if [[ ${installed} -eq 1 ]]; then
        apt-get purge -y g++-i686-linux-gnu cmake make git
        apt-get autoremove -y
        rm -rf /var/lib/apt/lists/*
    fi
    exit "${status}"
}
trap cleanup EXIT

if ! command -v i686-linux-gnu-g++ >/dev/null 2>&1 \
    || ! command -v cmake >/dev/null 2>&1 \
    || ! command -v git >/dev/null 2>&1 \
    || ! command -v make >/dev/null 2>&1; then
    log "installing the i686 toolchain"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates cmake g++-i686-linux-gnu git make
    installed=1
fi

work=$(mktemp -d)
src=${work}/ReGameDLL_CS
export GIT_TERMINAL_PROMPT=0
cloned=0
attempt=1
while [[ ${attempt} -le 3 ]]; do
    rm -rf "${src}"
    if git -c advice.detachedHead=false clone --branch "${version}" --depth 1 \
        https://github.com/rehlds/ReGameDLL_CS.git "${src}" \
        && git -C "${src}" submodule update --init --depth 1; then
        cloned=1
        break
    fi
    log "clone failed (attempt ${attempt} of 3)"
    sleep 5
    attempt=$((attempt + 1))
done
[[ ${cloned} -eq 1 ]] || die "could not clone ReGameDLL_CS ${version}"

git -C "${src}" apply "${patch}"
grep -q -F 'unsigned int m_openMarker = 0;' \
    "${src}/regamedll/game_shared/bot/nav_area.h" \
    || die "patch did not apply to nav_area.h"

log "building ${version} ($(nproc) jobs)"
CC=i686-linux-gnu-gcc CXX=i686-linux-gnu-g++ \
    cmake -DUSE_STATIC_LIBSTDC=ON -S "${src}" -B "${src}/build"
cmake --build "${src}/build" --parallel "$(nproc)"

built=${src}/build/regamedll/cs.so
is_i386_elf "${built}" || die "${built} is not an i386 ELF"
install -m 0644 "${built}" "${dest}"
log "installed patched cs.so to ${dest}"
