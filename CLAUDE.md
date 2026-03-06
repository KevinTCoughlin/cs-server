# CLAUDE.md

## What is this?

CS Server — a containerized Counter-Strike 1.6 ScoutzKnivez server built on the ReHLDS stack (ReHLDS, ReGameDLL_CS, Metamod-R, AMX Mod X, ReAPI). Low-gravity scout+knife gameplay with ZBot AI. Deployed via rootless Podman with Quadlet systemd integration.

## Build & Run

```bash
podman compose up --build           # build and start (attached)
podman compose up --build -d        # build and start (detached)
podman compose down                 # stop
```

Or via justfile: `just build`, `just up`, `just up-d`, `just down`, `just deploy`.

## Lint & Check

```bash
just lint                           # hadolint on Containerfile
just shellcheck                     # shellcheck on entrypoint.sh
just check                          # both
```

## Project Layout

```
Containerfile              Multi-stage Debian 13 build (builder + runtime)
compose.yml                Podman Compose service definition
entrypoint.sh              Container startup: FIFO control, graceful shutdown, PTY
config/
  server.cfg               Game server settings (gravity, air control, rounds)
  mapcycle.txt             Map rotation (3 scoutzknivez variants)
  autoexec.cfg             Auto-exec on server start
  game_init.cfg            Bot initialization
  liblist.gam              Points gamedll to Metamod
maps/                      BSP map files + NAV bot navigation mesh
plugins/
  amxmodx/
    plugins.ini            AMX Mod X plugin load order
    AQS.ini                Advanced Quake Sounds config (events, streaks, sounds)
    scripting/
      scoutzknivez.sma     Strip weapons, give scout+knife on spawn
      autobhop.sma         Auto bunny hop (hold jump to bhop)
      AQS.sma              Advanced Quake Sounds v8.0 (MIT, ClaudiuHKS)
      rtv.sma              Rock the Vote + map nominations
      websitebot.sma       Spectator bot showing server URL in scoreboard
      afkkicker.sma        Move idle players to spec, kick after timeout
      highpingkicker.sma   Warn then kick high-ping players
      advertisements.sma   Rotating chat messages (server info, commands)
  metamod/
    plugins.ini            Metamod plugin list (loads AMX Mod X)
sound/
  quake/                   Quake sound WAVs (gitignored, see README.md)
quadlet/
  scoutzknivez.container   Systemd Quadlet unit (rootless Podman)
.github/workflows/
  docker.yml               CI: build, Trivy scan, push to ghcr.io
  ci.yml                   CI: hadolint + shellcheck on every PR
  nightly.yml              Nightly: rebuild, scan, push nightly tag
```

## Architecture

- **Multi-stage container build**: Stage 1 (builder) downloads SteamCMD, HLDS, and the full ReHLDS stack, compiles all AMX Mod X plugins via a `for` loop, copies configs. Stage 2 (runtime) is a clean Debian 13-slim with only i386 runtime libs.
- **Runtime base image**: Debian 13 "Trixie" chosen for optimal security and performance in 2026:
  - 5-year security support (until ~2030) for long-term maintenance
  - Latest kernel (6.12 LTS) with improved container performance
  - Full i386/32-bit library support required for HLDS binaries
  - Minimal image size (~25-30MB for slim variant)
  - glibc compatibility (alternatives like Alpine's musl cause HLDS issues)
  - Alternatives rejected: Bookworm (shorter support window), Ubuntu (larger footprint), Alpine (glibc incompatibility)
- **FIFO-based server control**: `entrypoint.sh` creates a named pipe (`/tmp/hlds-input`) for sending commands to HLDS (say, quit, rcon). The `script` utility provides a PTY so HLDS doesn't block on stdin.
- **Graceful shutdown**: Traps SIGTERM/SIGINT, announces countdown in-game (30s → 10s → 5s → 2s → 1s), then sends `quit` via FIFO.
- **Quadlet for systemd**: `scoutzknivez.container` unit file enables auto-start, crash recovery (restart on-failure), and resource limits (512MB RAM, 2 CPUs).

## Key Conventions

- All component versions pinned as `ARG` in Containerfile (ReHLDS, ReGameDLL, Metamod, AMX Mod X, ReAPI)
- Config files bind-mounted read-only in compose.yml and Quadlet (server.cfg, mapcycle.txt)
- All Linux capabilities dropped (`cap_drop: ALL`, `NoNewPrivileges=true`)
- Container runs as non-root `hlds` system user
- Scripts must be shellcheck-clean, Containerfile must be hadolint-clean
- SPDX license headers on source files

## CI

- **docker.yml**: Builds container image on push/PR (path-filtered), runs Trivy scan, pushes to ghcr.io with semantic tags, generates SBOM
- **ci.yml**: Runs hadolint + shellcheck on every push/PR (no path filter) — fast lint gate
- **nightly.yml**: Daily rebuild at midnight UTC, Trivy scan, pushes `nightly` tag to ghcr.io

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAP` | `scoutzknivez` | Starting map |
| `MAXPLAYERS` | `20` | Max player slots |
| `PORT` | `27015` | Server port |
| `BOTS` | `1` | Enable ZBots (1=on, 0=off) |
