#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Archive the server state volume (bans, admins, stats, logs) and restore one.
#
#   backup-state.sh                  back up cs-server-state*, dod-server-state and dod-server-*-state
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
# The archive is mode 0600 and owned by the user who ran the backup. The game
# image runs as UID 10001, which cannot read that file through a bind mount, so
# restore streams it on stdin into a staging volume, and only then swaps it
# into the real volume. A bad or truncated archive never touches the live data.
set -euo pipefail
umask 077

KEEP="${CS_BACKUP_KEEP:-14}"
BACKUP_DIR="${CS_BACKUP_DIR:-${HOME}/cs-server-backups}"
RUNTIME="${CS_RUNTIME:-}"

usage() {
    cat <<EOF
Usage:
  backup-state.sh                 Archive cs-server-state* and dod-server-state* into ~/cs-server-backups
  backup-state.sh --restore FILE  Put one archive back into its volume
  backup-state.sh --help

Stop the server before --restore. CS_BACKUP_DIR, CS_BACKUP_KEEP,
CS_STATE_VOLUME, CS_RUNTIME and CS_SERVER_IMAGE override the defaults.
Config directories under ~/.config (cs-server, cs-server-*, dod-server,
dod-server-*) are archived too, as config-<name>-<utc>.tar.gz, without
offsite.env. CS_CONFIG_ROOT overrides that directory. Restoring one of those
archives puts the files back and leaves an existing offsite.env in place.
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
        elif [[ "${volume}" == "dod-server-state" || "${volume}" == dod-server-*-state ]]; then
            name="${volume%-state}"
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
            cs-server-state | cs-server-state-* | dod-server-state | dod-server-*-state)
                printf '%s\n' "${name}"
                ;;
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

# Move the extracted tree into the live volume. The container script rolls
# the live files back if the copy fails. The archive is not mounted here.
commit_staging() {
    local live="$1" staging="$2" image="$3" script
    # shellcheck disable=SC2016 # the script runs inside the container
    script=$(cat <<'EOS'
set -eu
rollback() {
    if [ -d /live/.cs-restore-old ]; then
        cd /live/.cs-restore-old || exit 1
        for f in .* *; do
            case "$f" in
                .|..) continue ;;
            esac
            if [ -e "$f" ] || [ -L "$f" ]; then
                mv -- "$f" /live/
            fi
        done
        rm -rf /live/.cs-restore-old
    fi
}
trap rollback EXIT
mkdir -p /live/.cs-restore-old
cd /live
for f in .* *; do
    case "$f" in
        .|..|.cs-restore-old) continue ;;
    esac
    if [ -e "$f" ] || [ -L "$f" ]; then
        mv -- "$f" /live/.cs-restore-old/
    fi
done
cd /staging
for f in .* *; do
    case "$f" in
        .|..) continue ;;
    esac
    if [ -e "$f" ] || [ -L "$f" ]; then
        cp -a -- "$f" /live/
    fi
done
rm -rf /live/.cs-restore-old
trap - EXIT
EOS
)
    ${RUNTIME} run --rm --network none --memory 128m --user 0 \
        --entrypoint /bin/sh \
        -v "${live}:/live" \
        -v "${staging}:/staging:ro" \
        "${image}" \
        -c "${script}"
}

drop_staging() {
    local staging="$1"
    ${RUNTIME} volume rm -f "${staging}" >/dev/null 2>&1 || true
}

restore_volume() {
    local volume="$1" archive="$2" image="" staging=""
    if volume_busy "${volume}"; then
        error "Stop the server using ${volume} before restoring"
    fi
    ${RUNTIME} volume inspect "${volume}" >/dev/null
    # Reject a truncated gzip before any volume is created.
    if ! gzip -t -- "${archive}"; then
        error "Archive is malformed or truncated; ${volume} was not changed"
    fi
    image=$(server_image)
    staging="${volume}-restore-staging"
    drop_staging "${staging}"
    ${RUNTIME} volume create "${staging}" >/dev/null
    # The host user opens the 0600 archive. The container (UID 10001 in the
    # game image) only reads the bytes on stdin.
    if ! gzip -dc -- "${archive}" | ${RUNTIME} run -i --rm --network none --memory 128m --user 0 \
        --entrypoint tar \
        -v "${staging}:/staging" \
        "${image}" \
        -C /staging -xf -; then
        drop_staging "${staging}"
        error "Archive did not extract; ${volume} was not changed"
    fi
    if ! commit_staging "${volume}" "${staging}" "${image}"; then
        drop_staging "${staging}"
        error "Could not swap in the restored files; ${volume} was left unchanged or rolled back"
    fi
    drop_staging "${staging}"
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

config_root() {
    printf '%s\n' "${CS_CONFIG_ROOT:-${HOME}/.config}"
}

# Game config lives next to the state volume, not inside it. Movement and any
# other instance (cs-server-<name>, dod-server-<name>) are included. offsite.env
# holds bucket keys and is left out of the archive.
list_config_dirs() {
    local root="$1" dir
    [[ -d "${root}" ]] || return 0
    shopt -s nullglob
    for dir in "${root}/cs-server" "${root}/cs-server-"* "${root}/dod-server" "${root}/dod-server-"*; do
        [[ -d "${dir}" ]] || continue
        basename "${dir}"
    done
    shopt -u nullglob
}

archive_config() {
    local base="$1" root="$2" ts="$3" archive="" tmp=""
    archive="${BACKUP_DIR}/config-${base}-${ts}.tar.gz"
    tmp="${archive}.partial"
    if ! tar -C "${root}" --exclude=offsite.env -czf "${tmp}" "${base}"; then
        rm -f "${tmp}"
        error "Could not archive ${root}/${base}"
    fi
    mv "${tmp}" "${archive}"
    chmod 600 "${archive}"
    rotate_archives "config-${base}"
    info "Backed up config ${base} to ${archive}"
}

restore_config() {
    local name="$1" archive="$2" root="" dest="" tmp="" saved=""
    root=$(config_root)
    dest="${root}/${name}"
    if ! gzip -t -- "${archive}"; then
        error "Archive is malformed or truncated; ${dest} was not changed"
    fi
    tmp=$(mktemp -d)
    if ! tar -C "${tmp}" -xzf "${archive}"; then
        rm -rf "${tmp}"
        error "Archive did not extract; ${dest} was not changed"
    fi
    mkdir -p "${dest}"
    if [[ -f "${dest}/offsite.env" ]]; then
        saved=$(mktemp)
        cp -a "${dest}/offsite.env" "${saved}"
    fi
    cp -a "${tmp}/${name}/." "${dest}/"
    if [[ -n "${saved}" ]]; then
        mv "${saved}" "${dest}/offsite.env"
    fi
    rm -f "${dest}/offsite.env.partial"
    rm -rf "${tmp}"
    info "Restored config ${name} from ${archive}"
}

if [[ "${ACTION}" == "restore" ]]; then
    volume="${CS_STATE_VOLUME:-$(volume_from_archive "${ARCHIVE}")}"
    volume_ok "${volume}"
    if [[ "${volume}" == config-* ]]; then
        restore_config "${volume#config-}" "${ARCHIVE}"
        exit 0
    fi
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

config_ts=$(date -u '+%Y%m%dT%H%M%SZ')
config_n=0
while IFS= read -r config_base; do
    [[ -n "${config_base}" ]] || continue
    archive_config "${config_base}" "$(config_root)" "${config_ts}"
    config_n=$((config_n + 1))
done < <(list_config_dirs "$(config_root)")

if [[ "${count}" -eq 0 && "${config_n}" -eq 0 ]]; then
    info "No cs-server-state volume yet; nothing to back up"
else
    info "Kept the newest ${KEEP} archive(s) per volume in ${BACKUP_DIR}"
fi
