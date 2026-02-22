#!/bin/bash
set -e

MAP="${MAP:-scoutzknivez}"
MAXPLAYERS="${MAXPLAYERS:-20}"
PORT="${PORT:-27015}"
BOTS="${BOTS:-1}"

# hlds_linux needs libs from its own directory (normally set by hlds_run)
export LD_LIBRARY_PATH=".:$LD_LIBRARY_PATH"

FIFO=/tmp/hlds-input
SCRIPT_PID=

cleanup() {
    rm -f "$FIFO"
}
trap cleanup EXIT

hlds_command() {
    echo "$1" > "$FIFO"
}

graceful_shutdown() {
    echo "[entrypoint] Caught shutdown signal, starting graceful shutdown..."

    if [ -n "$SCRIPT_PID" ] && kill -0 "$SCRIPT_PID" 2>/dev/null; then
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

    wait "$SCRIPT_PID" 2>/dev/null || true
}
trap graceful_shutdown SIGTERM SIGINT

mkfifo "$FIFO"

if [ "$BOTS" = "1" ]; then
    BOT_QUOTA_ARGS="+bot_quota 10"
else
    BOT_QUOTA_ARGS="+bot_quota 0"
fi

# Use 'script' to give hlds_linux a PTY — without a PTY, hlds_linux
# does blocking reads on stdin which freezes the game loop.
# tail -f keeps the FIFO open; script allocates the PTY.
tail -f "$FIFO" | script -qfc "./hlds_linux \
    -game cstrike \
    +map $MAP \
    +maxplayers $MAXPLAYERS \
    +port $PORT \
    -pingboost 2 \
    +exec server.cfg \
    $BOT_QUOTA_ARGS" /dev/null &
SCRIPT_PID=$!

echo "[entrypoint] HLDS started (PID: $SCRIPT_PID)"

wait "$SCRIPT_PID" || true
