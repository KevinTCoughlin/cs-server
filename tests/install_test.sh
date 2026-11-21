#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# install.sh end to end against stubbed podman/docker/systemctl in a scratch
# HOME: runtime detection, config seeding, the generated Quadlet unit and
# `docker run` flags, and uninstall. The PATH holds only the stubs and the
# few tools the installer needs, so a real podman or docker on the host is
# invisible to it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
TOOLS="${WORK}/tools"
STUBS="${WORK}/stubs"
LOG="${WORK}/calls"
HOME_DIR="${WORK}/home"
CONFIG="${HOME_DIR}/.config/cs-server"
UNIT="${HOME_DIR}/.config/containers/systemd/scoutzknivez.container"
BASH_BIN=$(command -v bash)
mkdir -p "${TOOLS}" "${STUBS}"

for tool in cat mktemp tar mkdir cp od tr chmod find rm grep awk cut sed; do
    path=$(command -v "${tool}") || fail "missing tool: ${tool}"
    ln -s "${path}" "${TOOLS}/${tool}"
done

# One stub for both engines. `run` is the config-seeding call: it answers
# with a tar of FAKE_IMAGE_CONFIG, as the real image does from /hlds/cstrike.
cat > "${STUBS}/engine" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "${CALLS}"
case "$1" in
    info) echo true ;;
    run)
        case "$*" in
            *"--entrypoint sh"*) cd "${FAKE_IMAGE_CONFIG}" && tar -cf - server.cfg mapcycle*.txt modes ;;
        esac
        ;;
    container) [ "${FAKE_CONTAINER:-0}" = 1 ] && echo true ;;
    image) [ "${FAKE_IMAGE:-0}" = 1 ] ;;
esac
EOF
cat > "${STUBS}/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "${CALLS}"
case "$2" in
    is-active | is-enabled) [ "${FAKE_ACTIVE:-1}" = 1 ] ;;
esac
EOF
cat > "${STUBS}/uname" <<'EOF'
#!/bin/sh
if [ "$1" = -s ]; then
    echo "${FAKE_OS:-Linux}"
else
    echo 0.0.0-test
fi
EOF
printf '#!/bin/sh\necho 192.0.2.10\n' > "${STUBS}/hostname"
printf '#!/bin/sh\n' > "${STUBS}/sleep"
chmod +x "${STUBS}"/*

# use_runtimes [podman] [docker]: which engines the installer can find.
use_runtimes() {
    rm -f "${STUBS}/podman" "${STUBS}/docker"
    local name
    for name in "$@"; do
        ln -s engine "${STUBS}/${name}"
    done
}

# install [VAR=value...] [-- args...]: run install.sh; stdin answers prompts.
install() {
    local -a env_args=()
    while [[ "$#" -gt 0 && "$1" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    [[ "$#" -eq 0 ]] || shift
    : > "${LOG}"
    set +e
    output=$(env -i PATH="${STUBS}:${TOOLS}" HOME="${HOME_DIR}" CALLS="${LOG}" \
        FAKE_IMAGE_CONFIG="${ROOT}/config" ${env_args[@]+"${env_args[@]}"} \
        "${BASH_BIN}" "${ROOT}/install.sh" "$@" 2>&1 <<< "${ANSWERS:-}")
    status=$?
    set -e
    calls=$(cat "${LOG}")
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

fresh_home() {
    rm -rf "${HOME_DIR}"
    mkdir -p "${HOME_DIR}"
}

CONFIG_NAMES=(server.cfg)
for f in "${ROOT}"/config/mapcycle*.txt; do
    CONFIG_NAMES+=("${f##*/}")
done

# --- Arguments and environment ----------------------------------------------
use_runtimes podman
fresh_home
install -- --help
expect_ok "--help"
assert_contains "--help prints usage" "${output}" "install.sh --uninstall"
assert_eq "--help touches nothing" "" "${calls}"

install -- --purge
expect_die "unknown option" "Unknown option: --purge"
assert_eq "unknown option touches nothing" "" "${calls}"

install "CS_SERVER_IMAGE=bad image"
expect_die "image with whitespace" "Invalid CS_SERVER_IMAGE"

install FAKE_OS=Darwin
expect_die "macOS" "this installer targets Linux"
assert_contains "macOS points at the launchd path" "${output}" "ops/cs-server install"
assert_eq "macOS touches nothing" "" "${calls}"

use_runtimes
install
expect_die "no container engine" "Neither podman nor docker found"

# --- Podman: Quadlet unit ---------------------------------------------------
use_runtimes podman docker
fresh_home
install CS_SERVER_IMAGE=localhost/cs-server:latest
expect_ok "podman install"
assert_contains "podman is preferred over docker" "${output}" "Podman found"
assert_not_contains "docker is not used when podman exists" "${calls}" "docker "
assert_contains "pulls the image" "${calls}" "podman pull localhost/cs-server:latest"
assert_contains "seeds config without network" "${calls}" "podman run --rm --network none --entrypoint sh localhost/cs-server:latest"
assert_contains "reloads systemd" "${calls}" "systemctl --user daemon-reload"
assert_contains "enables and starts the service" "${calls}" "systemctl --user enable --now scoutzknivez"
assert_contains "prints the server address" "${output}" "192.0.2.10:27015"

# The installer's unit is the repo's Quadlet unit with this user's paths.
[[ -f "${UNIT}" ]] || fail "no Quadlet unit at ${UNIT}"
generated=$(sed "s#${CONFIG}/#%h/.config/cs-server/#" "${UNIT}")
reference=$(sed -n '/^\[Unit\]/,$p' "${ROOT}/quadlet/scoutzknivez.container")
assert_eq "generated Quadlet unit matches quadlet/scoutzknivez.container" "${reference}" "${generated}"

# Seeded config: every mounted file, private, and no RCON password.
for name in "${CONFIG_NAMES[@]}"; do
    [[ -f "${CONFIG}/${name}" ]] || fail "config not seeded: ${name}"
    perms=$(mode_of "${CONFIG}/${name}")
    assert_eq "${name} permissions" 600 "${perms}"
    assert_contains "unit mounts ${name}" "${generated}" ":/hlds/cstrike/${name}:ro,Z"
done
for f in "${ROOT}"/config/modes/*.cfg; do
    cmp -s "${f}" "${CONFIG}/modes/${f##*/}" || fail "mode config not seeded: ${f##*/}"
done
perms=$(mode_of "${CONFIG}")
assert_eq "config dir permissions" 700 "${perms}"
perms=$(mode_of "${CONFIG}/modes")
assert_eq "modes dir permissions" 700 "${perms}"
cmp -s "${ROOT}/config/server.cfg" "${CONFIG}/server.cfg" || fail "server.cfg differs from the image default"
count=$(count_lines "${CONFIG}/server.cfg" "rcon_password")
assert_eq "no RCON password unless asked for" 0 "${count}"
cmp -s "${ROOT}/config/mapcycle.txt" "${CONFIG}/mapcycle.txt" || fail "mapcycle.txt differs from the image default"
assert_not_contains "no TCP port is published" "${generated}" "/tcp"
assert_not_contains "no FastDL URL unless asked for" "${generated}" "FASTDL_URL"

# Re-running keeps the operator's edits; CS_RCON=1 adds a password once.
printf 'de_dust2\n' > "${CONFIG}/mapcycle.txt"
install CS_SERVER_IMAGE=localhost/cs-server:latest CS_RCON=1
expect_ok "podman reinstall with CS_RCON=1"
kept=$(cat "${CONFIG}/mapcycle.txt")
assert_eq "reinstall keeps an edited mapcycle" "de_dust2" "${kept}"
password=$(sed -n 's/^rcon_password "\([0-9a-f]*\)"$/\1/p' "${CONFIG}/server.cfg")
assert_eq "RCON password is 48 hex chars" 48 "${#password}"
install CS_SERVER_IMAGE=localhost/cs-server:latest CS_RCON=1
expect_ok "podman reinstall with CS_RCON=1 again"
count=$(count_lines "${CONFIG}/server.cfg" "rcon_password")
assert_eq "reinstall keeps the one RCON password" 1 "${count}"
kept=$(cat "${CONFIG}/server.cfg")
assert_contains "reinstall keeps the same password" "${kept}" "${password}"

# FASTDL_URL lands in the unit, with % doubled for systemd.
install 'FASTDL_URL=https://example.com/cs%20dl/cstrike/'
expect_ok "podman install with FASTDL_URL"
unit=$(cat "${UNIT}")
assert_contains "unit carries the FastDL URL" "${unit}" 'Environment=FASTDL_URL=https://example.com/cs%%20dl/cstrike/'
install 'FASTDL_URL=https://example.com/";quit'
expect_die "bad FASTDL_URL" "Invalid FASTDL_URL"

# An image too old to carry a mounted file is refused, not half-installed.
fresh_home
mkdir -p "${WORK}/old-image"
cp -R "${ROOT}/config/." "${WORK}/old-image/"
rm "${WORK}/old-image/mapcycle-nipper-xmas.txt"
install FAKE_IMAGE_CONFIG="${WORK}/old-image"
expect_die "old image" "does not provide mapcycle-nipper-xmas.txt"
[[ ! -e "${UNIT}" ]] || fail "old image: the Quadlet unit was installed anyway"
assert_not_contains "old image: service not started" "${calls}" "enable --now"

install FAKE_IMAGE_CONFIG="${WORK}/no-such-image"
expect_die "unreadable image" "Unable to read the default config"

# --- Docker fallback --------------------------------------------------------
use_runtimes docker
fresh_home
install FAKE_CONTAINER=1
expect_ok "docker install"
assert_contains "docker fallback is announced" "${output}" "using Docker as fallback"
assert_contains "replaces an existing container" "${calls}" "docker rm scoutzknivez"
run_line=$(grep '^docker run -d ' "${LOG}")
for name in "${CONFIG_NAMES[@]}"; do
    assert_contains "docker mounts ${name}" "${run_line}" "-v ${CONFIG}/${name}:/hlds/cstrike/${name}:ro"
done
for flag in "--name scoutzknivez" "--restart on-failure:10" "--security-opt seccomp=unconfined" \
    "--security-opt no-new-privileges" "--cap-drop ALL" "-p 27015:27015/udp" \
    "-v ${CONFIG}/modes:/hlds/cstrike/modes:ro" "--memory 512m" "--cpus 2" "-e MODE=scoutz"; do
    assert_contains "docker run flag" "${run_line}" "${flag}"
done
if [[ "${run_line}" != *" ghcr.io/KevinTCoughlin/cs-server:latest" ]]; then
    fail "docker run: the default image must be the last argument: ${run_line}"
fi
assert_not_contains "docker path uses no systemd" "${calls}" "systemctl"
assert_not_contains "docker publishes no TCP port" "${run_line}" "/tcp"
assert_not_contains "docker: no FastDL URL unless asked for" "${run_line}" "FASTDL_URL"
count=$(count_lines "${CONFIG}/server.cfg" "rcon_password")
assert_eq "docker: no RCON password unless asked for" 0 "${count}"

fresh_home
install FAKE_CONTAINER=1 FASTDL_URL=https://example.com/cstrike/
expect_ok "docker install with FASTDL_URL"
run_line=$(grep '^docker run -d ' "${LOG}")
assert_contains "docker run carries the FastDL URL" "${run_line}" "-e FASTDL_URL=https://example.com/cstrike/ "

# --- Uninstall --------------------------------------------------------------
use_runtimes podman
fresh_home
install
expect_ok "install before uninstall"

ANSWERS=$'n\nn' install FAKE_IMAGE=1 -- --uninstall
expect_ok "podman uninstall, keep everything"
assert_contains "stops the service" "${calls}" "systemctl --user stop scoutzknivez"
[[ ! -e "${UNIT}" ]] || fail "uninstall left the Quadlet unit behind"
[[ -f "${CONFIG}/server.cfg" ]] || fail "uninstall removed config after the answer was no"
assert_not_contains "image kept after the answer was no" "${calls}" "podman rmi"

ANSWERS=$'y\ny' install FAKE_IMAGE=1 FAKE_ACTIVE=0 -- --uninstall
expect_ok "podman uninstall, remove everything"
assert_not_contains "a stopped service is not stopped again" "${calls}" "systemctl --user stop"
[[ ! -e "${CONFIG}" ]] || fail "uninstall kept config after the answer was yes"
assert_contains "image removed after the answer was yes" "${calls}" "podman rmi ghcr.io/KevinTCoughlin/cs-server:latest"

use_runtimes docker
ANSWERS="" install FAKE_CONTAINER=1 -- --uninstall
expect_ok "docker uninstall"
assert_contains "docker uninstall stops the container" "${calls}" "docker stop scoutzknivez"
assert_contains "docker uninstall removes the container" "${calls}" "docker rm scoutzknivez"

printf 'install tests passed\n'
