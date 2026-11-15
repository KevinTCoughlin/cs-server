#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Switch the running server's game mode without a restart. The switch is
# queued in-game (scoutzknivez.amxx `sk_switchmode`) and happens at the next
# round end, after a chat announcement.
#
#   mode.sh <engine> nipper   knife only, mapcycle-nipper.txt ("Nipper Friday")
#   mode.sh <engine> scoutz   scout + knife, mapcycle.txt (default)
#   mode.sh <engine> auto     nipper from Fri 17:00 to Sat 04:00 local time,
#                             scoutz otherwise; what the Friday schedule runs
#
# <engine> is `container` (Apple), `podman` or `docker`. Does nothing (exit 0)
# when the server isn't running, so scheduled runs never start or restart it.
# NIPPER_START_HOUR / NIPPER_END_HOUR / CS_CONTAINER_NAME override defaults;
# keep the hours in step with ops/systemd/cs-server-friday.timer and
# ops/launchd/com.kevintcoughlin.cs-server.friday.plist.
set -euo pipefail

ENGINE="${1:-}"
MODE="${2:-}"
NAME="${CS_CONTAINER_NAME:-scoutzknivez}"
START_HOUR="${NIPPER_START_HOUR:-17}"
END_HOUR="${NIPPER_END_HOUR:-4}"

usage() {
    echo "usage: ${0##*/} <container|podman|docker> <nipper|scoutz|auto>" >&2
    exit 2
}

log() {
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    printf '%s [mode] %s\n' "${ts}" "$*"
}

case "${ENGINE}" in
    container | podman | docker) ;;
    *) usage ;;
esac

# Nipper Friday window: Friday from START_HOUR until Saturday END_HOUR.
friday_window() {
    local dow hour
    dow=$(date +%u)
    hour=$((10#$(date +%H)))
    if [[ "${dow}" -eq 5 && "${hour}" -ge "${START_HOUR}" ]] ||
       [[ "${dow}" -eq 6 && "${hour}" -lt "${END_HOUR}" ]]; then
        echo nipper
    else
        echo scoutz
    fi
}

if [[ "${MODE}" == "auto" ]]; then
    MODE=$(friday_window)
fi

case "${MODE}" in
    nipper) COMMAND="sk_switchmode knife mapcycle-nipper.txt" ;;
    scoutz) COMMAND="sk_switchmode scoutz mapcycle.txt" ;;
    *) usage ;;
esac

if ! "${ENGINE}" exec "${NAME}" true >/dev/null 2>&1; then
    log "${NAME} is not running; nothing to do"
    exit 0
fi

# Same FIFO path as `just rcon` / `cs-server rcon`. The plugin ignores the
# command if the server is already in that mode.
# shellcheck disable=SC2016 # $1 expands inside the container's sh
"${ENGINE}" exec "${NAME}" sh -c 'printf "%s\n" "$1" > /hlds/.runtime/hlds-input' sh "${COMMAND}"
log "queued ${MODE} (${COMMAND}); switches at the next round end"
