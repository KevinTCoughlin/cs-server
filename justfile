default:
    @just --list

# Build container image
build:
    podman compose build

# Build and start server
up:
    podman compose up --build

# Start server (detached)
up-d:
    podman compose up --build -d

# Stop server
down:
    podman compose down

# Follow server logs
logs:
    podman logs -f scoutzknivez

# Rebuild image and restart Quadlet service
deploy:
    podman compose up --build -d && podman compose down
    systemctl --user restart scoutzknivez

# Show Quadlet service status
status:
    systemctl --user status scoutzknivez

# Install Quadlet unit file
install:
    mkdir -p ~/.config/containers/systemd
    cp quadlet/scoutzknivez.container ~/.config/containers/systemd/
    systemctl --user daemon-reload

# Lint Containerfile with hadolint
lint:
    podman run --rm -i hadolint/hadolint < Containerfile

# Lint shell scripts with shellcheck
shellcheck:
    shellcheck entrypoint.sh install.sh

# Run all checks
check: lint shellcheck

# Exec into running container
shell:
    podman exec -it scoutzknivez bash || podman exec -it scoutzknivez sh

# Send RCON command to server via FIFO
rcon cmd:
    podman exec scoutzknivez sh -c 'echo "{{cmd}}" > /tmp/hlds-input'

# Restart Quadlet service
restart:
    systemctl --user restart scoutzknivez

# View Quadlet service journal logs
journal:
    journalctl --user -u scoutzknivez -f

# Sync custom content to docs/cstrike/ for FastDL via GitHub Pages
fastdl:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p docs/cstrike/sound/quake docs/cstrike/maps
    count=0
    for f in sound/quake/*.wav maps/*.bsp maps/*.nav; do
        [ -f "$f" ] || continue
        dest="docs/cstrike/$f"
        mkdir -p "$(dirname "$dest")"
        cp "$f" "$dest"
        if command -v bzip2 >/dev/null 2>&1; then
            bzip2 -kf "$dest"
        fi
        count=$((count + 1))
    done
    echo "[fastdl] Synced $count file(s) to docs/cstrike/"
    echo "[fastdl] Commit and push to deploy via GitHub Pages"

# Remove built images
clean:
    podman rmi localhost/cs-server:latest 2>/dev/null || true
