#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# ops/cs-server (the macOS launchd wrapper) against stubbed `container`,
# `launchctl`, `plutil` and `ipconfig` in a scratch HOME: config seeding, the
# `container run` flags, the rendered launchd agents, and the build/rcon/mode
# plumbing. Nothing here talks to launchd or a real container.
#
# The script pins its own PATH (launchd starts it with a bare one), so the
# test runs a copy with that one line removed, inside a scratch checkout whose
# config/, scripts/ and ops/launchd/ are the real ones.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # lib.sh is linted on its own
source "${ROOT}/tests/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
# The script resolves its own location with `readlink -f`.
WORK=$(cd "${WORK}" && pwd -P)
TREE="${WORK}/checkout"
STUBS="${WORK}/stubs"
STATE="${WORK}/state"
LOG="${WORK}/calls"
HOME_DIR="${WORK}/home"
CONFIG="${HOME_DIR}/.config/cs-server"
AGENTS="${HOME_DIR}/Library/LaunchAgents"
LABEL="com.kevintcoughlin.cs-server"
mkdir -p "${TREE}/ops" "${STUBS}"

pinned=$(count_lines "${ROOT}/ops/cs-server" 'export PATH=')
assert_eq "ops/cs-server pins PATH on exactly one line" 1 "${pinned}"
grep -v '^export PATH=' "${ROOT}/ops/cs-server" > "${TREE}/ops/cs-server"
chmod +x "${TREE}/ops/cs-server"
ln -s "${ROOT}/config" "${TREE}/config"
ln -s "${ROOT}/Containerfile" "${TREE}/Containerfile"
ln -s "${ROOT}/scripts" "${TREE}/scripts"
ln -s "${ROOT}/ops/launchd" "${TREE}/ops/launchd"

# `container`: state lives in files so a case can stage "image built",
# "server running" or "builder already up".
cat > "${STUBS}/container" <<'EOF'
#!/bin/sh
printf 'container %s\n' "$*" >> "${CALLS}"
case "$1" in
    list) cat "${STATE}/list" 2>/dev/null ;;
    image)
        if [ "$2" = inspect ]; then
            [ -e "${STATE}/image" ]
        fi
        ;;
    build)
        : > "${STATE}/image"
        # Keep what -f names: the test checks its size and content.
        while [ "$#" -gt 1 ]; do
            if [ "$1" = -f ]; then cp "$2" "${STATE}/containerfile"; fi
            shift
        done
        ;;
esac
EOF
cat > "${STUBS}/launchctl" <<'EOF'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "${CALLS}"
EOF
printf '#!/bin/sh\necho 192.0.2.20\n' > "${STUBS}/ipconfig"
# Real plutil where there is one (macOS), so the rendered plists are linted.
if ! command -v plutil >/dev/null 2>&1; then
    printf '#!/bin/sh\n' > "${STUBS}/plutil"
fi
chmod +x "${STUBS}"/*

# ops [VAR=value...] [-- args...]: run the wrapper.
ops() {
    local -a env_args=()
    while [[ "$#" -gt 0 && "$1" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    [[ "$#" -eq 0 ]] || shift
    : > "${LOG}"
    set +e
    output=$(env PATH="${STUBS}:${PATH}" HOME="${HOME_DIR}" CALLS="${LOG}" STATE="${STATE}" \
        ${env_args[@]+"${env_args[@]}"} bash "${TREE}/ops/cs-server" "$@" 2>&1)
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

# fresh [image] [running] [builder]: new HOME and container state.
fresh() {
    rm -rf "${HOME_DIR}" "${STATE}"
    mkdir -p "${HOME_DIR}" "${STATE}"
    local what
    for what in "$@"; do
        case "${what}" in
            image) : > "${STATE}/image" ;;
            running) printf 'scoutzknivez  localhost/cs-server:latest  linux  arm64  running\n' >> "${STATE}/list" ;;
            builder) printf 'buildkit  builder-shim  linux  arm64  running\n' >> "${STATE}/list" ;;
            *) fail "fresh: unknown state ${what}" ;;
        esac
    done
}

CONFIG_NAMES=(server.cfg)
for f in "${ROOT}"/config/mapcycle*.txt; do
    CONFIG_NAMES+=("${f##*/}")
done

# --- Usage ------------------------------------------------------------------
fresh
ops
assert_eq "no command: exit status" 2 "${status}"
assert_contains "no command: prints usage" "${output}" "cs-server install"
ops -- frobnicate
assert_eq "unknown command: exit status" 2 "${status}"
assert_eq "unknown command touches nothing" "" "${calls}"

# --- serve: seed config, then `container run` -------------------------------
fresh
ops -- serve
expect_die "serve without an image" "image localhost/cs-server:latest missing"
assert_not_contains "serve without an image starts nothing" "${calls}" "container run"

fresh image
ops -- serve
expect_ok "serve"
run_line=$(grep '^container run ' "${LOG}")
for name in "${CONFIG_NAMES[@]}"; do
    [[ -f "${CONFIG}/${name}" ]] || fail "config not seeded: ${name}"
    perms=$(mode_of "${CONFIG}/${name}")
    assert_eq "${name} permissions" 600 "${perms}"
    assert_contains "serve mounts ${name}" "${run_line}" "-v ${CONFIG}/${name}:/hlds/cstrike/${name}:ro"
done
for f in "${ROOT}"/config/modes/*.cfg; do
    cmp -s "${f}" "${CONFIG}/modes/${f##*/}" || fail "mode config not seeded: ${f##*/}"
done
for flag in "--name scoutzknivez --rm" "-p 27015:27015/udp" "-m 640M -c 2" \
    "--cap-drop ALL" "-v ${CONFIG}/modes:/hlds/cstrike/modes:ro"; do
    assert_contains "container run flag" "${run_line}" "${flag}"
done
assert_not_contains "no env file unless one exists" "${run_line}" "--env-file"
if [[ "${run_line}" != *" localhost/cs-server:latest" ]]; then
    fail "container run: the image must be the last argument: ${run_line}"
fi
assert_contains "a stale container is removed first" "${calls}" "container rm -f scoutzknivez"
perms=$(mode_of "${CONFIG}")
assert_eq "config dir permissions" 700 "${perms}"
assert_not_contains "no TCP port is published" "${run_line}" "/tcp"
count=$(count_lines "${CONFIG}/server.cfg" "rcon_password")
assert_eq "no RCON password unless asked for" 0 "${count}"

# Restarts keep the operator's edits, the env file and sizing; CS_RCON=1 adds
# a password once.
printf 'de_dust2\n' > "${CONFIG}/mapcycle.txt"
printf 'MODE=knife\n' > "${CONFIG}/env"
ops CS_RCON=1 -- serve
expect_ok "serve with CS_RCON=1"
password=$(sed -n 's/^rcon_password "\([0-9a-f]*\)"$/\1/p' "${CONFIG}/server.cfg")
assert_eq "RCON password is 48 hex chars" 48 "${#password}"
ops CS_RCON=1 CS_MEMORY=1G CS_CPUS=4 -- serve
expect_ok "serve again"
kept=$(cat "${CONFIG}/mapcycle.txt")
assert_eq "restart keeps an edited mapcycle" "de_dust2" "${kept}"
count=$(count_lines "${CONFIG}/server.cfg" "rcon_password")
assert_eq "restart keeps the one RCON password" 1 "${count}"
assert_contains "env file is passed through" "${calls}" "--env-file ${CONFIG}/env"
assert_contains "VM size can be overridden" "${calls}" "-m 1G -c 4"

# --- install: build if needed, link, render and load the agent --------------
fresh
ops -- install
expect_ok "install"
assert_contains "install builds a missing image" "${calls}" "container build --platform linux/arm64 -t localhost/cs-server:latest -f "
# Apple's builder refuses a Containerfile over 16384 bytes (apple/container#735).
built="${STATE}/containerfile"
size=$(wc -c < "${built}")
[[ "${size}" -lt 16384 ]] || fail "the Containerfile handed to the builder is ${size} bytes; Apple container's limit is 16384"
comments=$(grep -cE '^[[:space:]]*#' "${built}") || true
assert_eq "the built Containerfile has no comment lines" 0 "${comments}"
instructions=$(grep -cE '^(FROM|RUN|COPY|ARG|ENV|USER|WORKDIR|ENTRYPOINT|HEALTHCHECK|EXPOSE|LABEL|STOPSIGNAL|VOLUME|CMD) ' "${ROOT}/Containerfile")
kept=$(grep -cE '^(FROM|RUN|COPY|ARG|ENV|USER|WORKDIR|ENTRYPOINT|HEALTHCHECK|EXPOSE|LABEL|STOPSIGNAL|VOLUME|CMD) ' "${built}")
assert_eq "the built Containerfile keeps every instruction" "${instructions}" "${kept}"
assert_contains "install stops the builder it started" "${calls}" "container builder stop"
link=$(readlink "${HOME_DIR}/.local/bin/cs-server")
assert_eq "install links the CLI" "${TREE}/ops/cs-server" "${link}"
plist=$(cat "${AGENTS}/${LABEL}.plist")
assert_not_contains "agent plist has no placeholders left" "${plist}" "__"
assert_contains "agent runs this checkout" "${plist}" "<string>${TREE}/ops/cs-server</string>"
assert_contains "agent logs under HOME" "${plist}" "<string>${HOME_DIR}/Library/Logs/cs-server/server.log</string>"
assert_contains "agent is bootstrapped" "${calls}" "launchctl bootstrap gui/"
assert_contains "agent is enabled" "${calls}" "/${LABEL}"

fresh image
ops -- install
expect_ok "install with an image"
assert_not_contains "install does not rebuild an existing image" "${calls}" "container build"

fresh builder
ops -- build
expect_ok "build with the builder already up"
assert_not_contains "a builder that was already running is left alone" "${calls}" "builder stop"

fresh
ops CS_KEEP_BUILDER=1 -- build
expect_ok "build with CS_KEEP_BUILDER"
assert_not_contains "CS_KEEP_BUILDER keeps the builder" "${calls}" "builder stop"

# --- rcon and mode ----------------------------------------------------------
fresh image
ops -- rcon say hello
expect_die "rcon while stopped" "scoutzknivez is not running"

fresh image running
ops -- rcon
expect_die "rcon without a command" "usage: cs-server rcon"
ops -- rcon say hello world
expect_ok "rcon"
sent=$(tail -n 1 "${LOG}")
assert_contains "rcon writes to the server FIFO" "${sent}" "container exec scoutzknivez sh -c"
if [[ "${sent}" != *" sh say hello world" ]]; then
    fail "rcon: the words must arrive as one console line: ${sent}"
fi

ops -- mode scoutz
expect_ok "mode"
sent=$(tail -n 1 "${LOG}")
if [[ "${sent}" != "container exec scoutzknivez"*" sh sk_switchmode scoutz mapcycle.txt" ]]; then
    fail "mode: expected a scoutz switch through Apple container, got: ${sent}"
fi
ops -- mode
expect_die "mode without a name" "usage: cs-server mode"

# --- stop / restart ---------------------------------------------------------
ops -- stop
expect_ok "stop"
assert_contains "stop waits out the in-game countdown" "${calls}" "container stop -t 50 scoutzknivez"
assert_contains "stop unloads the agent" "${calls}" "launchctl bootout gui/"

ops -- restart
expect_ok "restart"
assert_contains "restart stops gracefully first" "${calls}" "container stop -t 50 scoutzknivez"
assert_contains "restart kicks the agent" "${calls}" "launchctl kickstart -k gui/"

fresh image
ops -- stop
expect_ok "stop while stopped"
assert_not_contains "nothing to stop when not running" "${calls}" "container stop"

ops -- status
expect_ok "status"
assert_contains "status: container" "${output}" "container:  not running"
assert_contains "status: image" "${output}" "image:      localhost/cs-server:latest"
assert_contains "status: address" "${output}" "connect:    192.0.2.20:27015"

# --- Nipper Friday schedule -------------------------------------------------
fresh image
ops -- friday enable
expect_ok "friday enable"
plist=$(cat "${AGENTS}/${LABEL}.friday.plist")
assert_not_contains "friday plist has no placeholders left" "${plist}" "__"
assert_contains "friday agent runs mode.sh from this checkout" "${plist}" "<string>${TREE}/scripts/mode.sh</string>"
assert_contains "friday agent is bootstrapped" "${calls}" "launchctl bootstrap gui/"

ops -- friday disable
expect_ok "friday disable"
[[ ! -e "${AGENTS}/${LABEL}.friday.plist" ]] || fail "friday disable left the plist behind"
assert_contains "friday agent is unloaded" "${calls}" "/${LABEL}.friday"

ops -- friday sometimes
expect_die "friday with a bad argument" "usage: cs-server friday"

# --- uninstall keeps config -------------------------------------------------
fresh image running
ops -- install
ops -- uninstall
expect_ok "uninstall"
[[ ! -e "${AGENTS}/${LABEL}.plist" ]] || fail "uninstall left the agent plist behind"
[[ ! -e "${HOME_DIR}/.local/bin/cs-server" ]] || fail "uninstall left the CLI link behind"
[[ -f "${CONFIG}/server.cfg" ]] || fail "uninstall removed the config"
assert_contains "uninstall deletes the image" "${calls}" "container image delete localhost/cs-server:latest"

printf 'ops tests passed\n'
