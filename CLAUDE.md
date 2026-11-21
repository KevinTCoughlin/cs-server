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

The justfile picks its engine via `ENGINE := env("CONTAINER_ENGINE", ...)`: Apple `container` on macOS, `podman` elsewhere. Every recipe has a `container` branch next to the unchanged Podman command; service recipes (`install`, `status`, `restart`, `deploy`, `journal`) delegate to `ops/cs-server`, a launchd wrapper (`ops/launchd/com.kevintcoughlin.cs-server.plist`).

**Apple silicon:** HLDS is 32-bit i386 and Rosetta for Linux only translates x86_64 (`Exec format error`). The arm64 image runs it under `qemu-i386` user-mode emulation instead. All arch-specific logic lives in `scripts/i386-compat.sh`: every arch gets `ca-certificates` (steamclient needs a CA bundle to reach Steam), amd64 keeps the lib32* packages, while non-x86 gets multiarch `:i386` libs, a static `qemu-i386`, `scripts/i386-qemu-shim.c` (LD_PRELOAD: fakes `get_robust_list` and `/proc/cpuinfo`, the qemu-user gaps that crash steamclient/SteamCMD), `run-i386` for build-time tools (SteamCMD via `DEBUGGER=run-i386`, `amxxpc`), and an `hlds_linux` launcher that `entrypoint.sh` passes to `hlds_run -binary`. On x86, `run-i386` is a plain `exec`. Apple's builder does not set `TARGETARCH`, so don't branch stages on it. Keep the x86 and Podman/Quadlet behaviour unchanged when editing these.

## Lint & Check

```bash
just lint                           # hadolint on Containerfile
just shellcheck                     # shellcheck on entrypoint.sh
just test                           # script tests: stubbed engines, no server
just check                          # lint + shellcheck + test
just e2e                            # build, boot the image, test the live server (~2 min)
```

`tests/e2e_test.sh <engine> <image>` drives a running server through its console FIFO (plugins all running, `sk_switchmode` both ways, every mapcycle map, graceful shutdown); `docker.yml` runs it on both architectures. Run `just e2e` after touching `plugins/`, `config/`, `entrypoint.sh` or the Containerfile. It cannot see player-only behaviour (loadouts, buy/pickup blocking, RTV, kickers). Bots only play maps that have a `.nav`, so rounds never end on stock `de_dust2`.

## Project Layout

```
Containerfile              Multi-stage Debian 13 build (builder + plugins + runtime)
compose.yml                Podman Compose service definition
entrypoint.sh              Container startup: FIFO control, graceful shutdown, PTY
scripts/i386-compat.sh     Per-arch i386 libs + qemu-i386 emulation (arm64)
scripts/i386-qemu-shim.c   LD_PRELOAD shim for Steam libs under qemu-i386
scripts/mode.sh            Runtime mode switch (nipper|scoutz|auto) via the FIFO
scripts/fetch-maps.sh      Fetch sha256-pinned maps from maps/manifest.tsv
ops/cs-server              macOS launchd service wrapper (Apple container)
ops/launchd/               launchd agent templates (server + Nipper Friday)
ops/systemd/               Nipper Friday systemd user timer (Linux)
config/
  server.cfg               Game server settings (gravity, air control, rounds)
  mapcycle.txt             Map rotation (3 scoutzknivez variants)
  mapcycle-dust2.txt       Dust 2 rotation (classic de_dust2)
  mapcycle-nipper.txt      Nipper Friday (knife mode) rotation
  mapcycle-nipper-xmas.txt Nipper Friday Christmas rotation (Dec 1 to Jan 6)
  modes/<mode>.cfg         Per-mode cvars, exec'd after server.cfg each map
  modes/<mode>_<prefix>.cfg Per-map-prefix overrides (knife_he.cfg: grenade maps)
  autoexec.cfg             Auto-exec on server start
  game_init.cfg            Bot initialization
  liblist.gam              Points gamedll to Metamod
maps/                      Local BSP/NAV overlay (gitignored) + manifest.tsv pins
plugins/
  amxmodx/
    plugins.ini            AMX Mod X plugin load order
    AQS.ini                Advanced Quake Sounds config (events, streaks, sounds)
    scripting/
      scoutzknivez.sma     Spawn loadout + modes (scoutz/knife), sk_switchmode
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
tests/
  e2e_test.sh              Live-server test through the console FIFO (`just e2e`)
  *_test.sh, lib.sh        Script tests with stubbed engines (`just test`)
.github/workflows/
  docker.yml               CI: build, Trivy scan, push to ghcr.io
  ci.yml                   CI: hadolint + shellcheck on every PR
  nightly.yml              Weekly: rebuild, scan, push nightly tag
  friday-dust2.yml         Scheduled Friday PST Dust 2 announcements
  pages.yml                Jekyll-build docs/ and deploy to GitHub Pages
```

## Architecture

- **Multi-stage container build**: `builder` downloads SteamCMD, HLDS, the full ReHLDS stack and bot profiles (only pinned versions, no repo content, so it stays cached); `plugins` (FROM builder) compiles the AMX Mod X plugins via a `for` loop; `runtime` is a clean Debian 13-slim with only i386 runtime libs that copies the ~1 GB `/hlds` as one stable layer, then maps, sounds, `.amxx` and configs as small layers on top. Keep repo content out of `builder`, or every edit re-copies all of `/hlds`. The i386-compat `RUN`s bind only `i386-compat.sh` and `i386-qemu-shim.c` (a bind mount's contents are part of the cache key).
- **Apple container VM sizing**: 640M / 2 CPUs (`CS_MEMORY` / `CS_CPUS`); measured ~240 MiB HLDS+qemu RSS and ~250 server FPS with 10 bots. `ops/cs-server` stops the builder VM after a build it started.
- **Aggressive image optimization**: dpkg configured to exclude documentation, man pages, locales, bug templates, lintian overrides, MIME database, and info pages during package installation. Runtime cleanup removes all APT caches, logs, and temporary files. Combined with setuid/setgid bit removal for security hardening.
- **Runtime base image**: Debian 13 "Trixie" chosen for optimal security and performance in 2026:
  - 5-year security support (until ~2030) for long-term maintenance
  - Uses the host kernel; the image supplies only user-space libraries
  - Full i386/32-bit library support required for HLDS binaries
  - Minimal image size (~25-30MB for slim variant)
  - glibc compatibility (alternatives like Alpine's musl cause HLDS issues)
  - Alternatives rejected: Bookworm (shorter support window), Ubuntu (larger footprint), Alpine (glibc incompatibility)
- **FIFO-based server control**: `entrypoint.sh` creates a private named pipe (`/hlds/.runtime/hlds-input`) for sending commands to HLDS (say, quit, rcon). The `script` utility provides a PTY so HLDS doesn't block on stdin.
- **Graceful shutdown**: Traps SIGTERM/SIGINT, announces countdown in-game (30s → 10s → 5s → 2s → 1s), then sends `quit` via FIFO.
- **Game modes**: `scoutzknivez.sma` reads the mode from `localinfo sk_mode` (set by `MODE` at startup, survives map changes) and on every map execs `server.cfg` then `modes/<mode>.cfg` (the engine doesn't re-run `server.cfg` on `changelevel`, so the plugin does). `sk_switchmode <mode> <mapcycle> [map]` (server console/FIFO only) queues a switch for the next round end. In knife mode on `he_*` maps, HE grenade pickups are allowed. `scripts/mode.sh` picks the Christmas rotation from Dec 1 to Jan 6. `scripts/mode.sh` wraps it for `just mode`, `cs-server mode` and the opt-in Friday schedule. `rtv.sma` follows the `mapcyclefile` cvar.
- **Quadlet for systemd**: `scoutzknivez.container` unit file enables auto-start, crash recovery (restart on-failure), and resource limits (512MB RAM, 2 CPUs).

## Key Conventions

- All component versions pinned as `ARG` in Containerfile (ReHLDS, ReGameDLL, Metamod, AMX Mod X, ReAPI)
- Config files bind-mounted read-only in compose.yml and Quadlet (server.cfg, mapcycle.txt)
- All Linux capabilities dropped (`cap_drop: ALL`, `NoNewPrivileges=true`)
- Only 27015/udp is published (GoldSrc has no TCP listener on the game port); no `rcon_password` by default, the console FIFO is the admin path (`CS_RCON=1` opts in)
- Container runs as non-root `hlds` system user
- Scripts must be shellcheck-clean, Containerfile must be hadolint-clean
- SPDX license headers on source files

## CI

- **docker.yml**: Builds container image on push/PR (path-filtered), smoke-tests and e2e-tests it, runs Trivy scan, pushes to ghcr.io with semantic tags, generates SBOM
- **ci.yml**: Runs hadolint, shellcheck and the script tests on every push/PR (no path filter) — fast gate
- **nightly.yml**: Weekly rebuild (Monday 00:00 UTC), Trivy scan, pushes `nightly` tag to ghcr.io
- **pages.yml**: Builds `docs/` with Jekyll and deploys to GitHub Pages on push to main (Pages source must be "GitHub Actions")
- **friday-dust2.yml**: Scheduled Friday at 00:00 PST (08:00 UTC), generates Dust 2 Friday announcements with gameplay rules

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAP` | `scoutzknivez` | Starting map |
| `MAXPLAYERS` | `20` | Max player slots |
| `PORT` | `27015` | Server port |
| `BOTS` | `1` | Enable ZBots (1=on, 0=off) |
| `MAPCYCLE` | `mapcycle.txt` | Mapcycle file (e.g. `mapcycle-dust2.txt`, `mapcycle-nipper.txt`) |
| `MODE` | `scoutz` | Startup game mode: `scoutz` or `knife` |
| `FASTDL_URL` | empty | http(s) URL for `sv_downloadurl`; passed on the HLDS command line, never set in `server.cfg` (re-exec'd every map) |
