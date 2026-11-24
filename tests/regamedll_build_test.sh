#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# scripts/build-regamedll.sh clones the pinned tag, applies the nav open-list
# patch and installs an i386 cs.so. The compiler and the network are stubbed;
# the real build is the image build.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
BIN=${WORK}/bin
LOG=${WORK}/log
mkdir -p "${BIN}" "${LOG}"
PATCH=${ROOT}/scripts/regamedll-nav-openlist.patch
SCRIPT=${ROOT}/scripts/build-regamedll.sh

[[ -f ${PATCH} ]] || fail "missing ${PATCH}"
assert_contains "patch value-initializes the open-list marker" \
    "$(cat "${PATCH}")" "unsigned int m_openMarker = 0;"
assert_not_contains "patch does not add the UpdateOnOpenList early return" \
    "$(cat "${PATCH}")" "if (!IsOpen())"
assert_not_contains "patch does not unlink in the destructor" \
    "$(cat "${PATCH}")" "~CNavArea"
assert_not_contains "patch does not clear the list in DestroyNavigationMap" \
    "$(cat "${PATCH}")" "ClearSearchLists"
assert_contains "Containerfile rebuilds cs.so from the patch" \
    "$(cat "${ROOT}/Containerfile")" "scripts/build-regamedll.sh"
assert_contains "Containerfile passes the patch" \
    "$(cat "${ROOT}/Containerfile")" "scripts/regamedll-nav-openlist.patch"

# git/cmake/apt-get/nproc stand-ins. cmake --build writes the ELF the script
# checks; git apply plants the line the script greps for after the patch.
cat > "${BIN}/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${GIT_LOG}"
if [ "$1" = "-c" ]; then
    shift 2
fi
if [ "$1" = clone ]; then
    dest=
    prev=
    for arg in "$@"; do
        dest=$arg
        prev=$arg
    done
    unset prev
    mkdir -p "${dest}/regamedll/game_shared/bot" "${dest}/regamedll/extra"
    : > "${dest}/regamedll/game_shared/bot/nav_area.cpp"
    : > "${dest}/regamedll/game_shared/bot/nav_area.h"
fi
if [ "$1" = "-C" ]; then
    dir=$2
    if [ "$3" = apply ]; then
        printf '%s\n' 'unsigned int m_openMarker = 0;' \
            >> "${dir}/regamedll/game_shared/bot/nav_area.h"
    fi
fi
exit 0
EOF

cat > "${BIN}/cmake" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${CMAKE_LOG}"
if [ "$1" = "--build" ]; then
    dir=$2
    mkdir -p "${dir}/regamedll"
    if [ "${CMAKE_BAD_ELF:-0}" = 1 ]; then
        printf 'not-an-elf' > "${dir}/regamedll/cs.so"
    else
        {
            printf '\177ELF\001\001\001\000'
            i=0
            while [ "$i" -lt 10 ]; do printf '\000'; i=$((i + 1)); done
            printf '\003\000'
            i=0
            while [ "$i" -lt 32 ]; do printf '\000'; i=$((i + 1)); done
        } > "${dir}/regamedll/cs.so"
    fi
fi
exit 0
EOF

cat > "${BIN}/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${APT_LOG}"
exit 0
EOF

cat > "${BIN}/make" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "${BIN}/nproc" <<'EOF'
#!/bin/sh
printf '2\n'
EOF

# The script deletes its work tree and, after installing a toolchain, the apt
# lists. The second must not touch this machine.
cat > "${BIN}/rm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${RM_LOG}"
for arg in "$@"; do
    case "${arg}" in
        /var | /var/*) exit 0 ;;
    esac
done
exec /bin/rm "$@"
EOF

cat > "${BIN}/i686-linux-gnu-g++" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${BIN}/git" "${BIN}/cmake" "${BIN}/apt-get" "${BIN}/make" \
    "${BIN}/nproc" "${BIN}/rm" "${BIN}/i686-linux-gnu-g++"

# Only the stubbed tools and the few real ones the script needs. A host that
# already has i686-linux-gnu-g++ must not satisfy the "install the toolchain"
# case.
REAL=${WORK}/real
mkdir -p "${REAL}"
for cmd in bash od grep install mktemp mkdir sleep; do
    ln -s "$(command -v "${cmd}")" "${REAL}/${cmd}"
done

run_build() {
    local dest=$1
    GIT_LOG=${LOG}/git CMAKE_LOG=${LOG}/cmake APT_LOG=${LOG}/apt \
        RM_LOG=${LOG}/rm \
        PATH="${BIN}:${REAL}" \
        bash "${SCRIPT}" 5.30.0.814 "${dest}" "${PATCH}"
}

# Compiler present: no apt, and the clone/apply/build/install sequence runs.
: > "${LOG}/git"
: > "${LOG}/cmake"
: > "${LOG}/apt"
DEST=${WORK}/cs.so
printf 'stock\n' > "${DEST}"
run_build "${DEST}"
assert_contains "clones the pinned tag" "$(cat "${LOG}/git")" "--branch 5.30.0.814"
assert_contains "clones ReGameDLL_CS" "$(cat "${LOG}/git")" \
    "https://github.com/rehlds/ReGameDLL_CS.git"
assert_contains "initializes the CSSDK submodule" "$(cat "${LOG}/git")" \
    "submodule update --init"
assert_contains "applies the nav patch" "$(cat "${LOG}/git")" "apply ${PATCH}"
assert_contains "links libstdc++ in" "$(cat "${LOG}/cmake")" "-DUSE_STATIC_LIBSTDC=ON"
assert_contains "builds in parallel" "$(cat "${LOG}/cmake")" "--parallel 2"
assert_eq "apt is skipped when the toolchain is already there" "" "$(cat "${LOG}/apt")"
assert_eq "installs the built cs.so" "7f454c46" \
    "$(od -An -tx1 -N4 -- "${DEST}" | tr -d '[:space:]')"

# A library that is not an i386 ELF is refused and the stock file stays.
: > "${LOG}/git"
: > "${LOG}/cmake"
printf 'stock\n' > "${DEST}"
if CMAKE_BAD_ELF=1 run_build "${DEST}"; then
    fail "a non-ELF cs.so was accepted"
fi
assert_eq "stock cs.so kept when the build is not i386 ELF" "stock" "$(cat "${DEST}")"

# No compiler on PATH: the script installs the cross toolchain.
rm -f "${BIN}/i686-linux-gnu-g++"
: > "${LOG}/apt"
: > "${LOG}/git"
printf 'stock\n' > "${DEST}"
run_build "${DEST}"
assert_contains "installs the i686 cross compiler" "$(cat "${LOG}/apt")" \
    "g++-i686-linux-gnu"
assert_contains "installs cmake, git and make" "$(cat "${LOG}/apt")" "cmake"
assert_contains "removes the toolchain afterwards" "$(cat "${LOG}/apt")" "purge"

echo "regamedll_build_test: ok"
