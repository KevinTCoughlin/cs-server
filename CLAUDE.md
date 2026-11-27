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

**Apple silicon:** HLDS is 32-bit i386 and Rosetta for Linux only translates x86_64 (`Exec format error`). The arm64 image runs it under `qemu-i386` user-mode emulation instead. All arch-specific logic lives in `scripts/i386-compat.sh`: every arch gets `ca-certificates` (steamclient needs a CA bundle to reach Steam), amd64 keeps the lib32* packages, while non-x86 gets multiarch `:i386` libs, a static `qemu-i386`, `scripts/i386-qemu-shim.c` (LD_PRELOAD: fakes `get_robust_list` and `/proc/cpuinfo`, the qemu-user gaps that crash steamclient/SteamCMD), `run-i386` for build-time tools (SteamCMD via `DEBUGGER=run-i386`, `amxxpc`), and an `hlds_linux` launcher that `entrypoint.sh` passes to `hlds_run -binary`. On x86, `run-i386` is a plain `exec`. Apple's builder does not set `TARGETARCH`, so don't branch stages on it. It also refuses a Containerfile over 16 KiB (apple/container#735), so `ops/cs-server` (`build_image`, which the justfile's `CTR_BUILD` calls) builds from a copy with the comment lines removed; `tests/ops_test.sh` checks that copy stays under the limit. Keep the x86 and Podman/Quadlet behaviour unchanged when editing these.

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
ops/scripts/cs-records-export  Read-only export of movement records to records.json
ops/systemd/               systemd user timers (Nipper Friday, state backup, daily idle restart, records export)
ops/seccomp/               Docker's upstream default seccomp profile, kept in the image only for installers 1.1-1.4 (nothing current passes a profile; Docker 29.4.2 alone broke i386 sockets, install.sh refuses it)
ops/firewall/              nftables query-flood rate limit + boot unit (opt-in, never auto-applied)
config/
  server.cfg               Game server settings (gravity, air control, rounds)
  mapcycle.txt             Map rotation (3 scoutzknivez variants)
  mapcycle-dust2.txt       Dust 2 rotation (classic de_dust2)
  mapcycle-nipper.txt      Nipper Friday (knife mode) rotation
  mapcycle-nipper-xmas.txt Nipper Friday Christmas rotation (Dec 1 to Jan 6)
  mapcycle-climb.txt       Climb mode (KZ) rotation
  mapcycle-surf.txt        Surf mode rotation
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
      movement.sma         Climb and surf modes: run timer (buttons or zones), checkpoints, top lists, semiclip
  metamod/
    plugins.ini            Metamod plugin list (loads AMX Mod X)
sound/
  quake/                   Quake sound WAVs (gitignored, see README.md)
docs/records/              Movement records page (static HTML; sample records.json)
quadlet/
  scoutzknivez.container   Systemd Quadlet unit (rootless Podman)
tests/
  e2e_test.sh              Live-server test through the console FIFO (`just e2e`)
  *_test.sh, lib.sh        Script tests with stubbed engines (`just test`)
.github/workflows/
  docker.yml               CI: build, Trivy scan, push to ghcr.io
  movement.yml             CI: movement image (climb/surf maps) to ghcr.io/<repo>-movement
  ci.yml                   CI: hadolint + shellcheck on every PR
  nightly.yml              Weekly: rebuild, scan, push nightly tag
  friday-dust2.yml         Scheduled Friday PST Dust 2 announcements
  pages.yml                Jekyll-build docs/ and deploy to GitHub Pages
```

## Architecture

- **Multi-stage container build**: `builder` downloads SteamCMD, HLDS, the full ReHLDS stack and bot profiles (only pinned versions, no repo content, so it stays cached); `plugins` (FROM builder) compiles the AMX Mod X plugins via a `for` loop; `runtime` is a clean Debian 13-slim with only i386 runtime libs that copies the ~1 GB `/hlds` as one stable layer, then maps, sounds, `.amxx` and configs as small layers on top. Keep repo content out of `builder`, or every edit re-copies all of `/hlds`. The i386-compat `RUN`s bind only `i386-compat.sh` and `i386-qemu-shim.c` (a bind mount's contents are part of the cache key). The one exception is `scripts/build-regamedll.sh`, which rebuilds ReGameDLL `cs.so` from the pinned tag with `scripts/regamedll-nav-openlist.patch` (value-initializes `CNavArea`'s open-list fields; the rest of rehlds/ReGameDLL_CS#1202 was not taken) and is bind-mounted in its own last builder step, so editing the patch re-runs that compile and the `/hlds` copy, not SteamCMD. `tests/nav_openlist_repro.cpp` is the deterministic crash.
- **Apple container VM sizing**: 640M / 2 CPUs (`CS_MEMORY` / `CS_CPUS`); measured ~240 MiB HLDS+qemu RSS and ~250 server FPS with 10 bots. `ops/cs-server` stops the builder VM after a build it started.
- **Aggressive image optimization**: dpkg configured to exclude documentation, man pages, locales, bug templates, lintian overrides, MIME database, and info pages during package installation. Runtime cleanup removes all APT caches, logs, and temporary files. Combined with setuid/setgid bit removal for security hardening.
- **Runtime base image**: Debian 13 "Trixie" chosen for optimal security and performance in 2026:
  - 5-year security support (until ~2030) for long-term maintenance
  - Uses the host kernel; the image supplies only user-space libraries
  - Full i386/32-bit library support required for HLDS binaries
  - Minimal image size (~25-30MB for slim variant)
  - glibc compatibility (alternatives like Alpine's musl cause HLDS issues)
  - Alternatives rejected: Bookworm (shorter support window), Ubuntu (larger footprint), Alpine (glibc incompatibility)
- **`GAME` build argument** (`cstrike` default; `czero`, `dod`, `tfc`, `valve`, `gearbox`, `dmc`, `ricochet`): `scripts/game-env.sh` is the table (default map, AMX Mod X package, ReGameDLL, bots, stats file). The builder writes that game's row to `/usr/local/share/cs-server/game.env` and sources it in later steps; `entrypoint.sh` sources it at start (`HLDS_GAME_ENV` in tests). Counter-Strike's content comes from `config/`, `plugins/` and `maps/` in the `game-cstrike` stage; every other game keeps its stock files, with `liblist.gam` pointed at Metamod and `config/games/common.cfg` appended to `server.cfg` in the builder, and has an empty `game-<name>` stage. The final stage is `FROM game-${GAME}`. Adding a game: a row in the table and a `game-<name>` line. Known quirks: `steam_appid.txt` must hold the game's own Steam app id (`GAME_APPID`; the engine cannot rewrite it on the read-only root, and with the wrong id every real player gets "STEAM validation rejected" while bots, queries and the health check still work: only a real client shows it); `tfc.so` needs the system libstdc++ (the bundled copy is removed for TFC); some of Valve's files are mixed case (`tfc/events/wpn/Tf_sg.sc`) and the engine finds them case-insensitively on x86 but not under qemu-i386 on arm64, so the builder adds a lower-case link beside each one outside Counter-Strike; Condition Zero ignores `+bot_quota` on the command line, so the entrypoint sends it through the console, and its bots need `bot_join_after_player 0`. `tests/e2e_game_test.sh` (`just game <name>`) covers these images. `.github/workflows/games.yml` builds, tests and publishes them (`:<version>-<game>`, `:<game>`) on release tags only; on pull requests it runs every game when a game file changes (`scripts/game-env.sh`, `config/games/`, the test, the workflow) and Day of Defeat on amd64 alone when only the Containerfile or entrypoint does; run it by hand (workflow_dispatch) before tagging. It keeps no layer cache, so it does not evict the Counter-Strike image's. `install.sh` takes `CS_GAME=<game>` (service `<game>-server`, config `~/.config/<game>-server`, volume `<game>-server-state`; mounts are built from `CONFIG_FILES`/`CONFIG_DIRS` into `/hlds/${GAME}/`; the game titles there mirror `scripts/game-env.sh`). Compose, the Quadlet reference unit and `ops/cs-server` are Counter-Strike only (#108).
- **State volume and read-only root**: everything the server writes lives under `/hlds/state` (named volume `cs-server-state`; `~/.config/cs-server/state` on macOS). The Containerfile replaces `banned.cfg`, `listip.cfg`, `logs`, AMX Mod X `users.ini`, `cmdaccess.ini`, `logs`, `csstats.dat` and `vault*` with symlinks into it, plus `maps/<map>.nav` → `state/nav/` for every map that ships without a mesh (the bots write it there once; without the link the save fails and the map reloads in a loop), and `entrypoint.sh` (`prepare_state`) creates the targets and seeds `users.ini` from `/usr/local/share/cs-server/`. A new file the server must write needs a symlink there too, or it fails on the read-only root (Quadlet, Compose, `install.sh`). `/hlds/.runtime` is a symlink to `/tmp/hlds-runtime` (tmpfs). `tests/mounts_test.sh` checks the volume and read-only flags on every path; `tests/e2e_test.sh` checks that a ban survives container replacement.
- **FIFO-based server control**: `entrypoint.sh` creates a private named pipe (`/hlds/.runtime/hlds-input`) for sending commands to HLDS (say, quit, rcon). The `script` utility provides a PTY so HLDS doesn't block on stdin.
- **Graceful shutdown**: Traps SIGTERM/SIGINT, announces countdown in-game (30s → 10s → 5s → 2s → 1s), then sends `quit` via FIFO.
- **Quadlet unit**: `install.sh` (`quadlet_unit`) is the only definition. `quadlet/scoutzknivez.container` is generated from it (`just quadlet`, i.e. `CS_SERVER_IMAGE=localhost/cs-server:latest install.sh --print-unit`); never edit that file by hand, `tests/install_test.sh` fails when they differ. The installer builds its mounts from `CONFIG_FILES` / `CONFIG_DIRS`; `compose.yml`, the justfile and `ops/cs-server` still list theirs by hand (`tests/mounts_test.sh`).
- **FastDL sidecar and LAN kit**: `scripts/fastdl.sh` (`/fastdl.sh` in the image) runs busybox httpd (package `busybox-static`, added through `i386-compat.sh install`) on `FASTDL_PORT` over `/usr/local/share/cs-server/fastdl/<game>/`, a tree of symlinks the final build stage creates for `maps sound sprites models gfx overviews` and `*.wad` only; anything not linked there (settings, `addons/`, ban lists) is a 404. It is not `exec`ed: as PID 1 httpd would ignore SIGTERM. When `MAPS_LOCAL` is set (the movement sidecar mounts `~/cs-maps` there), it serves a copy of that tree under `/tmp` and adds a host file only if `maps/manifest.tsv` (`/usr/local/share/cs-server/maps-manifest.tsv` in the image) says `fastdl=yes`. Per-file mounts of `fastdl=no` maps must not be added to the sidecar: the serve tree follows `/hlds/cstrike/maps`. `install.sh`: `CS_FASTDL=1` writes a second unit (`cs-server-fastdl`, or `<game>-server-fastdl`; `PodmanArgs=--entrypoint /fastdl.sh`) once per run and derives `FASTDL_URL` from `CS_FASTDL_HOST`, `SERVER_IP` or `hostname -I`; `--uninstall` removes the sidecar only when `CS_FASTDL=1` (or the kit) is given. `CS_MAPS_LOCAL=1` (`CS_MAPS_HOST`, default `~/cs-maps`) adds the host-map mounts. `CS_LAN_KIT=<n>` loops `set_names` + `do_install` over `lan1..lan<n>` (`run_kit`) with the LAN profile, `CS_MODE=match`, `CS_BOTS=0` and the sidecar as defaults. `tests/e2e_test.sh` runs the sidecar and checks what it serves and refuses, including a host tree.
- **Host maps**: `~/cs-maps` (`/home/cs/cs-maps` on the VPS, Quadlet `%h/cs-maps`) is the read-only tree for maps a published image does not contain. `scripts/fetch-maps-host.sh` (`just fetch-maps-host`) fills it from `maps/manifest.tsv` for the movement rotation, SHA-256 checked. The game unit bind-mounts the tree at `/maps-local` and each file onto `/hlds/<game>/...` so stock files stay. `entrypoint.sh` links those files when the destination is writable and exits 1 when `MAPS_LOCAL` is set but the directory is missing, empty, or a host `.bsp` is not visible. `scripts/overlay-host-maps.sh install-unit` inserts the block into a live unit without rewriting `Image=` or `FASTDL_URL`. Published images stay `MAP_POLICY=cleared`.
- **Metrics**: `plugins/amxmodx/scripting/metrics.sma` (core + fakemeta only, compiled for every game; listed in `plugins.ini`, both `modes/*.ini` and appended to the other games' stock `plugins.ini` in the builder) rewrites `addons/amxmodx/data/metrics.prom` every `metrics_interval` seconds; the image links that path to `/hlds/.runtime/metrics.prom` (tmpfs). FPS is frames counted in an `FM_StartFrame` forward (`metrics_fps 0` skips registering it); uptime survives map changes through `localinfo metrics_start`. `scripts/metrics.pl` (`/metrics.pl`, perl-base only, one request at a time) serves `/metrics` with `hlds_up` = 1 only while the file is under 30 s old; `entrypoint.sh` starts it when `METRICS_PORT` is set (`METRICS_BIND`, `HLDS_METRICS_SERVER` in tests). A2S_INFO is not used: it is silent with `NOMASTER=1`. Any new mode plugin list must include `metrics.amxx`.
- **Game modes**: `scoutzknivez.sma` reads the mode from `localinfo sk_mode` (set by `MODE` at startup, survives map changes) and on every map execs `server.cfg` then `modes/<mode>.cfg` (the engine doesn't re-run `server.cfg` on `changelevel`, so the plugin does). `sk_switchmode <mode> <mapcycle> [map]` (server console/FIFO only) queues a switch for the next round end. In knife mode on `he_*` maps, HE grenade pickups are allowed. `scripts/mode.sh` picks the Christmas rotation from Dec 1 to Jan 6. `scripts/mode.sh` wraps it for `just mode`, `cs-server mode` and the opt-in Friday schedule. `rtv.sma` follows the `mapcyclefile` cvar. With `sk_bots 0` the plugin also hooks `bot_quota` (`hook_cvar_change`) and puts it back to 0 the moment `server.cfg` raises it: the engine runs `server.cfg` a frame before any plugin task can, and the game adds a bot on the next frame (that transient bot is the suspected trigger of the map-change segfault in #122). Modes are `scoutz`, `knife`, `vanilla` (stock rules; the plugin leaves spawns and buying alone) and `match` (5v5; `match.sma`, loaded only from `modes/match.ini`, is a state machine warmup → knife → choose → live on ReAPI hooks: `HasRestrictItem` for the knife round, `RoundEnd` for the knife winner and the half-time swap, superceding `OnRoundFreezeEnd` to hold a pause; `modes/match.cfg` holds the live settings and the plugin lays warmup cvars over them; its `plugin_end` clears `mp_forcerespawn`, `mp_round_infinite`, `mp_limitteams`, `mp_maxrounds` and `mp_winlimit` so they do not leak into the next mode). Gameplay cvars live in the mode cfgs, not `server.cfg`, and **every mode cfg sets all of them** (gravity, air acceleration, `sv_maxvelocity`, freeze/buy/round time, start money, `bot_knives_only`), because cvars carry over between modes and an installed `server.cfg` from before 1.3 still holds the ScoutzKnivez values. A mode can have its own plugin list, `plugins/amxmodx/modes/<mode>.ini` (image: `addons/amxmodx/configs/modes/`; not `plugins-*.ini`, which AMX Mod X loads in addition): AMX Mod X reads the file named by `localinfo amxx_plugins` on every map load, set by `entrypoint.sh` at start and by the plugin before a switch's changelevel, cleared for modes without one. `MODE=auto` (alias `MODE=movement`) reads `config/modes/map-modes.ini` on each map and execs `modes/surf.cfg` or `modes/climb.cfg` after `server.cfg`. `modes/auto.ini` is the shared plugin list. `movement.amxx` reads `localinfo sk_mapmode`, which `scoutzknivez.amxx` sets first. `MODE=climb` and `MODE=surf` stay one mode for every map. `scripts/mode.sh auto` is still the Friday schedule; `movement` is the per-map switch.
- **Climb mode**: `MODE=climb` loads `plugins/amxmodx/modes/climb.ini` (with `movement.sma`) and `modes/climb.cfg` (Kreedz legal physics from https://kreedz.com/rules, `mp_timelimit 60`, `mp_forcechasecam 0`, `mp_round_infinite 1`, `mp_forcerespawn 1`; the plugin's `plugin_end` resets those, `mp_limitteams` and `mp_falldamage`, which `server.cfg` does not set). `entrypoint.sh` defaults `MAPCYCLE` to `mapcycle-climb.txt`, `MAP` to that file's first map and `BOTS` to 0; `install.sh` writes no `MAP` for the mode. The timer is `Ham_Use` on `func_button` whose target is in `START_TARGETS` / `STOP_TARGETS`. Checkpoints are ground-only (two slots) and `/tp` clears velocity. `/spec` stops the run. Top lists (15 pro, 15 cp per map) live in `addons/amxmodx/data/records/<map>.tsv`, a symlink into the state volume (`prepare_state` creates `amxmodx/records`). The plugin counts runs and list entries in `localinfo mv_runs` / `mv_bests`, which `metrics.sma` publishes. No round ends in this mode, so a `sk_switchmode` out of it waits for the plugin's 180 s deadline (or `endround`). The e2e test cannot press a button: it enters times with the `mv_record` server command and loads the climb rotation with bots off (the general map sweep skips `mapcycle-climb.txt`, where bots would generate a mesh per map). A climb map row in `maps/manifest.tsv` must have timer buttons and nothing the fetcher cannot extract (models, sprites, sky, `.rar`).
- **Surf mode**: `MODE=surf` mirrors climb (`modes/surf.ini`, `modes/surf.cfg`: the same Kreedz list as climb except air acceleration 100 and `sv_maxvelocity 3500`, `mp_falldamage 0`, `mp_timelimit 40`, `mp_forcechasecam 0`, `autobhop_enabled 1`; `mapcycle-surf.txt`). Surf maps have no timer buttons, so `movement.sma` times runs between zones (`addons/amxmodx/data/zones/<map>.txt`, a symlink into the state volume, whole units): on a `surf_` map without a saved start zone it builds one around the spawn points, and an end zone comes from an admin (`mv_zone`, client console, `ADMIN_CFG`) or the server console (`mv_zone_set`, which the e2e test uses). Zone checks run in `FM_PlayerPreThink`. `autobhop.amxx` is in both movement plugin lists and each mode cfg sets `autobhop_enabled`. The map prefix picks the physics in a mixed rotation: `modes/surf_kz.cfg` and `surf_bkz.cfg` exec `climb.cfg`, `modes/climb_surf.cfg` execs `surf.cfg` (the existing `<mode>_<prefix>.cfg` hook). The plugin's chat tag follows the map (`[SURF]` on `surf_`, else `[CLIMB]`), and that same flag picks checkpoints: on surf, `/cp` saves in the air (five slots) and `/tp` restores velocity and view angles; the teleport still makes it a cp run. Climb keeps ground-only saves and zero velocity. `/spec` stops the run in both. AMX Mod X's `%.1f` writes 64.0 as 63.9, so do not format floats into files that are read back.
- **LAN profile**: `CS_PROFILE=lan` (`install.sh`) and `compose.lan.yml` (`just lan-party`) select host networking and `LAN_MODE=1`, because the LAN tab finds servers by broadcast. Never combine it with `NOMASTER=1` (`-nomaster` silences A2S_INFO, so the server is invisible) or `SERVER_IP` (a socket bound to one address hears no broadcasts). `tests/e2e_test.sh` boots once with `--network none` and checks the A2S_INFO reply.
- **Instances**: `CS_INSTANCE=<name> CS_PORT=<port>` in `install.sh` derives `cs-server-<name>` (service and container), `~/.config/cs-server-<name>` and volume `cs-server-state-<name>`; unset, the names stay `scoutzknivez`, `~/.config/cs-server`, `cs-server-state`. Container port always equals host port (GoldSrc advertises its own). `install.sh` starts the generated unit with `systemctl start`; `enable` fails on Quadlet units.
- **Quadlet for systemd**: `scoutzknivez.container` unit file enables auto-start, crash recovery (restart on-failure), and resource limits (512MB RAM, 2 CPUs).
- **Movement records page**: `ops/scripts/cs-records-export` reads `cs-server-state-movement`'s `amxmodx/records/*.tsv` (same rows as `movement.sma` `load_records()`: skip `#` and short rows, drop out-of-order times, 15 per category) and writes `records.json` with a temp file and rename, skipping the write when the lists are unchanged. It does not start, stop, reload or restart the game server. `ops/systemd/cs-records-export.timer` runs it every 10 minutes as user `cs`. The page is `docs/records/index.html` on GitHub Pages (`https://kevintcoughlin.com/cs-server/records/`); it only fetches `./records.json`. `ops/scripts/cs-records-push` (the service's `ExecStartPost`) pushes it to the `records-data` branch with a deploy key and the Pages workflow overlays it. The committed JSON is sample data. Do not put it under `docs/cstrike/`.
- **Daily idle restart (VPS)**: `ops/restart-idle.sh`, installed by `ops/bootstrap-vps.sh` (`CS_RESTART=1`; `--no-restart` removes it; `--restart-only` installs it for an existing deploy user). The user timer fires at 05:00 America/Los_Angeles and every 20 minutes through 08:00 (`Persistent=false`, `RandomizedDelaySec=90s`). It restarts a Quadlet game unit when A2S_INFO reports no human players (`players` minus `bots`). A server that does not answer, including `NOMASTER=1`, stays up. One stamp per unit per Los Angeles day keeps a later pass from restarting it again. `HealthCmd=/healthcheck.sh` marks a game unit; FastDL uses a different health command and is skipped.

## Key Conventions

- All component versions pinned as `ARG` in Containerfile (ReHLDS, ReGameDLL, Metamod, AMX Mod X, ReAPI)
- Config files bind-mounted read-only in compose.yml and Quadlet (server.cfg, mapcycle.txt)
- All Linux capabilities dropped (`cap_drop: ALL`, `NoNewPrivileges=true`)
- Only 27015/udp is published (GoldSrc has no TCP listener on the game port); no `rcon_password` by default, the console FIFO is the admin path (`CS_RCON=1` opts in)
- Container runs as non-root `hlds` system user
- Scripts must be shellcheck-clean, Containerfile must be hadolint-clean
- SPDX license headers on source files

## CI

- **docker.yml**: Builds container image on push/PR (path-filtered), smoke-tests and e2e-tests it, runs Trivy scan, pushes to ghcr.io with semantic tags, generates SBOM. A `v*.*.*` tag push also tags the image `X.Y.Z`, `X.Y` and `X` and creates the GitHub release from that version's `CHANGELOG.md` section (`scripts/release-notes.sh`)
- **movement.yml**: Same supply chain for the movement image (`ghcr.io/<owner>/cs-server-movement`). It is the Counter-Strike image plus the movement maps `scripts/cleared-maps.sh` allows (`fastdl=yes`). `scripts/movement-maps.sh` is the rotation, and a pinned map that is not cleared is not fetched or copied. CI fails if one is in the build context or the image. The VPS plays that rotation from `~/cs-maps`, not from the image. Tags are `:main` and `:sha-<7>` on main, plus release version tags. Linux runners only. Nipper maps stay out of it
- **ci.yml**: Runs hadolint, shellcheck and the script tests on every push/PR (no path filter) — fast gate
- **nightly.yml**: Weekly rebuild (Monday 00:00 UTC), Trivy scan, pushes `nightly` tag to ghcr.io
- **pages.yml**: Builds `docs/` with Jekyll and deploys to GitHub Pages on push to main (Pages source must be "GitHub Actions")
- **friday-dust2.yml**: Scheduled Friday at 00:00 PST (08:00 UTC), generates Dust 2 Friday announcements with gameplay rules

## Releasing

1. In `CHANGELOG.md`, rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`, add an empty `[Unreleased]` above it and update the links at the bottom. Merge that.
2. `git tag vX.Y.Z <merge commit> && git push origin vX.Y.Z`. The release job fails if the changelog has no notes for the version.
3. Check `gh release view vX.Y.Z` and `docker buildx imagetools inspect ghcr.io/kevintcoughlin/cs-server:X.Y.Z` (both architectures).

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAP` | `scoutzknivez` | Starting map |
| `MAXPLAYERS` | `20` | Max player slots |
| `PORT` | `27015` | Server port |
| `BOTS` | `1` | Enable ZBots (1=on, 0=off) |
| `MAPCYCLE` | `mapcycle.txt` | Mapcycle file (e.g. `mapcycle-dust2.txt`, `mapcycle-nipper.txt`) |
| `SERVER_IP_WAIT` | `30` | Seconds the entrypoint waits for `SERVER_IP` to be bindable (a UDP bind through perl; `HLDS_BIND_CHECK` stubs it in tests) before starting anyway with a warning |
| `MODE` | `scoutz` | Startup game mode: `scoutz`, `knife`, `vanilla`, `match`, `climb` or `surf` (vanilla and match default `MAP` to `de_dust2` and `MAPCYCLE` to `mapcycle-dust2.txt`; climb and surf default to `mapcycle-<mode>.txt`, its first map in the image and `BOTS=0`) |
| `FASTDL_URL` | empty | http(s) URL for `sv_downloadurl`; passed on the HLDS command line, never set in `server.cfg` (re-exec'd every map) |
| `LOGS` | `1` | `+log on`; files land in the state volume (`/hlds/state/logs`) |
| `LOG_RETENTION_DAYS` | `30` | Prune `*.log` older than this at start and daily (`0` = keep) |
| `LOGADDRESS` | empty | `host:port` for `+logaddress_add` |
| `SERVER_IP` | empty | IPv4 for `+ip` (bind + report); for public servers on host networking. `healthcheck.sh` queries it instead of loopback |
