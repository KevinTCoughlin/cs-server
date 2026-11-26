#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# One-time setup for a fresh KVM VPS, then the existing installer.
#
#   sudo apt-get update
#   sudo apt-get install -y ca-certificates curl
#   curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/ops/bootstrap-vps.sh \
#     | sudo bash -s -- --ssh-key "ssh-ed25519 AAAA... you@host"
#
# A minimal image (RackNerd's Debian 13) has apt and no curl. The two apt
# lines above are how this file is fetched. Running the file itself installs
# ca-certificates and curl before it downloads anything else.
#
# Idempotent: a second run creates nothing that is already there, and reloads
# the nftables units so a newly added port is applied. --dry-run prints the
# plan and changes nothing (this is what CI runs in a container).
#
# Hosts:
#   Debian 13     distro Podman 5 (recommended)
#   Ubuntu 24.04  distro Podman 4.9 (Quadlet works; no health-gated rollback)
#   Debian 12     distro Docker (distro Podman is 4.3, older than Quadlet)
#
# What it does, as root:
#   1. Create a deploy user (default cs; --user / CS_DEPLOY_USER)
#   2. Install an SSH public key (--ssh-key, --ssh-key-file, CS_SSH_PUBLIC_KEY)
#   3. Leave SSH authentication as the VPS image set it. --harden-ssh is a
#      later, separate step: it refuses to run until an authorized key is
#      present (the deploy user, or root), writes sshd_config.d/00-cs-server.conf
#      (first match wins, so it beats a provider 99-ctrl.conf), aligns active
#      directives in sshd_config, and reloads sshd only after sshd -t and
#      sshd -T agree. It does not restart sshd. Root key login stays
#      (PermitRootLogin prohibit-password). It does not require sudo: a
#      locked password is normal, and root's key is the admin path.
#      --nopasswd-sudo is opt-in. With --harden-ssh it also sets
#      PermitRootLogin no, and only after NOPASSWD sudo for the deploy user
#      actually works. --regenerate-host-keys is off unless passed. It backs
#      up template-baked host keys, generates new ones, and reloads sshd.
#      Clients then see a different fingerprint.
#   4. Install ca-certificates and curl when either is missing. Install
#      Podman or Docker from the distro, after reading the Podman version
#      when Podman is already installed
#   5. Enable unattended-upgrades (Automatic-Reboot false) and fail2ban's
#      sshd jail. Install /etc/sysctl.d/61-cs-hardening.conf. Install
#      cs-reboot-if-idle, which reboots for a pending kernel update only when
#      no human is on a game port and no SSH session is open.
#   6. Install the query-flood nftables unit and reload it, so a second run
#      picks up new ports. Allow SSH and 27015/udp (and 27016/udp when
#      CS_DOD=1, and the FastDL port when CS_FASTDL=1) with nftables, or with
#      ufw when ufw is installed, or with firewalld when firewalld is already
#      running. The nftables input policy is reloaded with the query-flood unit
#   7. loginctl enable-linger for the deploy user. On Podman, also
#      systemctl add-wants multi-user.target network-online.target: rootless
#      Quadlets wait for network-online, and with linger that wait runs out
#      the network-online timeout when nothing else pulls the target into boot
#   8. Run install.sh as that user (CS_BACKUP=1 unless CS_BACKUP=0).
#      CS_DOD_MODE and CS_DOD_PASSWORD are passed only to the Day of Defeat
#      install. An inherited value is removed from the Counter-Strike install,
#      which exits when it sees one
#   9. Install a systemd user timer that restarts each game server at 05:00
#      America/Los_Angeles, and every 20 minutes until 08:00, when A2S_INFO
#      reports no human players (CS_RESTART=1 unless CS_RESTART=0).
#      --restart-only does this step and nothing else
#
# --no-install does the host setup and prints an install.sh command whose
# path still exists after this process exits (/usr/local/lib/cs-server/install.sh
# when the script was piped in). --harden-ssh only changes sshd (and, with
# --nopasswd-sudo, the sudoers drop-in). --regenerate-host-keys during a full
# run also replaces host keys; with --no-install the game server is not
# restarted. A second run does not regenerate keys unless the flag is passed
# again, and passing it again changes the fingerprint again.
# A machine with under about 1.8 GB of RAM and no swap gets a 1 GiB swap file.
# Ubuntu's unprivileged-user-namespace restriction is relaxed when it is on,
# which rootless Podman needs.
#
# Tests point CS_OS_RELEASE at a fake os-release file and CS_DEPLOY_HOME at a
# home directory that is not the real account.
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main"
DEPLOY_USER="${CS_DEPLOY_USER:-cs}"
SSH_KEY="${CS_SSH_PUBLIC_KEY:-}"
SSH_KEY_FILE=""
DRY_RUN=0
RUN_INSTALL=1
HARDEN_SSH=0
NOPASSWD_SUDO=0
REGEN_HOST_KEYS=0
INSTALLER_STORE="/usr/local/lib/cs-server/install.sh"
if [[ -z "${CS_BACKUP+x}" ]]; then
    CS_BACKUP=1
fi
if [[ -z "${CS_RESTART+x}" ]]; then
    CS_RESTART=1
fi
RESTART_ONLY=0
FASTDL="${CS_FASTDL:-0}"
GAME_PORT="${CS_PORT:-27015}"
# Day of Defeat beside Counter-Strike: its own install on 27016/udp.
DOD="${CS_DOD:-0}"
DOD_PORT="${CS_DOD_PORT:-27016}"
# install.sh exits when these are set for any game other than Day of Defeat.
# Every install.sh invocation clears them; the Day of Defeat environment sets
# them again afterwards. GNU env applies -u before NAME=VALUE.
DOD_SCOPED_VARS=(CS_DOD_MODE CS_DOD_PASSWORD)
FASTDL_PORT="${CS_FASTDL_PORT:-27080}"
SSH_KEYS=()
ENGINE=""
ENGINE_WHY=""
FIREWALL=""
SSH_PORT=22
OPS_CACHE=""
TMP_INSTALLER=""

info() { printf '\033[1;34m[info]\033[0m  %s\n' "$1"; }
ok() { printf '\033[1;32m[ok]\033[0m    %s\n' "$1"; }
warn() { printf '\033[1;33m[warn]\033[0m  %s\n' "$1"; }
error() { printf '\033[1;31m[error]\033[0m %s\n' "$1" >&2; exit 1; }

cleanup() {
    if [[ -n "${TMP_INSTALLER}" ]]; then
        rm -f "${TMP_INSTALLER}"
    fi
    if [[ -n "${OPS_CACHE}" ]]; then
        rm -rf "${OPS_CACHE}"
    fi
}
trap cleanup EXIT

usage() {
    local line
    while IFS= read -r line; do
        printf '%s\n' "${line}"
    done <<EOF
Usage: bootstrap-vps.sh [options]

Prepare a fresh Debian 13, Debian 12 or Ubuntu 24.04 VPS and run install.sh
as an unprivileged user. Run it as root. --dry-run prints the plan.

Options:
  --user NAME         Deploy user (default: cs, or CS_DEPLOY_USER)
  --ssh-key KEY       OpenSSH public key for that user (or CS_SSH_PUBLIC_KEY)
  --ssh-key-file PATH File of public keys (one per line)
  --no-install        Set the host up and print a lasting install.sh command
  --no-backup         Do not install daily state-volume backups (CS_BACKUP=0)
  --no-restart        Do not install the daily idle-restart timer (CS_RESTART=0)
  --restart-only      Install or remove only that timer, for an existing user
  --dod               Also install Day of Defeat on 27016/udp (CS_DOD=1)
  --harden-ssh        Password SSH off, root key login kept; nothing else
  --nopasswd-sudo     Let the deploy user sudo without a password. With
                      --harden-ssh, also turn root SSH login off
  --regenerate-host-keys
                      Replace SSH host keys (off by default). Clients see a
                      new fingerprint. With --no-install the game is not
                      restarted
  --dry-run           Print what would be done; change nothing
  --help              Show this help

SSH logins are not changed unless you pass --harden-ssh. Before that, from a
second terminal, confirm a key login (ssh <user>@<host>, or ssh root@<host>
when the deploy user's password is locked). --harden-ssh does not need sudo.
Root key login stays the admin path unless you also pass --nopasswd-sudo.

Environment (passed through to install.sh when set):
  CS_SERVER_VERSION, CS_SERVER_IMAGE, CS_PIN_DIGEST, CS_PORT, CS_FASTDL,
  CS_FASTDL_PORT, CS_MODE, CS_BOTS, CS_PROFILE, SERVER_IP, CS_RCON, CS_GAME,
  CS_INSTANCE, CS_BACKUP (default 1), CS_RESTART (default 1), CS_SSH_PORT,
  CS_DOD, CS_DOD_PORT, CS_DOD_GSLT, CS_GSLT, CS_REBOOT_PORTS
  CS_DOD_MODE (pub or match) and CS_DOD_PASSWORD are Day of Defeat only.
  They are removed from the Counter-Strike install.
  CS_PIN_DIGEST=0 leaves the Quadlet image on a tag. The default resolves
  the pulled image's digest and writes Image=name:tag@sha256:...
  CS_REBOOT_PORTS replaces the idle-reboot port list (default: the game
  ports this install knows, plus 27015 and 27016).
EOF
    return 0
}

# Directory of this file when it was executed from the checkout. Empty when
# the script was piped into bash (curl | bash), which downloads siblings.
script_dir() {
    local src="${BASH_SOURCE[0]}"
    case "${src}" in
        */bootstrap-vps.sh | bootstrap-vps.sh) ;;
        *)
            printf '\n'
            return 0
            ;;
    esac
    if [[ "${src}" == */* ]]; then
        printf '%s\n' "${src%/*}"
    else
        printf '%s\n' "."
    fi
}

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

load_os() {
    local file="${CS_OS_RELEASE:-/etc/os-release}" line key value
    [[ -r "${file}" ]] || error "Cannot read ${file}"
    ID=""
    VERSION_ID=""
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        case "${line}" in
            ID=* | VERSION_ID=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        case "${key}" in
            ID) ID="${value}" ;;
            VERSION_ID) VERSION_ID="${value}" ;;
        esac
    done < "${file}"
    [[ -n "${ID}" && -n "${VERSION_ID}" ]] || error "${file} has no ID or VERSION_ID"
}

valid_port() {
    local name="$1" value="$2" min="$3"
    if [[ ! "${value}" =~ ^[0-9]+$ ]] || ((10#${value} < min || 10#${value} > 65535)); then
        error "Invalid ${name}: ${value}"
    fi
}

validate_ssh_key() {
    local key="$1" tmp=""
    if [[ "${key}" == *$'\n'* || "${key}" == *$'\r'* ]]; then
        error "An SSH public key must be a single line"
    fi
    command -v ssh-keygen >/dev/null 2>&1 || error "ssh-keygen is required to check an SSH public key"
    tmp=$(mktemp)
    chmod 600 "${tmp}"
    printf '%s\n' "${key}" > "${tmp}"
    if ! ssh-keygen -l -f "${tmp}" >/dev/null 2>&1; then
        rm -f "${tmp}"
        error "Not an OpenSSH public key (ssh-keygen rejected it): ${key:0:40}"
    fi
    rm -f "${tmp}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            --no-install) RUN_INSTALL=0; shift ;;
            --no-backup) CS_BACKUP=0; shift ;;
            --no-restart) CS_RESTART=0; shift ;;
            --restart-only) RESTART_ONLY=1; shift ;;
            --dod) DOD=1; shift ;;
            --harden-ssh) HARDEN_SSH=1; shift ;;
            --nopasswd-sudo) NOPASSWD_SUDO=1; shift ;;
            --regenerate-host-keys) REGEN_HOST_KEYS=1; shift ;;
            --user)
                [[ $# -ge 2 ]] || error "--user needs a name"
                DEPLOY_USER="$2"
                shift 2
                ;;
            --ssh-key)
                [[ $# -ge 2 ]] || error "--ssh-key needs a key"
                SSH_KEY="$2"
                shift 2
                ;;
            --ssh-key-file)
                [[ $# -ge 2 ]] || error "--ssh-key-file needs a path"
                SSH_KEY_FILE="$2"
                shift 2
                ;;
            --help | -h) usage; exit 0 ;;
            *) error "Unknown option: $1" ;;
        esac
    done
}

collect_keys() {
    local line
    SSH_KEYS=()
    if [[ -n "${SSH_KEY}" ]]; then
        validate_ssh_key "${SSH_KEY}"
        SSH_KEYS+=("${SSH_KEY}")
    fi
    if [[ -n "${SSH_KEY_FILE}" ]]; then
        [[ -r "${SSH_KEY_FILE}" ]] || error "Cannot read ${SSH_KEY_FILE}"
        while IFS= read -r line || [[ -n "${line}" ]]; do
            line="${line%$'\r'}"
            [[ -z "${line}" || "${line}" == \#* ]] && continue
            validate_ssh_key "${line}"
            SSH_KEYS+=("${line}")
        done < "${SSH_KEY_FILE}"
    fi
}

validate() {
    if [[ "${DEPLOY_USER}" == "root" ]]; then
        error "The deploy user must be an unprivileged account, not root"
    fi
    if [[ ! "${DEPLOY_USER}" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
        error "Invalid deploy user: ${DEPLOY_USER} (a lowercase letter, then lowercase letters, digits or hyphens)"
    fi
    if [[ "${CS_BACKUP}" != "0" && "${CS_BACKUP}" != "1" ]]; then
        error "Invalid CS_BACKUP: ${CS_BACKUP} (expected 0 or 1)"
    fi
    if [[ "${CS_RESTART}" != "0" && "${CS_RESTART}" != "1" ]]; then
        error "Invalid CS_RESTART: ${CS_RESTART} (expected 0 or 1)"
    fi
    if [[ "${RESTART_ONLY}" == "1" && "${HARDEN_SSH}" == "1" ]]; then
        error "--restart-only and --harden-ssh are separate commands"
    fi
    if [[ "${RESTART_ONLY}" == "1" && "${REGEN_HOST_KEYS}" == "1" ]]; then
        error "--restart-only and --regenerate-host-keys are separate commands"
    fi
    if [[ "${RESTART_ONLY}" == "1" && "${NOPASSWD_SUDO}" == "1" ]]; then
        error "--restart-only and --nopasswd-sudo are separate commands"
    fi
    if [[ -n "${CS_REBOOT_PORTS:-}" ]]; then
        local reboot_port
        local -a reboot_ports=()
        read -r -a reboot_ports <<< "${CS_REBOOT_PORTS}"
        for reboot_port in "${reboot_ports[@]}"; do
            valid_port CS_REBOOT_PORTS "${reboot_port}" 1
        done
    fi
    if [[ "${FASTDL}" != "0" && "${FASTDL}" != "1" ]]; then
        error "Invalid CS_FASTDL: ${FASTDL} (expected 0 or 1)"
    fi
    if [[ "${DOD}" != "0" && "${DOD}" != "1" ]]; then
        error "Invalid CS_DOD: ${DOD} (expected 0 or 1)"
    fi
    valid_port CS_PORT "${GAME_PORT}" 1024
    valid_port CS_DOD_PORT "${DOD_PORT}" 1024
    if [[ "${DOD}" == "1" && "${DOD_PORT}" == "${GAME_PORT}" ]]; then
        error "Day of Defeat port ${DOD_PORT} is the same as CS_PORT. Counter-Strike keeps ${GAME_PORT}; set CS_DOD_PORT to another port."
    fi
    if [[ -n "${CS_DOD_MODE:-}" && "${CS_DOD_MODE}" != "pub" && "${CS_DOD_MODE}" != "match" ]]; then
        error "Invalid CS_DOD_MODE: ${CS_DOD_MODE} (expected pub or match)"
    fi
    if [[ -n "${CS_DOD_GSLT:-}" && ! "${CS_DOD_GSLT}" =~ ^[A-Fa-f0-9]{32}$ ]]; then
        error "Invalid CS_DOD_GSLT: expected a 32-character hex Steam game server token for app 30"
    fi
    if [[ -n "${CS_GSLT:-}" && ! "${CS_GSLT}" =~ ^[A-Fa-f0-9]{32}$ ]]; then
        error "Invalid CS_GSLT: expected a 32-character hex Steam game server token"
    fi
    if [[ -n "${CS_DOD_PASSWORD:-}" && ! "${CS_DOD_PASSWORD}" =~ ^[A-Za-z0-9!@#^*_=+.-]{1,32}$ ]]; then
        error "Invalid CS_DOD_PASSWORD: use 1 to 32 characters from letters, digits, and !@#^*_=+.-"
    fi
    valid_port CS_FASTDL_PORT "${FASTDL_PORT}" 1024
    if [[ -n "${CS_SSH_PORT:-}" ]]; then
        valid_port CS_SSH_PORT "${CS_SSH_PORT}" 1
    fi
    collect_keys
}

choose_engine() {
    case "${ID}:${VERSION_ID}" in
        debian:13 | debian:13.*)
            ENGINE="podman"
            ENGINE_WHY="Debian 13 ships Podman 5"
            ;;
        ubuntu:24.04 | ubuntu:24.04.*)
            ENGINE="podman"
            ENGINE_WHY="Ubuntu 24.04 ships Podman 4.9; health-gated auto-update rollback needs Podman 5"
            ;;
        debian:12 | debian:12.*)
            ENGINE="docker"
            ENGINE_WHY="Debian 12's Podman is 4.3, older than Quadlet (4.4)"
            ;;
        *)
            error "This bootstrap supports Debian 13 (Podman 5), Debian 12 (Docker) and Ubuntu 24.04 (Podman 4.9). This machine reports ${ID} ${VERSION_ID}. Install Podman 4.4+ or Docker and run install.sh as a normal user."
            ;;
    esac
    # An already-installed Podman wins over the distro default when it is new
    # enough, and loses when it is older than Quadlet.
    if command -v podman >/dev/null 2>&1; then
        local ver=""
        if ver=$(podman_cli_version); then
            if version_ge "${ver}" 4.4; then
                ENGINE="podman"
                if version_ge "${ver}" 5.0; then
                    ENGINE_WHY="Podman ${ver}"
                else
                    ENGINE_WHY="Podman ${ver}; health-gated auto-update rollback needs Podman 5"
                fi
            else
                ENGINE="docker"
                ENGINE_WHY="Podman ${ver} is older than 4.4, which Quadlet needs"
            fi
        fi
    fi
}

choose_firewall() {
    # firewalld that is already running is left in place. ufw, if installed,
    # is used instead of a second packet filter. Otherwise nftables.
    FIREWALL="nftables"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        FIREWALL="firewalld"
    elif command -v ufw >/dev/null 2>&1; then
        FIREWALL="ufw"
    fi
}

detect_ssh_port() {
    local sshd_bin="" line=""
    if [[ -n "${CS_SSH_PORT:-}" ]]; then
        SSH_PORT="${CS_SSH_PORT}"
        return 0
    fi
    SSH_PORT=22
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    if [[ -z "${sshd_bin}" && -x /usr/sbin/sshd ]]; then
        sshd_bin=/usr/sbin/sshd
    fi
    if [[ -n "${sshd_bin}" ]] && command -v awk >/dev/null 2>&1; then
        line=$("${sshd_bin}" -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
        if [[ "${line}" =~ ^[0-9]+$ ]]; then
            SSH_PORT="${line}"
        fi
    fi
}

deploy_home() {
    local home=""
    # Tests point this at a scratch directory. A real run leaves it unset.
    if [[ -n "${CS_DEPLOY_HOME:-}" ]]; then
        printf '%s\n' "${CS_DEPLOY_HOME}"
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        home=$(getent passwd "${DEPLOY_USER}" | cut -d: -f6 || true)
    fi
    if [[ -z "${home}" ]]; then
        home="/home/${DEPLOY_USER}"
    fi
    printf '%s\n' "${home}"
}

# ssh-keygen -l accepts a file of one or more public keys and rejects a bad line.
authorized_keys_ok() {
    local auth="$1"
    [[ -s "${auth}" ]] || return 1
    command -v ssh-keygen >/dev/null 2>&1 || return 1
    ssh-keygen -l -f "${auth}" >/dev/null 2>&1
}

# True when the deploy user can run sudo with no password and no tty.
deploy_has_nopasswd() {
    local bin=""
    command -v sudo >/dev/null 2>&1 || return 1
    bin=$(command -v runuser 2>/dev/null || true)
    if [[ -z "${bin}" && -x /usr/sbin/runuser ]]; then
        bin=/usr/sbin/runuser
    fi
    [[ -n "${bin}" ]] || return 1
    "${bin}" -u "${DEPLOY_USER}" -- sudo -n true >/dev/null 2>&1
}

fill_packages() {
    PACKAGES=(ca-certificates curl nftables fail2ban unattended-upgrades dbus-user-session sudo python3 rclone iproute2)
    if [[ "${ENGINE}" == "podman" ]]; then
        PACKAGES+=(podman uidmap)
    else
        PACKAGES+=(docker.io)
    fi
}

firewall_words() {
    local extra="" ports="${GAME_PORT}/udp"
    if [[ "${DOD}" == "1" ]]; then
        ports="${GAME_PORT}/udp, dod ${DOD_PORT}/udp"
    fi
    if [[ "${FASTDL}" == "1" ]]; then
        extra=", fastdl ${FASTDL_PORT}/tcp"
    fi
    printf '%s, SSH %s/tcp, game %s%s, query-flood unit\n' \
        "${FIREWALL}" "${SSH_PORT}" "${ports}" "${extra}"
}

installer_path() {
    local dir parent
    dir="$(script_dir)"
    if [[ -n "${dir}" && -f "${dir}/../install.sh" ]]; then
        parent=$(cd "${dir}/.." && pwd) || return 1
        printf '%s\n' "${parent}/install.sh"
        return 0
    fi
    return 1
}

# A checkout already has install.sh. A piped bootstrap saves a copy that is
# still there after this process exits, instead of a temp file.
printed_installer() {
    local path=""
    if path=$(installer_path); then
        printf '%s\n' "${path}"
        return 0
    fi
    printf '%s\n' "${INSTALLER_STORE}"
}

save_installer() {
    local path="" tmp=""
    if path=$(installer_path); then
        printf '%s\n' "${path}"
        return 0
    fi
    install -d -m 755 /usr/local/lib/cs-server
    tmp=$(mktemp)
    ensure_curl
    curl -fsSL "${RAW_BASE}/install.sh" -o "${tmp}"
    install -m 644 "${tmp}" "${INSTALLER_STORE}"
    rm -f "${tmp}"
    printf '%s\n' "${INSTALLER_STORE}"
}

# INSTALL_ENV is the environment install.sh runs with.
build_install_env() {
    local uid="$1" home="$2" name
    INSTALL_ENV=(
        "HOME=${home}"
        "USER=${DEPLOY_USER}"
        "LOGNAME=${DEPLOY_USER}"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "XDG_RUNTIME_DIR=/run/user/${uid}"
        "CS_BACKUP=${CS_BACKUP}"
        "CS_RUNTIME=${ENGINE}"
    )
    for name in CS_SERVER_VERSION CS_SERVER_IMAGE CS_FASTDL CS_FASTDL_PORT CS_FASTDL_HOST \
        CS_PORT CS_MODE CS_BOTS CS_PROFILE SERVER_IP CS_RCON CS_AUTO_UPDATE CS_PIN_DIGEST \
        CS_METRICS_PORT CS_METRICS_BIND CS_GAME CS_INSTANCE CS_LAN_KIT FASTDL_URL \
        CS_BACKUP_KEEP CS_GSLT CS_INSECURE; do
        if [[ -n "${!name:-}" ]]; then
            INSTALL_ENV+=("${name}=${!name}")
        fi
    done
}

# The Day of Defeat install is a second run of install.sh: its own image,
# Quadlet unit (dod-server), config directory and state volume. It does not
# inherit Counter-Strike's mode, instance, LAN kit or FastDL sidecar.
build_dod_install_env() {
    local uid="$1" home="$2" name
    DOD_INSTALL_ENV=(
        "HOME=${home}"
        "USER=${DEPLOY_USER}"
        "LOGNAME=${DEPLOY_USER}"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "XDG_RUNTIME_DIR=/run/user/${uid}"
        "CS_BACKUP=${CS_BACKUP}"
        "CS_RUNTIME=${ENGINE}"
        "CS_GAME=dod"
        "CS_PORT=${DOD_PORT}"
        "CS_DOD_MODE=${CS_DOD_MODE:-pub}"
    )
    for name in CS_SERVER_VERSION CS_SERVER_IMAGE CS_PIN_DIGEST CS_RCON CS_AUTO_UPDATE CS_BACKUP_KEEP SERVER_IP; do
        if [[ -n "${!name:-}" ]]; then
            DOD_INSTALL_ENV+=("${name}=${!name}")
        fi
    done
    if [[ -n "${CS_DOD_GSLT:-}" ]]; then
        DOD_INSTALL_ENV+=("CS_GSLT=${CS_DOD_GSLT}")
    fi
    if [[ -n "${CS_DOD_PASSWORD:-}" ]]; then
        DOD_INSTALL_ENV+=("CS_DOD_PASSWORD=${CS_DOD_PASSWORD}")
    fi
}

print_install_command() {
    local installer="$1" item name
    printf 'runuser -u %q -- env' "${DEPLOY_USER}"
    for name in "${DOD_SCOPED_VARS[@]}"; do
        printf ' -u %q' "${name}"
    done
    for item in "${INSTALL_ENV[@]}"; do
        printf ' %q' "${item}"
    done
    printf ' bash %q\n' "${installer}"
}

print_plan() {
    local uid="UID" home="/home/${DEPLOY_USER}" installer=""
    info "Host: ${ID} ${VERSION_ID}"
    if command -v id >/dev/null 2>&1 && id "${DEPLOY_USER}" >/dev/null 2>&1; then
        info "Deploy user: ${DEPLOY_USER} (already exists)"
        uid=$(id -u "${DEPLOY_USER}")
        home=$(deploy_home)
    else
        info "Deploy user: ${DEPLOY_USER} (will create)"
    fi
    info "Engine: ${ENGINE} (${ENGINE_WHY})"
    info "Packages: ${PACKAGES[*]}"
    info "Downloads: install ca-certificates and curl before anything is fetched"
    info "SSH: authentication unchanged (run --harden-ssh after a key login works; root key login stays unless --nopasswd-sudo)"
    info "Hardening: unattended-upgrades (no automatic reboot), fail2ban sshd jail, sysctl 61-cs-hardening.conf"
    info "Idle reboot: cs-reboot-if-idle.timer, 04:05 to 07:45 America/Los_Angeles every 20 min, only when a reboot is pending, no human is playing, and no SSH session is open"
    info "Firewall: $(firewall_words)"
    if [[ "${FIREWALL}" == "nftables" ]]; then
        info "Firewall reload: systemctl reload cs-server-input cs-server-firewall"
    else
        info "Firewall reload: systemctl reload cs-server-firewall"
    fi
    info "Linger: loginctl enable-linger ${DEPLOY_USER}"
    if [[ "${ENGINE}" == "podman" ]]; then
        info "Boot: systemctl add-wants multi-user.target network-online.target"
    fi
    if [[ "${CS_BACKUP}" == "1" ]]; then
        info "Backups: on, daily, keep ${CS_BACKUP_KEEP:-14}, ~${DEPLOY_USER}/cs-server-backups"
        info "Off-site backups: hook enabled only when ~${DEPLOY_USER}/.config/cs-server/offsite.env is mode 600"
    else
        info "Backups: off (CS_BACKUP=0)"
    fi
    if [[ "${REGEN_HOST_KEYS}" == "1" ]]; then
        warn "SSH host keys: this run generates new keys. Clients will see a changed fingerprint and must forget the old one (ssh-keygen -R <host>)."
    else
        info "SSH host keys: left as they are (pass --regenerate-host-keys once for a template image)"
    fi
    if [[ "${NOPASSWD_SUDO}" == "1" ]]; then
        info "Sudo: NOPASSWD for ${DEPLOY_USER}"
    fi
    if [[ "${CS_RESTART}" == "1" ]]; then
        info "Daily restart: on, 05:00 America/Los_Angeles, every 20 min until 08:00, only with no human players"
    else
        info "Daily restart: off (CS_RESTART=0)"
    fi
    if mem_is_small; then
        info "Swap: add a 1 GiB swap file (this host has little RAM and little swap)"
    fi
    installer=$(printed_installer)
    build_install_env "${uid}" "${home}"
    info "Install command:"
    print_install_command "${installer}"
    if [[ "${DOD}" == "1" ]]; then
        build_dod_install_env "${uid}" "${home}"
        info "Day of Defeat (${CS_DOD_MODE:-pub}) on ${DOD_PORT}/udp, unit dod-server, volume dod-server-state:"
        # print_install_command reads INSTALL_ENV.
        INSTALL_ENV=("${DOD_INSTALL_ENV[@]}")
        print_install_command "${installer}"
    fi
}

mem_is_small() {
    local mem_kb=0 swap_kb=0 key val
    [[ -r /proc/meminfo ]] || return 1
    while read -r key val _; do
        case "${key}" in
            MemTotal:) mem_kb="${val}" ;;
            SwapTotal:) swap_kb="${val}" ;;
        esac
    done < /proc/meminfo
    [[ "${mem_kb}" =~ ^[0-9]+$ ]] || return 1
    [[ "${swap_kb}" =~ ^[0-9]+$ ]] || swap_kb=0
    [[ "${mem_kb}" -lt 1800000 && "${swap_kb}" -lt 524288 ]]
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || error "Run as root: sudo bash ops/bootstrap-vps.sh"
    command -v systemctl >/dev/null 2>&1 || error "systemd is required. This script targets a VPS; --dry-run is the container check."
}

create_user() {
    if id "${DEPLOY_USER}" >/dev/null 2>&1; then
        ok "User ${DEPLOY_USER} already exists"
        return 0
    fi
    useradd --create-home --shell /bin/bash --comment "CS 1.6 server" "${DEPLOY_USER}"
    ok "Created user ${DEPLOY_USER}"
}

install_ssh_keys() {
    local home auth key
    [[ ${#SSH_KEYS[@]} -gt 0 ]] || return 0
    home=$(deploy_home)
    [[ -d "${home}" ]] || error "Home directory ${home} does not exist"
    auth="${home}/.ssh/authorized_keys"
    install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${home}/.ssh"
    if [[ ! -f "${auth}" ]]; then
        touch "${auth}"
    fi
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${auth}"
    chmod 600 "${auth}"
    for key in "${SSH_KEYS[@]}"; do
        if grep -qxF -- "${key}" "${auth}"; then
            info "SSH key already present for ${DEPLOY_USER}"
        else
            printf '%s\n' "${key}" >> "${auth}"
            ok "Installed an SSH key for ${DEPLOY_USER}"
        fi
    done
}

sshd_bin() {
    local bin=""
    bin=$(command -v sshd 2>/dev/null || true)
    if [[ -z "${bin}" && -x /usr/sbin/sshd ]]; then
        bin=/usr/sbin/sshd
    fi
    printf '%s\n' "${bin}"
}

# Reload the running daemon. Never restart: a restart drops the session that
# is applying the change.
reload_sshd() {
    if systemctl cat ssh.service >/dev/null 2>&1; then
        systemctl reload ssh || return 1
        return 0
    fi
    if systemctl cat sshd.service >/dev/null 2>&1; then
        systemctl reload sshd || return 1
        return 0
    fi
    return 1
}

# sshd -T prints the first value it kept. prohibit-password is reported as
# without-password. A provider file that sorts later must not win.
sshd_effective_ok() {
    local bin="$1" root_login="$2" effective="" expect_root="without-password"
    effective=$("${bin}" -T 2>/dev/null) || return 1
    if [[ "${root_login}" == "no" ]]; then
        expect_root="no"
    fi
    grep -qi "^permitrootlogin ${expect_root}$" <<< "${effective}" || return 1
    grep -qi "^passwordauthentication no$" <<< "${effective}" || return 1
    grep -qi "^kbdinteractiveauthentication no$" <<< "${effective}" || return 1
    grep -qi "^x11forwarding no$" <<< "${effective}" || return 1
    grep -qi "^allowagentforwarding no$" <<< "${effective}" || return 1
    grep -qi "^maxauthtries 3$" <<< "${effective}" || return 1
    grep -qi "^logingracetime 30$" <<< "${effective}" || return 1
    grep -qi "^permitemptypasswords no$" <<< "${effective}" || return 1
    grep -qi "^pubkeyauthentication yes$" <<< "${effective}" || return 1
}

# Active directives only. A commented line is left alone. The same values go
# into the main file so a setting that sits above Include cannot beat the
# drop-in (sshd keeps the first value it reads).
rewrite_sshd_main() {
    local file="$1" root_login="$2" tmp=""
    [[ -f "${file}" ]] || return 0
    tmp=$(mktemp)
    awk -v root="${root_login}" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
        /^[[:space:]]*PermitRootLogin[[:space:]]+/ { print "PermitRootLogin " root; next }
        /^[[:space:]]*PasswordAuthentication[[:space:]]+/ { print "PasswordAuthentication no"; next }
        /^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+/ { print "KbdInteractiveAuthentication no"; next }
        /^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+/ { print "ChallengeResponseAuthentication no"; next }
        /^[[:space:]]*X11Forwarding[[:space:]]+/ { print "X11Forwarding no"; next }
        /^[[:space:]]*AllowAgentForwarding[[:space:]]+/ { print "AllowAgentForwarding no"; next }
        /^[[:space:]]*PermitEmptyPasswords[[:space:]]+/ { print "PermitEmptyPasswords no"; next }
        /^[[:space:]]*PubkeyAuthentication[[:space:]]+/ { print "PubkeyAuthentication yes"; next }
        /^[[:space:]]*MaxAuthTries[[:space:]]+/ { print "MaxAuthTries 3"; next }
        /^[[:space:]]*LoginGraceTime[[:space:]]+/ { print "LoginGraceTime 30"; next }
        { print }
    ' "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f "${tmp}"
}

backup_ssh_dir() {
    local stamp="" dir=""
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dir="/root/cs-server-ssh-${stamp}"
    mkdir -p "${dir}/sshd_config.d"
    chmod 700 "${dir}"
    if [[ -f /etc/ssh/sshd_config ]]; then
        cp -a /etc/ssh/sshd_config "${dir}/sshd_config"
    fi
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        cp -a /etc/ssh/sshd_config.d/. "${dir}/sshd_config.d/"
    fi
    printf '%s\n' "${dir}"
}

restore_ssh_backup() {
    local dir="$1"
    if [[ -f "${dir}/sshd_config" ]]; then
        cp -a "${dir}/sshd_config" /etc/ssh/sshd_config
    fi
    rm -rf /etc/ssh/sshd_config.d
    mkdir -p /etc/ssh/sshd_config.d
    chmod 755 /etc/ssh/sshd_config.d
    if [[ -d "${dir}/sshd_config.d" ]]; then
        cp -a "${dir}/sshd_config.d/." /etc/ssh/sshd_config.d/
    fi
}

install_nopasswd_sudo() {
    local file="/etc/sudoers.d/cs-server" tmp=""
    command -v visudo >/dev/null 2>&1 || error "visudo is required to install NOPASSWD sudo (package sudo)"
    tmp=$(mktemp)
    cat > "${tmp}" <<EOF
# Managed by ops/bootstrap-vps.sh --nopasswd-sudo.
# ${DEPLOY_USER} can administer this host without a password. That is what
# lets --harden-ssh turn root SSH login off. Without this flag, root key
# login stays the admin path.
${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL
Defaults:${DEPLOY_USER} !requiretty
EOF
    chmod 440 "${tmp}"
    if ! visudo -cf "${tmp}" >/dev/null; then
        rm -f "${tmp}"
        error "The NOPASSWD sudoers drop-in was rejected by visudo. Nothing was installed."
    fi
    install -m 440 -o root -g root "${tmp}" "${file}"
    rm -f "${tmp}"
    ok "NOPASSWD sudo installed for ${DEPLOY_USER} (${file})"
}

# --harden-ssh only. The ordinary bootstrap never calls this.
# Password login is turned off only after a key is confirmed, and sshd is
# reloaded, not restarted. Root key login stays unless --nopasswd-sudo was
# passed and that sudo actually works.
harden_ssh() {
    local home="" auth="" root_login="prohibit-password" src="" drop="" bin="" backup=""
    if [[ "${NOPASSWD_SUDO}" == "1" ]]; then
        root_login="no"
    fi
    if [[ ${#SSH_KEYS[@]} -gt 0 && "${DRY_RUN}" != "1" ]]; then
        install_ssh_keys
    fi
    home=$(deploy_home)
    auth="${home}/.ssh/authorized_keys"
    if [[ "${root_login}" == "no" ]]; then
        if ! authorized_keys_ok "${auth}"; then
            error "${DEPLOY_USER} has no valid authorized key at ${auth}. --nopasswd-sudo turns root SSH off, so this key has to work first. Nothing was changed."
        fi
    elif ! authorized_keys_ok "${auth}" && ! authorized_keys_ok /root/.ssh/authorized_keys; then
        error "No valid authorized key for ${DEPLOY_USER} (${auth}) or for root. Password login was not changed."
    fi
    if [[ "${DRY_RUN}" == "1" ]]; then
        if [[ "${root_login}" == "no" ]]; then
            info "SSH: would install NOPASSWD sudo for ${DEPLOY_USER} and write 00-cs-server.conf with PermitRootLogin no"
        else
            info "SSH: would write /etc/ssh/sshd_config.d/00-cs-server.conf (passwords off, root login by key only)"
        fi
        info "SSH: would run sshd -t and reload sshd, not restart it"
        info "Dry run: nothing was changed"
        exit 0
    fi
    bin=$(sshd_bin)
    [[ -n "${bin}" ]] || error "sshd is not installed; nothing was changed"
    if [[ "${NOPASSWD_SUDO}" == "1" ]]; then
        install_nopasswd_sudo
        if ! deploy_has_nopasswd; then
            error "NOPASSWD sudo for ${DEPLOY_USER} did not work. Root SSH login was left unchanged."
        fi
    fi
    backup=$(backup_ssh_dir)
    src=$(ops_file ssh/00-cs-server.conf)
    drop=/etc/ssh/sshd_config.d/00-cs-server.conf
    mkdir -p /etc/ssh/sshd_config.d
    chmod 755 /etc/ssh/sshd_config.d
    if [[ -f /etc/ssh/sshd_config ]]; then
        rewrite_sshd_main /etc/ssh/sshd_config "${root_login}"
    fi
    awk -v root="${root_login}" '
        /^PermitRootLogin[[:space:]]/ { print "PermitRootLogin " root; next }
        { print }
    ' "${src}" > "${drop}"
    chmod 644 "${drop}"
    # 99-cs-server.conf sorts with provider files such as 99-ctrl.conf, and
    # sshd keeps the first value, so that older name never applied. Drop it
    # when it is the file this script used to write.
    if [[ -f /etc/ssh/sshd_config.d/99-cs-server.conf ]] &&
        grep -q 'Managed by ops/bootstrap-vps.sh' /etc/ssh/sshd_config.d/99-cs-server.conf; then
        rm -f /etc/ssh/sshd_config.d/99-cs-server.conf
    fi
    if ! "${bin}" -t; then
        restore_ssh_backup "${backup}"
        error "sshd -t rejected the drop-in. The previous sshd config was restored and sshd was not reloaded."
    fi
    if ! sshd_effective_ok "${bin}" "${root_login}"; then
        restore_ssh_backup "${backup}"
        error "sshd -T does not show the hardened settings (a directive before Include wins, or sshd_config.d is not included). The previous config was restored and sshd was not reloaded."
    fi
    if ! reload_sshd; then
        restore_ssh_backup "${backup}"
        error "sshd reload failed. The previous config was restored and sshd was not restarted."
    fi
    if [[ "${root_login}" == "no" ]]; then
        ok "sshd: password login off, root login off (${DEPLOY_USER} has NOPASSWD sudo)"
    else
        ok "sshd: password login off, root login by key only"
    fi
    info "Rollback copy: ${backup}"
}

restore_host_keys() {
    local dir="$1" f=""
    for f in /etc/ssh/ssh_host_*; do
        [[ -e "${f}" ]] || continue
        rm -f "${f}"
    done
    for f in "${dir}"/ssh_host_*; do
        [[ -e "${f}" ]] || continue
        mv "${f}" /etc/ssh/
    done
}

# Off unless --regenerate-host-keys is passed. A later bootstrap without the
# flag does not touch host keys. Passing the flag again rotates them again.
regenerate_host_keys() {
    local stamp="" dir="" bin="" f="" pub="" old_umask=""
    warn "Regenerating SSH host keys. Every client that has connected here will see a changed fingerprint and refuse to log in until the old key is removed (ssh-keygen -R <host>). This session stays up: sshd is reloaded, not restarted. Running this again changes the fingerprint again."
    if [[ "${DRY_RUN}" == "1" ]]; then
        info "SSH host keys: would back up /etc/ssh/ssh_host_* , drop any DSA key, generate new keys, and reload sshd"
        return 0
    fi
    command -v ssh-keygen >/dev/null 2>&1 || error "ssh-keygen is required to regenerate host keys"
    bin=$(sshd_bin)
    [[ -n "${bin}" ]] || error "sshd is not installed; host keys were not changed"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    dir="/root/cs-server-hostkeys-${stamp}"
    mkdir -p "${dir}"
    chmod 700 "${dir}"
    for f in /etc/ssh/ssh_host_*; do
        [[ -e "${f}" ]] || continue
        mv "${f}" "${dir}/"
    done
    old_umask=$(umask)
    umask 077
    if ! ssh-keygen -A; then
        umask "${old_umask}"
        restore_host_keys "${dir}"
        error "ssh-keygen -A failed. The previous host keys were restored and sshd was not reloaded."
    fi
    umask "${old_umask}"
    rm -f /etc/ssh/ssh_host_dsa_key /etc/ssh/ssh_host_dsa_key.pub
    if ! "${bin}" -t; then
        restore_host_keys "${dir}"
        error "sshd -t rejected the new host keys. The previous keys were restored and sshd was not reloaded."
    fi
    if ! reload_sshd; then
        restore_host_keys "${dir}"
        error "sshd reload failed after host key regeneration. The previous keys were restored and sshd was not restarted."
    fi
    ok "SSH host keys regenerated. Previous keys: ${dir}"
    warn "Clients must accept the new fingerprint before they can log in again."
    for pub in /etc/ssh/ssh_host_*.pub; do
        [[ -f "${pub}" ]] || continue
        ssh-keygen -lf "${pub}"
    done
}

# RackNerd's Debian 13 image ships apt and not curl. curl fetches install.sh
# and the firewall files over HTTPS, which needs a CA bundle. Idempotent: a
# second run with both already installed does not touch apt.
ensure_curl() {
    if command -v curl >/dev/null 2>&1 && dpkg -s ca-certificates >/dev/null 2>&1; then
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    info "Installing ca-certificates and curl"
    apt-get update
    apt-get install -y ca-certificates curl
    command -v curl >/dev/null 2>&1 || error "curl is not available after installing it"
    ok "curl and ca-certificates are installed"
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${PACKAGES[@]}"
    ok "Packages installed"
}

recheck_engine_version() {
    local ver=""
    [[ "${ENGINE}" == "podman" ]] || return 0
    ver=$(podman_cli_version) || error "Podman is installed but its version could not be read"
    if ! version_ge "${ver}" 4.4; then
        warn "Podman ${ver} is older than 4.4. Installing Docker instead."
        ENGINE="docker"
        ENGINE_WHY="Podman ${ver} is older than 4.4, which Quadlet needs"
        apt-get install -y docker.io
        systemctl enable --now docker.service
        return 0
    fi
    if ! version_ge "${ver}" 5.0; then
        warn "Podman ${ver}: Quadlet is available. Notify=healthy needs Podman 5, so an automatic update cannot roll back."
    else
        ok "Podman ${ver}"
    fi
}

configure_access() {
    if getent group sudo >/dev/null 2>&1; then
        usermod -aG sudo "${DEPLOY_USER}"
        ok "${DEPLOY_USER} is in the sudo group"
    else
        warn "No sudo group; ${DEPLOY_USER} was not granted sudo"
    fi
    if [[ "${ENGINE}" == "docker" ]]; then
        usermod -aG docker "${DEPLOY_USER}"
        systemctl enable --now docker.service
        ok "Docker is enabled and ${DEPLOY_USER} is in the docker group"
        return 0
    fi
    if ! grep -q "^${DEPLOY_USER}:" /etc/subuid 2>/dev/null; then
        usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${DEPLOY_USER}"
        ok "Added subordinate uids for ${DEPLOY_USER}"
    fi
    if ! grep -q "^${DEPLOY_USER}:" /etc/subgid 2>/dev/null; then
        usermod --add-subgids 100000-165535 "${DEPLOY_USER}"
    fi
}

add_swap_if_small() {
    mem_is_small || return 0
    info "Adding a 1 GiB swap file so the image pull can finish on this host."
    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l 1G /swapfile; then
            dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
        fi
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
        swapon /swapfile
    fi
    if ! grep -q '^/swapfile[[:space:]]' /etc/fstab; then
        printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    fi
    ok "Swap file /swapfile is on"
}

relax_userns() {
    local sys="/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
    [[ "${ENGINE}" == "podman" ]] || return 0
    [[ -r "${sys}" ]] || return 0
    [[ "$(cat "${sys}")" == "1" ]] || return 0
    info "This kernel restricts unprivileged user namespaces. Relaxing that so rootless Podman can run."
    printf 'kernel.apparmor_restrict_unprivileged_userns=0\n' > /etc/sysctl.d/99-cs-server-userns.conf
    sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null
    ok "Unprivileged user namespaces are allowed"
}

configure_upgrades() {
    local src=""
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    # unattended-upgrades cannot see game players, so it must not reboot.
    # cs-reboot-if-idle does that when the host is idle.
    src=$(ops_file apt/52unattended-upgrades-local)
    install -Dm644 "${src}" /etc/apt/apt.conf.d/52unattended-upgrades-local
    if systemctl cat unattended-upgrades.service >/dev/null 2>&1; then
        systemctl enable --now unattended-upgrades.service
    fi
    ok "Unattended upgrades install packages and do not reboot on their own"
}

install_sysctl() {
    local src=""
    src=$(ops_file sysctl/61-cs-hardening.conf)
    install -Dm644 "${src}" /etc/sysctl.d/61-cs-hardening.conf
    if sysctl -p /etc/sysctl.d/61-cs-hardening.conf >/dev/null; then
        ok "Sysctl hardening applied (/etc/sysctl.d/61-cs-hardening.conf)"
    else
        warn "Could not apply every sysctl now. /etc/sysctl.d/61-cs-hardening.conf is installed for the next boot."
    fi
}

# Ports the idle reboot asks about. An explicit CS_REBOOT_PORTS replaces the
# list. Otherwise the game ports this install knows are included, and so are
# 27015 and 27016: a second server on the usual extra port must block a
# reboot even when this bootstrap did not create it. A port nobody listens
# on is ignored by the script.
idle_reboot_ports() {
    local ports="" p=""
    if [[ -n "${CS_REBOOT_PORTS:-}" ]]; then
        printf '%s\n' "${CS_REBOOT_PORTS}"
        return 0
    fi
    ports="${GAME_PORT}"
    if [[ "${DOD}" == "1" && "${DOD_PORT}" != "${GAME_PORT}" ]]; then
        ports="${ports} ${DOD_PORT}"
    fi
    for p in 27015 27016; do
        case " ${ports} " in
            *" ${p} "*) ;;
            *) ports="${ports} ${p}" ;;
        esac
    done
    printf '%s\n' "${ports}"
}

install_idle_reboot() {
    local players="" reboot="" svc="" timer="" ports=""
    players=$(ops_file cs-players)
    reboot=$(ops_file cs-reboot-if-idle)
    svc=$(ops_file systemd/cs-reboot-if-idle.service)
    timer=$(ops_file systemd/cs-reboot-if-idle.timer)
    install -d -m 755 /usr/local/sbin /etc/cs-server
    install -m 755 "${players}" /usr/local/sbin/cs-players
    install -m 755 "${reboot}" /usr/local/sbin/cs-reboot-if-idle
    install -m 644 "${svc}" /etc/systemd/system/cs-reboot-if-idle.service
    install -m 644 "${timer}" /etc/systemd/system/cs-reboot-if-idle.timer
    ports=$(idle_reboot_ports)
    printf 'CS_REBOOT_PORTS="%s"\n' "${ports}" > /etc/cs-server/reboot.env
    chmod 644 /etc/cs-server/reboot.env
    systemctl daemon-reload
    systemctl enable --now cs-reboot-if-idle.timer
    ok "Idle reboot timer enabled (pending update, no human players, no SSH session)"
}

# The upload script is always installed with backups. The ExecStartPost hook
# is installed only when offsite.env exists and is mode 600, and removed when
# that file is gone, so a re-run turns the hook off again. The env file is
# never created here: it holds credentials and does not belong in git.
install_offsite() {
    local home="" script="" drop_src="" drop_dir="" drop="" env_file="" perm=""
    home=$(deploy_home)
    drop_dir="${home}/.config/systemd/user/cs-server-backup.service.d"
    drop="${drop_dir}/offsite.conf"
    if [[ "${CS_BACKUP}" != "1" ]]; then
        if [[ -f "${drop}" ]]; then
            rm -f "${drop}"
            user_systemctl daemon-reload || true
        fi
        info "Off-site backups: off (CS_BACKUP=0)"
        return 0
    fi
    script=$(ops_file cs-server-offsite)
    drop_src=$(ops_file systemd/offsite.conf)
    install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${home}/.local/bin"
    install -m 755 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
        "${script}" "${home}/.local/bin/cs-server-offsite"
    env_file="${home}/.config/cs-server/offsite.env"
    if [[ -f "${env_file}" ]]; then
        perm=$(stat -c %a "${env_file}")
        if [[ "${perm}" != "600" ]]; then
            if [[ -f "${drop}" ]]; then
                rm -f "${drop}"
                user_systemctl daemon-reload || true
            fi
            warn "Off-site backups: ${env_file} is mode ${perm}, not 600. The upload hook was not enabled."
            return 0
        fi
        install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${drop_dir}"
        install -m 644 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${drop_src}" "${drop}"
        user_systemctl daemon-reload
        ok "Off-site backups run after each daily backup"
        return 0
    fi
    if [[ -f "${drop}" ]]; then
        rm -f "${drop}"
        user_systemctl daemon-reload || true
        ok "Off-site backups: hook removed (${env_file} is not present)"
        return 0
    fi
    info "Off-site backups: disabled until ${env_file} exists (mode 600)"
}

configure_fail2ban() {
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/cs-server.local <<EOF
[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
maxretry = 5
bantime = 1h
EOF
    systemctl enable --now fail2ban.service
    systemctl reload fail2ban.service || systemctl restart fail2ban.service
    ok "fail2ban sshd jail is on"
}

# Download a sibling under ops/ when this script was piped in. A checkout
# uses the file next to this one.
ops_file() {
    local rel="$1" dir local_path dest
    dir="$(script_dir)"
    local_path="${dir}/${rel}"
    if [[ -n "${dir}" && -f "${local_path}" ]]; then
        printf '%s\n' "${local_path}"
        return 0
    fi
    if [[ -z "${OPS_CACHE}" ]]; then
        OPS_CACHE=$(mktemp -d)
    fi
    dest="${OPS_CACHE}/${rel}"
    mkdir -p "${dest%/*}"
    if [[ ! -f "${dest}" ]]; then
        ensure_curl
        curl -fsSL "${RAW_BASE}/ops/${rel}" -o "${dest}"
    fi
    printf '%s\n' "${dest}"
}

# One port, or an nftables set when Day of Defeat is installed beside CS.
game_port_define() {
    if [[ "${DOD}" == "1" ]]; then
        printf '{ %s, %s }\n' "${GAME_PORT}" "${DOD_PORT}"
    else
        printf '%s\n' "${GAME_PORT}"
    fi
}

apply_firewall() {
    local src_fw src_unit src_in src_in_unit fastdl_line="" game_define
    game_define=$(game_port_define)
    src_fw=$(ops_file firewall/cs-server.nft)
    src_unit=$(ops_file firewall/cs-server-firewall.service)
    install -d -m 755 /etc/cs-server
    awk -v game="${game_define}" '
        /^define game_port/ { print "define game_port = " game; next }
        { print }
    ' "${src_fw}" > /etc/cs-server/firewall.nft
    chmod 644 /etc/cs-server/firewall.nft
    install -Dm644 "${src_unit}" /etc/systemd/system/cs-server-firewall.service

    if [[ "${FIREWALL}" == "nftables" ]]; then
        src_in=$(ops_file firewall/cs-server-input.nft)
        src_in_unit=$(ops_file firewall/cs-server-input.service)
        if [[ "${FASTDL}" == "1" ]]; then
            fastdl_line="        tcp dport ${FASTDL_PORT} accept"
        fi
        awk -v ssh="${SSH_PORT}" -v game="${game_define}" -v fastdl="${fastdl_line}" '
            /^define ssh_port/ { print "define ssh_port = " ssh; next }
            /^define game_port/ { print "define game_port = " game; next }
            /^[[:space:]]*# FASTDL_RULE$/ { if (fastdl != "") print fastdl; next }
            { print }
        ' "${src_in}" > /etc/cs-server/input.nft
        chmod 644 /etc/cs-server/input.nft
        install -Dm644 "${src_in_unit}" /etc/systemd/system/cs-server-input.service
    elif [[ -f /etc/systemd/system/cs-server-input.service ]]; then
        systemctl disable --now cs-server-input.service
    fi

    systemctl daemon-reload
    # enable --now does not re-run a oneshot that is already active, so a
    # second run would keep the previous ports. Reload reads the file just
    # written. Restart covers a unit that is not in a state reload can apply.
    enable_and_reload cs-server-firewall.service
    ok "Query-flood nftables unit is enabled"

    if [[ "${FIREWALL}" == "nftables" ]]; then
        enable_and_reload cs-server-input.service
        if [[ "${DOD}" == "1" ]]; then
            ok "nftables allows SSH ${SSH_PORT}/tcp and ${GAME_PORT}/udp and ${DOD_PORT}/udp"
        else
            ok "nftables allows SSH ${SSH_PORT}/tcp and ${GAME_PORT}/udp"
        fi
        warn "Confirm a new SSH session before closing this one."
    elif [[ "${FIREWALL}" == "ufw" ]]; then
        ufw allow "${SSH_PORT}/tcp"
        ufw allow "${GAME_PORT}/udp"
        if [[ "${DOD}" == "1" ]]; then
            ufw allow "${DOD_PORT}/udp"
        fi
        if [[ "${FASTDL}" == "1" ]]; then
            ufw allow "${FASTDL_PORT}/tcp"
        fi
        if ufw status | grep -q 'Status: active'; then
            ok "ufw is already active; the server ports are allowed"
        else
            info "Enabling ufw. SSH ${SSH_PORT}/tcp is allowed."
            ufw --force enable
            ok "ufw is enabled"
        fi
        warn "Confirm a new SSH session before closing this one."
    else
        firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
        firewall-cmd --permanent --add-port="${GAME_PORT}/udp"
        if [[ "${DOD}" == "1" ]]; then
            firewall-cmd --permanent --add-port="${DOD_PORT}/udp"
        fi
        if [[ "${FASTDL}" == "1" ]]; then
            firewall-cmd --permanent --add-port="${FASTDL_PORT}/tcp"
        fi
        firewall-cmd --reload
        ok "firewalld allows the server ports"
    fi
}

# enable --now leaves an already-active oneshot (RemainAfterExit) untouched.
enable_and_reload() {
    local unit="$1"
    systemctl enable --now "${unit}"
    systemctl reload "${unit}" || systemctl restart "${unit}"
}

enable_linger_user() {
    loginctl enable-linger "${DEPLOY_USER}"
    ok "Lingering enabled for ${DEPLOY_USER}"
}

# add-wants is itself idempotent: an existing wants symlink is left in place.
enable_network_online() {
    [[ "${ENGINE}" == "podman" ]] || return 0
    systemctl add-wants multi-user.target network-online.target
    ok "multi-user.target wants network-online.target"
}

start_user_manager() {
    local uid waited=0
    uid=$(id -u "${DEPLOY_USER}")
    systemctl start "user@${uid}.service"
    while [[ "${waited}" -lt 10 ]]; do
        [[ -d "/run/user/${uid}" ]] && break
        sleep 0.2
        waited=$((waited + 1))
    done
    [[ -d "/run/user/${uid}" ]] || error "The user manager for ${DEPLOY_USER} did not start"
    printf '%s\n' "${uid}"
}

user_systemctl() {
    local uid bin
    uid=$(id -u "${DEPLOY_USER}")
    [[ -d "/run/user/${uid}" ]] || error "The user manager for ${DEPLOY_USER} did not start"
    bin=$(command -v runuser 2>/dev/null || true)
    if [[ -z "${bin}" && -x /usr/sbin/runuser ]]; then
        bin=/usr/sbin/runuser
    fi
    [[ -n "${bin}" ]] || error "runuser is not installed (package util-linux)"
    "${bin}" -u "${DEPLOY_USER}" -- env "XDG_RUNTIME_DIR=/run/user/${uid}" systemctl --user "$@"
}

# Matches install.sh set_names for the Counter-Strike (or CS_GAME) install.
primary_service_name() {
    local game="${CS_GAME:-cstrike}" instance="${CS_INSTANCE:-}"
    if [[ "${game}" != "cstrike" ]]; then
        printf '%s-server%s\n' "${game}" "${instance:+-${instance}}"
    elif [[ -n "${instance}" ]]; then
        printf 'cs-server-%s\n' "${instance}"
    else
        printf '%s\n' scoutzknivez
    fi
}

detect_engine_name() {
    if [[ -n "${ENGINE}" ]]; then
        printf '%s\n' "${ENGINE}"
        return 0
    fi
    if command -v podman >/dev/null 2>&1; then
        printf '%s\n' podman
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        printf '%s\n' docker
        return 0
    fi
    printf '%s\n' podman
}

write_restart_files() {
    local home="$1" runtime="$2" dest host="" name
    # install -d resets an existing directory to 755. server.cfg lives here
    # and install.sh keeps the directory mode 700, so match that.
    mkdir -p "${home}/.config/cs-server"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${home}/.config/cs-server"
    chmod 700 "${home}/.config/cs-server"
    printf 'CS_RUNTIME=%s\n' "${runtime}" > "${home}/.config/cs-server/restart.env"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${home}/.config/cs-server/restart.env"
    chmod 644 "${home}/.config/cs-server/restart.env"
    # Quadlet files override these ports. Docker has no Quadlet file, so this
    # list is how the timer finds those containers. --restart-only leaves an
    # existing list in place and discovers Quadlet units on disk.
    if [[ "${RESTART_ONLY}" == "1" ]]; then
        return 0
    fi
    if [[ "${SERVER_IP:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        host="${SERVER_IP}"
    fi
    dest="${home}/.config/cs-server/restart.targets"
    {
        name=$(primary_service_name)
        if [[ -n "${host}" ]]; then
            printf '%s %s %s\n' "${name}" "${GAME_PORT}" "${host}"
        else
            printf '%s %s\n' "${name}" "${GAME_PORT}"
        fi
        if [[ "${DOD}" == "1" ]]; then
            if [[ -n "${host}" ]]; then
                printf 'dod-server %s %s\n' "${DOD_PORT}" "${host}"
            else
                printf 'dod-server %s\n' "${DOD_PORT}"
            fi
        fi
    } > "${dest}"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${dest}"
    chmod 644 "${dest}"
}

remove_restart_units() {
    local home="$1"
    if [[ -f "${home}/.config/systemd/user/cs-server-restart.timer" ]]; then
        user_systemctl disable --now cs-server-restart.timer || true
    fi
    rm -f \
        "${home}/.config/systemd/user/cs-server-restart.service" \
        "${home}/.config/systemd/user/cs-server-restart.timer" \
        "${home}/.local/bin/cs-server-restart" \
        "${home}/.config/cs-server/restart.env" \
        "${home}/.config/cs-server/restart.targets"
    if [[ -d "/run/user/$(id -u "${DEPLOY_USER}")" ]]; then
        user_systemctl daemon-reload || true
    fi
}

# Copy the script and the user timer. A second run replaces the same files
# and enables the timer again. CS_RESTART=0 removes them.
install_daily_restart() {
    local home script unit timer runtime
    home=$(deploy_home)
    if [[ "${CS_RESTART}" != "1" ]]; then
        remove_restart_units "${home}"
        ok "Daily restart: off"
        return 0
    fi
    script=$(ops_file restart-idle.sh)
    unit=$(ops_file systemd/cs-server-restart.service)
    timer=$(ops_file systemd/cs-server-restart.timer)
    runtime=$(detect_engine_name)
    install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
        "${home}/.local/bin" "${home}/.config/systemd/user"
    install -m 755 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
        "${script}" "${home}/.local/bin/cs-server-restart"
    install -m 644 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
        "${unit}" "${home}/.config/systemd/user/cs-server-restart.service"
    install -m 644 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
        "${timer}" "${home}/.config/systemd/user/cs-server-restart.timer"
    write_restart_files "${home}" "${runtime}"
    user_systemctl daemon-reload
    user_systemctl enable --now cs-server-restart.timer
    ok "Daily idle restart installed for ${DEPLOY_USER} (05:00 America/Los_Angeles, every 20 min until 08:00)"
}

run_installer() {
    local installer="" uid home runuser_bin="" name
    local -a unset_args=()
    home=$(deploy_home)
    uid=$(start_user_manager)
    # Persistent path: a piped --no-install must still be runnable after exit.
    installer=$(save_installer)
    install_daily_restart
    build_install_env "${uid}" "${home}"
    if [[ "${RUN_INSTALL}" == "0" ]]; then
        info "Host setup is done. Install command:"
        print_install_command "${installer}"
        if [[ "${DOD}" == "1" ]]; then
            build_dod_install_env "${uid}" "${home}"
            info "Day of Defeat install command:"
            INSTALL_ENV=("${DOD_INSTALL_ENV[@]}")
            print_install_command "${installer}"
        fi
        install_offsite
        return 0
    fi
    info "Running install.sh as ${DEPLOY_USER}"
    runuser_bin=$(command -v runuser 2>/dev/null || true)
    if [[ -z "${runuser_bin}" && -x /usr/sbin/runuser ]]; then
        runuser_bin=/usr/sbin/runuser
    fi
    [[ -n "${runuser_bin}" ]] || error "runuser is not installed (package util-linux)"
    for name in "${DOD_SCOPED_VARS[@]}"; do
        unset_args+=(-u "${name}")
    done
    "${runuser_bin}" -u "${DEPLOY_USER}" -- env "${unset_args[@]}" "${INSTALL_ENV[@]}" bash "${installer}"
    if [[ "${DOD}" == "1" ]]; then
        build_dod_install_env "${uid}" "${home}"
        info "Installing Day of Defeat on ${DOD_PORT}/udp"
        "${runuser_bin}" -u "${DEPLOY_USER}" -- env "${unset_args[@]}" "${DOD_INSTALL_ENV[@]}" bash "${installer}"
    fi
    install_offsite
}

parse_args "$@"
validate
if [[ "${RESTART_ONLY}" == "1" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
        if [[ "${CS_RESTART}" == "1" ]]; then
            info "Daily restart only: install the timer for ${DEPLOY_USER} (05:00 America/Los_Angeles, every 20 min until 08:00)"
        else
            info "Daily restart only: remove the timer for ${DEPLOY_USER}"
        fi
        info "Dry run: nothing was changed"
        exit 0
    fi
    require_root
    id "${DEPLOY_USER}" >/dev/null 2>&1 ||
        error "Deploy user ${DEPLOY_USER} does not exist. Run a full bootstrap before --restart-only."
    enable_linger_user
    start_user_manager >/dev/null
    install_daily_restart
    exit 0
fi
if [[ "${HARDEN_SSH}" == "1" ]]; then
    if [[ "${DRY_RUN}" != "1" ]]; then
        require_root
    fi
    if [[ "${REGEN_HOST_KEYS}" == "1" ]]; then
        regenerate_host_keys
    fi
    harden_ssh
    exit 0
fi
load_os
choose_engine
fill_packages
choose_firewall
detect_ssh_port
print_plan

if [[ "${DRY_RUN}" == "1" ]]; then
    info "Dry run: nothing was changed"
    exit 0
fi

require_root
if [[ "${REGEN_HOST_KEYS}" == "1" ]]; then
    regenerate_host_keys
fi
ensure_curl
create_user
install_ssh_keys
info "SSH authentication was not changed."
info "From a second terminal, confirm a key login: ssh ${DEPLOY_USER}@<this-host>"
info "Root key login is the admin path when ${DEPLOY_USER}'s password is locked."
info "After that login works: sudo bash ops/bootstrap-vps.sh --harden-ssh"
info "That turns password login off and leaves root key login on. Add --nopasswd-sudo only if ${DEPLOY_USER} should be the admin and root SSH should be turned off."
install_packages
recheck_engine_version
configure_access
if [[ "${NOPASSWD_SUDO}" == "1" ]]; then
    install_nopasswd_sudo
fi
add_swap_if_small
relax_userns
configure_upgrades
install_sysctl
install_idle_reboot
configure_fail2ban
apply_firewall
enable_linger_user
enable_network_online
run_installer
