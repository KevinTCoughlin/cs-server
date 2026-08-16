# Copilot Instructions

## Project

CS Server — a containerized Counter-Strike 1.6 ScoutzKnivez server built on the ReHLDS stack (ReHLDS, ReGameDLL_CS, Metamod-R, AMX Mod X, ReAPI). Low-gravity scout+knife gameplay with ZBot AI. Deployed via rootless Podman with Quadlet systemd integration.

## Build & Run

```bash
podman compose up --build           # build and start
podman compose up --build -d        # detached
podman compose down                 # stop
just build                          # build image only
just deploy                         # rebuild and restart Quadlet service
```

## Lint

```bash
just lint                           # hadolint on Containerfile
just shellcheck                     # shellcheck on entrypoint.sh
just check                          # both
```

## Project Layout

- `Containerfile` — multi-stage Debian 13 build (builder downloads SteamCMD/HLDS/ReHLDS stack, runtime is clean slim image)
- `compose.yml` — Podman Compose service (ports, volumes, security, resource limits)
- `entrypoint.sh` — container startup: FIFO control pipe, graceful shutdown with in-game announcements, PTY via `script`
- `config/` — server.cfg (gameplay), mapcycle.txt, autoexec.cfg, game_init.cfg, liblist.gam (Metamod)
- `maps/` — BSP map files + NAV bot navigation mesh
- `plugins/amxmodx/` — AMX Mod X config + scoutzknivez.sma custom plugin (strip weapons, give scout+knife)
- `plugins/metamod/` — Metamod plugin list
- `quadlet/` — systemd Quadlet unit for rootless Podman (auto-start, crash recovery, resource limits)

## Architecture & Conventions

- **Multi-stage build**: builder stage downloads and assembles everything, runtime stage has only i386 libs
- **FIFO control**: entrypoint.sh creates `/hlds/.runtime/hlds-input` named pipe for sending commands to HLDS
- **Graceful shutdown**: traps SIGTERM/SIGINT, announces countdown, sends `quit` via FIFO
- **Quadlet**: `scoutzknivez.container` for systemd integration (auto-start, restart on-failure)
- **Pinned versions**: all component versions are `ARG` in Containerfile
- **Security**: all capabilities dropped, no-new-privileges, non-root `hlds` user, bind-mounted read-only configs
- **Scripts**: must be shellcheck-clean
- **Containerfile**: must be hadolint-clean
- **License**: SPDX headers on source files

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAP` | `scoutzknivez` | Starting map |
| `MAXPLAYERS` | `20` | Max player slots |
| `PORT` | `27015` | Server port |
| `BOTS` | `1` | Enable ZBots (1=on, 0=off) |

## CI

- `docker.yml` — build, Trivy scan, push to ghcr.io (path-filtered)
- `ci.yml` — hadolint + shellcheck on every push/PR (no path filter)
- `nightly.yml` — daily rebuild, Trivy scan, push nightly tag
