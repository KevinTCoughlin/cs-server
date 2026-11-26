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
CTR_MEMORY := env("CS_MEMORY", "640M")
CTR_CPUS := env("CS_CPUS", "2")
# Through ops/cs-server: Apple's builder refuses a Containerfile over 16 KiB,
# so that script builds from a copy without the comments.
CTR_BUILD := "ops/cs-server build"
CTR_ENV_FILE := if path_exists(justfile_directory() / ".env") == "true" { "--env-file " + justfile_directory() / ".env" } else { "" }
CTR_STATE := home_directory() / ".config/cs-server/state"
CTR_RUN := "mkdir -p " + CTR_STATE + " && container run --name scoutzknivez --rm -p 27015:27015/udp -m " + CTR_MEMORY + " -c " + CTR_CPUS + " --cap-drop ALL " + CTR_ENV_FILE + " -v " + justfile_directory() / "config/server.cfg" + ":/hlds/cstrike/server.cfg:ro -v " + justfile_directory() / "config/mapcycle.txt" + ":/hlds/cstrike/mapcycle.txt:ro -v " + justfile_directory() / "config/mapcycle-dust2.txt" + ":/hlds/cstrike/mapcycle-dust2.txt:ro -v " + justfile_directory() / "config/mapcycle-nipper.txt" + ":/hlds/cstrike/mapcycle-nipper.txt:ro -v " + justfile_directory() / "config/mapcycle-nipper-xmas.txt" + ":/hlds/cstrike/mapcycle-nipper-xmas.txt:ro -v " + justfile_directory() / "config/mapcycle-climb.txt" + ":/hlds/cstrike/mapcycle-climb.txt:ro -v " + justfile_directory() / "config/mapcycle-surf.txt" + ":/hlds/cstrike/mapcycle-surf.txt:ro -v " + justfile_directory() / "config/modes" + ":/hlds/cstrike/modes:ro -v " + CTR_STATE + ":/hlds/state"

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

# Start a LAN party server: host networking + sv_lan 1, listed in the LAN tab (Podman/Docker only)
lan-party:
    {{ if ENGINE == "container" { "echo 'Apple container has no host networking: clients connect by address (connect <mac-ip>:27015)' >&2; exit 1" } else { "podman compose -f compose.yml -f compose.lan.yml up --build -d" } }}

# Stop server
down:
    {{ if ENGINE == "container" { "container stop -t 50 scoutzknivez" } else { "podman compose down" } }}

# Restart with sv_lan 1 (no Steam auth/VAC, for Xash3D clients); `just lan off` reverts
lan mode="on":
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{mode}}" in
      on) lan=1 ;;
      off) lan=0 ;;
      *) echo "usage: just lan [on|off]" >&2; exit 2 ;;
    esac
    if [ "{{ENGINE}}" = container ]; then
      container stop -t 50 scoutzknivez >/dev/null 2>&1 || true
      {{CTR_RUN}} -e LAN_MODE=$lan -d {{IMAGE}} >/dev/null 2>&1
    else
      LAN_MODE=$lan podman compose up -d --force-recreate
    fi
    printf 'waiting for server'
    for _ in $(seq 40); do
      if {{ENGINE}} logs scoutzknivez 2>&1 | grep -q 'VAC secure mode'; then break; fi
      printf .; sleep 3
    done
    echo
    {{ENGINE}} logs scoutzknivez 2>&1 | grep 'VAC secure mode' | tail -1

# Follow server logs
logs:
    {{ENGINE}} logs -f scoutzknivez

# Rebuild image and restart Quadlet service (launchd agent on Apple container)
deploy:
    {{ if ENGINE == "container" { "ops/cs-server update" } else { "podman compose build && systemctl --user restart scoutzknivez" } }}

# Show Quadlet service status (launchd agent on Apple container)
status:
    {{ if ENGINE == "container" { "ops/cs-server status" } else { "systemctl --user status scoutzknivez" } }}

# Install Quadlet unit file (launchd agent on Apple container)
install:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{ENGINE}}" = container ]; then exec ops/cs-server install; fi
    cfg="${HOME}/.config/cs-server"
    mkdir -p "${cfg}/modes" ~/.config/containers/systemd
    # Seed any config file the unit mounts that isn't there yet.
    for f in config/server.cfg config/mapcycle*.txt config/modes/*.cfg; do
        dest="${cfg}/${f#config/}"
        [ -e "${dest}" ] || cp "${f}" "${dest}"
    done
    cp quadlet/scoutzknivez.container ~/.config/containers/systemd/
    systemctl --user daemon-reload

# Lint Containerfile with hadolint
lint:
    {{ENGINE}} run --rm -i {{HADOLINT_IMAGE}} < Containerfile

# Lint shell scripts with shellcheck
shellcheck:
    shellcheck entrypoint.sh install.sh scripts/i386-compat.sh scripts/mode.sh scripts/fetch-maps.sh scripts/healthcheck.sh scripts/game-env.sh scripts/release-notes.sh scripts/build-regamedll.sh ops/cs-server ops/bootstrap-vps.sh ops/backup-state.sh ops/restart-idle.sh tests/*.sh

# Run all checks
check: lint shellcheck test

# On Apple container the two entrypoint tests run in a Debian container (they
# need util-linux `script`) and the compose test is skipped.
# Run the script tests: stubbed engines, no server needed
test:
    {{ if ENGINE == "container" { "container run --rm -m 512M -v " + justfile_directory() + ":/repo -w /repo debian:trixie-slim bash -c 'bash tests/entrypoint_test.sh && bash tests/shutdown_test.sh'" } else { "bash tests/entrypoint_test.sh && bash tests/shutdown_test.sh" } }}
    bash tests/mapcycle_test.sh
    bash tests/dod_config_test.sh
    bash tests/mounts_test.sh
    bash tests/mode_test.sh
    bash tests/fetch_maps_test.sh
    bash tests/install_test.sh
    bash tests/release_notes_test.sh
    bash tests/firewall_test.sh
    bash tests/ops_test.sh
    bash tests/bootstrap_test.sh
    bash tests/restart_idle_test.sh
    bash tests/backup_test.sh
    bash tests/backup_docker_test.sh
    bash tests/regamedll_build_test.sh
    bash tests/nav_openlist_repro_test.sh
    {{ if ENGINE == "container" { "echo 'compose tests skipped: Apple container has no compose'" } else { "bash tests/compose_test.sh" } }}

# Checks plugins, mode switching, every mapcycle map and graceful shutdown
# through the console FIFO.
# Build the image, boot it and test the live server (about 2 minutes)
e2e: build
    bash tests/e2e_test.sh {{ENGINE}} {{IMAGE}}

# Regenerate quadlet/scoutzknivez.container from install.sh, the one place
# the unit is defined (tests/install_test.sh fails when they differ)
quadlet:
    CS_SERVER_IMAGE=localhost/cs-server:latest bash install.sh --print-unit > quadlet/scoutzknivez.container

# LAN event: n match servers (lan1..lan<n>) on consecutive ports and one
# FastDL sidecar, from the published image. Remove them with
# `CS_LAN_KIT=<n> bash install.sh --uninstall`
lan-kit n="2":
    CS_LAN_KIT={{n}} bash install.sh

# Build another game's image (localhost/cs-server:<game>) and test it:
# czero, dod, tfc, valve, gearbox, dmc or ricochet
game name:
    podman build --build-arg GAME={{name}} -t localhost/cs-server:{{name}} .
    bash tests/e2e_game_test.sh podman localhost/cs-server:{{name}}

# Exec into running container
shell:
    {{ENGINE}} exec -it scoutzknivez bash || {{ENGINE}} exec -it scoutzknivez sh

# Send RCON command to server via FIFO
rcon cmd:
    {{ENGINE}} exec scoutzknivez sh -c 'printf "%s\n" "$1" > /hlds/.runtime/hlds-input' sh "{{cmd}}"

# Switch game mode at the next round end, no restart: nipper | scoutz | auto
mode name:
    scripts/mode.sh {{ENGINE}} {{name}}

# Enable the Nipper Friday schedule (knife mode Fri 17:00 to Sat 04:00)
friday-enable:
    {{ if ENGINE == "container" { "ops/cs-server friday enable" } else { "install -Dm755 scripts/mode.sh ~/.local/bin/cs-server-mode && mkdir -p ~/.config/systemd/user && cp ops/systemd/cs-server-friday.service ops/systemd/cs-server-friday.timer ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now cs-server-friday.timer" } }}

# Disable the Nipper Friday schedule (leaves the current mode as is)
friday-disable:
    {{ if ENGINE == "container" { "ops/cs-server friday disable" } else { "systemctl --user disable --now cs-server-friday.timer; rm -f ~/.config/systemd/user/cs-server-friday.service ~/.config/systemd/user/cs-server-friday.timer ~/.local/bin/cs-server-mode; systemctl --user daemon-reload" } }}

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
    # Maps pinned in maps/manifest.tsv stay off FastDL unless their row says
    # fastdl=yes (the author's terms allow re-hosting).
    blocked=" "
    while IFS= read -r row; do
        IFS=$'\037' read -r name _url _sum _license _attribution _extras fastdl <<< "${row//$'\t'/$'\037'}"
        [[ -z "$name" || "$name" == \#* || "${fastdl:-no}" == yes ]] && continue
        blocked+="$name "
    done < maps/manifest.tsv
    count=0
    skipped=0
    for f in sound/quake/*.wav maps/*.bsp maps/*.nav; do
        [ -f "$f" ] || continue
        base=${f##*/}
        if [[ "$f" == maps/* && "$blocked" == *" ${base%.*} "* ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        dest="docs/cstrike/$f"
        mkdir -p "$(dirname "$dest")"
        cp "$f" "$dest"
        if command -v bzip2 >/dev/null 2>&1; then
            bzip2 -kf "$dest"
        fi
        count=$((count + 1))
    done
    echo "[fastdl] Synced $count file(s) to docs/cstrike/"
    if [ "$skipped" -gt 0 ]; then
        echo "[fastdl] Skipped $skipped file(s) of maps not cleared for FastDL in maps/manifest.tsv"
    fi
    echo "[fastdl] Commit and push to deploy via GitHub Pages"

# Fetch third-party maps pinned in maps/manifest.tsv (sha256-checked)
fetch-maps *names:
    scripts/fetch-maps.sh {{names}}

# Remove built images
clean:
    {{ if ENGINE == "container" { "container image delete " + IMAGE } else { "podman rmi " + IMAGE } }} 2>/dev/null || true
