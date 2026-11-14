# Keep in sync with the hadolint version bundled by hadolint/hadolint-action
# in .github/workflows/ci.yml, so `just lint` and CI agree on the ruleset.
HADOLINT_IMAGE := "ghcr.io/hadolint/hadolint:v2.15.0-debian"

# Container engine. Apple `container` on macOS, Podman elsewhere; override
# with CONTAINER_ENGINE=podman (e.g. `podman machine`) or docker.
ENGINE := env("CONTAINER_ENGINE", if os() == "macos" { "container" } else { "podman" })

# Apple `container` (no compose, no Quadlet): the image is built as linux/arm64
# and the i386 HLDS payload runs under qemu-i386 (scripts/i386-compat.sh).
# Run flags mirror compose.yml; the launchd service lives in ops/cs-server.
IMAGE := "localhost/cs-server:latest"
CTR_MEMORY := env("CS_MEMORY", "1G")
CTR_CPUS := env("CS_CPUS", "2")
CTR_BUILD := "container build --platform linux/arm64 -t " + IMAGE + " -f Containerfile ."
CTR_ENV_FILE := if path_exists(justfile_directory() / ".env") == "true" { "--env-file " + justfile_directory() / ".env" } else { "" }
CTR_RUN := "container run --name scoutzknivez --rm -p 27015:27015/udp -p 27015:27015/tcp -m " + CTR_MEMORY + " -c " + CTR_CPUS + " --cap-drop ALL " + CTR_ENV_FILE + " -v " + justfile_directory() / "config/server.cfg" + ":/hlds/cstrike/server.cfg:ro -v " + justfile_directory() / "config/mapcycle.txt" + ":/hlds/cstrike/mapcycle.txt:ro -v " + justfile_directory() / "config/mapcycle-dust2.txt" + ":/hlds/cstrike/mapcycle-dust2.txt:ro -v " + justfile_directory() / "config/mapcycle-nipper.txt" + ":/hlds/cstrike/mapcycle-nipper.txt:ro"

default:
    @just --list

# Build container image
build:
    {{ if ENGINE == "container" { CTR_BUILD } else { "podman compose build" } }}

# Build and start server
up:
    {{ if ENGINE == "container" { CTR_BUILD + " && " + CTR_RUN + " " + IMAGE } else { "podman compose up --build" } }}

# Start server (detached)
up-d:
    {{ if ENGINE == "container" { CTR_BUILD + " && " + CTR_RUN + " -d " + IMAGE } else { "podman compose up --build -d" } }}

# Stop server
down:
    {{ if ENGINE == "container" { "container stop -t 50 scoutzknivez" } else { "podman compose down" } }}

# Follow server logs
logs:
    {{ENGINE}} logs -f scoutzknivez

# Rebuild image and restart Quadlet service (launchd agent on Apple container)
deploy:
    {{ if ENGINE == "container" { "ops/cs-server update" } else { "podman compose up --build -d && podman compose down && systemctl --user restart scoutzknivez" } }}

# Show Quadlet service status (launchd agent on Apple container)
status:
    {{ if ENGINE == "container" { "ops/cs-server status" } else { "systemctl --user status scoutzknivez" } }}

# Install Quadlet unit file (launchd agent on Apple container)
install:
    {{ if ENGINE == "container" { "ops/cs-server install" } else { "mkdir -p ~/.config/containers/systemd && cp quadlet/scoutzknivez.container ~/.config/containers/systemd/ && systemctl --user daemon-reload" } }}

# Lint Containerfile with hadolint
lint:
    {{ENGINE}} run --rm -i {{HADOLINT_IMAGE}} < Containerfile

# Lint shell scripts with shellcheck
shellcheck:
    shellcheck entrypoint.sh install.sh scripts/i386-compat.sh ops/cs-server

# Run all checks
check: lint shellcheck test

# Run entrypoint regression tests (in a Debian container on Apple container:
# they need util-linux `script`; compose.yml isn't used there)
test:
    {{ if ENGINE == "container" { "container run --rm -m 512M -v " + justfile_directory() + ":/repo -w /repo debian:trixie-slim bash tests/entrypoint_test.sh" } else { "bash tests/entrypoint_test.sh" } }}
    {{ if ENGINE == "container" { "echo 'compose tests skipped: Apple container has no compose'" } else { "bash tests/compose_test.sh" } }}

# Exec into running container
shell:
    {{ENGINE}} exec -it scoutzknivez bash || {{ENGINE}} exec -it scoutzknivez sh

# Send RCON command to server via FIFO
rcon cmd:
    {{ENGINE}} exec scoutzknivez sh -c 'printf "%s\n" "$1" > /hlds/.runtime/hlds-input' sh "{{cmd}}"

# Restart Quadlet service (launchd agent on Apple container)
restart:
    {{ if ENGINE == "container" { "ops/cs-server restart" } else { "systemctl --user restart scoutzknivez" } }}

# View Quadlet service journal logs (launchd log file on Apple container)
journal:
    {{ if ENGINE == "container" { "ops/cs-server logs -f" } else { "journalctl --user -u scoutzknivez -f" } }}

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
    {{ if ENGINE == "container" { "container image delete " + IMAGE } else { "podman rmi " + IMAGE } }} 2>/dev/null || true
