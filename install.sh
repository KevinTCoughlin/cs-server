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
set -euo pipefail

REPO="KevinTCoughlin/cs-server"
REGISTRY="ghcr.io"
IMAGE="${REGISTRY}/${REPO}:latest"
SERVICE_NAME="scoutzknivez"
CONFIG_DIR="${HOME}/.config/cs-server"
QUADLET_DIR="${HOME}/.config/containers/systemd"
RUNTIME=""

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
    if command -v podman &>/dev/null; then
        RUNTIME="podman"
        ok "Podman found: $(command -v podman)"
    elif command -v docker &>/dev/null; then
        RUNTIME="docker"
        ok "Docker found: $(command -v docker)"
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
        if confirm "Remove config directory ${CONFIG_DIR}?"; then
            rm -rf "${CONFIG_DIR}"
            ok "Config directory removed"
        else
            info "Keeping config directory"
        fi
    fi

    # Prompt before removing image
    if ${RUNTIME} image inspect "${IMAGE}" &>/dev/null; then
        if confirm "Remove container image ${IMAGE}?"; then
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

    # --- Create config directory ---------------------------------------------

    info "Creating config directory: ${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}"

    if [[ ! -f "${CONFIG_DIR}/server.cfg" ]]; then
        cat > "${CONFIG_DIR}/server.cfg" << 'SERVER_CFG'
// CS 1.6 ScoutzKnivez Server Configuration
// Edit this file to customize your server

hostname "ScoutzKnivez Server"
rcon_password ""

// Gameplay — ScoutzKnivez settings
sv_gravity 240
sv_airaccelerate 100
mp_freezetime 0
mp_buytime 0
mp_roundtime 3
mp_startmoney 16000
mp_autoteambalance 1
mp_friendlyfire 0

// Network
sv_maxrate 25000
sv_minrate 5000
sv_maxupdaterate 102
sv_minupdaterate 30

// Bots
bot_quota 10
bot_quota_mode "fill"
bot_difficulty 1
bot_join_after_player 0
bot_auto_vacate 1

// Anti-abuse
sv_max_queries_sec 3
sv_rcon_maxfailures 5
sv_rcon_banpenalty 60
SERVER_CFG
        ok "Default server.cfg created"
    else
        ok "server.cfg already exists, skipping"
    fi

    if [[ ! -f "${CONFIG_DIR}/mapcycle.txt" ]]; then
        cat > "${CONFIG_DIR}/mapcycle.txt" << 'MAPCYCLE'
scoutzknivez
scoutzknivez_2k
scoutzknivez_bender
MAPCYCLE
        ok "Default mapcycle.txt created"
    else
        ok "mapcycle.txt already exists, skipping"
    fi

    # --- Start server --------------------------------------------------------

    if [[ "${RUNTIME}" == "podman" ]]; then
        install_podman
    else
        install_docker
    fi
}

# --- Podman install (Quadlet) -----------------------------------------------

install_podman() {
    info "Installing Quadlet systemd unit"
    mkdir -p "${QUADLET_DIR}"

    cat > "${QUADLET_DIR}/${SERVICE_NAME}.container" << QUADLET
[Unit]
Description=CS 1.6 ScoutzKnivez Server
After=network-online.target

[Container]
Image=${IMAGE}
ContainerName=${SERVICE_NAME}
PublishPort=27015:27015/udp
PublishPort=27015:27015/tcp
Volume=${CONFIG_DIR}/server.cfg:/hlds/cstrike/server.cfg:ro,Z
Volume=${CONFIG_DIR}/mapcycle.txt:/hlds/cstrike/mapcycle.txt:ro,Z
Environment=MAP=scoutzknivez
Environment=MAXPLAYERS=20
Environment=PORT=27015
Environment=BOTS=1
Sysctl=net.core.rmem_max=26214400
Sysctl=net.core.wmem_max=26214400
DropCapability=ALL
NoNewPrivileges=true

[Service]
Restart=on-failure
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
    echo "  Server address:  $(hostname -I 2>/dev/null | awk '{print $1}' || echo 'your-ip'):27015"
    echo "  Config files:    ${CONFIG_DIR}/"
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

    info "Creating and starting container"
    docker run -d \
        --name "${SERVICE_NAME}" \
        --restart on-failure:10 \
        -p 27015:27015/udp \
        -p 27015:27015/tcp \
        -v "${CONFIG_DIR}/server.cfg:/hlds/cstrike/server.cfg:ro" \
        -v "${CONFIG_DIR}/mapcycle.txt:/hlds/cstrike/mapcycle.txt:ro" \
        -e MAP=scoutzknivez \
        -e MAXPLAYERS=20 \
        -e PORT=27015 \
        -e BOTS=1 \
        --sysctl net.core.rmem_max=26214400 \
        --sysctl net.core.wmem_max=26214400 \
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
    echo "  Server address:  $(hostname -I 2>/dev/null | awk '{print $1}' || echo 'your-ip'):27015"
    echo "  Config files:    ${CONFIG_DIR}/"
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

# --- Main -------------------------------------------------------------------

if [[ "${ACTION}" == "uninstall" ]]; then
    do_uninstall
else
    do_install
fi
