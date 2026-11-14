# Keep in sync with the hadolint version bundled by hadolint/hadolint-action
# in .github/workflows/ci.yml, so `just lint` and CI agree on the ruleset.
HADOLINT_IMAGE := "ghcr.io/hadolint/hadolint:v2.15.0-debian"

# Container engine. Apple `container` on macOS, Podman elsewhere; override
# with CONTAINER_ENGINE=podman (e.g. `podman machine`) or docker.
ENGINE := env("CONTAINER_ENGINE", if os() == "macos" { "container" } else { "podman" })

# Apple `container` + Rosetta only translates x86_64; the HLDS payload is
# 32-bit i386 (hlds_linux, engine_i486.so), so it cannot build or run there.
[private]
_require-podman:
    #!/usr/bin/env bash
    if [ "{{ENGINE}}" = "container" ]; then
        echo "error: this recipe needs Podman (compose + Quadlet); Apple 'container' cannot run the 32-bit i386 HLDS payload (Rosetta translates x86_64 only)." >&2
        echo "       Use a Linux host, or CONTAINER_ENGINE=podman with 'podman machine start'. See README: macOS / Apple silicon." >&2
        exit 1
    fi

default:
    @just --list

# Build container image
build: _require-podman
    podman compose build

# Build and start server
up: _require-podman
    podman compose up --build

# Start server (detached)
up-d: _require-podman
    podman compose up --build -d

# Stop server
down: _require-podman
    podman compose down

# Follow server logs
logs:
    {{ENGINE}} logs -f scoutzknivez

# Rebuild image and restart Quadlet service
deploy: _require-podman
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
    {{ENGINE}} run --rm -i {{HADOLINT_IMAGE}} < Containerfile

# Lint shell scripts with shellcheck
shellcheck:
    shellcheck entrypoint.sh install.sh

# Run all checks
check: lint shellcheck test

# Run entrypoint regression tests
test:
    bash tests/entrypoint_test.sh
    bash tests/compose_test.sh

# Exec into running container
shell:
    {{ENGINE}} exec -it scoutzknivez bash || {{ENGINE}} exec -it scoutzknivez sh

# Send RCON command to server via FIFO
rcon cmd:
    podman exec scoutzknivez sh -c 'printf "%s\n" "$1" > /hlds/.runtime/hlds-input' sh "{{cmd}}"

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
