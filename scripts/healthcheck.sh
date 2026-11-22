#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Container health check: hlds_linux must be running AND answer a ping query
# (A2A_PING) on its game port. A process check alone stays green while the
# server is hung or has not opened its port yet.
#
# The engine answers the ping itself (A2A_ACK) in every configuration. An
# A2S_INFO query would not do: Steam's game-server layer answers that one, and
# stays silent with NOMASTER=1 (-nomaster). Uses bash's /dev/udp, so the image
# needs no extra packages.
set -u

PORT="${PORT:-27015}"
# With SERVER_IP the engine binds that address only, not loopback.
HOST="${SERVER_IP:-127.0.0.1}"

grep -qs hlds_linux /proc/[0-9]*/comm || exit 1

exec 3<>"/dev/udp/${HOST}/${PORT}" || exit 1
printf '\377\377\377\377i' >&3 || exit 1
LC_ALL=C IFS= read -r -t 3 -N 1 -u 3 _ 2>/dev/null || exit 1
