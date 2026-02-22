#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# CS 1.6 ScoutzKnivez Server — One-line installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash
#
# What this does:
#   1. Checks for Podman (required)
#   2. Pulls the container image from ghcr.io
#   3. Creates config directory with default settings
#   4. Installs Quadlet systemd unit for auto-start
#   5. Starts the server
#
set -euo pipefail

REPO="KevinTCoughlin/cs-server"
REGISTRY="ghcr.io"
IMAGE="${REGISTRY}/${REPO}:latest"
SERVICE_NAME="scoutzknivez"
CONFIG_DIR="${HOME}/.config/cs-server"
QUADLET_DIR="${HOME}/.config/containers/systemd"

# --- Helpers ----------------------------------------------------------------

info()  { printf '\033[1;34m[info]\033[0m  %s\n' "$1"; }
ok()    { printf '\033[1;32m[ok]\033[0m    %s\n' "$1"; }
warn()  { printf '\033[1;33m[warn]\033[0m  %s\n' "$1"; }
error() { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; exit 1; }

check_command() {
    if ! command -v "$1" &>/dev/null; then
        error "$1 is required but not installed. See: $2"
    fi
    ok "$1 found: $(command -v "$1")"
}

# --- Preflight checks -------------------------------------------------------

info "CS 1.6 ScoutzKnivez Server — Installer"
echo ""

check_command podman "https://podman.io/getting-started/installation"

# Verify podman can run rootless containers
if ! podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
    warn "Podman rootless mode not detected — the server may require root"
fi

# --- Pull image --------------------------------------------------------------

info "Pulling container image: ${IMAGE}"
podman pull "${IMAGE}"
ok "Image pulled"

# --- Create config directory -------------------------------------------------

info "Creating config directory: ${CONFIG_DIR}"
mkdir -p "${CONFIG_DIR}"

if [ ! -f "${CONFIG_DIR}/server.cfg" ]; then
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

if [ ! -f "${CONFIG_DIR}/mapcycle.txt" ]; then
    cat > "${CONFIG_DIR}/mapcycle.txt" << 'MAPCYCLE'
scoutzknivez
scoutzknivez_2k
scoutzknivez_bender
MAPCYCLE
    ok "Default mapcycle.txt created"
else
    ok "mapcycle.txt already exists, skipping"
fi

# --- Install Quadlet unit ----------------------------------------------------

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
DropCapability=ALL
NoNewPrivileges=true
StopTimeout=50

[Service]
Restart=on-failure
RestartSec=10
MemoryMax=512M
CPUQuota=200%

[Install]
WantedBy=default.target
QUADLET

ok "Quadlet unit installed to ${QUADLET_DIR}/${SERVICE_NAME}.container"

# --- Start service -----------------------------------------------------------

info "Reloading systemd and starting server"
systemctl --user daemon-reload
systemctl --user enable --now "${SERVICE_NAME}"

# Give it a moment to start
sleep 3

if systemctl --user is-active --quiet "${SERVICE_NAME}"; then
    ok "Server is running!"
else
    warn "Server may still be starting (first launch downloads Steam API state)"
    warn "Check status with: systemctl --user status ${SERVICE_NAME}"
fi

# --- Done --------------------------------------------------------------------

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
