#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# The redistribution allowlist is scripts/cleared-maps.sh (manifest rows
# with fastdl=yes). Published images and FastDL both use it. The four climb
# maps from v1.5.0 stay off it, and the v1.5.0 surf and climb rotations
# still name the maps those modes play.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# Every manifest row is cleared or not, and the two lists do not overlap.
cleared=$(bash "${ROOT}/scripts/cleared-maps.sh")
uncleared=$(bash "${ROOT}/scripts/cleared-maps.sh" --uncleared)
[[ -z "${cleared}" ]] || fail "the current manifest clears a map; this test expects none"
[[ -n "${uncleared}" ]] || fail "the manifest has no pinned maps"

while IFS= read -r row || [[ -n "${row}" ]]; do
    IFS=$'\037' read -r name _url _sum _license _attribution _extras fastdl <<< "${row//$'\t'/$'\037'}"
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    if [[ "${fastdl:-no}" == yes ]]; then
        grep -Fxq "${name}" <<< "${cleared}" || fail "${name} is fastdl=yes but not on the allowlist"
        if grep -Fxq "${name}" <<< "${uncleared}"; then
            fail "${name} is on both lists"
        fi
    else
        grep -Fxq "${name}" <<< "${uncleared}" || fail "${name} is not cleared but missing from --uncleared"
        if grep -Fxq "${name}" <<< "${cleared}"; then
            fail "${name} is not fastdl=yes but the allowlist includes it"
        fi
    fi
done < "${ROOT}/maps/manifest.tsv"

# v1.5.0 climb and surf. The modes still name these maps. None is cleared,
# so a published image must not contain them.
climb_v150=(kz_man_everest bkz_goldbhop bkz_toonworld kz_climbers_b01)
surf_v150=(surf_ski_5 surf_nice_fly_4 surf_srventer surf_nice_fly surf_colorama_beta)
for name in "${climb_v150[@]}"; do
    grep -Fxq "${name}" "${ROOT}/config/mapcycle-climb.txt" || fail "climb rotation lost ${name}"
    grep -Fxq "${name}" "${ROOT}/config/mapcycle-movement.txt" || fail "movement rotation lost ${name}"
    grep -Fxq "${name}" <<< "${uncleared}" || fail "${name} must stay off the allowlist until it is cleared"
done
for name in "${surf_v150[@]}"; do
    grep -Fxq "${name}" "${ROOT}/config/mapcycle-surf.txt" || fail "surf rotation lost ${name}"
    grep -Fxq "${name}" "${ROOT}/config/mapcycle-movement.txt" || fail "movement rotation lost ${name}"
    grep -Fxq "${name}" <<< "${uncleared}" || fail "${name} must stay off the allowlist until it is cleared"
done

# The real tree publishes none of them.
bash "${ROOT}/scripts/check-published-maps.sh" "${ROOT}/maps" "${ROOT}/docs/cstrike/maps" >/dev/null

# A directory that contains one of the four fails. Stock and first-party
# names in the same directory do not.
bad="${WORK}/context"
mkdir -p "${bad}"
printf 'x' > "${bad}/de_dust2.bsp"
printf 'x' > "${bad}/scoutzknivez.bsp"
printf 'x' > "${bad}/scoutzknivez.nav"
printf 'x' > "${bad}/kz_man_everest.bsp"
printf 'x' > "${bad}/bkz_goldbhop.nav"
printf 'x' > "${bad}/surf_ski_5.bsp.bz2"
set +e
output=$(bash "${ROOT}/scripts/check-published-maps.sh" "${bad}" 2>&1)
status=$?
set -e
[[ "${status}" -eq 1 ]] || fail "uncleared maps in the context were accepted (status ${status})"
assert_contains "the allowlist is part of the report" "${output}" "allowlist:"
assert_contains "an empty allowlist is shown" "${output}" "(none)"
assert_contains "the context map list includes a stock map" "${output}" "de_dust2"
assert_contains "the context map list includes a surf map that is present" "${output}" "surf_ski_5"
for name in kz_man_everest.bsp bkz_goldbhop.nav surf_ski_5.bsp.bz2; do
    assert_contains "${name} is rejected" "${output}" "${name}: not on the redistribution allowlist"
done
assert_not_contains "stock maps are not rejected" "${output}" "de_dust2.bsp: not on the redistribution allowlist"
assert_not_contains "first-party maps are not rejected" "${output}" "scoutzknivez.bsp: not on the redistribution allowlist"

# Every uncleared pinned map is rejected on its own, not only the four.
while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    one="${WORK}/one"
    rm -rf "${one}"
    mkdir -p "${one}"
    printf 'x' > "${one}/${name}.bsp"
    if bash "${ROOT}/scripts/check-published-maps.sh" "${one}" >/dev/null 2>&1; then
        fail "${name}.bsp was accepted and it is not cleared"
    fi
done <<< "${uncleared}"

# Published copy: the four and the surf maps stay out. A bundled nav stays.
src="${WORK}/src"
dest="${WORK}/dest"
mkdir -p "${src}" "${dest}"
printf 'stock' > "${dest}/de_dust2.bsp"
printf 'nav' > "${src}/scoutzknivez.nav"
printf 'keep' > "${src}/.gitkeep"
for name in "${climb_v150[@]}" "${surf_v150[@]}"; do
    printf 'x' > "${src}/${name}.bsp"
done
MAP_POLICY=cleared bash "${ROOT}/scripts/install-maps.sh" "${src}" "${dest}" >/dev/null
for name in "${climb_v150[@]}" "${surf_v150[@]}"; do
    [[ ! -e "${dest}/${name}.bsp" ]] || fail "cleared install copied ${name}.bsp"
done
[[ -f "${dest}/de_dust2.bsp" ]] || fail "cleared install removed the stock map"
[[ -f "${dest}/scoutzknivez.nav" ]] || fail "cleared install dropped the bundled nav"
[[ -f "${dest}/.gitkeep" ]] || fail "cleared install dropped .gitkeep"

# A row marked yes is copied. That is the allowlist, not a denylist of the
# four climb names.
printf 'yes-map\thttps://example.invalid/y\tabc\tCC0\tauthor\t-\tyes\n' > "${WORK}/manifest.tsv"
printf 'no-map\thttps://example.invalid/n\tdef\tunknown-no-fastdl\tauthor\t-\tno\n' >> "${WORK}/manifest.tsv"
allow_src="${WORK}/allow-src"
allow_dest="${WORK}/allow-dest"
mkdir -p "${allow_src}" "${allow_dest}"
printf 'stock' > "${allow_dest}/de_dust2.bsp"
printf 'y' > "${allow_src}/yes-map.bsp"
printf 'n' > "${allow_src}/no-map.bsp"
MAP_POLICY=cleared MAPS_MANIFEST="${WORK}/manifest.tsv" \
    bash "${ROOT}/scripts/install-maps.sh" "${allow_src}" "${allow_dest}" >/dev/null
[[ -f "${allow_dest}/yes-map.bsp" ]] || fail "cleared install dropped the one allowlisted map"
[[ ! -e "${allow_dest}/no-map.bsp" ]] || fail "cleared install copied a map that is not on the allowlist"

# Private build: the modes' maps are in the image the operator builds.
priv="${WORK}/private"
mkdir -p "${priv}"
printf 'stock' > "${priv}/de_dust2.bsp"
MAP_POLICY=local bash "${ROOT}/scripts/install-maps.sh" "${src}" "${priv}" >/dev/null
for name in "${climb_v150[@]}" "${surf_v150[@]}"; do
    [[ -f "${priv}/${name}.bsp" ]] || fail "local install left out ${name}, which the mode still plays"
done
[[ -f "${priv}/scoutzknivez.nav" ]] || fail "local install left out the bundled nav"

# --from-image reads the game maps and the FastDL link. A stub engine prints
# the listing a built image would.
stub="${WORK}/engine"
cat > "${stub}" <<'EOF'
#!/bin/sh
cat <<'LIST'
# game maps
de_dust2.bsp
scoutzknivez.bsp
scoutzknivez.nav
kz_man_everest.bsp
bkz_toonworld.bsp
# fastdl maps
de_dust2.bsp
scoutzknivez.bsp
kz_man_everest.bsp
surf_nice_fly.bsp
LIST
EOF
chmod +x "${stub}"
set +e
output=$(bash "${ROOT}/scripts/check-published-maps.sh" --from-image "${stub}" local/cs-server:movement 2>&1)
status=$?
set -e
[[ "${status}" -eq 1 ]] || fail "an image listing the four climb maps was accepted"
assert_contains "image game map list" "${output}" "de_dust2"
assert_contains "image game map list has the first-party map" "${output}" "scoutzknivez"
assert_contains "fastdl map list is separate" "${output}" $'fastdl maps:\n'
for name in kz_man_everest.bsp bkz_toonworld.bsp surf_nice_fly.bsp; do
    assert_contains "image rejected ${name}" "${output}" "${name}: not on the redistribution allowlist"
done

cat > "${stub}" <<'EOF'
#!/bin/sh
cat <<'LIST'
# game maps
de_dust2.bsp
scoutzknivez.bsp
# fastdl maps
de_dust2.bsp
scoutzknivez.bsp
LIST
EOF
bash "${ROOT}/scripts/check-published-maps.sh" --from-image "${stub}" local/cs-server:ci >/dev/null

# A missing FastDL directory is an empty list, not a failure.
cat > "${stub}" <<'EOF'
#!/bin/sh
cat <<'LIST'
# game maps
de_dust2.bsp
# missing fastdl maps
LIST
EOF
output=$(bash "${ROOT}/scripts/check-published-maps.sh" --from-image "${stub}" local/cs-server:ci)
assert_contains "missing fastdl is reported empty" "${output}" $'fastdl maps:\n(none)'

# The publish workflows and the private build both name this policy.
move=$(cat "${ROOT}/.github/workflows/movement.yml")
docker_wf=$(cat "${ROOT}/.github/workflows/docker.yml")
nightly=$(cat "${ROOT}/.github/workflows/nightly.yml")
games=$(cat "${ROOT}/.github/workflows/games.yml")
for wf in "${move}" "${docker_wf}" "${nightly}"; do
    assert_contains "image workflow passes the cleared policy" "${wf}" "MAP_POLICY=cleared"
    assert_contains "image workflow checks the build context" "${wf}" "scripts/check-published-maps.sh maps docs/cstrike/maps"
    assert_contains "image workflow checks the built image" "${wf}" "scripts/check-published-maps.sh --from-image docker"
done
assert_contains "other game images check the build context" "${games}" "scripts/check-published-maps.sh maps docs/cstrike/maps"
assert_contains "movement fetch uses the allowlist" "${move}" "scripts/cleared-maps.sh"
assert_contains "FastDL recipe uses the allowlist" "$(cat "${ROOT}/justfile")" "scripts/cleared-maps.sh --uncleared"
assert_contains "compose private builds opt into local maps" "$(cat "${ROOT}/compose.yml")" "MAP_POLICY: \${MAP_POLICY:-local}"
assert_contains "Apple container private builds opt into local maps" "$(cat "${ROOT}/ops/cs-server")" "MAP_POLICY"

printf 'cleared map tests passed\n'
