#!/bin/bash
set -e

MAP="${MAP:-scoutzknivez}"
MAXPLAYERS="${MAXPLAYERS:-20}"
PORT="${PORT:-27015}"

exec ./hlds_run \
    -game cstrike \
    +map "$MAP" \
    +maxplayers "$MAXPLAYERS" \
    +port "$PORT" \
    -pingboost 2 \
    +exec server.cfg
