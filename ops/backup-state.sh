#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Archive the server state volume (bans, admins, stats, logs) and restore one.
#
#   backup-state.sh                  back up cs-server-state and cs-server-state-*
#   backup-state.sh --restore FILE  replace that volume with one archive
#
# Archives go to ~/cs-server-backups (CS_BACKUP_DIR), named
# <volume>-YYYYMMDDTHHMMSSZ.tar.gz. CS_BACKUP_KEEP (default 14) older copies
# of each volume are removed. CS_STATE_VOLUME backs up that volume instead of
# the cs-server-state* set. CS_RUNTIME=podman|docker picks the engine.
#
# Stop the server first, then restore. The archive replaces the volume; it
# does not contain ~/.config/cs-server.
#
#   systemctl --user stop scoutzknivez
#   cs-server-backup --restore ~/cs-server-backups/cs-server-state-20261123T041500Z.tar.gz
#   systemctl --user start scoutzknivez
#
# Podman uses `volume export` / `volume import`. Docker tars the volume with
# the server image (CS_SERVER_IMAGE, or the image the running container uses).
set -euo pipefail
umask 077

KEEP="${CS_BACKUP_KEEP:-14}"
BACKUP_DIR="${CS_BACKUP_DIR:-${HOME}/cs-server-backups}"
RUNTIME="${CS_RUNTIME:-}"

usage() {
    cat <<EOF
Usage:
  backup-state.sh                 Archive cs-server-state* into ~/cs-server-backups
  backup-state.sh --restore FILE  Put one archive back into its volume
  backup-state.sh --help

Stop the server before --restore. CS_BACKUP_DIR, CS_BACKUP_KEEP,
CS_STATE_VOLUME, CS_RUNTIME and CS_SERVER_IMAGE override the defaults.
EOF
}

info() { printf '[info] %s\n' "$1"; }
error() { printf '[error] %s\n' "$1" >&2; exit 1; }

if [[ ! "${KEEP}" =~ ^[0-9]+$ ]] || [[ "${KEEP}" -lt 1 ]]; then
    error "Invalid CS_BACKUP_KEEP: ${KEEP} (expected a positive integer)"
fi

case "${1:-}" in
    "") ACTION="backup" ;;
    --restore)
        ACTION="restore"
        ARCHIVE="${2:-}"
        [[ -n "${ARCHIVE}" && -f "${ARCHIVE}" ]] || error "Usage: ${0##*/} --restore <archive.tar.gz>"
        ;;
    --help | -h) usage; exit 0 ;;
    *) error "Unknown option: ${1}. Use --help." ;;
esac

if [[ -z "${RUNTIME}" ]]; then
    if command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
    elif command -v docker >/dev/null 2>&1; then
        RUNTIME="docker"
    else
        error "Neither podman nor docker is installed"
    fi
fi
case "${RUNTIME}" in
    podman | docker) ;;
    *) error "Invalid CS_RUNTIME: ${RUNTIME} (expected podman or docker)" ;;
esac

# A container still using the volume must not be overwritten under its feet.
volume_busy() {
    local volume="$1" ids="" name=""
    ids=$(${RUNTIME} ps -aq --filter "volume=${volume}" --filter status=running 2>/dev/null || true)
    if [[ -n "${ids//[[:space:]]/}" ]]; then
        return 0
    fi
    name="${CS_CONTAINER_NAME:-}"
    if [[ -z "${name}" ]]; then
        if [[ "${volume}" == "cs-server-state" ]]; then
            name="scoutzknivez"
        elif [[ "${volume}" == cs-server-state-* ]]; then
            name="cs-server-${volume#cs-server-state-}"
        fi
    fi
    [[ -n "${name}" ]] || return 1
    [[ "$(${RUNTIME} inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)" == "true" ]]
}

server_image() {
    local name="${CS_CONTAINER_NAME:-scoutzknivez}" image=""
    if [[ -n "${CS_SERVER_IMAGE:-}" ]]; then
        printf '%s\n' "${CS_SERVER_IMAGE}"
        return 0
    fi
    image=$(${RUNTIME} inspect --format '{{.Config.Image}}' "${name}" 2>/dev/null || true)
    [[ -n "${image}" ]] || error "Set CS_SERVER_IMAGE so the volume can be archived with tar"
    printf '%s\n' "${image}"
}

# Names worth backing up. CS_STATE_VOLUME selects one volume of any name.
list_volumes() {
    local name listed=""
    if [[ -n "${CS_STATE_VOLUME:-}" ]]; then
        printf '%s\n' "${CS_STATE_VOLUME}"
        return 0
    fi
    if [[ "${RUNTIME}" == "podman" ]]; then
        listed=$(podman volume ls --format '{{.Name}}')
    else
        listed=$(docker volume ls -q)
    fi
    while IFS= read -r name; do
        case "${name}" in
            cs-server-state | cs-server-state-*) printf '%s\n' "${name}" ;;
        esac
    done <<< "${listed}"
}

volume_ok() {
    case "$1" in
        "" | *[!A-Za-z0-9_.-]*) error "Refusing volume name: ${1}" ;;
    esac
}

rotate_archives() {
    local volume="$1" path
    local -a files=()
    local i
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        files+=("${path}")
    done < <(find "${BACKUP_DIR}" -maxdepth 1 -type f \
        -name "${volume}-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.tar.gz" \
        | sort -r)
    for ((i = KEEP; i < ${#files[@]}; i++)); do
        rm -f "${files[i]}"
    done
}

write_archive() {
    local volume="$1" archive="$2" tmp="" image=""
    tmp=$(mktemp)
    if [[ "${RUNTIME}" == "podman" ]]; then
        podman volume export "${volume}" > "${tmp}"
        gzip -c "${tmp}" > "${archive}.partial"
    else
        image=$(server_image)
        ${RUNTIME} run --rm --network none --memory 128m --entrypoint tar \
            -v "${volume}:/volume:ro" \
            "${image}" \
            -C /volume -czf - . > "${archive}.partial"
    fi
    rm -f "${tmp}"
    mv "${archive}.partial" "${archive}"
    chmod 600 "${archive}"
}

clear_mountpoint() {
    local volume="$1" mp=""
    mp=$(${RUNTIME} volume inspect --format '{{.Mountpoint}}' "${volume}")
    case "${mp}" in
        /*/volumes/"${volume}"/_data) ;;
        *) error "Refusing to clear unexpected mountpoint: ${mp}" ;;
    esac
    if [[ "${RUNTIME}" == "podman" ]]; then
        podman unshare find "${mp}" -mindepth 1 -delete
    else
        # The Docker mount is root-owned. Clear it from inside a container.
        local image
        image=$(server_image)
        # `*` is literal when the directory has no match; skip those names.
        # shellcheck disable=SC2016 # this script runs inside the container
        ${RUNTIME} run --rm --network none --memory 128m --entrypoint /bin/sh \
            -v "${volume}:/volume" \
            "${image}" \
            -c 'cd /volume && for f in .* *; do case "$f" in .|..) continue ;; "*" | ".*") [ -e "$f" ] || continue ;; esac; rm -rf -- "$f"; done'
    fi
}

restore_volume() {
    local volume="$1" archive="$2" tmp="" image="" dir="" base=""
    volume_busy "${volume}" && error "Stop the server using ${volume} before restoring"
    ${RUNTIME} volume inspect "${volume}" >/dev/null
    gzip -t -- "${archive}"
    clear_mountpoint "${volume}"
    if [[ "${RUNTIME}" == "podman" ]]; then
        tmp=$(mktemp)
        gzip -dc -- "${archive}" > "${tmp}"
        podman volume import "${volume}" "${tmp}"
        rm -f "${tmp}"
    else
        image=$(server_image)
        dir=$(dirname "${archive}")
        base=$(basename "${archive}")
        ${RUNTIME} run --rm --network none --memory 128m --entrypoint tar \
            -v "${volume}:/volume" \
            -v "${dir}:/backup:ro" \
            "${image}" \
            -C /volume -xzf "/backup/${base}"
    fi
    info "Restored ${volume} from ${archive}"
}

volume_from_archive() {
    local base
    base=$(basename "$1" .tar.gz)
    if [[ ! "${base}" =~ ^(.+)-[0-9]{8}T[0-9]{6}Z$ ]]; then
        error "Archive name must be <volume>-YYYYMMDDTHHMMSSZ.tar.gz: ${base}"
    fi
    printf '%s\n' "${BASH_REMATCH[1]}"
}

if [[ "${ACTION}" == "restore" ]]; then
    volume="${CS_STATE_VOLUME:-$(volume_from_archive "${ARCHIVE}")}"
    volume_ok "${volume}"
    restore_volume "${volume}" "${ARCHIVE}"
    exit 0
fi

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
count=0
while IFS= read -r volume; do
    [[ -n "${volume}" ]] || continue
    volume_ok "${volume}"
    if volume_busy "${volume}"; then
        info "Backing up ${volume} while the server is running (a point-in-time copy)"
    fi
    ts=$(date -u '+%Y%m%dT%H%M%SZ')
    archive="${BACKUP_DIR}/${volume}-${ts}.tar.gz"
    info "Backing up ${volume} to ${archive}"
    write_archive "${volume}" "${archive}"
    rotate_archives "${volume}"
    count=$((count + 1))
done < <(list_volumes)

if [[ "${count}" -eq 0 ]]; then
    info "No cs-server-state volume yet; nothing to back up"
else
    info "Kept the newest ${KEEP} archive(s) per volume in ${BACKUP_DIR}"
fi
