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
umask 077

REPO="KevinTCoughlin/cs-server"
REGISTRY="ghcr.io"
IMAGE="${REGISTRY}/${REPO}:latest"
IMAGE="${CS_SERVER_IMAGE:-${IMAGE}}"
SERVICE_NAME="scoutzknivez"
CONFIG_DIR="${HOME}/.config/cs-server"
QUADLET_DIR="${HOME}/.config/containers/systemd"
RUNTIME=""

if [[ -z "${IMAGE}" || "${IMAGE}" =~ [[:space:]] ]]; then
    printf '[error] Invalid CS_SERVER_IMAGE: %s\n' "${IMAGE}" >&2
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

    # --- Create config directory ---------------------------------------------

    info "Creating config directory: ${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"

    if [[ ! -f "${CONFIG_DIR}/server.cfg" ]]; then
        local rcon_password
        rcon_password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n') || error "Unable to generate an RCON password"
        cat > "${CONFIG_DIR}/server.cfg" << 'SERVER_CFG'
// CS 1.6 ScoutzKnivez Server Configuration
// Edit this file to customize your server

hostname "ScoutzKnivez Server"

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
sv_max_queries_window 30
sv_rcon_maxfailures 5
sv_rcon_banpenalty 60
SERVER_CFG
        printf 'rcon_password "%s"\n' "${rcon_password}" >> "${CONFIG_DIR}/server.cfg"
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

    if [[ ! -f "${CONFIG_DIR}/mapcycle-dust2.txt" ]]; then
        cat > "${CONFIG_DIR}/mapcycle-dust2.txt" << 'DUST2MAPCYCLE'
de_dust2
DUST2MAPCYCLE
        ok "Default mapcycle-dust2.txt created"
    else
        ok "mapcycle-dust2.txt already exists, skipping"
    fi

    if [[ ! -f "${CONFIG_DIR}/mapcycle-nipper.txt" ]]; then
        cat > "${CONFIG_DIR}/mapcycle-nipper.txt" << 'NIPPERMAPCYCLE'
scoutzknivez
scoutzknivez_2k
scoutzknivez_bender
scoutzknivez2
scoutzknivez_pro
scoutzknivez_winter
scoutzknivez_x
NIPPERMAPCYCLE
        ok "Default mapcycle-nipper.txt created"
    else
        ok "mapcycle-nipper.txt already exists, skipping"
    fi
    chmod 600 "${CONFIG_DIR}"/*.cfg "${CONFIG_DIR}"/*.txt

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
Wants=network-online.target
After=network-online.target

[Container]
Image=${IMAGE}
ContainerName=${SERVICE_NAME}
PublishPort=27015:27015/udp
PublishPort=27015:27015/tcp
Volume=${CONFIG_DIR}/server.cfg:/hlds/cstrike/server.cfg:ro,Z
Volume=${CONFIG_DIR}/mapcycle.txt:/hlds/cstrike/mapcycle.txt:ro,Z
Volume=${CONFIG_DIR}/mapcycle-dust2.txt:/hlds/cstrike/mapcycle-dust2.txt:ro,Z
Volume=${CONFIG_DIR}/mapcycle-nipper.txt:/hlds/cstrike/mapcycle-nipper.txt:ro,Z
Environment=MAP=scoutzknivez
Environment=MAXPLAYERS=20
Environment=PORT=27015
Environment=BOTS=1
Environment=MAPCYCLE=mapcycle.txt
Environment=LAN_MODE=0
Sysctl=net.core.rmem_max=26214400
Sysctl=net.core.wmem_max=26214400
DropCapability=ALL
NoNewPrivileges=true
HealthCmd=grep -qs hlds_linux /proc/[0-9]*/comm
HealthInterval=30s
HealthTimeout=5s
HealthStartPeriod=60s
HealthRetries=3
Notify=healthy

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
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || server_ip=""
    server_ip="${server_ip:-your-ip}"
    echo "  Server address:  ${server_ip}:27015"
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
        -v "${CONFIG_DIR}/mapcycle-dust2.txt:/hlds/cstrike/mapcycle-dust2.txt:ro" \
        -v "${CONFIG_DIR}/mapcycle-nipper.txt:/hlds/cstrike/mapcycle-nipper.txt:ro" \
        -e MAP=scoutzknivez \
        -e MAXPLAYERS=20 \
        -e PORT=27015 \
        -e BOTS=1 \
        -e MAPCYCLE=mapcycle.txt \
        -e LAN_MODE=0 \
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
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || server_ip=""
    server_ip="${server_ip:-your-ip}"
    echo "  Server address:  ${server_ip}:27015"
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
