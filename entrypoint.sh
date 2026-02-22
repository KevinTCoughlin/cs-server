#!/bin/bash
set -e

MAP="${MAP:-scoutzknivez}"
MAXPLAYERS="${MAXPLAYERS:-20}"
PORT="${PORT:-27015}"
BOTS="${BOTS:-1}"

# hlds_linux needs libs from its own directory (normally set by hlds_run)
export LD_LIBRARY_PATH=".:$LD_LIBRARY_PATH"

FIFO=/tmp/hlds-input
HLDS_PID=

cleanup() {
    exec 3>&- 2>/dev/null
    rm -f "$FIFO"
}
trap cleanup EXIT

hlds_command() {
    echo "$1" >&3
}

graceful_shutdown() {
    echo "[entrypoint] Caught shutdown signal, starting graceful shutdown..."

    if [ -n "$HLDS_PID" ] && kill -0 "$HLDS_PID" 2>/dev/null; then
        hlds_command "say [SERVER] Shutting down in 30 seconds..."
        sleep 20

        hlds_command "say [SERVER] Shutting down in 10 seconds..."
        sleep 5

        hlds_command "say [SERVER] Shutting down in 5 seconds..."
        sleep 3

        hlds_command "say [SERVER] Shutting down in 2 seconds..."
        sleep 2

        hlds_command "say [SERVER] Goodbye!"
        sleep 1

        echo "[entrypoint] Sending quit command to HLDS"
        hlds_command "quit"
    fi

    wait "$HLDS_PID" 2>/dev/null || true
}
trap graceful_shutdown SIGTERM SIGINT

mkfifo "$FIFO"

if [ "$BOTS" = "1" ]; then
    BOT_QUOTA_ARGS=(+bot_quota 10)
else
    BOT_QUOTA_ARGS=(+bot_quota 0)
fi

./hlds_linux \
    -game cstrike \
    +map "$MAP" \
    +maxplayers "$MAXPLAYERS" \
    +port "$PORT" \
    -pingboost 2 \
    +exec server.cfg \
    "${BOT_QUOTA_ARGS[@]}" < "$FIFO" &
HLDS_PID=$!

# Open write end of FIFO (completes the handshake, unblocks hlds_linux)
exec 3>"$FIFO"

echo "[entrypoint] HLDS started (PID: $HLDS_PID)"

wait "$HLDS_PID" || true
