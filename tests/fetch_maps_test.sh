#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# scripts/fetch-maps.sh: a download is only used if it matches its pinned
# SHA-256, and only the map's own files (plus listed sound extras) leave a
# zip. Runs a copy of the script in a scratch tree with `curl` stubbed, so
# it never touches the network or the real maps/ directory.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

command -v zip >/dev/null 2>&1 || fail "zip is required to build the fixtures"
command -v unzip >/dev/null 2>&1 || fail "unzip is required (fetch-maps.sh uses it)"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
TREE="${WORK}/repo"
BIN="${WORK}/bin"
FIX="${WORK}/fixtures"
CACHE="${WORK}/cache"
CURL_CALLS="${WORK}/curl-calls"
mkdir -p "${TREE}/scripts" "${TREE}/maps" "${BIN}" "${FIX}"
cp "${ROOT}/scripts/fetch-maps.sh" "${TREE}/scripts/fetch-maps.sh"
MANIFEST="${TREE}/maps/manifest.tsv"

# Serves ${CURL_SERVE} as the download, or fails like an unreachable host.
cat > "${BIN}/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${CURL_CALLS}"
out=
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        out=$2
    fi
    shift
done
[ -n "${CURL_SERVE:-}" ] || exit 22
cp "${CURL_SERVE}" "${out}"
EOF
chmod +x "${BIN}/curl"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# row <name> <url> <sha256> [license] [extras] [fastdl]: append a manifest row.
row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "${4-test-license}" "test author" "${5--}" "${6-no}" >> "${MANIFEST}"
}

# Start a case from an empty manifest, maps/, sound/ and cache.
reset() {
    rm -rf "${TREE}/maps" "${TREE}/sound" "${CACHE}"
    mkdir -p "${TREE}/maps"
    printf '# comment line\n\n' > "${MANIFEST}"
    : > "${CURL_CALLS}"
}

# fetch [VAR=value...] [-- map...]: run the scratch copy.
fetch() {
    local -a env_args=()
    while [[ "$#" -gt 0 && "$1" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    [[ "$#" -eq 0 ]] || shift
    set +e
    output=$(env PATH="${BIN}:${PATH}" FETCH_MAPS_CACHE="${CACHE}" CURL_CALLS="${CURL_CALLS}" \
        ${env_args[@]+"${env_args[@]}"} bash "${TREE}/scripts/fetch-maps.sh" "$@" 2>&1)
    status=$?
    set -e
}

expect_ok() {
    if [[ "${status}" -ne 0 ]]; then
        fail "$1: expected success, got ${status}: ${output}"
    fi
}

# expect_die <description> <message fragment>
expect_die() {
    if [[ "${status}" -eq 0 ]]; then
        fail "$1: expected a failure, but it succeeded: ${output}"
    fi
    assert_contains "$1" "${output}" "$2"
}

downloads() {
    wc -l < "${CURL_CALLS}" | tr -d ' '
}

# --- Fixtures ---------------------------------------------------------------
# A GoldSrc BSP starts with version 30 as a little-endian int.
printf '\036\000\000\000 plain bsp' > "${FIX}/plain.bsp"
printf 'not a map at all' > "${FIX}/junk.bin"

mkdir -p "${FIX}/pack/maps" "${FIX}/pack/sound/arena" "${FIX}/pack/sound/other" "${FIX}/pack/overviews"
printf '\036\000\000\000 arena bsp' > "${FIX}/pack/maps/arena.bsp"
printf 'arena nav' > "${FIX}/pack/maps/arena.nav"
printf 'arena notes' > "${FIX}/pack/arena.txt"
printf '\036\000\000\000 second bsp' > "${FIX}/pack/maps/second.bsp"
printf 'wav one' > "${FIX}/pack/sound/arena/horn.wav"
printf 'wav two' > "${FIX}/pack/sound/other/unlisted.wav"
printf '#!/bin/sh\necho pwned\n' > "${FIX}/pack/install.sh"
printf 'model' > "${FIX}/pack/arena.mdl"
printf 'overview' > "${FIX}/pack/overviews/arena.bmp"
(cd "${FIX}/pack" && zip -q -r "${FIX}/pack.zip" .)

mkdir -p "${FIX}/nobsp"
printf 'readme' > "${FIX}/nobsp/arena.txt"
(cd "${FIX}/nobsp" && zip -q -r "${FIX}/nobsp.zip" .)

PLAIN_SUM=$(sha256 "${FIX}/plain.bsp")
PACK_SUM=$(sha256 "${FIX}/pack.zip")
NOBSP_SUM=$(sha256 "${FIX}/nobsp.zip")
JUNK_SUM=$(sha256 "${FIX}/junk.bin")
URL="https://maps.example/file"

# --- A bare .bsp download ---------------------------------------------------
reset
row plain "${URL}" "${PLAIN_SUM}"
fetch CURL_SERVE="${FIX}/plain.bsp"
expect_ok "bare bsp"
cmp -s "${FIX}/plain.bsp" "${TREE}/maps/plain.bsp" || fail "bare bsp: maps/plain.bsp differs from the download"
assert_contains "bare bsp: summary" "${output}" "fetched 1 map(s)"
calls=$(cat "${CURL_CALLS}")
assert_contains "curl is restricted to https" "${calls}" "--proto =https --proto-redir =https"
assert_contains "curl has a size cap" "${calls}" "--max-filesize"

# Already present: skipped without a download. Named: fetched again, from cache.
fetch
expect_ok "present map"
assert_contains "present map is skipped" "${output}" "plain: present, skipping"
printf 'locally edited' > "${TREE}/maps/plain.bsp"
fetch -- plain
expect_ok "named map"
cmp -s "${FIX}/plain.bsp" "${TREE}/maps/plain.bsp" || fail "named map: was not re-fetched"
count=$(downloads)
assert_eq "verified downloads are cached by hash" 1 "${count}"

# --- A zip: only the map's own files and listed extras are extracted --------
reset
row arena "${URL}" "${PACK_SUM}" test-license sound/arena/horn.wav
row second "${URL}" "${PACK_SUM}"
row other "${URL}" "${PLAIN_SUM}"
fetch CURL_SERVE="${FIX}/pack.zip" -- arena second
expect_ok "zip pack"
extracted=$(cd "${TREE}" && find maps sound -type f | LC_ALL=C sort | tr '\n' ' ')
assert_eq "zip pack: exactly these files" \
    "maps/arena.bsp maps/arena.nav maps/arena.txt maps/manifest.tsv maps/second.bsp sound/arena/horn.wav " \
    "${extracted}"
cmp -s "${FIX}/pack/maps/arena.bsp" "${TREE}/maps/arena.bsp" || fail "zip pack: arena.bsp content differs"
cmp -s "${FIX}/pack/sound/arena/horn.wav" "${TREE}/sound/arena/horn.wav" || fail "zip pack: extra content differs"
count=$(downloads)
assert_eq "a pack shared by two rows downloads once" 1 "${count}"
assert_contains "only the named maps are fetched" "${output}" "fetched 2 map(s)"

# --- Integrity --------------------------------------------------------------
reset
row plain "${URL}" "${PLAIN_SUM}"
fetch CURL_SERVE="${FIX}/junk.bin"
expect_die "tampered download" "sha256 mismatch"
[[ ! -e "${TREE}/maps/plain.bsp" ]] || fail "tampered download: the map was installed anyway"
leftovers=$(find "${CACHE}" -type f | wc -l | tr -d ' ')
assert_eq "tampered download: nothing kept in the cache" 0 "${leftovers}"

reset
row plain "${URL}" "${PLAIN_SUM}"
fetch
expect_die "unreachable host" "download failed"

reset
row junk "${URL}" "${JUNK_SUM}"
fetch CURL_SERVE="${FIX}/junk.bin"
expect_die "wrong file type" "neither a zip nor a GoldSrc .bsp"

reset
row arena "${URL}" "${NOBSP_SUM}"
fetch CURL_SERVE="${FIX}/nobsp.zip"
expect_die "zip without the map" "zip has no arena.bsp"

reset
row arena "${URL}" "${PACK_SUM}" test-license sound/arena/missing.wav
fetch CURL_SERVE="${FIX}/pack.zip"
expect_die "zip without a listed extra" "zip has no sound/arena/missing.wav"
[[ ! -e "${TREE}/maps/arena.bsp" ]] || fail "zip without a listed extra: the map was installed anyway"

reset
row plain "${URL}" "${PLAIN_SUM}" test-license sound/arena/horn.wav
fetch CURL_SERVE="${FIX}/plain.bsp"
expect_die "extras on a bare bsp" "extras need a zip download"

# --- Manifest validation: rejected before anything is downloaded ------------
# expect_rejected <description> <message> <row args...>
expect_rejected() {
    local description="$1" message="$2" count
    shift 2
    reset
    row "$@"
    fetch CURL_SERVE="${FIX}/pack.zip"
    expect_die "${description}" "${message}"
    count=$(downloads)
    assert_eq "${description}: nothing downloaded" 0 "${count}"
}

expect_rejected "http url" "only https URLs are allowed" plain "http://maps.example/file" "${PLAIN_SUM}"
expect_rejected "file url" "only https URLs are allowed" plain "file:///etc/passwd" "${PLAIN_SUM}"
expect_rejected "short checksum" "sha256 must be 64 lowercase hex chars" plain "${URL}" abc123
expect_rejected "uppercase checksum" "sha256 must be 64 lowercase hex chars" plain "${URL}" "${PLAIN_SUM^^}"
expect_rejected "path in the map name" "bad map name" ../plain "${URL}" "${PLAIN_SUM}"
expect_rejected "dotfile map name" "bad map name" .plain "${URL}" "${PLAIN_SUM}"
expect_rejected "extra outside sound/" "must be a sound/<path>.wav" arena "${URL}" "${PACK_SUM}" test-license install.sh
expect_rejected "extra that is not a wav" "must be a sound/<path>.wav" arena "${URL}" "${PACK_SUM}" test-license sound/arena/horn.sh
expect_rejected "extra with a parent path" "must be a sound/<path>.wav" arena "${URL}" "${PACK_SUM}" test-license sound/../../horn.wav
expect_rejected "second extra is bad" "must be a sound/<path>.wav" arena "${URL}" "${PACK_SUM}" test-license sound/arena/horn.wav,/etc/x.wav

expect_rejected "empty license column" "license column is empty" plain "${URL}" "${PLAIN_SUM}" ""

# A row that stops before the license column.
reset
printf 'plain\t%s\t%s\n' "${URL}" "${PLAIN_SUM}" >> "${MANIFEST}"
fetch CURL_SERVE="${FIX}/plain.bsp"
expect_die "row without a license column" "license column is empty"
count=$(downloads)
assert_eq "row without a license column: nothing downloaded" 0 "${count}"

# Empty columns keep their place: an empty extras column means no extras, and
# must not pull the fastdl value into its slot.
reset
row plain "${URL}" "${PLAIN_SUM}" test-license "" yes
fetch CURL_SERVE="${FIX}/plain.bsp"
expect_ok "empty extras column"
cmp -s "${FIX}/plain.bsp" "${TREE}/maps/plain.bsp" || fail "empty extras column: the map was not installed"

# A host populate writes the bsp and the extras outside the repo tree.
reset
mkdir -p "${TREE}/host"
row arena "${URL}" "${PACK_SUM}" test-license sound/arena/horn.wav
fetch FETCH_MAPS_DEST="${TREE}/host/maps" FETCH_MAPS_ROOT="${TREE}/host" CURL_SERVE="${FIX}/pack.zip" -- arena
expect_ok "host destination"
cmp -s "${FIX}/pack/maps/arena.bsp" "${TREE}/host/maps/arena.bsp" || fail "host destination: bsp"
cmp -s "${FIX}/pack/sound/arena/horn.wav" "${TREE}/host/sound/arena/horn.wav" || fail "host destination: extra"
[[ ! -e "${TREE}/maps/arena.bsp" ]] || fail "host destination: also wrote the repo maps/ tree"

printf 'fetch-maps tests passed\n'
