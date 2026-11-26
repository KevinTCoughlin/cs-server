#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# FastDL sidecar: a second container from the same image that serves the
# game's maps and assets over HTTP, so clients fetch custom content from it
# instead of through the game connection (~5 KB/s).
#
#   podman run --entrypoint /fastdl.sh -p 27080:27080 <image>
#
# and on the game server FASTDL_URL=http://<this host>:27080/<game>/
#
# It serves /usr/local/share/cs-server/fastdl, a tree of links the image
# build lays out: the game's maps, sounds, sprites, models, gfx, overviews
# and .wad files, and nothing else. Settings, ban lists, admin files and
# plugins are not in it. busybox httpd lists no directories.
#
#   fastdl.sh          serve (FASTDL_PORT, default 27080)
#   fastdl.sh check    health check: the default map is served
set -euo pipefail

ROOT="${FASTDL_ROOT:-/usr/local/share/cs-server/fastdl}"
GAME_ENV="${HLDS_GAME_ENV:-/usr/local/share/cs-server/game.env}"
PORT="${FASTDL_PORT:-27080}"
GAME=cstrike
GAME_MAP=scoutzknivez
if [[ -f "${GAME_ENV}" ]]; then
    # shellcheck disable=SC1090 # generated at image build
    source "${GAME_ENV}"
fi

if [[ ! "${PORT}" =~ ^[0-9]{1,5}$ ]] || [[ "$((10#${PORT}))" -lt 1024 || "$((10#${PORT}))" -gt 65535 ]]; then
    echo "[fastdl] FASTDL_PORT must be an integer from 1024 to 65535" >&2
    exit 1
fi
PORT="$((10#${PORT}))"

# Host maps mounted at MAPS_LOCAL. Publish a file only when the manifest
# says fastdl=yes. The image tree is unchanged when MAPS_LOCAL is unset.
if [[ -n "${MAPS_LOCAL:-}" ]]; then
    maps_overlay=""
    for maps_overlay in \
        "${HLDS_OVERLAY_SH:-}" \
        /usr/local/share/cs-server/overlay-host-maps.sh
    do
        [[ -n "${maps_overlay}" && -f "${maps_overlay}" ]] && break
        maps_overlay=""
    done
    if [[ -z "${maps_overlay}" ]]; then
        maps_overlay="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/overlay-host-maps.sh"
    fi
    if [[ ! -f "${maps_overlay}" ]]; then
        echo "[fastdl] missing overlay-host-maps.sh" >&2
        exit 1
    fi
    # shellcheck source=scripts/overlay-host-maps.sh
    source "${maps_overlay}"
    if ! ROOT=$(maps_stage_fastdl); then
        exit 1
    fi
fi

case "${1:-serve}" in
    serve)
        [[ -d "${ROOT}/${GAME}/maps" ]] || { echo "[fastdl] ${ROOT}/${GAME}/maps is missing" >&2; exit 1; }
        echo "[fastdl] serving ${GAME} content on port ${PORT} (http://<host>:${PORT}/${GAME}/)"
        # Not exec: as process 1 httpd would ignore SIGTERM and the container
        # would only stop when the engine gives up and kills it.
        busybox httpd -f -p "${PORT}" -h "${ROOT}" &
        httpd_pid=$!
        trap 'kill "${httpd_pid}" 2>/dev/null' TERM INT
        wait "${httpd_pid}" || true
        ;;
    check)
        exec 3<>"/dev/tcp/127.0.0.1/${PORT}" || exit 1
        printf 'HEAD /%s/maps/%s.bsp HTTP/1.0\r\n\r\n' "${GAME}" "${GAME_MAP}" >&3
        IFS= read -r -t 3 -u 3 status || exit 1
        [[ "${status}" == "HTTP/1."*" 200 "* ]]
        ;;
    *)
        echo "usage: ${0##*/} [serve|check]" >&2
        exit 2
        ;;
esac
