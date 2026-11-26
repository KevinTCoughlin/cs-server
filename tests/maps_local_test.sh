#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Host maps (~/cs-maps): the game container links or requires a file mount,
# and FastDL publishes a host file only when the manifest says fastdl=yes.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${ROOT}/tests/lib.sh"

SCRIPT="${ROOT}/scripts/overlay-host-maps.sh"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

run_maps() {
    set +e
    env "$@" bash "${SCRIPT}" "${CMD[@]}" >"${WORK}/out" 2>"${WORK}/err"
    status=$?
    set -e
    err=$(cat "${WORK}/err")
}

# --- Quadlet block matches the committed movement units --------------------
block=$(bash "${SCRIPT}" quadlet-block)
fastdl_block=$(bash "${SCRIPT}" quadlet-block --fastdl)
game_unit=$(cat "${ROOT}/quadlet/cs-server-movement.container")
fastdl_unit=$(cat "${ROOT}/quadlet/cs-fastdl-movement.container")
assert_contains "game unit contains the generated block" "${game_unit}" "${block}"
assert_contains "FastDL unit contains the directory mount only" "${fastdl_unit}" "${fastdl_block}"
assert_not_contains "FastDL block has no bsp file mount" "${fastdl_block}" ".bsp:"

# Re-applying the block does not change the committed units.
cp "${ROOT}/quadlet/cs-server-movement.container" "${WORK}/game.container"
cp "${ROOT}/quadlet/cs-fastdl-movement.container" "${WORK}/fastdl.container"
bash "${SCRIPT}" install-unit "${WORK}/game.container" >/dev/null
bash "${SCRIPT}" install-unit --fastdl "${WORK}/fastdl.container" >/dev/null
cmp -s "${ROOT}/quadlet/cs-server-movement.container" "${WORK}/game.container" ||
    fail "install-unit changed the committed game unit"
cmp -s "${ROOT}/quadlet/cs-fastdl-movement.container" "${WORK}/fastdl.container" ||
    fail "install-unit changed the committed FastDL unit"

# A unit that predates the block gains it in front of the state volume,
# and Image= is left alone.
cat > "${WORK}/old.container" <<'EOF'
[Container]
Image=ghcr.io/kevintcoughlin/cs-server-movement:sha-old@sha256:abc
Volume=%h/.config/cs-server-movement/modes:/hlds/cstrike/modes:ro,Z
Volume=cs-server-state-movement:/hlds/state
Environment=FASTDL_URL=http://203.0.113.5:27080/cstrike/
EOF
bash "${SCRIPT}" install-unit "${WORK}/old.container" >/dev/null
updated=$(cat "${WORK}/old.container")
assert_contains "install-unit keeps the digest pin" "${updated}" "sha-old@sha256:abc"
assert_contains "install-unit keeps FASTDL_URL" "${updated}" "http://203.0.113.5:27080/cstrike/"
assert_contains "install-unit adds the host tree" "${updated}" "Volume=%h/cs-maps:/maps-local:ro,Z"
assert_contains "install-unit adds a rotation bsp" "${updated}" \
    "Volume=%h/cs-maps/maps/bkz_goldbhop.bsp:/hlds/cstrike/maps/bkz_goldbhop.bsp:ro,Z"
# The block sits before the state volume.
state_at=$(grep -n 'Volume=cs-server-state-movement:/hlds/state' "${WORK}/old.container" | cut -d: -f1)
maps_at=$(grep -n 'Volume=%h/cs-maps:/maps-local:ro,Z' "${WORK}/old.container" | cut -d: -f1)
[[ "${maps_at}" -lt "${state_at}" ]] || fail "maps-local block should precede the state volume"

# --- apply: link when writable, never hide, fail when missing ---------------
CMD=(apply)
run_maps MAPS_LOCAL="${WORK}/missing"
[[ "${status}" -ne 0 ]] || fail "missing MAPS_LOCAL should fail"
assert_contains "missing directory is named" "${err}" "is not a directory"
assert_contains "missing directory names the populate command" "${err}" "just fetch-maps-host"

mkdir -p "${WORK}/empty"
run_maps MAPS_LOCAL="${WORK}/empty"
[[ "${status}" -ne 0 ]] || fail "empty host dir should fail"
assert_contains "empty host dir asks for a populate" "${err}" "no .bsp"

mkdir -p "${WORK}/hlds/cstrike/maps" "${WORK}/host/maps" "${WORK}/host/sound"
printf 'baked\n' > "${WORK}/hlds/cstrike/maps/kz_baked.bsp"
printf 'hostbaked\n' > "${WORK}/host/maps/kz_baked.bsp"
printf 'new\n' > "${WORK}/host/maps/kz_fromhost.bsp"
printf 'wav\n' > "${WORK}/host/sound/horn.wav"
(
    cd "${WORK}/hlds"
    MAPS_LOCAL="${WORK}/host" GAME=cstrike bash "${SCRIPT}" apply
) >"${WORK}/apply.out" 2>"${WORK}/apply.err"
[[ -L "${WORK}/hlds/cstrike/maps/kz_fromhost.bsp" ]] || fail "host bsp was not linked"
[[ -L "${WORK}/hlds/cstrike/sound/horn.wav" ]] || fail "host sound was not linked"
[[ "$(cat "${WORK}/hlds/cstrike/maps/kz_baked.bsp")" == "baked" ]] ||
    fail "existing map was replaced by the host file"
assert_contains "apply reports the host maps" "$(cat "${WORK}/apply.out")" "2 host map"

mkdir -p "${WORK}/stock/maps"
printf 'x\n' > "${WORK}/stock/maps/de_dust2.bsp"
run_maps MAPS_LOCAL="${WORK}/stock"
# apply walks from the cwd's game dir. Run it in a tree.
set +e
stock_err=$(
    cd "${WORK}/hlds"
    MAPS_LOCAL="${WORK}/stock" GAME=cstrike bash "${SCRIPT}" apply 2>&1
)
stock_status=$?
set -e
[[ "${stock_status}" -ne 0 ]] || fail "a stock map name should be refused: ${stock_err}"
assert_contains "stock map refusal" "${stock_err}" "must not hide"

mkdir -p "${WORK}/escape/maps"
printf 'x\n' > "${WORK}/escape/maps/ok.bsp"
ln -s /etc/passwd "${WORK}/escape/maps/escaped.bsp" 2>/dev/null || true
# A path with .. is refused when find reports it. A symlink that leaves the
# tree is dropped, so the bsp that stays is still applied.
(
    cd "${WORK}/hlds"
    MAPS_LOCAL="${WORK}/escape" GAME=cstrike bash "${SCRIPT}" apply
) >/dev/null
if [[ -e "${WORK}/hlds/cstrike/maps/escaped.bsp" ]]; then
    target=$(readlink "${WORK}/hlds/cstrike/maps/escaped.bsp" || true)
    case "${target}" in
        /etc/passwd | */etc/passwd) fail "a symlink out of the host tree was linked" ;;
    esac
fi

# --- FastDL stage: fastdl=no stays out, fastdl=yes is added ------------------
mkdir -p "${WORK}/image/cstrike/maps" "${WORK}/image/cstrike"
printf 'stock\n' > "${WORK}/image/cstrike/maps/scoutzknivez.bsp"
printf 'wad\n' > "${WORK}/image/cstrike/cstrike.wad"
mkdir -p "${WORK}/pub/maps" "${WORK}/pub/sound"
printf 'climb\n' > "${WORK}/pub/maps/kz_man_everest.bsp"
printf 'surf\n' > "${WORK}/pub/maps/surf_ski_5.bsp"
printf 'yes\n' > "${WORK}/pub/maps/cleared_one.bsp"
printf 'secret\n' > "${WORK}/pub/sound/secret.wav"
printf 'public\n' > "${WORK}/pub/sound/public.wav"
printf '%s\n' \
    $'cleared_one\thttps://example.invalid/c\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ttest\ttest\tsound/public.wav\tyes' \
    $'kz_man_everest\thttps://example.invalid/k\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\ttest\ttest\tsound/secret.wav\tno' \
    > "${WORK}/manifest.tsv"

mkdir -p "${WORK}/stage" "${WORK}/real-stage"
stage=$(
    MAPS_LOCAL="${WORK}/pub" \
        MAPS_MANIFEST="${WORK}/manifest.tsv" \
        HLDS_ROOT="${WORK}/image" \
        MAPS_STAGE_ROOT="${WORK}/stage/fastdl-root" \
        GAME=cstrike \
        bash "${SCRIPT}" stage 2>"${WORK}/stage.err"
)
[[ "${stage}" == "${WORK}/stage/fastdl-root" ]] || fail "stage root: ${stage}"
[[ -f "${stage}/cstrike/maps/scoutzknivez.bsp" ]] || fail "baked map missing from the serve tree"
[[ -f "${stage}/cstrike/cstrike.wad" ]] || fail "baked wad missing from the serve tree"
[[ -f "${stage}/cstrike/maps/cleared_one.bsp" ]] || fail "fastdl=yes host map was not served"
[[ -f "${stage}/cstrike/sound/public.wav" ]] || fail "extra of a cleared map was not served"
[[ ! -e "${stage}/cstrike/maps/kz_man_everest.bsp" ]] || fail "fastdl=no climb map was served"
[[ ! -e "${stage}/cstrike/maps/surf_ski_5.bsp" ]] || fail "a map the manifest does not clear was served"
[[ ! -e "${stage}/cstrike/sound/secret.wav" ]] || fail "extra of a fastdl=no map was served"
assert_contains "climb map is named in the log" "$(cat "${WORK}/stage.err")" "not serving kz_man_everest (fastdl=no)"

# The real manifest keeps the four climb maps off FastDL.
mkdir -p "${WORK}/real/maps"
for map in kz_man_everest bkz_goldbhop bkz_toonworld kz_climbers_b01 surf_ski_5; do
    printf 'x\n' > "${WORK}/real/maps/${map}.bsp"
done
real_stage=$(
    MAPS_LOCAL="${WORK}/real" \
        MAPS_MANIFEST="${ROOT}/maps/manifest.tsv" \
        HLDS_ROOT="${WORK}/image" \
        MAPS_STAGE_ROOT="${WORK}/real-stage/fastdl-root" \
        GAME=cstrike \
        bash "${SCRIPT}" stage 2>"${WORK}/real.err"
)
for map in kz_man_everest bkz_goldbhop bkz_toonworld kz_climbers_b01 surf_ski_5; do
    [[ ! -e "${real_stage}/cstrike/maps/${map}.bsp" ]] || fail "real manifest served ${map}"
done
assert_contains "real manifest logs the climb map" "$(cat "${WORK}/real.err")" "not serving bkz_toonworld (fastdl=no)"

# volumes refuses a stock name and emits a file mount for a custom one.
set +e
vol=$(bash "${SCRIPT}" volumes --host "${WORK}/stock" --prefix '%h/cs-maps' 2>&1)
vol_status=$?
set -e
[[ "${vol_status}" -ne 0 ]] || fail "volumes should refuse de_dust2: ${vol}"
assert_contains "volumes names the stock map" "${vol}" "must not hide"
vol=$(bash "${SCRIPT}" volumes --host "${WORK}/host" --game cstrike --prefix '%h/cs-maps')
assert_contains "volumes mounts the custom bsp" "${vol}" \
    "Volume=%h/cs-maps/maps/kz_fromhost.bsp:/hlds/cstrike/maps/kz_fromhost.bsp:ro,Z"
assert_contains "volumes mounts the sound" "${vol}" \
    "Volume=%h/cs-maps/sound/horn.wav:/hlds/cstrike/sound/horn.wav:ro,Z"

printf 'maps local tests passed\n'
