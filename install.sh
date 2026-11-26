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
#   CS_SERVER_VERSION  release to run instead of the pinned one (DEFAULT_VERSION
#                      below): 1.0.0 (exact), 1.0 or 1 (newest patch / minor)
#   CS_SERVER_IMAGE    full image reference instead, e.g. one pinned by digest,
#                      or ghcr.io/kevintcoughlin/cs-server:latest for main's build
#   CS_RUNTIME         podman or docker. Default: podman when it is installed
#   CS_BACKUP=1        daily archive of the state volume (ops/backup-state.sh)
#   CS_AUTO_UPDATE=1   Podman only: let podman-auto-update pull new images for
#                      the tag (use with CS_SERVER_VERSION=1 or 1.0). Rollback
#                      of a bad image needs Podman 5 (Notify=healthy)
#   CS_RCON=1          generate an rcon_password for network rcon (off by
#                      default; the local console needs none)
#   FASTDL_URL         http(s) URL that serves your cstrike/ content
#   CS_PROFILE=lan     LAN party server: host networking and sv_lan 1, so it
#                      shows in the LAN tab; no Steam, no VAC, no master list
#   SERVER_IP          IPv4 address to bind and report (+ip), for a public
#                      server on host networking or a multi-homed host
#   CS_INSTANCE        name of an additional server on this host (letters,
#                      digits, hyphens). Gets its own service, config
#                      directory and state volume; needs CS_PORT
#   CS_PORT            UDP port (default 27015). Each instance needs its own
#   CS_MODE            Counter-Strike game mode at startup: scoutz (default),
#                      knife, vanilla, match, climb or surf
#   CS_BOTS=0          no bots (default 1; 0 in climb and surf mode)
#   CS_FASTDL=1        also run a FastDL sidecar: a small web server from the
#                      same image that serves the maps to clients over HTTP
#                      (CS_FASTDL_PORT, default 27080/tcp; CS_FASTDL_HOST is the
#                      address clients use, default this machine's first one)
#   CS_LAN_KIT=<n>     LAN event: n servers (1 to 8) named lan1..lan<n> on
#                      consecutive ports from CS_PORT, LAN profile, match mode,
#                      no bots, and one FastDL sidecar for all of them
#   CS_METRICS_PORT    serve Prometheus metrics (players, map, uptime, server
#                      FPS) at http://127.0.0.1:<port>/metrics;
#                      CS_METRICS_BIND names another address to listen on
#   CS_GAME            another Valve game on the same engine: czero, dod, tfc,
#                      valve, gearbox, dmc or ricochet (default cstrike). Gets
#                      its own image tag, service (<game>-server), config
#                      directory and state volume
#   CS_DOD_MODE        Day of Defeat only: pub (default) or match (6v6, 12 slots)
#   CS_DOD_PASSWORD    Day of Defeat match password (sv_password). Optional
#   CS_GSLT            32-character hex Steam game server login token
#                      (sv_setsteamaccount). One token per server, for that
#                      game's app id (10 for Counter-Strike, 30 for Day of Defeat)
#   CS_INSECURE=1      pass -insecure without -nomaster (off by default)
#
# With no route to the registry, an image already in local storage (from
# `podman load` / `docker load`) is used as it is.
#
set -euo pipefail
umask 077

REPO="KevinTCoughlin/cs-server"
REGISTRY="ghcr.io"
# Image names are lowercase; engines reject the repository's mixed case.
IMAGE_REPO="${REGISTRY}/kevintcoughlin/cs-server"
# Newest released version in CHANGELOG.md (the first ## [x.y.z] heading).
# tests/install_test.sh fails when this and that heading differ, so a release
# that renames [Unreleased] updates this too. :latest is not the default:
# that tag moves with every push to main. CS_SERVER_VERSION and
# CS_SERVER_IMAGE still override it. The same comparison lives in
# ops/bootstrap-vps.sh (version_ge); keep the two copies in step.
DEFAULT_VERSION="1.4.2"
VERSION="${CS_SERVER_VERSION:-${DEFAULT_VERSION}}"
VERSION="${VERSION#v}"
if [[ -n "${VERSION}" && ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf '[error] Invalid CS_SERVER_VERSION: %s (expected 1.0.0, 1.0 or 1)\n' "${CS_SERVER_VERSION}" >&2
    exit 1
fi
# Another game is the same release under a tag suffix: 1.3.0-dod, or dod for
# the newest. Keep the titles in step with scripts/game-env.sh.
GAME="${CS_GAME:-cstrike}"
case "${GAME}" in
    cstrike)  GAME_TITLE="CS 1.6 ScoutzKnivez" ;;
    czero)    GAME_TITLE="Condition Zero" ;;
    dod)      GAME_TITLE="Day of Defeat" ;;
    tfc)      GAME_TITLE="Team Fortress Classic" ;;
    valve)    GAME_TITLE="Half-Life" ;;
    gearbox)  GAME_TITLE="Opposing Force" ;;
    dmc)      GAME_TITLE="Deathmatch Classic" ;;
    ricochet) GAME_TITLE="Ricochet" ;;
    *)
        printf '[error] Invalid CS_GAME: %s (expected cstrike, czero, dod, tfc, valve, gearbox, dmc or ricochet)\n' "${GAME}" >&2
        exit 1
        ;;
esac
IMAGE="${IMAGE_REPO}:${VERSION:-latest}"
if [[ "${GAME}" != "cstrike" ]]; then
    IMAGE="${IMAGE_REPO}:${VERSION:+${VERSION}-}${GAME}"
fi
IMAGE="${CS_SERVER_IMAGE:-${IMAGE}}"
AUTO_UPDATE="${CS_AUTO_UPDATE:-0}"
# Podman 5 emits Notify=healthy. check_podman_quadlet clears this on 4.4–4.9.
# --print-unit does not detect a version, so the unit in the repository
# (just quadlet) is the Podman 5 unit.
PODMAN_NOTIFY=1
PODMAN_CHECKED=0
LINGER_DONE=0
BACKUP_DONE=0
CS_BACKUP="${CS_BACKUP:-0}"
if [[ "${CS_BACKUP}" != "0" && "${CS_BACKUP}" != "1" ]]; then
    printf '[error] Invalid CS_BACKUP: %s (expected 0 or 1)\n' "${CS_BACKUP}" >&2
    exit 1
fi
CS_BACKUP_KEEP="${CS_BACKUP_KEEP:-14}"
if [[ ! "${CS_BACKUP_KEEP}" =~ ^[0-9]+$ ]] || [[ "${CS_BACKUP_KEEP}" -lt 1 ]]; then
    printf '[error] Invalid CS_BACKUP_KEEP: %s (expected a positive integer)\n' "${CS_BACKUP_KEEP}" >&2
    exit 1
fi
RUNTIME_CHOICE="${CS_RUNTIME:-auto}"
case "${RUNTIME_CHOICE}" in
    auto | podman | docker) ;;
    *)
        printf '[error] Invalid CS_RUNTIME: %s (expected podman, docker or auto)\n' "${CS_RUNTIME}" >&2
        exit 1
        ;;
esac
# The default instance keeps the names every earlier release used. A named
# one (CS_INSTANCE) gets its own service, config directory and state volume.
INSTANCE="${CS_INSTANCE:-}"
if [[ -n "${INSTANCE}" && ! "${INSTANCE}" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]]; then
    printf '[error] Invalid CS_INSTANCE: %s (lowercase letters, digits and hyphens, at most 32)\n' "${INSTANCE}" >&2
    exit 1
fi
PORT="${CS_PORT:-27015}"
if [[ ! "${PORT}" =~ ^[0-9]{1,5}$ ]] || [[ "$((10#${PORT}))" -lt 1024 || "$((10#${PORT}))" -gt 65535 ]]; then
    printf '[error] Invalid CS_PORT: %s (expected 1024 to 65535)\n' "${PORT}" >&2
    exit 1
fi
PORT="$((10#${PORT}))"
# set_names: the service, config directory and state volume of INSTANCE.
set_names() {
    SERVICE_NAME="scoutzknivez"
    CONFIG_DIR="${HOME}/.config/cs-server"
    # Named volume for what the server writes: bans, admins, stats, logs.
    STATE_VOLUME="cs-server-state"
    if [[ -n "${INSTANCE}" ]]; then
        SERVICE_NAME="cs-server-${INSTANCE}"
        CONFIG_DIR="${HOME}/.config/cs-server-${INSTANCE}"
        STATE_VOLUME="cs-server-state-${INSTANCE}"
    fi
    # Another game never shares a name with a Counter-Strike server or instance.
    if [[ "${GAME}" != "cstrike" ]]; then
        SERVICE_NAME="${GAME}-server${INSTANCE:+-${INSTANCE}}"
        CONFIG_DIR="${HOME}/.config/${SERVICE_NAME}"
        STATE_VOLUME="${SERVICE_NAME}-state"
    fi
}
set_names

# LAN kit: several servers for one event (see run_kit).
LAN_KIT="${CS_LAN_KIT:-}"
if [[ -n "${LAN_KIT}" ]]; then
    if [[ ! "${LAN_KIT}" =~ ^[1-8]$ ]]; then
        printf '[error] Invalid CS_LAN_KIT: %s (expected 1 to 8 servers)\n' "${LAN_KIT}" >&2
        exit 1
    fi
    if [[ -n "${INSTANCE}" || "${GAME}" != "cstrike" ]]; then
        printf '[error] CS_LAN_KIT names its own servers (lan1, lan2, ...) and is Counter-Strike only: drop CS_INSTANCE and CS_GAME\n' >&2
        exit 1
    fi
fi

# Game mode and bots the server starts with.
MODE="${CS_MODE:-}"
if [[ -n "${MODE}" && "${GAME}" != "cstrike" ]]; then
    printf '[error] CS_MODE is Counter-Strike only\n' >&2
    exit 1
fi
if [[ -z "${MODE}" ]]; then
    MODE="scoutz"
    [[ -z "${LAN_KIT}" ]] || MODE="match"
fi
case "${MODE}" in
    scoutz | knife | vanilla | match | climb | surf) ;;
    *)
        printf '[error] Invalid CS_MODE: %s (expected scoutz, knife, vanilla, match, climb or surf)\n' "${MODE}" >&2
        exit 1
        ;;
esac
# Day of Defeat's own mode. CS_MODE stays Counter-Strike only.
DOD_MODE="${CS_DOD_MODE:-}"
if [[ -n "${DOD_MODE}" && "${GAME}" != "dod" ]]; then
    printf '[error] CS_DOD_MODE is Day of Defeat only\n' >&2
    exit 1
fi
if [[ "${GAME}" == "dod" ]]; then
    if [[ -z "${DOD_MODE}" ]]; then
        DOD_MODE="pub"
    fi
    case "${DOD_MODE}" in
        pub | match) ;;
        *)
            printf '[error] Invalid CS_DOD_MODE: %s (expected pub or match)\n' "${DOD_MODE}" >&2
            exit 1
            ;;
    esac
fi
DOD_PASSWORD="${CS_DOD_PASSWORD:-}"
if [[ -n "${DOD_PASSWORD}" && "${GAME}" != "dod" ]]; then
    printf '[error] CS_DOD_PASSWORD is Day of Defeat only\n' >&2
    exit 1
fi
if [[ -n "${DOD_PASSWORD}" && ! "${DOD_PASSWORD}" =~ ^[A-Za-z0-9!@#^*_=+.-]{1,32}$ ]]; then
    printf '[error] Invalid CS_DOD_PASSWORD: use 1 to 32 characters from letters, digits, and !@#^*_=+.- (no spaces or %%)\n' >&2
    exit 1
fi
GSLT="${CS_GSLT:-}"
if [[ -n "${GSLT}" && ! "${GSLT}" =~ ^[A-Fa-f0-9]{32}$ ]]; then
    printf '[error] Invalid CS_GSLT: expected a 32-character hex Steam game server token\n' >&2
    exit 1
fi
INSECURE="${CS_INSECURE:-0}"
if [[ "${INSECURE}" != "0" && "${INSECURE}" != "1" ]]; then
    printf '[error] Invalid CS_INSECURE: %s (expected 0 or 1)\n' "${INSECURE}" >&2
    exit 1
fi
BOTS="${CS_BOTS:-}"
if [[ -z "${BOTS}" ]]; then
    BOTS=1
    [[ -z "${LAN_KIT}" && "${MODE}" != "climb" && "${MODE}" != "surf" ]] || BOTS=0
fi
if [[ "${BOTS}" != "0" && "${BOTS}" != "1" ]]; then
    printf '[error] Invalid CS_BOTS: %s (expected 0 or 1)\n' "${BOTS}" >&2
    exit 1
fi

# FastDL sidecar: one per game on this machine, shared by its instances.
FASTDL="${CS_FASTDL:-}"
if [[ -z "${FASTDL}" ]]; then
    FASTDL=0
    [[ -z "${LAN_KIT}" ]] || FASTDL=1
fi
if [[ "${FASTDL}" != "0" && "${FASTDL}" != "1" ]]; then
    printf '[error] Invalid CS_FASTDL: %s (expected 0 or 1)\n' "${FASTDL}" >&2
    exit 1
fi
FASTDL_PORT="${CS_FASTDL_PORT:-27080}"
if [[ ! "${FASTDL_PORT}" =~ ^[0-9]{1,5}$ ]] || [[ "$((10#${FASTDL_PORT}))" -lt 1024 || "$((10#${FASTDL_PORT}))" -gt 65535 ]]; then
    printf '[error] Invalid CS_FASTDL_PORT: %s (expected 1024 to 65535)\n' "${FASTDL_PORT}" >&2
    exit 1
fi
FASTDL_PORT="$((10#${FASTDL_PORT}))"
FASTDL_HOST="${CS_FASTDL_HOST:-}"
if [[ -n "${FASTDL_HOST}" && ! "${FASTDL_HOST}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,62}[A-Za-z0-9])?$ ]]; then
    printf '[error] Invalid CS_FASTDL_HOST: %s (expected a host name or an IPv4 address)\n' "${FASTDL_HOST}" >&2
    exit 1
fi
FASTDL_NAME="cs-server-fastdl"
if [[ "${GAME}" != "cstrike" ]]; then
    FASTDL_NAME="${GAME}-server-fastdl"
fi
if [[ "${INSTANCE}" == "fastdl" ]]; then
    printf '[error] CS_INSTANCE=fastdl is the name of the FastDL sidecar: pick another\n' >&2
    exit 1
fi
FASTDL_DONE=0

# Prometheus endpoint in the server container; off unless a port is given.
METRICS_PORT="${CS_METRICS_PORT:-}"
if [[ -n "${METRICS_PORT}" ]]; then
    if [[ ! "${METRICS_PORT}" =~ ^[0-9]{1,5}$ ]] || [[ "$((10#${METRICS_PORT}))" -lt 1024 || "$((10#${METRICS_PORT}))" -gt 65535 ]]; then
        printf '[error] Invalid CS_METRICS_PORT: %s (expected 1024 to 65535)\n' "${METRICS_PORT}" >&2
        exit 1
    fi
    METRICS_PORT="$((10#${METRICS_PORT}))"
fi
METRICS_BIND="${CS_METRICS_BIND:-127.0.0.1}"
if [[ ! "${METRICS_BIND}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    printf '[error] Invalid CS_METRICS_BIND: %s (expected an IPv4 address)\n' "${METRICS_BIND}" >&2
    exit 1
fi
IMAGE_PULLED=0
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
PROFILE="${CS_PROFILE:-}"
if [[ -z "${PROFILE}" ]]; then
    PROFILE="public"
    [[ -z "${LAN_KIT}" ]] || PROFILE="lan"
fi
case "${PROFILE}" in
    public | lan) ;;
    *)
        printf '[error] Invalid CS_PROFILE: %s (expected public or lan)\n' "${PROFILE}" >&2
        exit 1
        ;;
esac
SERVER_IP="${SERVER_IP:-}"
if [[ -n "${SERVER_IP}" && ! "${SERVER_IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    printf '[error] Invalid SERVER_IP: %s (expected an IPv4 address)\n' "${SERVER_IP}" >&2
    exit 1
fi
# A socket bound to one address hears no broadcasts, and the LAN tab finds
# servers by broadcast.
if [[ "${PROFILE}" == "lan" && -n "${SERVER_IP}" ]]; then
    printf '[error] SERVER_IP cannot be combined with CS_PROFILE=lan: the LAN tab would not find the server\n' >&2
    exit 1
fi
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
  install.sh --print-unit Print the Quadlet unit it would install; change nothing
  install.sh --help       Show this help message

Supports Podman (preferred) and Docker. The script auto-detects
which runtime is available, preferring Podman when both are present.

Environment:
  CS_SERVER_VERSION=<v>    Release instead of the pinned one (${DEFAULT_VERSION}): 1.0.0, 1.0 or 1
  CS_SERVER_IMAGE=<image>  Run this image reference instead (e.g. a digest, or :latest)
  CS_RUNTIME=<engine>      podman or docker (default: podman if it is installed)
  CS_BACKUP=1              Daily archive of the state volume, 14 copies
  CS_AUTO_UPDATE=1         Podman: pull new images for the tag automatically
  CS_RCON=1                Generate an rcon_password (network rcon is off by default)
  FASTDL_URL=<url>         http(s) URL that serves your cstrike/ content
  CS_PROFILE=lan           LAN party server: host networking, sv_lan 1
  SERVER_IP=<ipv4>         Address to bind and report (+ip)
  CS_INSTANCE=<name>       An additional server: own service, config, state
  CS_PORT=<port>           UDP port (default 27015); one per instance
  CS_GAME=<game>           Another game: czero, dod, tfc, valve, gearbox, dmc, ricochet
  CS_DOD_MODE=<mode>       Day of Defeat: pub (default) or match (6v6, 12 slots)
  CS_DOD_PASSWORD=<pass>   Day of Defeat sv_password (optional)
  CS_GSLT=<token>          32-hex Steam token (app 10 for CS, app 30 for DoD)
  CS_INSECURE=1            -insecure, without hiding the server (-nomaster)
  CS_MODE=<mode>           Start in scoutz (default), knife, vanilla, match, climb or surf
  CS_BOTS=0                No bots
  CS_FASTDL=1              Also serve the maps to clients over HTTP (port 27080/tcp)
  CS_LAN_KIT=<n>           LAN event: n match servers (lan1..lan<n>) and FastDL
  CS_METRICS_PORT=<port>   Prometheus metrics at http://127.0.0.1:<port>/metrics

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
elif [[ "${1:-}" == "--print-unit" ]]; then
    ACTION="print-unit"
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

    if [[ "${RUNTIME_CHOICE}" == "podman" ]]; then
        command -v podman &>/dev/null || error "CS_RUNTIME=podman but podman is not installed"
        RUNTIME="podman"
        ok "Podman selected (CS_RUNTIME=podman): $(command -v podman)"
        return 0
    fi
    if [[ "${RUNTIME_CHOICE}" == "docker" ]]; then
        command -v docker &>/dev/null || error "CS_RUNTIME=docker but docker is not installed"
        RUNTIME="docker"
        ok "Docker selected (CS_RUNTIME=docker): $(command -v docker)"
        return 0
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
    info "${GAME_TITLE} Server — Uninstaller"
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
            # Another instance on this host may still run from it.
            if ${RUNTIME} rmi "${IMAGE}"; then
                ok "Image removed"
            else
                warn "Image ${IMAGE} is still in use; kept"
            fi
        else
            info "Keeping container image"
        fi
    fi

    echo ""
    ok "Uninstall complete"
}

# --- Install ----------------------------------------------------------------

do_install() {
    info "${GAME_TITLE} Server — Installer"
    echo ""

    detect_runtime

    # The Quadlet unit is a user unit, so it needs lingering to start at boot.
    # Podman before 4.4 has no Quadlet. Notify=healthy (rollback of a bad
    # auto-update) needs Podman 5; 4.4 through 4.9 omit that line.
    if [[ "${RUNTIME}" == "podman" ]]; then
        if ! podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q true; then
            warn "Podman rootless mode not detected — the server may require root"
        fi
        if [[ "${PODMAN_CHECKED}" != "1" ]]; then
            check_podman_quadlet
            PODMAN_CHECKED=1
        fi
    fi

    # --- Pull image ----------------------------------------------------------

    if [[ "${IMAGE_PULLED}" == "1" ]]; then
        :
    elif info "Pulling container image: ${IMAGE}" && ${RUNTIME} pull "${IMAGE}"; then
        ok "Image pulled"
    elif ${RUNTIME} image inspect "${IMAGE}" >/dev/null 2>&1; then
        # Offline install: the image came from `podman load` / `docker load`.
        warn "Could not pull ${IMAGE}; using the copy already on this machine"
    else
        error "Could not pull ${IMAGE} and no local copy exists. Offline? Load one first: ${RUNTIME} load -i cs-server.tar"
    fi

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

    IMAGE_PULLED=1
    seed_config

    # --- FastDL sidecar (once, before the servers that point at it) ----------

    if [[ "${FASTDL}" == "1" && "${FASTDL_DONE}" == "0" ]]; then
        ${RUNTIME} run --rm --network none --entrypoint sh "${IMAGE}" -c 'test -x /fastdl.sh' >/dev/null 2>&1 ||
            error "${IMAGE} has no FastDL server (it came with 1.4.0); use a newer image or drop CS_FASTDL / CS_LAN_KIT"
        fastdl_url
        if [[ "${RUNTIME}" == "podman" ]]; then
            install_fastdl_podman
        else
            install_fastdl_docker
        fi
        FASTDL_DONE=1
    fi

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
CONFIG_FILES=(server.cfg mapcycle.txt mapcycle-dust2.txt mapcycle-nipper.txt mapcycle-nipper-xmas.txt mapcycle-climb.txt mapcycle-surf.txt)
CONFIG_DIRS=(modes)
# Another game has its stock settings and one map cycle, and no modes.
# Day of Defeat mounts the pub and match files so an admin can edit them.
if [[ "${GAME}" == "dod" ]]; then
    CONFIG_FILES=(server.cfg mapcycle.txt mapcycle-match.txt pub.cfg match.cfg match-ot.cfg)
    CONFIG_DIRS=()
elif [[ "${GAME}" != "cstrike" ]]; then
    CONFIG_FILES=(server.cfg mapcycle.txt)
    CONFIG_DIRS=()
fi

# Seed missing config files from the image itself, so the defaults always
# match the image version. Existing files are never overwritten.
seed_config() {
    local tmp f rel rcon_password
    tmp=$(mktemp -d) || error "Unable to create a temporary directory"
    local dod_cfgs=""
    if [[ "${GAME}" == "dod" ]]; then
        dod_cfgs="pub.cfg match.cfg match-ot.cfg"
    fi
    if ! ${RUNTIME} run --rm --network none --entrypoint sh "${IMAGE}" -c \
        "cd /hlds/${GAME} && tar -cf - server.cfg mapcycle*.txt ${dod_cfgs} ${CONFIG_DIRS[*]-}" |
        tar -C "${tmp}" --no-same-owner -xf -; then
        rm -rf "${tmp}"
        error "Unable to read the default config from ${IMAGE}"
    fi

    for f in ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"}; do
        mkdir -p "${CONFIG_DIR}/${f}"
    done
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
    # The server runs as an unprivileged user in the container, which is not
    # this user there: it reads these files as "other". The directory above
    # them (mode 700) is what keeps them from other users of this machine.
    find "${CONFIG_DIR}" -mindepth 1 -type d -exec chmod 755 {} +
    find "${CONFIG_DIR}" -type f -exec chmod 644 {} +
}

# --- Starting map -----------------------------------------------------------

# The stock modes start on a stock map with the stock rotation.
start_map() {
    START_MAP="scoutzknivez"
    START_CYCLE="mapcycle.txt"
    START_PLAYERS=20
    if [[ "${GAME}" == "cstrike" && ( "${MODE}" == "vanilla" || "${MODE}" == "match" ) ]]; then
        START_MAP="de_dust2"
        START_CYCLE="mapcycle-dust2.txt"
    elif [[ "${GAME}" == "cstrike" && ( "${MODE}" == "climb" || "${MODE}" == "surf" ) ]]; then
        # No MAP: the server starts on the first map of the rotation, so an
        # edited rotation needs no second change here.
        START_MAP=""
        START_CYCLE="mapcycle-${MODE}.txt"
    elif [[ "${GAME}" == "dod" ]]; then
        START_MAP="dod_anzio"
        if [[ "${DOD_MODE}" == "match" ]]; then
            START_CYCLE="mapcycle-match.txt"
            START_PLAYERS=12
        else
            START_CYCLE="mapcycle.txt"
            START_PLAYERS=16
        fi
    fi
}

# --- FastDL sidecar ---------------------------------------------------------

# The URL the game servers hand to clients, unless FASTDL_URL names another.
fastdl_url() {
    [[ -z "${FASTDL_URL}" ]] || return 0
    local host="${FASTDL_HOST:-${SERVER_IP}}"
    if [[ -z "${host}" ]]; then
        host=$(hostname -I 2>/dev/null | awk '{print $1}') || host=""
    fi
    [[ "${host}" =~ ^[A-Za-z0-9.-]+$ ]] ||
        error "Could not work out this machine's address for FastDL; set CS_FASTDL_HOST"
    FASTDL_URL="http://${host}:${FASTDL_PORT}/${GAME}/"
}

fastdl_unit() {
    cat << QUADLET
[Unit]
Description=${GAME_TITLE} FastDL (maps over HTTP)
Wants=network-online.target
After=network-online.target

[Container]
Image=${IMAGE}
ContainerName=${FASTDL_NAME}
PodmanArgs=--entrypoint /fastdl.sh
PublishPort=${FASTDL_PORT}:${FASTDL_PORT}/tcp
Environment=FASTDL_PORT=${FASTDL_PORT}
ReadOnly=true
DropCapability=ALL
NoNewPrivileges=true
HealthCmd=/fastdl.sh check
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3

[Service]
Restart=on-failure
RestartSec=10
MemoryMax=64M

[Install]
WantedBy=default.target
QUADLET
}

install_fastdl_podman() {
    info "Installing the FastDL sidecar: ${FASTDL_NAME} on port ${FASTDL_PORT}/tcp"
    mkdir -p "${QUADLET_DIR}"
    fastdl_unit > "${QUADLET_DIR}/${FASTDL_NAME}.container"
    systemctl --user daemon-reload
    systemctl --user restart "${FASTDL_NAME}"
    ok "FastDL serves ${FASTDL_URL}"
}

install_fastdl_docker() {
    info "Starting the FastDL sidecar: ${FASTDL_NAME} on port ${FASTDL_PORT}/tcp"
    if docker container inspect "${FASTDL_NAME}" &>/dev/null; then
        docker rm -f "${FASTDL_NAME}" >/dev/null 2>&1 || true
    fi
    docker run -d \
        --name "${FASTDL_NAME}" \
        --restart on-failure:10 \
        --entrypoint /fastdl.sh \
        -p "${FASTDL_PORT}:${FASTDL_PORT}/tcp" \
        -e "FASTDL_PORT=${FASTDL_PORT}" \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        --memory 64m \
        "${IMAGE}"
    ok "FastDL serves ${FASTDL_URL}"
}

# `--uninstall` with CS_FASTDL=1 (or CS_LAN_KIT) also removes the sidecar.
# Without it the sidecar stays: other servers may still point at it.
remove_fastdl() {
    if [[ "${RUNTIME}" == "podman" ]]; then
        [[ -f "${QUADLET_DIR}/${FASTDL_NAME}.container" ]] || return 0
        info "Removing the FastDL sidecar: ${FASTDL_NAME}"
        systemctl --user stop "${FASTDL_NAME}" 2>/dev/null || true
        rm -f "${QUADLET_DIR}/${FASTDL_NAME}.container"
        systemctl --user daemon-reload
    else
        docker container inspect "${FASTDL_NAME}" &>/dev/null || return 0
        info "Removing the FastDL sidecar: ${FASTDL_NAME}"
        docker rm -f "${FASTDL_NAME}" >/dev/null 2>&1 || true
    fi
    ok "FastDL sidecar removed"
}

# --- Podman version, lingering, backups ------------------------------------

# version_ge A B is true when A is at least B. Same function as
# ops/bootstrap-vps.sh; keep the two copies in step.
version_ge() {
    local left="$1" right="$2" li ri
    while [[ -n "${left}" || -n "${right}" ]]; do
        li="${left%%.*}"
        ri="${right%%.*}"
        if [[ "${left}" == *.* ]]; then left="${left#*.}"; else left=""; fi
        if [[ "${right}" == *.* ]]; then right="${right#*.}"; else right=""; fi
        li="${li%%[^0-9]*}"
        ri="${ri%%[^0-9]*}"
        li="${li:-0}"
        ri="${ri:-0}"
        if ((10#${li} > 10#${ri})); then return 0; fi
        if ((10#${li} < 10#${ri})); then return 1; fi
    done
    return 0
}

podman_cli_version() {
    local raw=""
    raw=$(podman version --format '{{.Version}}' 2>/dev/null || true)
    if [[ ! "${raw}" =~ ^[0-9]+\.[0-9]+ ]]; then
        raw=$(podman --version 2>/dev/null || true)
    fi
    if [[ "${raw}" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

check_podman_quadlet() {
    local ver=""
    if ! ver=$(podman_cli_version); then
        error "Could not read the Podman version. Quadlet needs Podman 4.4 or newer. On Debian 12, ops/bootstrap-vps.sh installs Docker; or re-run with CS_RUNTIME=docker."
    fi
    if ! version_ge "${ver}" 4.4; then
        error "Podman ${ver} is older than 4.4, which systemd Quadlet needs. Install Podman 4.4 or newer, or use Docker (Debian 12: ops/bootstrap-vps.sh, or CS_RUNTIME=docker)."
    fi
    if version_ge "${ver}" 5.0; then
        PODMAN_NOTIFY=1
        ok "Podman ${ver}"
    else
        PODMAN_NOTIFY=0
        warn "Podman ${ver} has no Notify=healthy (that needs Podman 5). The server still runs. Automatic-update rollback is unavailable on this version."
    fi
}

# User Quadlet units start at boot only when the user's manager does.
enable_linger() {
    local user
    [[ "${LINGER_DONE}" == "1" ]] && return 0
    LINGER_DONE=1
    user="${USER:-}"
    if [[ -z "${user}" ]] && command -v id >/dev/null 2>&1; then
        user=$(id -un 2>/dev/null || true)
    fi
    if [[ -z "${user}" ]]; then
        warn "Could not tell which user to enable lingering for. The server starts at boot after: sudo loginctl enable-linger <user>"
        return 0
    fi
    if command -v loginctl >/dev/null 2>&1; then
        if loginctl show-user "${user}" -p Linger 2>/dev/null | grep -q '^Linger=yes$'; then
            ok "Lingering is already enabled for ${user}"
            return 0
        fi
        if loginctl enable-linger "${user}"; then
            ok "Lingering enabled for ${user} (the server starts at boot)"
            return 0
        fi
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n loginctl enable-linger "${user}"; then
        ok "Lingering enabled for ${user} (the server starts at boot)"
        return 0
    fi
    warn "Could not enable lingering for ${user}. The server starts at boot only after: sudo loginctl enable-linger ${user}"
}

# Copy ops/backup-state.sh and its user timer. A curled install.sh downloads
# them from the same repository; a checkout uses the files beside this script.
install_backup() {
    local script_path script_dir ops="" fetched="" dest unit_dir
    [[ "${CS_BACKUP}" == "1" ]] || return 0
    [[ "${BACKUP_DONE}" == "1" ]] && return 0
    script_path="${BASH_SOURCE[0]}"
    script_dir="."
    if [[ "${script_path}" == */* ]]; then
        script_dir="${script_path%/*}"
    fi
    if [[ -f "${script_dir}/ops/backup-state.sh" ]]; then
        ops="${script_dir}/ops"
    else
        command -v curl >/dev/null 2>&1 || error "curl is required to download the backup units (CS_BACKUP=1)"
        fetched=$(mktemp -d)
        mkdir -p "${fetched}/systemd"
        curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/ops/backup-state.sh" \
            -o "${fetched}/backup-state.sh" \
            || error "Could not download ops/backup-state.sh"
        curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/ops/systemd/cs-server-backup.service" \
            -o "${fetched}/systemd/cs-server-backup.service" \
            || error "Could not download ops/systemd/cs-server-backup.service"
        curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/ops/systemd/cs-server-backup.timer" \
            -o "${fetched}/systemd/cs-server-backup.timer" \
            || error "Could not download ops/systemd/cs-server-backup.timer"
        ops="${fetched}"
    fi
    dest="${HOME}/.local/bin/cs-server-backup"
    unit_dir="${HOME}/.config/systemd/user"
    mkdir -p "${HOME}/.local/bin" "${HOME}/.config/cs-server" "${unit_dir}"
    # The timer must keep the engine this install selected. Re-detecting at
    # backup time would pick Podman whenever it is also installed.
    printf 'CS_RUNTIME=%s\nCS_BACKUP_KEEP=%s\n' "${RUNTIME}" "${CS_BACKUP_KEEP}" \
        > "${HOME}/.config/cs-server/backup.env"
    chmod 644 "${HOME}/.config/cs-server/backup.env"
    cp "${ops}/backup-state.sh" "${dest}"
    chmod 755 "${dest}"
    cp "${ops}/systemd/cs-server-backup.service" "${unit_dir}/cs-server-backup.service"
    cp "${ops}/systemd/cs-server-backup.timer" "${unit_dir}/cs-server-backup.timer"
    chmod 644 "${unit_dir}/cs-server-backup.service" "${unit_dir}/cs-server-backup.timer"
    [[ -z "${fetched}" ]] || rm -rf "${fetched}"
    systemctl --user daemon-reload
    systemctl --user enable --now cs-server-backup.timer
    enable_linger
    BACKUP_DONE=1
    ok "Daily backups of the state volume: ${HOME}/cs-server-backups (keeps ${CS_BACKUP_KEEP:-14})"
}

# --- Quadlet unit -----------------------------------------------------------

# The one definition of the unit. quadlet/scoutzknivez.container in the
# repository is this function's output for the defaults (`--print-unit`,
# `just quadlet`); tests/install_test.sh fails when the two differ.
quadlet_unit() {
    # systemd expands % specifiers in unit files; a URL may carry %XX escapes.
    local fastdl_env=""
    if [[ -n "${FASTDL_URL}" ]]; then
        fastdl_env=$'\n'"Environment=FASTDL_URL=${FASTDL_URL//%/%%}"
    fi
    # podman-auto-update pulls the tag and restarts the unit. On Podman 5 the
    # unit only counts as started once healthy (Notify=healthy), so a new
    # image that does not come up is rolled back. Podman 4.4–4.9 omit the line.
    local server_ip_env=""
    if [[ -n "${SERVER_IP}" ]]; then
        server_ip_env=$'\n'"Environment=SERVER_IP=${SERVER_IP}"
    fi
    # LAN: the server sits on the host's network so broadcast queries from
    # the LAN tab reach it. Published ports would hide it from them.
    local network="PublishPort=${PORT}:${PORT}/udp" lan_mode=0
    if [[ "${PROFILE}" == "lan" ]]; then
        network="Network=host"
        lan_mode=1
    fi
    local auto_update=""
    if [[ "${AUTO_UPDATE}" == "1" ]]; then
        auto_update=$'\n'"AutoUpdate=registry"
    fi
    # The checked-in unit keeps this line: it is the Podman 5 default.
    # install.sh drops it when the installed Podman is 4.4 through 4.9.
    local notify=""
    if [[ "${PODMAN_NOTIFY}" == "1" ]]; then
        notify=$'\n# Notify=healthy needs Podman 5 or newer. install.sh omits this line on Podman 4.4 to 4.9:\n# the server still runs, and an automatic update cannot roll a bad image back.\nNotify=healthy'
    fi
    # Metrics listen inside the container; they are published on one host
    # address only (loopback unless CS_METRICS_BIND). On host networking the
    # endpoint binds that address itself.
    local metrics_publish="" metrics_env=""
    if [[ -n "${METRICS_PORT}" ]]; then
        metrics_env=$'\n'"Environment=METRICS_PORT=${METRICS_PORT}"
        if [[ "${PROFILE}" == "lan" ]]; then
            metrics_env+=$'\n'"Environment=METRICS_BIND=${METRICS_BIND}"
        else
            metrics_publish=$'\n'"PublishPort=${METRICS_BIND}:${METRICS_PORT}:${METRICS_PORT}/tcp"
        fi
    fi
    local volumes="" f
    for f in "${CONFIG_FILES[@]}" ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"}; do
        volumes+="Volume=${CONFIG_DIR}/${f}:/hlds/${GAME}/${f}:ro,Z"$'\n'
    done
    # The image of another game starts on that game's own map; MODE is the
    # ScoutzKnivez plugin's. Day of Defeat has DOD_MODE instead.
    local map_env="" mode_env="" dod_env="" insecure_env=""
    start_map
    if [[ "${GAME}" == "cstrike" ]]; then
        [[ -z "${START_MAP}" ]] || map_env="Environment=MAP=${START_MAP}"$'\n'
        mode_env="Environment=MODE=${MODE}"$'\n'
    elif [[ "${GAME}" == "dod" ]]; then
        dod_env="Environment=DOD_MODE=${DOD_MODE}"$'\n'
        if [[ -n "${DOD_PASSWORD}" ]]; then
            dod_env+="Environment=DOD_PASSWORD=${DOD_PASSWORD}"$'\n'
        fi
    fi
    if [[ -n "${GSLT}" ]]; then
        dod_env+="Environment=GSLT=${GSLT}"$'\n'
    fi
    if [[ "${INSECURE}" == "1" ]]; then
        insecure_env="Environment=INSECURE=1"$'\n'
    fi

    cat << QUADLET
[Unit]
Description=${GAME_TITLE} Server${INSTANCE:+ (${INSTANCE})}
Wants=network-online.target
After=network-online.target

[Container]
Image=${IMAGE}${auto_update}
ContainerName=${SERVICE_NAME}
${network}${metrics_publish}
${volumes}Volume=${STATE_VOLUME}:/hlds/state
${map_env}Environment=MAXPLAYERS=${START_PLAYERS}
Environment=PORT=${PORT}
Environment=BOTS=${BOTS}
Environment=MAPCYCLE=${START_CYCLE}
Environment=LAN_MODE=${lan_mode}
${mode_env}${dod_env}${insecure_env}Environment=LOGS=1
Environment=LOG_RETENTION_DAYS=7${fastdl_env}${server_ip_env}${metrics_env}
ReadOnly=true
Tmpfs=/tmp
DropCapability=ALL
NoNewPrivileges=true
HealthCmd=/healthcheck.sh
HealthInterval=30s
HealthTimeout=5s
HealthStartPeriod=60s
HealthRetries=3${notify}

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
}

# --- Podman install (Quadlet) -----------------------------------------------

install_podman() {
    # The unit is a user unit. Lingering is what starts it at boot.
    enable_linger
    # A running server keeps its old image until restarted (upgrade, rollback).
    local was_active=0
    if systemctl --user is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        was_active=1
    fi

    info "Installing Quadlet systemd unit"
    mkdir -p "${QUADLET_DIR}"

    quadlet_unit > "${QUADLET_DIR}/${SERVICE_NAME}.container"

    ok "Quadlet unit installed to ${QUADLET_DIR}/${SERVICE_NAME}.container"

    info "Reloading systemd and starting server"
    systemctl --user daemon-reload
    # Quadlet's generator enables the unit itself ([Install] in the
    # .container file); `systemctl enable` refuses generated units.
    systemctl --user start "${SERVICE_NAME}"
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
    echo "  Server address:  ${server_ip}:${PORT}"
    echo "  Image:           ${IMAGE}"
    if [[ "${PROFILE}" == "lan" ]]; then
        echo "  Profile:         LAN (host networking, sv_lan 1): look in the LAN tab,"
        echo "                   and open ${PORT}/udp in this machine's firewall"
    fi
    echo "  Config files:    ${CONFIG_DIR}/"
    echo "  Saved state:     volume ${STATE_VOLUME} (bans, admins, stats, logs)"
    echo "  Quadlet unit:    ${QUADLET_DIR}/${SERVICE_NAME}.container"
    if [[ "${FASTDL}" == "1" ]]; then
        echo "  FastDL:          ${FASTDL_URL} (open ${FASTDL_PORT}/tcp in this machine's firewall)"
    fi
    if [[ -n "${METRICS_PORT}" ]]; then
        echo "  Metrics:         http://${METRICS_BIND}:${METRICS_PORT}/metrics"
    fi
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

    local network_args=(-p "${PORT}:${PORT}/udp") lan_mode=0
    if [[ "${PROFILE}" == "lan" ]]; then
        network_args=(--network host)
        lan_mode=1
    fi
    local server_ip_args=()
    if [[ -n "${SERVER_IP}" ]]; then
        server_ip_args=(-e "SERVER_IP=${SERVER_IP}")
    fi
    local fastdl_args=()
    if [[ -n "${FASTDL_URL}" ]]; then
        fastdl_args=(-e "FASTDL_URL=${FASTDL_URL}")
    fi
    local metrics_args=()
    if [[ -n "${METRICS_PORT}" ]]; then
        metrics_args=(-e "METRICS_PORT=${METRICS_PORT}")
        if [[ "${PROFILE}" == "lan" ]]; then
            metrics_args+=(-e "METRICS_BIND=${METRICS_BIND}")
        else
            metrics_args+=(-p "${METRICS_BIND}:${METRICS_PORT}:${METRICS_PORT}/tcp")
        fi
    fi
    local mount_args=() f
    for f in "${CONFIG_FILES[@]}" ${CONFIG_DIRS[@]+"${CONFIG_DIRS[@]}"}; do
        mount_args+=(-v "${CONFIG_DIR}/${f}:/hlds/${GAME}/${f}:ro")
    done
    local game_args=()
    start_map
    if [[ "${GAME}" == "cstrike" ]]; then
        game_args=(-e "MODE=${MODE}")
        [[ -z "${START_MAP}" ]] || game_args+=(-e "MAP=${START_MAP}")
    elif [[ "${GAME}" == "dod" ]]; then
        game_args=(-e "DOD_MODE=${DOD_MODE}")
        if [[ -n "${DOD_PASSWORD}" ]]; then
            game_args+=(-e "DOD_PASSWORD=${DOD_PASSWORD}")
        fi
    fi
    if [[ -n "${GSLT}" ]]; then
        game_args+=(-e "GSLT=${GSLT}")
    fi
    if [[ "${INSECURE}" == "1" ]]; then
        game_args+=(-e INSECURE=1)
    fi

    # Docker 29.4.2 blocked socketcall(2) in its built-in seccomp profile, so
    # no 32-bit program could open a socket (moby/moby#52506); 29.4.3 undid
    # it. Every other release runs the server under the built-in profile.
    local engine
    engine=$(docker version --format '{{.Server.Version}}' 2>/dev/null) || engine=""
    if [[ "${engine}" == "29.4.2" ]]; then
        error "Docker Engine 29.4.2 cannot run 32-bit programs with networking (fixed in 29.4.3): update Docker and run the installer again"
    fi
    # A profile an earlier installer saved for `docker run`.
    rm -f "${CONFIG_DIR}/seccomp.json"

    info "Creating and starting container"
    docker run -d \
        --name "${SERVICE_NAME}" \
        --restart on-failure:10 \
        "${network_args[@]}" \
        "${mount_args[@]}" \
        -v "${STATE_VOLUME}:/hlds/state" \
        ${game_args[@]+"${game_args[@]}"} \
        -e "MAXPLAYERS=${START_PLAYERS}" \
        -e "PORT=${PORT}" \
        -e "BOTS=${BOTS}" \
        -e "MAPCYCLE=${START_CYCLE}" \
        -e "LAN_MODE=${lan_mode}" \
        -e LOGS=1 \
        -e LOG_RETENTION_DAYS=7 \
        ${fastdl_args[@]+"${fastdl_args[@]}"} \
        ${server_ip_args[@]+"${server_ip_args[@]}"} \
        ${metrics_args[@]+"${metrics_args[@]}"} \
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
    echo "  Server address:  ${server_ip}:${PORT}"
    echo "  Image:           ${IMAGE}"
    if [[ "${PROFILE}" == "lan" ]]; then
        echo "  Profile:         LAN (host networking, sv_lan 1): look in the LAN tab,"
        echo "                   and open ${PORT}/udp in this machine's firewall"
    fi
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

# LAN kit: the same install or uninstall for lan1..lan<n> on consecutive ports.
run_kit() {
    local i base="${PORT}" metrics_base="${METRICS_PORT}"
    for ((i = 1; i <= LAN_KIT; i++)); do
        INSTANCE="lan${i}"
        PORT=$((base + i - 1))
        [[ -z "${metrics_base}" ]] || METRICS_PORT=$((metrics_base + i - 1))
        set_names
        "$1"
    done
    PORT="${base}"
    METRICS_PORT="${metrics_base}"
}

if [[ "${ACTION}" == "print-unit" ]]; then
    [[ -z "${LAN_KIT}" ]] || error "--print-unit prints one unit; it does not take CS_LAN_KIT"
    # %h is systemd's specifier for the home directory.
    CONFIG_DIR="%h/.config/${CONFIG_DIR##*/}"
    if [[ "${FASTDL}" == "1" ]]; then
        fastdl_url
    fi
    quadlet_unit
elif [[ "${ACTION}" == "uninstall" ]]; then
    if [[ -n "${LAN_KIT}" ]]; then
        run_kit do_uninstall
    else
        do_uninstall
    fi
    if [[ "${FASTDL}" == "1" ]]; then
        remove_fastdl
    fi
elif [[ -n "${LAN_KIT}" ]]; then
    run_kit do_install
    install_backup
    check_host_tuning
    echo ""
    info "LAN kit: ${LAN_KIT} ${MODE} servers on ports ${PORT} to $((PORT + LAN_KIT - 1))/udp, maps from ${FASTDL_URL}"
    echo "      Open those ports and ${FASTDL_PORT}/tcp in this machine's firewall."
    echo "      Remove them all: CS_LAN_KIT=${LAN_KIT} bash install.sh --uninstall"
else
    do_install
    install_backup
    check_host_tuning
fi
