#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# CS 1.6 ScoutzKnivez Server — One-line installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --uninstall
#
# What this does:
#   1. Detects Podman or Docker (Podman preferred)
#   2. Pulls the container image from ghcr.io
#   3. Creates config directory with default settings
#   4. Installs Quadlet systemd unit (Podman) or container (Docker)
#   5. Starts the server
#
# Optional settings (environment):
#   CS_SERVER_VERSION  release to run instead of :latest: 1.0.0 (exact), 1.0 or
#                      1 (newest patch / minor of that line)
#   CS_SERVER_IMAGE    full image reference instead, e.g. one pinned by digest
#   CS_AUTO_UPDATE=1   Podman only: let podman-auto-update pull new images for
#                      the tag (use with CS_SERVER_VERSION=1 or 1.0)
#   CS_RCON=1          generate an rcon_password for network rcon (off by
#                      default; the local console needs none)
#   FASTDL_URL         http(s) URL that serves your cstrike/ content
#
set -euo pipefail
umask 077

REPO="KevinTCoughlin/cs-server"
REGISTRY="ghcr.io"
# Image names are lowercase; engines reject the repository's mixed case.
IMAGE_REPO="${REGISTRY}/kevintcoughlin/cs-server"
VERSION="${CS_SERVER_VERSION:-}"
VERSION="${VERSION#v}"
if [[ -n "${VERSION}" && ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf '[error] Invalid CS_SERVER_VERSION: %s (expected 1.0.0, 1.0 or 1)\n' "${CS_SERVER_VERSION}" >&2
    exit 1
fi
IMAGE="${IMAGE_REPO}:${VERSION:-latest}"
IMAGE="${CS_SERVER_IMAGE:-${IMAGE}}"
AUTO_UPDATE="${CS_AUTO_UPDATE:-0}"
SERVICE_NAME="scoutzknivez"
CONFIG_DIR="${HOME}/.config/cs-server"
# Named volume for what the server writes: bans, admins, stats, logs.
STATE_VOLUME="cs-server-state"
QUADLET_DIR="${HOME}/.config/containers/systemd"
RUNTIME=""

if [[ -z "${IMAGE}" || "${IMAGE}" =~ [[:space:]] ]]; then
    printf '[error] Invalid CS_SERVER_IMAGE: %s\n' "${IMAGE}" >&2
    exit 1
fi

# Auto-update follows a tag; a digest never changes.
if [[ "${AUTO_UPDATE}" == "1" && "${IMAGE}" == *@sha256:* ]]; then
    printf '[error] CS_AUTO_UPDATE=1 needs a tag, not a digest: %s\n' "${IMAGE}" >&2
    exit 1
fi

# Same rule as entrypoint.sh: the URL reaches the HLDS console.
FASTDL_URL="${FASTDL_URL:-}"
if [[ -n "${FASTDL_URL}" ]] &&
   [[ "${#FASTDL_URL}" -gt 128 || ! "${FASTDL_URL}" =~ ^https?://[A-Za-z0-9._~:/?#@!\&=+,%-]+$ ]]; then
    printf '[error] Invalid FASTDL_URL: %s\n' "${FASTDL_URL}" >&2
    exit 1
fi

# --- Helpers ----------------------------------------------------------------

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$1"; }
ok()    { printf '\033[1;32m[ok]\033[0m    %s\n' "$1"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$1"; }
error() { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<EOF
CS 1.6 ScoutzKnivez Server — Installer

Usage:
  install.sh              Install and start the server
  install.sh --uninstall  Stop and remove the server
  install.sh --help       Show this help message

Supports Podman (preferred) and Docker. The script auto-detects
which runtime is available, preferring Podman when both are present.

Environment:
  CS_SERVER_VERSION=<v>    Run a release instead of :latest: 1.0.0, 1.0 or 1
  CS_SERVER_IMAGE=<image>  Run this image reference instead (e.g. a digest)
  CS_AUTO_UPDATE=1         Podman: pull new images for the tag automatically
  CS_RCON=1                Generate an rcon_password (network rcon is off by default)
  FASTDL_URL=<url>         http(s) URL that serves your cstrike/ content

Upgrade or roll back: run the installer again with another CS_SERVER_VERSION
(or CS_SERVER_IMAGE). Config files are kept.

Install:
  curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash

Uninstall:
  curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash -s -- --uninstall
EOF
}

confirm() {
    printf '%s [y/N] ' "$1"
    read -r reply
    [[ "${reply}" =~ ^[Yy]$ ]]
}

# --- Parse arguments --------------------------------------------------------

ACTION="install"
if [[ "${1:-}" == "--uninstall" ]]; then
    ACTION="uninstall"
elif [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
    exit 0
elif [[ -n "${1:-}" ]]; then
    error "Unknown option: ${1}. Use --help for usage."
fi

# --- Runtime detection ------------------------------------------------------

detect_runtime() {
    # macOS has no systemd/Quadlet and ghcr.io only publishes linux/amd64
    # (32-bit HLDS can't run under Rosetta). The macOS path builds an arm64
    # image from a checkout and runs it under launchd: ops/cs-server.
    local host_os
    host_os=$(uname -s) || host_os=""
    if [[ "${host_os}" == "Darwin" ]]; then
        error "this installer targets Linux (systemd/Quadlet, linux/amd64 image).
  On macOS (Apple silicon), use Apple 'container' from a checkout instead:
    git clone https://github.com/${REPO}.git && cd cs-server
    ops/cs-server install
  See README: 'macOS / Apple silicon'."
    fi

    if command -v podman &>/dev/null; then
        RUNTIME="podman"
        local runtime_path
        runtime_path=$(command -v podman) || runtime_path="podman"
        ok "Podman found: ${runtime_path}"
    elif command -v docker &>/dev/null; then
        RUNTIME="docker"
        local runtime_path
        runtime_path=$(command -v docker) || runtime_path="docker"
        ok "Docker found: ${runtime_path}"
        warn "Podman not found — using Docker as fallback"
    else
        error "Neither podman nor docker found. Install one of:
  Podman: https://podman.io/getting-started/installation
  Docker: https://docs.docker.com/get-docker/"
    fi
}

# --- Uninstall --------------------------------------------------------------

do_uninstall() {
    info "CS 1.6 ScoutzKnivez Server — Uninstaller"
    echo ""

    detect_runtime

    if [[ "${RUNTIME}" == "podman" ]]; then
        # Stop and disable the Quadlet service
        if systemctl --user is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            info "Stopping service: ${SERVICE_NAME}"
            systemctl --user stop "${SERVICE_NAME}"
            ok "Service stopped"
        else
            info "Service is not running"
        fi

        if systemctl --user is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
            systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
        fi

        # Remove Quadlet unit file
        local quadlet_file="${QUADLET_DIR}/${SERVICE_NAME}.container"
        if [[ -f "${quadlet_file}" ]]; then
            info "Removing Quadlet unit: ${quadlet_file}"
            rm -f "${quadlet_file}"
            systemctl --user daemon-reload
            ok "Quadlet unit removed"
        else
            info "No Quadlet unit file found"
        fi
    else
        # Docker: stop and remove container
        if docker container inspect "${SERVICE_NAME}" &>/dev/null; then
            info "Stopping and removing container: ${SERVICE_NAME}"
            docker stop "${SERVICE_NAME}" 2>/dev/null || true
            docker rm "${SERVICE_NAME}" 2>/dev/null || true
            ok "Container removed"
        else
            info "No container named ${SERVICE_NAME} found"
        fi
    fi

    # Prompt before removing config
    if [[ -d "${CONFIG_DIR}" ]]; then
        echo ""
        local remove_config=false
        # confirm intentionally returns false when the user declines.
        # shellcheck disable=SC2310
        confirm "Remove config directory ${CONFIG_DIR}?" && remove_config=true
        if [[ "${remove_config}" == true ]]; then
            rm -rf "${CONFIG_DIR}"
            ok "Config directory removed"
        else
            info "Keeping config directory"
        fi
    fi

    # Prompt before removing saved state
    if ${RUNTIME} volume inspect "${STATE_VOLUME}" &>/dev/null; then
        local remove_state=false
        # confirm intentionally returns false when the user declines.
        # shellcheck disable=SC2310
        confirm "Remove saved server state (bans, admins, stats, logs) in volume ${STATE_VOLUME}?" && remove_state=true
        if [[ "${remove_state}" == true ]]; then
            ${RUNTIME} volume rm "${STATE_VOLUME}"
            ok "State volume removed"
        else
            info "Keeping state volume ${STATE_VOLUME}"
        fi
    fi

    # Prompt before removing image
    if ${RUNTIME} image inspect "${IMAGE}" &>/dev/null; then
        local remove_image=false
        # confirm intentionally returns false when the user declines.
        # shellcheck disable=SC2310
        confirm "Remove container image ${IMAGE}?" && remove_image=true
        if [[ "${remove_image}" == true ]]; then
            ${RUNTIME} rmi "${IMAGE}"
            ok "Image removed"
        else
            info "Keeping container image"
        fi
    fi

    echo ""
    ok "Uninstall complete"
}

# --- Install ----------------------------------------------------------------

do_install() {
    info "CS 1.6 ScoutzKnivez Server — Installer"
    echo ""

    detect_runtime

    # Verify podman rootless mode
    if [[ "${RUNTIME}" == "podman" ]]; then
        if ! podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
            warn "Podman rootless mode not detected — the server may require root"
        fi
    fi

    # --- Pull image ----------------------------------------------------------

    info "Pulling container image: ${IMAGE}"
    ${RUNTIME} pull "${IMAGE}"
    ok "Image pulled"

    # The digest names exactly this build: keep it to come back to.
    local digest
    digest=$(${RUNTIME} image inspect --format '{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null) || digest=""
    if [[ "${digest}" == *@sha256:* ]]; then
        info "This build: ${digest}"
        info "To return to it later: CS_SERVER_IMAGE=${digest}"
    fi

    if [[ "${AUTO_UPDATE}" == "1" && "${RUNTIME}" != "podman" ]]; then
        warn "CS_AUTO_UPDATE=1 is only supported with Podman; ignoring it"
        AUTO_UPDATE=0
    fi

    # --- Create config directory ---------------------------------------------

    info "Creating config directory: ${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"

    seed_config

    # --- Start server --------------------------------------------------------

    if [[ "${RUNTIME}" == "podman" ]]; then
        install_podman
    else
        install_docker
    fi
}

# --- Default config ---------------------------------------------------------

# Files bind-mounted into the container. Keep in sync with compose.yml and
# quadlet/scoutzknivez.container (tests/mounts_test.sh checks all of them).
CONFIG_FILES=(server.cfg mapcycle.txt mapcycle-dust2.txt mapcycle-nipper.txt mapcycle-nipper-xmas.txt)

# Seed missing config files from the image itself, so the defaults always
# match the image version. Existing files are never overwritten.
seed_config() {
    local tmp f rel rcon_password
    tmp=$(mktemp -d) || error "Unable to create a temporary directory"
    if ! ${RUNTIME} run --rm --network none --entrypoint sh "${IMAGE}" -c \
        'cd /hlds/cstrike && tar -cf - server.cfg mapcycle*.txt modes' |
        tar -C "${tmp}" --no-same-owner -xf -; then
        rm -rf "${tmp}"
        error "Unable to read the default config from ${IMAGE}"
    fi

    mkdir -p "${CONFIG_DIR}/modes"
    for f in "${tmp}"/*.cfg "${tmp}"/*.txt "${tmp}"/modes/*.cfg; do
        [[ -f "${f}" ]] || continue
        rel="${f#"${tmp}"/}"
        if [[ -e "${CONFIG_DIR}/${rel}" ]]; then
            ok "${rel} already exists, skipping"
            continue
        fi
        cp "${f}" "${CONFIG_DIR}/${rel}"
        ok "Default ${rel} created"
    done
    rm -rf "${tmp}"

    for f in "${CONFIG_FILES[@]}"; do
        [[ -f "${CONFIG_DIR}/${f}" ]] || error "${IMAGE} does not provide ${f}; use a newer image"
    done

    # Network rcon is opt-in: with no rcon_password the engine refuses every
    # rcon packet, and the local console (podman exec, the FIFO) needs none.
    if [[ "${CS_RCON:-0}" == "1" ]] && ! grep -q '^rcon_password' "${CONFIG_DIR}/server.cfg"; then
        rcon_password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n') || error "Unable to generate an RCON password"
        printf 'rcon_password "%s"\n' "${rcon_password}" >> "${CONFIG_DIR}/server.cfg"
        ok "Generated rcon_password in ${CONFIG_DIR}/server.cfg (keep that file private)"
    fi
    chmod 700 "${CONFIG_DIR}/modes"
    find "${CONFIG_DIR}" -type f -exec chmod 600 {} +
}

# --- Podman install (Quadlet) -----------------------------------------------

install_podman() {
    # A running server keeps its old image until restarted (upgrade, rollback).
    local was_active=0
    if systemctl --user is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        was_active=1
    fi

    info "Installing Quadlet systemd unit"
    mkdir -p "${QUADLET_DIR}"

    # systemd expands % specifiers in unit files; a URL may carry %XX escapes.
    local fastdl_env=""
    if [[ -n "${FASTDL_URL}" ]]; then
        fastdl_env=$'\n'"Environment=FASTDL_URL=${FASTDL_URL//%/%%}"
    fi
    # podman-auto-update pulls the tag, restarts the unit and, because the
    # unit only counts as started once healthy (Notify=healthy), puts the
    # previous image back when the new one does not come up.
    local auto_update=""
    if [[ "${AUTO_UPDATE}" == "1" ]]; then
        auto_update=$'\n'"AutoUpdate=registry"
    fi

    cat > "${QUADLET_DIR}/${SERVICE_NAME}.container" << QUADLET
[Unit]
Description=CS 1.6 ScoutzKnivez Server
Wants=network-online.target
After=network-online.target

[Container]
Image=${IMAGE}${auto_update}
ContainerName=${SERVICE_NAME}
PublishPort=27015:27015/udp
Volume=${CONFIG_DIR}/server.cfg:/hlds/cstrike/server.cfg:ro,Z
Volume=${CONFIG_DIR}/mapcycle.txt:/hlds/cstrike/mapcycle.txt:ro,Z
Volume=${CONFIG_DIR}/mapcycle-dust2.txt:/hlds/cstrike/mapcycle-dust2.txt:ro,Z
Volume=${CONFIG_DIR}/mapcycle-nipper.txt:/hlds/cstrike/mapcycle-nipper.txt:ro,Z
Volume=${CONFIG_DIR}/mapcycle-nipper-xmas.txt:/hlds/cstrike/mapcycle-nipper-xmas.txt:ro,Z
Volume=${CONFIG_DIR}/modes:/hlds/cstrike/modes:ro,Z
Volume=${STATE_VOLUME}:/hlds/state
Environment=MAP=scoutzknivez
Environment=MAXPLAYERS=20
Environment=PORT=27015
Environment=BOTS=1
Environment=MAPCYCLE=mapcycle.txt
Environment=LAN_MODE=0
Environment=MODE=scoutz
Environment=LOGS=1
Environment=LOG_RETENTION_DAYS=7${fastdl_env}
ReadOnly=true
Tmpfs=/tmp
DropCapability=ALL
NoNewPrivileges=true
HealthCmd=/healthcheck.sh
HealthInterval=30s
HealthTimeout=5s
HealthStartPeriod=60s
HealthRetries=3
Notify=healthy

[Service]
Restart=on-failure
TimeoutStartSec=180
RestartSec=10
TimeoutStopSec=50
MemoryMax=512M
CPUQuota=200%

[Install]
WantedBy=default.target
QUADLET

    ok "Quadlet unit installed to ${QUADLET_DIR}/${SERVICE_NAME}.container"

    info "Reloading systemd and starting server"
    systemctl --user daemon-reload
    systemctl --user enable --now "${SERVICE_NAME}"
    if [[ "${was_active}" == "1" ]]; then
        info "Restarting the running server on ${IMAGE} (in-game countdown, about 35 s)"
        systemctl --user restart "${SERVICE_NAME}"
    fi
    if [[ "${AUTO_UPDATE}" == "1" ]]; then
        systemctl --user enable --now podman-auto-update.timer
        ok "Automatic updates enabled (podman-auto-update.timer, daily)"
    fi

    sleep 3

    if systemctl --user is-active --quiet "${SERVICE_NAME}"; then
        ok "Server is running!"
    else
        warn "Server may still be starting (first launch downloads Steam API state)"
        warn "Check status with: systemctl --user status ${SERVICE_NAME}"
    fi

    echo ""
    info "Installation complete!"
    echo ""
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || server_ip=""
    server_ip="${server_ip:-your-ip}"
    echo "  Server address:  ${server_ip}:27015"
    echo "  Image:           ${IMAGE}"
    echo "  Config files:    ${CONFIG_DIR}/"
    echo "  Saved state:     volume ${STATE_VOLUME} (bans, admins, stats, logs)"
    echo "  Quadlet unit:    ${QUADLET_DIR}/${SERVICE_NAME}.container"
    echo ""
    echo "  Useful commands:"
    echo "    systemctl --user status ${SERVICE_NAME}     # check status"
    echo "    systemctl --user restart ${SERVICE_NAME}    # restart server"
    echo "    systemctl --user stop ${SERVICE_NAME}       # stop server"
    echo "    podman logs -f ${SERVICE_NAME}              # follow logs"
    echo "    journalctl --user -u ${SERVICE_NAME} -f     # systemd journal"
    echo ""
    echo "  Edit ${CONFIG_DIR}/server.cfg to customize gameplay settings."
    echo "  Restart the service after config changes."
    echo ""
}

# --- Docker install ----------------------------------------------------------

install_docker() {
    # Stop existing container if present
    if docker container inspect "${SERVICE_NAME}" &>/dev/null; then
        info "Removing existing container: ${SERVICE_NAME}"
        docker stop "${SERVICE_NAME}" 2>/dev/null || true
        docker rm "${SERVICE_NAME}" 2>/dev/null || true
    fi

    local fastdl_args=()
    if [[ -n "${FASTDL_URL}" ]]; then
        fastdl_args=(-e "FASTDL_URL=${FASTDL_URL}")
    fi

    # The seccomp profile built into Docker 29 answers the i386 HLDS binary's
    # 32-bit socket() with ENOSYS, so it can't open its port. The image
    # carries Docker's upstream default profile, which does not have that
    # fault; an image from before 1.1.0 has none and runs unconfined.
    local seccomp="${CONFIG_DIR}/seccomp.json"
    if docker run --rm --network none --entrypoint cat "${IMAGE}" \
        /usr/local/share/cs-server/seccomp.json > "${seccomp}.new" 2>/dev/null && [[ -s "${seccomp}.new" ]]; then
        mv "${seccomp}.new" "${seccomp}"
        chmod 600 "${seccomp}"
    else
        rm -f "${seccomp}.new" "${seccomp}"
        seccomp="unconfined"
        warn "${IMAGE} has no seccomp profile; running with seccomp=unconfined"
    fi

    info "Creating and starting container"
    docker run -d \
        --name "${SERVICE_NAME}" \
        --restart on-failure:10 \
        --security-opt "seccomp=${seccomp}" \
        -p 27015:27015/udp \
        -v "${CONFIG_DIR}/server.cfg:/hlds/cstrike/server.cfg:ro" \
        -v "${CONFIG_DIR}/mapcycle.txt:/hlds/cstrike/mapcycle.txt:ro" \
        -v "${CONFIG_DIR}/mapcycle-dust2.txt:/hlds/cstrike/mapcycle-dust2.txt:ro" \
        -v "${CONFIG_DIR}/mapcycle-nipper.txt:/hlds/cstrike/mapcycle-nipper.txt:ro" \
        -v "${CONFIG_DIR}/mapcycle-nipper-xmas.txt:/hlds/cstrike/mapcycle-nipper-xmas.txt:ro" \
        -v "${CONFIG_DIR}/modes:/hlds/cstrike/modes:ro" \
        -v "${STATE_VOLUME}:/hlds/state" \
        -e MAP=scoutzknivez \
        -e MAXPLAYERS=20 \
        -e PORT=27015 \
        -e BOTS=1 \
        -e MAPCYCLE=mapcycle.txt \
        -e LAN_MODE=0 \
        -e MODE=scoutz \
        -e LOGS=1 \
        -e LOG_RETENTION_DAYS=7 \
        ${fastdl_args[@]+"${fastdl_args[@]}"} \
        --read-only \
        --tmpfs /tmp \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --memory 512m \
        --cpus 2 \
        "${IMAGE}"

    sleep 3

    if docker container inspect -f '{{.State.Running}}' "${SERVICE_NAME}" 2>/dev/null | grep -q true; then
        ok "Server is running!"
    else
        warn "Server may still be starting (first launch downloads Steam API state)"
        warn "Check status with: docker ps -f name=${SERVICE_NAME}"
    fi

    echo ""
    info "Installation complete!"
    echo ""
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || server_ip=""
    server_ip="${server_ip:-your-ip}"
    echo "  Server address:  ${server_ip}:27015"
    echo "  Image:           ${IMAGE}"
    echo "  Config files:    ${CONFIG_DIR}/"
    echo "  Saved state:     volume ${STATE_VOLUME} (bans, admins, stats, logs)"
    echo ""
    echo "  Useful commands:"
    echo "    docker ps -f name=${SERVICE_NAME}           # check status"
    echo "    docker restart ${SERVICE_NAME}              # restart server"
    echo "    docker stop ${SERVICE_NAME}                 # stop server"
    echo "    docker logs -f ${SERVICE_NAME}              # follow logs"
    echo ""
    echo "  Edit ${CONFIG_DIR}/server.cfg to customize gameplay settings."
    echo "  Restart the container after config changes."
    echo ""
}

# --- Host tuning checks -----------------------------------------------------

check_host_tuning() {
    echo ""
    info "Checking host performance tuning..."

    local issues=0

    # --- Kernel timer (CONFIG_HZ) ---
    local hz=""
    local config_file=""
    local kernel_release=""
    kernel_release=$(uname -r) || kernel_release=""
    if [[ -r /proc/config.gz ]] && command -v zcat >/dev/null 2>&1; then
        config_file="/proc/config.gz"
        hz=$(zcat "${config_file}" 2>/dev/null | grep -m1 '^CONFIG_HZ=' | cut -d= -f2 || true)
    elif [[ -n "${kernel_release}" && -r "/boot/config-${kernel_release}" ]]; then
        config_file="/boot/config-${kernel_release}"
        hz=$(grep -m1 '^CONFIG_HZ=' "${config_file}" 2>/dev/null | cut -d= -f2 || true)
    fi

    if [[ -n "${hz}" ]] && [[ "${hz}" =~ ^[0-9]+$ ]]; then
        if [[ "${hz}" -ge 1000 ]] 2>/dev/null; then
            ok "Kernel timer: ${hz} Hz"
        else
            warn "Kernel timer: ${hz} Hz (1000 Hz may improve HLDS tick consistency)"
            echo "      Treat host kernel changes as an operator decision and benchmark before/after."
            issues=$((issues + 1))
        fi
    else
        info "Kernel timer: could not detect CONFIG_HZ (skipping)"
    fi

    # --- CPU frequency governor ---
    local gov_path="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    if [[ -r "${gov_path}" ]]; then
        local gov
        gov=$(cat "${gov_path}")
        if [[ "${gov}" == "performance" ]]; then
            ok "CPU governor: ${gov}"
        else
            info "CPU governor: ${gov} (host-managed policy; no change recommended automatically)"
        fi
    else
        info "CPU governor: not available (VM, container, or no cpufreq — skipping)"
    fi

    # --- Query-flood rate limit (never applied automatically) ---
    if command -v nft >/dev/null 2>&1; then
        info "Public server? An nftables recipe rate-limits query floods per source address:"
        echo "      https://github.com/${REPO}#query-floods"
    fi

    if [[ "${issues}" -eq 0 ]]; then
        ok "Host tuning looks good"
    else
        echo ""
        info "The above host tuning is optional but improves server tick accuracy."
        info "Re-run after applying changes to verify."
    fi
}

# --- Main -------------------------------------------------------------------

if [[ "${ACTION}" == "uninstall" ]]; then
    do_uninstall
else
    do_install
    check_host_tuning
fi
