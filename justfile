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
    shellcheck entrypoint.sh

# Run all checks
check: lint shellcheck

# Remove built images
clean:
    podman rmi localhost/cs-server:latest 2>/dev/null || true
