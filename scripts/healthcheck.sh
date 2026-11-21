#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# Container health check: hlds_linux must be running AND answer a server query
# (A2S_INFO) on its game port. A process check alone stays green while the
# server is hung or has not opened its port yet.
#
# Any reply counts (ReHLDS may answer with a challenge instead of the info
# packet). Uses bash's /dev/udp, so the image needs no extra packages.
set -u

PORT="${PORT:-27015}"

grep -qs hlds_linux /proc/[0-9]*/comm || exit 1

exec 3<>"/dev/udp/127.0.0.1/${PORT}" || exit 1
printf '\377\377\377\377TSource Engine Query\0' >&3 || exit 1
LC_ALL=C IFS= read -r -t 3 -N 1 -u 3 _ 2>/dev/null || exit 1
