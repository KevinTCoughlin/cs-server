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

# install.sh pins this. It has to be the newest released heading in the changelog.
DEFAULT_VERSION=$(sed -n 's/^DEFAULT_VERSION="\([0-9][0-9.]*\)"/\1/p' "${ROOT}/install.sh")
[[ -n "${DEFAULT_VERSION}" ]] || fail "install.sh has no DEFAULT_VERSION"
released=$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "${ROOT}/CHANGELOG.md" | head -n 1)
assert_eq "DEFAULT_VERSION is the newest CHANGELOG release" "${released}" "${DEFAULT_VERSION}"

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

for tool in cat mktemp tar mkdir cp mv od tr chmod find rm grep awk cut sed sort dirname; do
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
    version)
        case "${0##*/}" in
            podman)
                if [ "${FAKE_PODMAN_VERSION_FAIL:-0}" = 1 ]; then
                    echo "podman version unknown"
                    exit 0
                fi
                printf '%s\n' "${FAKE_PODMAN_VERSION:-5.4.2}"
                ;;
            *) printf '%s\n' "${FAKE_DOCKER_VERSION:-29.10.0}" ;;
        esac
        ;;
    pull) [ "${FAKE_PULL_FAIL:-0}" = 0 ] || exit 1 ;;
    run)
        case "$*" in
            *"test -x /fastdl.sh"*) exit "${FAKE_NO_FASTDL:-0}" ;;
            *"--entrypoint sh"*"cd /hlds/cstrike "*) cd "${FAKE_IMAGE_CONFIG}" && tar -cf - server.cfg mapcycle*.txt modes ;;
            *"--entrypoint sh"*"cd /hlds/dod "*) cd "${FAKE_IMAGE_CONFIG}/dod" && tar -cf - server.cfg mapcycle*.txt pub.cfg match.cfg match-ot.cfg ;;
            # Another game: its stock settings and one map cycle, no modes.
            *"--entrypoint sh"*) cd "${FAKE_IMAGE_CONFIG}" && tar -cf - server.cfg mapcycle.txt ;;
        esac
        ;;
    container) [ "${FAKE_CONTAINER:-0}" = 1 ] && echo true ;;
    volume)
        case "$2" in
            inspect) [ "${FAKE_VOLUME:-0}" = 1 ] ;;
        esac
        ;;
    image)
        case "$*" in
            *RepoDigests*)
                [ -n "${FAKE_DIGEST:-}" ] || exit 1
                echo "${FAKE_DIGEST}"
                exit 0
                ;;
            *".Digest"*)
                if [ -n "${FAKE_IMAGE_DIGEST:-}" ]; then
                    printf '%s\n' "${FAKE_IMAGE_DIGEST}"
                    exit 0
                fi
                exit 1
                ;;
        esac
        [ "${FAKE_IMAGE:-0}" = 1 ]
        ;;
esac
EOF
cat > "${STUBS}/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "${CALLS}"
case "$2" in
    is-active | is-enabled) [ "${FAKE_ACTIVE:-1}" = 1 ] ;;
    # As systemd does: a Quadlet-generated service cannot be enabled.
    enable)
        case "$*" in
            *.timer) ;;
            *) echo "Failed to enable unit: Unit is transient or generated" >&2; exit 1 ;;
        esac
        ;;
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
cat > "${STUBS}/loginctl" <<'EOF'
#!/bin/sh
printf 'loginctl %s\n' "$*" >> "${CALLS}"
case "$1" in
    show-user)
        if [ "${FAKE_LINGER:-no}" = yes ]; then
            echo Linger=yes
        else
            echo Linger=no
        fi
        ;;
    enable-linger)
        [ "${FAKE_LINGER_FAIL:-0}" = 0 ]
        ;;
esac
EOF
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
    output=$(env -i PATH="${STUBS}:${TOOLS}" HOME="${HOME_DIR}" USER=tester CALLS="${LOG}" \
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

# --- The repository's unit is the installer's (`just quadlet`) ----------------
use_runtimes
install CS_SERVER_IMAGE=localhost/cs-server:latest -- --print-unit
expect_ok "--print-unit"
assert_eq "--print-unit touches nothing" "" "${calls}"
assert_eq "quadlet/scoutzknivez.container is out of date: run \`just quadlet\`" \
    "$(cat "${ROOT}/quadlet/scoutzknivez.container")" "${output}"
install CS_GAME=dod CS_INSTANCE=two CS_PORT=27017 -- --print-unit
expect_ok "--print-unit for a game instance"
assert_contains "--print-unit: home-relative config path" "${output}" "Volume=%h/.config/dod-server-two/server.cfg:/hlds/dod/server.cfg:ro,Z"

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
assert_contains "starts the service" "${calls}" "systemctl --user start scoutzknivez"
assert_not_contains "does not try to enable a generated unit" "${calls}" "enable --now scoutzknivez"
assert_contains "enables lingering for boot" "${calls}" "loginctl enable-linger tester"
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
    # Readable by the container's unprivileged user; the 700 directory
    # above keeps other users of the host out.
    assert_eq "${name} permissions" 644 "${perms}"
    assert_contains "unit mounts ${name}" "${generated}" ":/hlds/cstrike/${name}:ro,Z"
done
for f in "${ROOT}"/config/modes/*.cfg; do
    cmp -s "${f}" "${CONFIG}/modes/${f##*/}" || fail "mode config not seeded: ${f##*/}"
done
perms=$(mode_of "${CONFIG}")
assert_eq "config dir permissions" 700 "${perms}"
perms=$(mode_of "${CONFIG}/modes")
assert_eq "modes dir permissions" 755 "${perms}"
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

# CS_PROFILE=lan: host networking instead of a published port, sv_lan 1.
install CS_PROFILE=lan
expect_ok "podman install with CS_PROFILE=lan"
unit=$(cat "${UNIT}")
assert_contains "LAN unit uses host networking" "${unit}" "Network=host"
assert_not_contains "LAN unit publishes no port" "${unit}" "PublishPort="
assert_contains "LAN unit sets sv_lan" "${unit}" "Environment=LAN_MODE=1"
assert_not_contains "LAN unit keeps answering browser queries" "${unit}" "NOMASTER"
assert_contains "LAN install points at the LAN tab" "${output}" "LAN tab"
install CS_PROFILE=wan
expect_die "bad CS_PROFILE" "Invalid CS_PROFILE"
install CS_PROFILE=lan SERVER_IP=192.0.2.10
expect_die "LAN profile with SERVER_IP" "cannot be combined"

# SERVER_IP lands in the unit.
install SERVER_IP=192.0.2.10
expect_ok "podman install with SERVER_IP"
unit=$(cat "${UNIT}")
assert_contains "unit carries SERVER_IP" "${unit}" "Environment=SERVER_IP=192.0.2.10"
assert_contains "SERVER_IP keeps the published port" "${unit}" "PublishPort=27015:27015/udp"
install 'SERVER_IP=192.0.2.10;quit'
expect_die "bad SERVER_IP" "Invalid SERVER_IP"

# Offline: a failed pull falls back to an image loaded by hand, and stops
# when there is none.
install FAKE_PULL_FAIL=1 FAKE_IMAGE=1
expect_ok "offline install with a loaded image"
assert_contains "offline install says what it used" "${output}" "using the copy already on this machine"
install FAKE_PULL_FAIL=1
expect_die "offline install without an image" "no local copy exists"

# --- A second instance next to the default one --------------------------------
fresh_home
install
expect_ok "default install before adding an instance"
default_unit=$(cat "${UNIT}")
install CS_INSTANCE=match-2 CS_PORT=27016
expect_ok "install of a named instance"
INSTANCE_UNIT="${HOME_DIR}/.config/containers/systemd/cs-server-match-2.container"
[[ -f "${INSTANCE_UNIT}" ]] || fail "no unit for the named instance"
unit=$(cat "${INSTANCE_UNIT}")
assert_contains "instance: own container name" "${unit}" "ContainerName=cs-server-match-2"
assert_contains "instance: own port, same inside and out" "${unit}" "PublishPort=27016:27016/udp"
assert_contains "instance: HLDS listens on that port" "${unit}" "Environment=PORT=27016"
assert_contains "instance: own state volume" "${unit}" "Volume=cs-server-state-match-2:/hlds/state"
assert_contains "instance: own config directory" "${unit}" "Volume=${HOME_DIR}/.config/cs-server-match-2/server.cfg:/hlds/cstrike/server.cfg:ro,Z"
[[ -f "${HOME_DIR}/.config/cs-server-match-2/server.cfg" ]] || fail "instance config was not seeded"
assert_contains "instance: its own service is started" "${calls}" "systemctl --user start cs-server-match-2"
assert_eq "the default unit is untouched by a named instance" "${default_unit}" "$(cat "${UNIT}")"
install CS_INSTANCE=Match_2
expect_die "bad CS_INSTANCE" "Invalid CS_INSTANCE"
install CS_PORT=80
expect_die "privileged CS_PORT" "Invalid CS_PORT"
install 'CS_PORT=27016;quit'
expect_die "bad CS_PORT" "Invalid CS_PORT"
ANSWERS=$'y\ny' install CS_INSTANCE=match-2 FAKE_VOLUME=1 -- --uninstall
expect_ok "uninstall of the named instance"
[[ ! -e "${INSTANCE_UNIT}" ]] || fail "instance unit survived its uninstall"
[[ -f "${UNIT}" && -f "${CONFIG}/server.cfg" ]] || fail "uninstalling an instance removed the default server"
assert_contains "instance uninstall removes only its volume" "${calls}" "podman volume rm cs-server-state-match-2"

# --- Pinning, upgrade and rollback ------------------------------------------
# Default image: lowercase (engines reject the repository's mixed case).
fresh_home
install FAKE_ACTIVE=0
expect_ok "default install"
assert_contains "pulls the default image" "${calls}" "podman pull ghcr.io/kevintcoughlin/cs-server:${DEFAULT_VERSION}"
unit=$(cat "${UNIT}")
assert_contains "unit runs the default image" "${unit}" "Image=ghcr.io/kevintcoughlin/cs-server:${DEFAULT_VERSION}"
assert_contains "default unit keeps Notify=healthy on Podman 5" "${unit}" "Notify=healthy"
assert_not_contains "no auto-update unless asked for" "${unit}" "AutoUpdate"
assert_not_contains "no auto-update timer unless asked for" "${calls}" "podman-auto-update.timer"
assert_not_contains "a stopped server is started, not restarted" "${calls}" "systemctl --user restart"

# CS_SERVER_VERSION pins a release; with the server running it is restarted
# onto the new image, and the build's digest is printed for a later rollback.
install CS_SERVER_VERSION=v1.2.3 FAKE_DIGEST=ghcr.io/kevintcoughlin/cs-server@sha256:abc123
expect_ok "pinned upgrade"
assert_contains "pulls the pinned release" "${calls}" "podman pull ghcr.io/kevintcoughlin/cs-server:1.2.3"
unit=$(cat "${UNIT}")
assert_contains "unit runs the pinned release" "${unit}" "Image=ghcr.io/kevintcoughlin/cs-server:1.2.3"
assert_contains "a running server is restarted onto it" "${calls}" "systemctl --user restart scoutzknivez"
assert_contains "prints the digest to roll back to" "${output}" "CS_SERVER_IMAGE=ghcr.io/kevintcoughlin/cs-server@sha256:abc123"

install CS_SERVER_VERSION=1
expect_ok "floating major"
assert_contains "pulls the floating major tag" "${calls}" "podman pull ghcr.io/kevintcoughlin/cs-server:1"
install CS_SERVER_VERSION=latest
expect_die "bad version" "Invalid CS_SERVER_VERSION"
install "CS_SERVER_VERSION=1.0.0;x"
expect_die "bad version" "Invalid CS_SERVER_VERSION"

# Rollback: a digest reference wins over a version.
install CS_SERVER_VERSION=1.2.3 CS_SERVER_IMAGE=ghcr.io/kevintcoughlin/cs-server@sha256:abc123
expect_ok "rollback to a digest"
unit=$(cat "${UNIT}")
assert_contains "unit runs the digest" "${unit}" "Image=ghcr.io/kevintcoughlin/cs-server@sha256:abc123"

# A resolved 64-character digest is written into the unit as tag@sha256.
# .Digest wins over a different RepoDigests entry (the multi-arch index).
PIN_SHA=sha256:ee8369ef1622fad1c7f66dd25594702d49fa913728e8ac7f611f86048700f5de
INDEX_SHA=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
install CS_SERVER_VERSION=1.2.3 \
    FAKE_IMAGE_DIGEST="${PIN_SHA}" \
    FAKE_DIGEST="ghcr.io/kevintcoughlin/cs-server@${INDEX_SHA}"
expect_ok "digest pin"
unit=$(cat "${UNIT}")
assert_contains "unit pins the arch digest on the tag" "${unit}" \
    "Image=ghcr.io/kevintcoughlin/cs-server:1.2.3@${PIN_SHA}"
assert_not_contains "unit does not pin the index digest" "${unit}" "${INDEX_SHA}"
assert_contains "prints the arch digest to roll back to" "${output}" \
    "CS_SERVER_IMAGE=ghcr.io/kevintcoughlin/cs-server@${PIN_SHA}"
assert_contains "says the quadlet image is pinned" "${output}" "Quadlet image pinned"

# Daily tag rollout keeps the tag so podman-auto-update can move it.
install CS_SERVER_VERSION=1 CS_AUTO_UPDATE=1 FAKE_IMAGE_DIGEST="${PIN_SHA}"
expect_ok "auto-update leaves the tag"
unit=$(cat "${UNIT}")
assert_contains "auto-update unit stays on the tag" "${unit}" "Image=ghcr.io/kevintcoughlin/cs-server:1"
assert_not_contains "auto-update unit is not digest pinned" "${unit}" "@${PIN_SHA}"
assert_contains "auto-update still opts in" "${unit}" "AutoUpdate=registry"
assert_contains "auto-update explains the unpinned tag" "${output}" "follows that tag"

install CS_PIN_DIGEST=0 CS_SERVER_VERSION=1.2.3 FAKE_IMAGE_DIGEST="${PIN_SHA}"
expect_ok "pin opt-out"
unit=$(cat "${UNIT}")
assert_contains "opt-out stays on the tag" "${unit}" "Image=ghcr.io/kevintcoughlin/cs-server:1.2.3"
assert_not_contains "opt-out does not append the digest" "${unit}" "@${PIN_SHA}"
assert_contains "opt-out is announced" "${output}" "CS_PIN_DIGEST=0"
install CS_PIN_DIGEST=2
expect_die "bad CS_PIN_DIGEST" "Invalid CS_PIN_DIGEST"

# Auto-update: a label on the unit plus Podman's timer; needs a tag.
install CS_SERVER_VERSION=1 CS_AUTO_UPDATE=1
expect_ok "auto-update"
unit=$(cat "${UNIT}")
assert_contains "unit opts in to auto-update" "${unit}" "AutoUpdate=registry"
assert_contains "auto-update timer is enabled" "${calls}" "systemctl --user enable --now podman-auto-update.timer"
install CS_AUTO_UPDATE=1 CS_SERVER_IMAGE=ghcr.io/kevintcoughlin/cs-server@sha256:abc123
expect_die "auto-update with a digest" "needs a tag, not a digest"

# Podman 4.4–4.9 can run Quadlet, without the health notification Podman 5 uses
# to roll a bad auto-update back. Older than 4.4 is refused.
fresh_home
install FAKE_PODMAN_VERSION=4.9.3 CS_AUTO_UPDATE=1
expect_ok "Podman 4.9 install"
unit=$(cat "${UNIT}")
assert_not_contains "Podman 4.9 omits Notify=healthy" "${unit}" "Notify=healthy"
assert_contains "Podman 4.9 warns that rollback is unavailable" "${output}" "Automatic-update rollback is unavailable"
assert_contains "Podman 4.9 still opts in to auto-update" "${unit}" "AutoUpdate=registry"
install FAKE_PODMAN_VERSION=4.4.0
expect_ok "Podman 4.4 install"
assert_not_contains "Podman 4.4 omits Notify=healthy" "$(cat "${UNIT}")" "Notify=healthy"
install FAKE_PODMAN_VERSION=5.0.0
expect_ok "Podman 5.0 install"
assert_contains "Podman 5 keeps Notify=healthy" "$(cat "${UNIT}")" "Notify=healthy"
install FAKE_PODMAN_VERSION=4.3.1
expect_die "Podman 4.3 has no Quadlet" "older than 4.4"
assert_not_contains "Podman 4.3 pulls nothing" "${calls}" "podman pull"
install FAKE_PODMAN_VERSION_FAIL=1
expect_die "unreadable Podman version" "Could not read the Podman version"

install FAKE_LINGER=yes
expect_ok "linger already enabled"
assert_contains "notices lingering" "${output}" "already enabled"
assert_not_contains "does not enable linger again" "${calls}" "loginctl enable-linger"
install FAKE_LINGER_FAIL=1
expect_ok "linger cannot be set"
assert_contains "prints the linger command" "${output}" "sudo loginctl enable-linger tester"

use_runtimes podman docker
fresh_home
install CS_RUNTIME=docker
expect_ok "CS_RUNTIME=docker skips podman"
assert_contains "announces the forced engine" "${output}" "Docker selected (CS_RUNTIME=docker)"
assert_not_contains "podman is not used" "${calls}" "podman "
use_runtimes podman
install CS_RUNTIME=docker
expect_die "CS_RUNTIME=docker with no docker" "docker is not installed"
install CS_RUNTIME=container
expect_die "bad CS_RUNTIME" "Invalid CS_RUNTIME"

fresh_home
install
expect_ok "default install does not install backups"
[[ ! -e "${HOME_DIR}/.local/bin/cs-server-backup" ]] || fail "backup script installed without CS_BACKUP=1"
assert_not_contains "no backup timer unless asked" "${calls}" "cs-server-backup.timer"
install CS_BACKUP=1
expect_ok "install with backups"
[[ -x "${HOME_DIR}/.local/bin/cs-server-backup" ]] || fail "backup script missing"
assert_eq "backup script is the repo's" "$(cat "${ROOT}/ops/backup-state.sh")" "$(cat "${HOME_DIR}/.local/bin/cs-server-backup")"
assert_eq "backup service is the repo's" "$(cat "${ROOT}/ops/systemd/cs-server-backup.service")" "$(cat "${HOME_DIR}/.config/systemd/user/cs-server-backup.service")"
assert_eq "backup timer is the repo's" "$(cat "${ROOT}/ops/systemd/cs-server-backup.timer")" "$(cat "${HOME_DIR}/.config/systemd/user/cs-server-backup.timer")"
assert_contains "backup timer enabled" "${calls}" "systemctl --user enable --now cs-server-backup.timer"
assert_contains "backup unit pins the runtime" "$(cat "${HOME_DIR}/.config/systemd/user/cs-server-backup.service")" "EnvironmentFile=%h/.config/cs-server/backup.env"
assert_eq "backup env remembers podman" "CS_RUNTIME=podman
CS_BACKUP_KEEP=14" "$(cat "${HOME_DIR}/.config/cs-server/backup.env")"
install CS_BACKUP=yes
expect_die "bad CS_BACKUP" "Invalid CS_BACKUP"

# An image too old to carry a mounted file is refused, not half-installed.
fresh_home
mkdir -p "${WORK}/old-image"
cp -R "${ROOT}/config/." "${WORK}/old-image/"
rm "${WORK}/old-image/mapcycle-nipper-xmas.txt"
install FAKE_IMAGE_CONFIG="${WORK}/old-image"
expect_die "old image" "does not provide mapcycle-nipper-xmas.txt"
[[ ! -e "${UNIT}" ]] || fail "old image: the Quadlet unit was installed anyway"
assert_not_contains "old image: service not started" "${calls}" "systemctl --user start"

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
for flag in "--name scoutzknivez" "--restart on-failure:10" \
    "--security-opt no-new-privileges" "--cap-drop ALL" "-p 27015:27015/udp" \
    "-v ${CONFIG}/modes:/hlds/cstrike/modes:ro" "--memory 512m" "--cpus 2" "-e MODE=scoutz"; do
    assert_contains "docker run flag" "${run_line}" "${flag}"
done
if [[ "${run_line}" != *" ghcr.io/kevintcoughlin/cs-server:${DEFAULT_VERSION}" ]]; then
    fail "docker run: the default image must be the last argument: ${run_line}"
fi
assert_not_contains "docker path uses no systemd" "${calls}" "systemctl"
assert_not_contains "docker path does not enable lingering" "${calls}" "loginctl"
fresh_home
install FAKE_CONTAINER=1 CS_BACKUP=1
expect_ok "docker install with backups"
assert_contains "docker backups enable the timer" "${calls}" "systemctl --user enable --now cs-server-backup.timer"
assert_contains "docker backups enable lingering" "${calls}" "loginctl enable-linger tester"
assert_eq "docker-only backup env" "CS_RUNTIME=docker
CS_BACKUP_KEEP=14" "$(cat "${HOME_DIR}/.config/cs-server/backup.env")"
# Podman is installed too. The backup must stay on the engine that hosts the game.
use_runtimes podman docker
fresh_home
install FAKE_CONTAINER=1 CS_RUNTIME=docker CS_BACKUP=1
expect_ok "docker backup while podman is also installed"
assert_not_contains "backup install does not switch to podman" "${calls}" "podman "
assert_eq "backup env stays on docker" "CS_RUNTIME=docker
CS_BACKUP_KEEP=14" "$(cat "${HOME_DIR}/.config/cs-server/backup.env")"
use_runtimes docker
# Docker's built-in seccomp profile: no profile is named, none is read out of
# the image, and one saved by an earlier installer is removed.
assert_not_contains "docker run names no seccomp profile" "${run_line}" "seccomp"
assert_not_contains "no profile is read out of the image" "${calls}" "seccomp.json"
printf '{}\n' > "${CONFIG}/seccomp.json"
install FAKE_CONTAINER=1
expect_ok "docker reinstall over an earlier install"
[[ ! -e "${CONFIG}/seccomp.json" ]] || fail "a seccomp.json from an earlier installer was left behind"
run_line=$(grep '^docker run -d ' "${LOG}")

# Docker 29.4.2 blocks every 32-bit socket (moby/moby#52506).
install FAKE_DOCKER_VERSION=29.4.2
expect_die "Docker 29.4.2" "Docker Engine 29.4.2 cannot run 32-bit programs"
assert_not_contains "Docker 29.4.2: nothing is started" "${calls}" "docker run -d"
install FAKE_DOCKER_VERSION=29.4.3
expect_ok "Docker 29.4.3"
run_line=$(grep '^docker run -d ' "${LOG}")
assert_not_contains "docker publishes no TCP port" "${run_line}" "/tcp"
assert_not_contains "docker: no FastDL URL unless asked for" "${run_line}" "FASTDL_URL"
count=$(count_lines "${CONFIG}/server.cfg" "rcon_password")
assert_eq "docker: no RCON password unless asked for" 0 "${count}"

fresh_home
install FAKE_CONTAINER=1 CS_SERVER_VERSION=1.2.3 CS_AUTO_UPDATE=1
expect_ok "docker pinned install"
run_line=$(grep '^docker run -d ' "${LOG}")
if [[ "${run_line}" != *" ghcr.io/kevintcoughlin/cs-server:1.2.3" ]]; then
    fail "docker run: the pinned release must be the last argument: ${run_line}"
fi
assert_contains "docker: auto-update is declined" "${output}" "only supported with Podman"

fresh_home
install FAKE_CONTAINER=1 FASTDL_URL=https://example.com/cstrike/
expect_ok "docker install with FASTDL_URL"
run_line=$(grep '^docker run -d ' "${LOG}")
assert_contains "docker run carries the FastDL URL" "${run_line}" "-e FASTDL_URL=https://example.com/cstrike/ "
assert_contains "docker run mounts the state volume" "${run_line}" " -v cs-server-state:/hlds/state "
assert_contains "docker run: read-only root" "${run_line}" " --read-only --tmpfs /tmp "

fresh_home
install FAKE_CONTAINER=1 CS_PROFILE=lan
expect_ok "docker install with CS_PROFILE=lan"
run_line=$(grep '^docker run -d ' "${LOG}")
assert_contains "docker LAN: host networking" "${run_line}" " --network host "
assert_not_contains "docker LAN: no published port" "${run_line}" " -p "
assert_contains "docker LAN: sv_lan" "${run_line}" " -e LAN_MODE=1 "
fresh_home
install FAKE_CONTAINER=1 SERVER_IP=192.0.2.10
expect_ok "docker install with SERVER_IP"
run_line=$(grep '^docker run -d ' "${LOG}")
assert_contains "docker run carries SERVER_IP" "${run_line}" " -e SERVER_IP=192.0.2.10 "

# --- Another game (CS_GAME) -------------------------------------------------
use_runtimes podman
fresh_home
install
expect_ok "default install before adding a game"
default_unit=$(cat "${UNIT}")
install CS_GAME=dod CS_SERVER_VERSION=1.3.0
expect_ok "install of another game"
GAME_UNIT="${HOME_DIR}/.config/containers/systemd/dod-server.container"
GAME_CONFIG="${HOME_DIR}/.config/dod-server"
[[ -f "${GAME_UNIT}" ]] || fail "no unit for the game"
unit=$(cat "${GAME_UNIT}")
assert_contains "game: the release under the game's tag suffix" "${calls}" "podman pull ghcr.io/kevintcoughlin/cs-server:1.3.0-dod"
assert_contains "game: config is read from its own directory" "${calls}" "cd /hlds/dod && tar -cf - server.cfg mapcycle*.txt"
assert_contains "game: its title" "${unit}" "Description=Day of Defeat Server"
assert_contains "game: own container name" "${unit}" "ContainerName=dod-server"
assert_contains "game: server.cfg mounts into its directory" "${unit}" "Volume=${GAME_CONFIG}/server.cfg:/hlds/dod/server.cfg:ro,Z"
assert_contains "game: mapcycle.txt mounts into its directory" "${unit}" "Volume=${GAME_CONFIG}/mapcycle.txt:/hlds/dod/mapcycle.txt:ro,Z"
assert_contains "game: pub.cfg is mounted" "${unit}" "Volume=${GAME_CONFIG}/pub.cfg:/hlds/dod/pub.cfg:ro,Z"
assert_contains "game: match.cfg is mounted" "${unit}" "Volume=${GAME_CONFIG}/match.cfg:/hlds/dod/match.cfg:ro,Z"
assert_contains "game: starts in pub mode" "${unit}" "Environment=DOD_MODE=pub"
assert_contains "game: pub slot count" "${unit}" "Environment=MAXPLAYERS=16"
assert_not_contains "game: no token unless asked" "${unit}" "GSLT"
assert_not_contains "game: insecure stays off" "${unit}" "INSECURE"
assert_contains "game: own state volume" "${unit}" "Volume=dod-server-state:/hlds/state"
assert_contains "game: read-only root" "${unit}" "ReadOnly=true"
for absent in cstrike "Environment=MAP=" "Environment=MODE=" mapcycle-dust2 /modes; do
    assert_not_contains "game: nothing of Counter-Strike (${absent})" "${unit}" "${absent}"
done
[[ -f "${GAME_CONFIG}/server.cfg" && -f "${GAME_CONFIG}/mapcycle.txt" && -f "${GAME_CONFIG}/match.cfg" ]] || fail "game config was not seeded"
assert_contains "seeded pub clock" "$(cat "${GAME_CONFIG}/pub.cfg")" "mp_timelimit 25"
[[ ! -e "${GAME_CONFIG}/modes" ]] || fail "a game has no modes directory"
assert_contains "game: its own service is started" "${calls}" "systemctl --user start dod-server"
assert_eq "the default unit is untouched by a game" "${default_unit}" "$(cat "${UNIT}")"
install CS_GAME=tfc
expect_ok "install of a game without a version"
assert_contains "game: pinned release under the game's tag suffix" "${calls}" "podman pull ghcr.io/kevintcoughlin/cs-server:${DEFAULT_VERSION}-tfc"
install CS_GAME=dod CS_INSTANCE=two CS_PORT=27017
expect_ok "install of a game instance"
unit=$(cat "${HOME_DIR}/.config/containers/systemd/dod-server-two.container")
assert_contains "game instance: own state volume" "${unit}" "Volume=dod-server-two-state:/hlds/state"
assert_contains "game instance: own port" "${unit}" "PublishPort=27017:27017/udp"
install CS_GAME=svencoop
expect_die "unknown CS_GAME" "Invalid CS_GAME"
ANSWERS=$'y\ny' install CS_GAME=dod FAKE_VOLUME=1 -- --uninstall
expect_ok "uninstall of a game"
[[ ! -e "${GAME_UNIT}" ]] || fail "game unit survived its uninstall"
[[ -f "${UNIT}" && -f "${CONFIG}/server.cfg" ]] || fail "uninstalling a game removed the default server"
assert_contains "game uninstall removes only its volume" "${calls}" "podman volume rm dod-server-state"

# The installer and the workflow each list the games; scripts/game-env.sh is
# the table they must agree with.
all_games=$(sed -n 's/^  ALL_GAMES: //p' "${ROOT}/.github/workflows/games.yml")
[[ -n "${all_games}" ]] || fail "games.yml has no ALL_GAMES"
for game in ${all_games}; do
    title=$(bash "${ROOT}/scripts/game-env.sh" "${game}" | sed -n 's/^GAME_TITLE="\(.*\)"$/\1/p')
    grep -qE "^ +${game}\) +GAME_TITLE=\"${title}\" ;;" "${ROOT}/install.sh" ||
        fail "install.sh does not know ${game} as ${title}"
done
count=$(grep -cE '^ +[a-z0-9]+\) +GAME_TITLE=' "${ROOT}/install.sh")
# shellcheck disable=SC2086 # counting the words
set -- ${all_games}
assert_eq "install.sh lists Counter-Strike and every game" "$(($# + 1))" "${count}"

use_runtimes docker
fresh_home
install CS_GAME=czero
expect_ok "docker install of another game"
run_line=$(grep '^docker run -d ' "${LOG}")
for flag in "--name czero-server" "-v ${HOME_DIR}/.config/czero-server/server.cfg:/hlds/czero/server.cfg:ro" \
    "-v ${HOME_DIR}/.config/czero-server/mapcycle.txt:/hlds/czero/mapcycle.txt:ro" \
    "-v czero-server-state:/hlds/state" "--read-only" "-e BOTS=1" "ghcr.io/kevintcoughlin/cs-server:${DEFAULT_VERSION}-czero"; do
    assert_contains "docker game flag" "${run_line}" "${flag}"
done
for absent in cstrike "-e MAP=" "-e MODE=" /modes; do
    assert_not_contains "docker game: nothing of Counter-Strike (${absent})" "${run_line}" "${absent}"
done

# --- Mode, bots, FastDL sidecar and the LAN kit -------------------------------
use_runtimes podman
fresh_home
install CS_MODE=match CS_BOTS=0
expect_ok "install in match mode"
unit=$(cat "${UNIT}")
for line in "Environment=MODE=match" "Environment=MAP=de_dust2" "Environment=MAPCYCLE=mapcycle-dust2.txt" "Environment=BOTS=0"; do
    assert_contains "match mode unit" "${unit}" "${line}"
done
assert_not_contains "no sidecar unless asked for" "${calls}" "fastdl"
install CS_MODE=zombies
expect_die "bad CS_MODE" "Invalid CS_MODE"
# Climb: its own rotation, no bots, and no MAP (the server starts on the
# rotation's first map).
fresh_home
install CS_MODE=climb
expect_ok "install in climb mode"
unit=$(cat "${UNIT}")
for line in "Environment=MODE=climb" "Environment=MAPCYCLE=mapcycle-climb.txt" "Environment=BOTS=0" \
    ":/hlds/cstrike/mapcycle-climb.txt:ro"; do
    assert_contains "climb mode unit" "${unit}" "${line}"
done
assert_not_contains "climb mode sets no MAP" "${unit}" "Environment=MAP="
install CS_MODE=surf
assert_contains "surf mode uses its own rotation" "$(cat "${UNIT}")" "Environment=MAPCYCLE=mapcycle-surf.txt"
assert_contains "surf mode has no bots" "$(cat "${UNIT}")" "Environment=BOTS=0"
install CS_MODE=auto
assert_contains "auto mode uses the combined rotation" "$(cat "${UNIT}")" "Environment=MAPCYCLE=mapcycle-movement.txt"
assert_contains "auto mode has no bots" "$(cat "${UNIT}")" "Environment=BOTS=0"
assert_contains "auto mode is named auto" "$(cat "${UNIT}")" "Environment=MODE=auto"
install CS_MODE=movement
assert_contains "movement is another name for auto" "$(cat "${UNIT}")" "Environment=MODE=auto"
install CS_MODE=climb CS_BOTS=1
assert_contains "CS_BOTS=1 still wins in climb mode" "$(cat "${UNIT}")" "Environment=BOTS=1"
install CS_MODE=match CS_GAME=dod
expect_die "CS_MODE with another game" "CS_MODE is Counter-Strike only"
install CS_DOD_MODE=match
expect_die "CS_DOD_MODE on Counter-Strike" "CS_DOD_MODE is Day of Defeat only"
install CS_GAME=dod CS_DOD_MODE=match CS_PORT=27016 CS_DOD_PASSWORD=scrim CS_GSLT=00112233445566778899AABBCCDDEEFF
expect_ok "Day of Defeat match install"
unit=$(cat "${HOME_DIR}/.config/containers/systemd/dod-server.container")
for line in "Environment=DOD_MODE=match" "Environment=MAXPLAYERS=12" "Environment=PORT=27016" \
    "Environment=MAPCYCLE=mapcycle-match.txt" "Environment=DOD_PASSWORD=scrim" \
    "Environment=GSLT=00112233445566778899AABBCCDDEEFF" "PublishPort=27016:27016/udp"; do
    assert_contains "dod match unit" "${unit}" "${line}"
done
assert_not_contains "dod match is not -insecure" "${unit}" "INSECURE"
install CS_GAME=dod CS_DOD_MODE=warmup
expect_die "bad CS_DOD_MODE" "Invalid CS_DOD_MODE"
install CS_GSLT=zzzz
expect_die "bad CS_GSLT" "Invalid CS_GSLT"
install CS_BOTS=yes
expect_die "bad CS_BOTS" "Invalid CS_BOTS"
install CS_MAPS_LOCAL=maybe
expect_die "bad CS_MAPS_LOCAL" "Invalid CS_MAPS_LOCAL"

fresh_home
MAPS="${WORK}/maps-host"
install CS_MAPS_LOCAL=1 CS_MAPS_HOST="${MAPS}" -- --print-unit
expect_die "missing host maps directory" "is not a directory"
mkdir -p "${MAPS}"
install CS_MAPS_LOCAL=1 CS_MAPS_HOST="${MAPS}" -- --print-unit
expect_die "empty host maps directory" "no .bsp"
mkdir -p "${MAPS}/maps" "${MAPS}/sound/quake"
printf 'x\n' > "${MAPS}/maps/kz_fromhost.bsp"
printf 'wav\n' > "${MAPS}/sound/quake/horn.wav"
printf 'x\n' > "${MAPS}/maps/de_dust2.bsp"
install CS_MAPS_LOCAL=1 CS_MAPS_HOST="${MAPS}" -- --print-unit
expect_die "host file must not cover a stock map" "must not hide"
rm -f "${MAPS}/maps/de_dust2.bsp"
install CS_MAPS_LOCAL=1 CS_MAPS_HOST="${MAPS}" CS_SERVER_IMAGE=localhost/cs-server:latest -- --print-unit
expect_ok "print-unit with host maps"
assert_contains "host tree is mounted" "${output}" "Volume=${MAPS}:/maps-local:ro,Z"
assert_contains "host bsp is a file mount" "${output}" \
    "Volume=${MAPS}/maps/kz_fromhost.bsp:/hlds/cstrike/maps/kz_fromhost.bsp:ro,Z"
assert_contains "host sound is a file mount" "${output}" \
    "Volume=${MAPS}/sound/quake/horn.wav:/hlds/cstrike/sound/quake/horn.wav:ro,Z"
assert_contains "entrypoint is told about the tree" "${output}" "Environment=MAPS_LOCAL=/maps-local"
mkdir -p "${HOME_DIR}/cs-maps/maps"
printf 'x\n' > "${HOME_DIR}/cs-maps/maps/kz_fromhost.bsp"
install CS_MAPS_LOCAL=1 CS_SERVER_IMAGE=localhost/cs-server:latest -- --print-unit
expect_ok "print-unit with the default host path"
assert_contains "default host path uses the home specifier" "${output}" \
    "Volume=%h/cs-maps/maps/kz_fromhost.bsp:/hlds/cstrike/maps/kz_fromhost.bsp:ro,Z"
install CS_MAPS_LOCAL=1 CS_FASTDL=1
expect_ok "sidecar with host maps"
side=$(cat "${HOME_DIR}/.config/containers/systemd/cs-server-fastdl.container")
assert_contains "sidecar mounts the host tree" "${side}" "Volume=%h/cs-maps:/maps-local:ro,Z"
assert_contains "sidecar is told to filter the tree" "${side}" "Environment=MAPS_LOCAL=/maps-local"
assert_not_contains "sidecar does not file-mount the host bsp" "${side}" "/hlds/cstrike/maps/kz_fromhost.bsp"
assert_contains "game unit still file-mounts the host bsp" "$(cat "${UNIT}")" \
    "kz_fromhost.bsp:/hlds/cstrike/maps/kz_fromhost.bsp"

fresh_home
install CS_FASTDL=1
expect_ok "install with the FastDL sidecar"
FASTDL_UNIT="${HOME_DIR}/.config/containers/systemd/cs-server-fastdl.container"
[[ -f "${FASTDL_UNIT}" ]] || fail "no unit for the FastDL sidecar"
sidecar=$(cat "${FASTDL_UNIT}")
for line in "ContainerName=cs-server-fastdl" "PodmanArgs=--entrypoint /fastdl.sh" "PublishPort=27080:27080/tcp" \
    "ReadOnly=true" "DropCapability=ALL" "NoNewPrivileges=true" "HealthCmd=/fastdl.sh check"; do
    assert_contains "sidecar unit" "${sidecar}" "${line}"
done
assert_not_contains "the sidecar mounts nothing" "${sidecar}" "Volume="
assert_contains "the sidecar is started" "${calls}" "systemctl --user restart cs-server-fastdl"
unit=$(cat "${UNIT}")
assert_contains "the server points clients at the sidecar" "${unit}" "Environment=FASTDL_URL=http://192.0.2.10:27080/cstrike/"
assert_not_contains "the game port stays UDP only" "${unit}" "/tcp"
install CS_FASTDL=1 CS_FASTDL_HOST=lan.example CS_FASTDL_PORT=8080
expect_ok "sidecar with a host name and port"
assert_contains "host and port reach the URL" "$(cat "${UNIT}")" "Environment=FASTDL_URL=http://lan.example:8080/cstrike/"
install CS_FASTDL=1 FASTDL_URL=https://cdn.example/cstrike/
expect_ok "sidecar with an explicit URL"
assert_contains "an explicit FASTDL_URL wins" "$(cat "${UNIT}")" "Environment=FASTDL_URL=https://cdn.example/cstrike/"
install CS_FASTDL=1 FAKE_NO_FASTDL=1
expect_die "image from before the sidecar" "has no FastDL server"
install CS_FASTDL=1 'CS_FASTDL_HOST=a b'
expect_die "bad CS_FASTDL_HOST" "Invalid CS_FASTDL_HOST"
install CS_FASTDL=1 CS_FASTDL_PORT=80
expect_die "privileged CS_FASTDL_PORT" "Invalid CS_FASTDL_PORT"
install CS_INSTANCE=fastdl
expect_die "instance named like the sidecar" "name of the FastDL sidecar"
ANSWERS=$'n\nn' install -- --uninstall
expect_ok "uninstall without CS_FASTDL"
[[ -f "${FASTDL_UNIT}" ]] || fail "the sidecar was removed without CS_FASTDL=1"
ANSWERS=$'n\nn' install CS_FASTDL=1 -- --uninstall
expect_ok "uninstall with CS_FASTDL=1"
[[ ! -e "${FASTDL_UNIT}" ]] || fail "the sidecar survived an uninstall with CS_FASTDL=1"

fresh_home
install CS_LAN_KIT=3 CS_PORT=27020
expect_ok "LAN kit"
for i in 1 2 3; do
    kit_unit="${HOME_DIR}/.config/containers/systemd/cs-server-lan${i}.container"
    [[ -f "${kit_unit}" ]] || fail "LAN kit: no unit for lan${i}"
    unit=$(cat "${kit_unit}")
    for line in "Network=host" "Environment=PORT=$((27019 + i))" "Environment=LAN_MODE=1" "Environment=MODE=match" \
        "Environment=BOTS=0" "Volume=cs-server-state-lan${i}:/hlds/state" \
        "Environment=FASTDL_URL=http://192.0.2.10:27080/cstrike/"; do
        assert_contains "LAN kit lan${i}" "${unit}" "${line}"
    done
    [[ -f "${HOME_DIR}/.config/cs-server-lan${i}/modes/match.cfg" ]] || fail "LAN kit: lan${i} has no config"
done
[[ ! -e "${UNIT}" ]] || fail "the LAN kit installed the default server too"
[[ -f "${FASTDL_UNIT}" ]] || fail "LAN kit: no FastDL sidecar"
count=$(grep -c '^podman pull ' "${LOG}")
assert_eq "LAN kit pulls the image once" 1 "${count}"
count=$(grep -c 'restart cs-server-fastdl' "${LOG}")
assert_eq "LAN kit starts one sidecar" 1 "${count}"
assert_contains "LAN kit summary" "${output}" "LAN kit: 3 match servers on ports 27020 to 27022/udp"
install CS_LAN_KIT=2 CS_MODE=vanilla CS_BOTS=1
expect_ok "LAN kit in another mode"
assert_contains "LAN kit honours CS_MODE" "$(cat "${HOME_DIR}/.config/containers/systemd/cs-server-lan1.container")" "Environment=MODE=vanilla"
install CS_LAN_KIT=9
expect_die "LAN kit too large" "Invalid CS_LAN_KIT"
install CS_LAN_KIT=2 CS_INSTANCE=a
expect_die "LAN kit with an instance name" "names its own servers"
install CS_LAN_KIT=2 -- --print-unit
expect_die "LAN kit with --print-unit" "does not take CS_LAN_KIT"
ANSWERS=$'y\ny\ny\ny\ny\ny' install CS_LAN_KIT=3 FAKE_VOLUME=1 -- --uninstall
expect_ok "LAN kit uninstall"
for i in 1 2 3; do
    [[ ! -e "${HOME_DIR}/.config/containers/systemd/cs-server-lan${i}.container" ]] || fail "LAN kit uninstall left lan${i}"
done
[[ ! -e "${FASTDL_UNIT}" ]] || fail "LAN kit uninstall left the sidecar"

use_runtimes docker
fresh_home
install CS_FASTDL=1
expect_ok "docker install with the FastDL sidecar"
sidecar=$(grep '^docker run -d --name cs-server-fastdl ' "${LOG}")
for flag in "--entrypoint /fastdl.sh" "-p 27080:27080/tcp" "--read-only" "--cap-drop ALL" "--security-opt no-new-privileges"; do
    assert_contains "docker sidecar flag" "${sidecar}" "${flag}"
done
assert_not_contains "the docker sidecar mounts nothing" "${sidecar}" " -v "
run_line=$(grep '^docker run -d --name scoutzknivez ' "${LOG}")
assert_contains "docker server points at the sidecar" "${run_line}" "-e FASTDL_URL=http://192.0.2.10:27080/cstrike/ "

# --- Metrics endpoint ---------------------------------------------------------
use_runtimes podman
fresh_home
install
expect_ok "install without metrics"
assert_not_contains "no metrics port unless asked for" "$(cat "${UNIT}")" "METRICS"
install CS_METRICS_PORT=9137
expect_ok "install with metrics"
unit=$(cat "${UNIT}")
assert_contains "metrics: the endpoint is on" "${unit}" "Environment=METRICS_PORT=9137"
assert_contains "metrics: published on loopback only" "${unit}" "PublishPort=127.0.0.1:9137:9137/tcp"
assert_contains "metrics: the game port is still published" "${unit}" "PublishPort=27015:27015/udp"
install CS_METRICS_PORT=9137 CS_METRICS_BIND=192.0.2.10 CS_PROFILE=lan
expect_ok "metrics on host networking"
unit=$(cat "${UNIT}")
assert_contains "metrics on host networking: binds the address itself" "${unit}" "Environment=METRICS_BIND=192.0.2.10"
assert_not_contains "metrics on host networking: nothing to publish" "${unit}" "PublishPort="
install CS_METRICS_PORT=80
expect_die "privileged CS_METRICS_PORT" "Invalid CS_METRICS_PORT"
install CS_METRICS_PORT=9137 CS_METRICS_BIND=localhost
expect_die "bad CS_METRICS_BIND" "Invalid CS_METRICS_BIND"
fresh_home
install CS_LAN_KIT=2 CS_METRICS_PORT=9200
expect_ok "LAN kit with metrics"
assert_contains "LAN kit metrics: lan1" "$(cat "${HOME_DIR}/.config/containers/systemd/cs-server-lan1.container")" "Environment=METRICS_PORT=9200"
assert_contains "LAN kit metrics: lan2 on the next port" "$(cat "${HOME_DIR}/.config/containers/systemd/cs-server-lan2.container")" "Environment=METRICS_PORT=9201"
use_runtimes docker
fresh_home
install CS_METRICS_PORT=9137
expect_ok "docker install with metrics"
run_line=$(grep '^docker run -d --name scoutzknivez ' "${LOG}")
assert_contains "docker metrics flags" "${run_line}" "-e METRICS_PORT=9137 -p 127.0.0.1:9137:9137/tcp"

# --- Firewall recipe: mentioned, never applied -------------------------------
cat > "${STUBS}/nft" <<'EOF'
#!/bin/sh
printf 'nft %s\n' "$*" >> "${CALLS}"
EOF
chmod +x "${STUBS}/nft"
use_runtimes podman
fresh_home
install
expect_ok "install on a host with nftables"
assert_contains "points at the query-flood recipe" "${output}" "#query-floods"
assert_not_contains "never runs nft itself" "${calls}" "nft "
rm -f "${STUBS}/nft"
fresh_home
install
expect_ok "install on a host without nftables"
assert_not_contains "no recipe hint without nft" "${output}" "#query-floods"

# --- Uninstall --------------------------------------------------------------
use_runtimes podman
fresh_home
install
expect_ok "install before uninstall"

ANSWERS=$'n\nn\nn' install FAKE_IMAGE=1 FAKE_VOLUME=1 -- --uninstall
expect_ok "podman uninstall, keep everything"
assert_contains "asks about saved state" "${output}" "Keeping state volume cs-server-state"
assert_not_contains "state kept after the answer was no" "${calls}" "podman volume rm"
assert_contains "stops the service" "${calls}" "systemctl --user stop scoutzknivez"
[[ ! -e "${UNIT}" ]] || fail "uninstall left the Quadlet unit behind"
[[ -f "${CONFIG}/server.cfg" ]] || fail "uninstall removed config after the answer was no"
assert_not_contains "image kept after the answer was no" "${calls}" "podman rmi"

ANSWERS=$'y\ny\ny' install FAKE_IMAGE=1 FAKE_VOLUME=1 FAKE_ACTIVE=0 -- --uninstall
expect_ok "podman uninstall, remove everything"
assert_contains "state removed after the answer was yes" "${calls}" "podman volume rm cs-server-state"
assert_not_contains "a stopped service is not stopped again" "${calls}" "systemctl --user stop"
[[ ! -e "${CONFIG}" ]] || fail "uninstall kept config after the answer was yes"
assert_contains "image removed after the answer was yes" "${calls}" "podman rmi ghcr.io/kevintcoughlin/cs-server:${DEFAULT_VERSION}"

use_runtimes docker
ANSWERS="" install FAKE_CONTAINER=1 -- --uninstall
expect_ok "docker uninstall"
assert_contains "docker uninstall stops the container" "${calls}" "docker stop scoutzknivez"
assert_contains "docker uninstall removes the container" "${calls}" "docker rm scoutzknivez"
assert_not_contains "no state volume, no question about it" "${output}" "Remove saved server state"

printf 'install tests passed\n'
