# CS 1.6 ScoutzKnivez Server

[![GHCR](https://img.shields.io/badge/ghcr.io-cs--server-blue?style=flat-square&logo=github)](https://ghcr.io/kevintcoughlin/cs-server)

Containerized Counter-Strike 1.6 scoutzknivez server using the ReHLDS stack.

## Stack

- **ReHLDS** 3.15.0.896 — reverse-engineered engine
- **ReGameDLL_CS** 5.30.0.814 — reverse-engineered game DLL
- **Metamod-R** 1.3.0.149 — plugin loader
- **AMX Mod X** 1.10.0 (build 5488) — scripting platform
- **ReAPI** 5.29.0.358 — extended API

## Install

[![Install with Podman](https://img.shields.io/badge/Install_with-Podman-892CA0?style=for-the-badge&logo=podman&logoColor=white)](https://github.com/KevinTCoughlin/cs-server#install)

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash
```

Requires [Podman](https://podman.io/getting-started/installation) (rootless) or [Docker](https://docs.docker.com/get-docker/). The script pulls the image from ghcr.io, creates config files, and starts the server on port 27015. With Podman it installs a systemd Quadlet unit for auto-start; with Docker it creates a container with restart policy. For production, set `CS_SERVER_IMAGE` to an immutable image digest instead of the mutable `latest` tag.

That runs the newest build of `main` (`:latest`). To run a release instead, name it; see [Releases, upgrade and rollback](#releases-upgrade-and-rollback):

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/v1.0.0/install.sh | CS_SERVER_VERSION=1.0.0 bash
```

To uninstall: `curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash -s -- --uninstall`

## Zed

The repository includes `.zed/tasks.json` with tasks for checking, building,
starting, stopping, viewing logs, and checking the Podman machine. Open the
repository in Zed, then use `task: spawn` to run them from the task picker.

On macOS, start the rootless Podman VM before using the container tasks:

```bash
podman machine start
```

The justfile defaults to Apple `container` on macOS (`CONTAINER_ENGINE=podman` overrides it);
see [macOS / Apple silicon](#macos--apple-silicon).

## Quick Start

### Option 1: Pull from ghcr.io (fastest)

Pre-built images are available on GitHub Container Registry:

```bash
podman pull ghcr.io/kevintcoughlin/cs-server:latest
podman run -d -p 27015:27015/udp \
  --name scoutzknivez ghcr.io/kevintcoughlin/cs-server:latest
```

The server starts on port **27015**. Connect with your CS 1.6 client:

```
connect <your-lan-ip>:27015
```

> **Docker users:** replace `podman` with `docker` in the commands below, and
> on x86_64 hosts add
> `--security-opt seccomp=ops/seccomp/docker-default.json` (the file is in
> this repository). The seccomp profile built into Docker 29 rejects HLDS's
> 32-bit `socket()` call with `ENOSYS`, so the server can't open its port and
> crash-loops (`UDP_OpenSocket … Function not implemented`); that file is
> Docker's own upstream default profile, which works. Podman's default
> profile and Apple `container` are unaffected; `compose.yml` and
> `install.sh` already set it. See [Container Hardening](#container-hardening).

### Option 2: Build from source

If you need custom maps or configurations:

#### 1. Add maps

Place `.bsp` files into the `maps/` directory. They get baked into the image at build time.

The default ScoutzKnivez maps are bundled from `docs/cstrike/maps/`. Add custom
maps to `maps/`; they overlay the bundled maps during the image build.

#### 2. Build and run

```bash
podman compose up --build
```

The server starts on port **27015**. Connect with your CS 1.6 client:

```
connect <your-lan-ip>:27015
```

### Windows (WSL2)

Docker Desktop for Windows cannot reliably forward UDP game traffic to containers ([#18](https://github.com/KevinTCoughlin/cs-server/issues/18)). Run the server natively inside a WSL2 Debian distro instead.

#### 1. Install WSL2 Debian

```powershell
wsl --install Debian
```

#### 2. Install dependencies

```bash
wsl -d Debian
sudo dpkg --add-architecture i386
sudo apt-get update
sudo apt-get install -y ca-certificates curl lib32gcc-s1 lib32stdc++6 \
    lib32z1 libc6-i386 patchelf unzip tar
```

#### 3. Run the install script

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash
```

Or build from source (from the repo root on the Windows filesystem):

```bash
cd /mnt/c/path/to/cs-server
# Follow the Containerfile steps manually or use the install script
```

#### 4. Connect

From your Windows CS 1.6 client, open the console and connect using the WSL2 IP:

```bash
# Find your WSL2 IP
wsl -d Debian -- ip addr show eth0 | grep "inet "
```

```
connect <wsl2-ip>:27015
```

> **Note:** The WSL2 IP changes on reboot. `localhost:27015` may also work depending on your WSL2 networking mode.

### macOS / Apple silicon

Runs under Apple's [`container`](https://github.com/apple/container) CLI (tested with 1.7.1 on an M-series Mac). Rosetta for Linux only translates x86_64, and HLDS is 32-bit i386, so the macOS image is **arm64 and runs the server under `qemu-i386` user-mode emulation** instead. The same `Containerfile` builds it; `scripts/i386-compat.sh` picks the per-architecture pieces:

| | linux/amd64 (CI, ghcr.io, Linux hosts) | linux/arm64 (Apple silicon) |
|---|---|---|
| i386 libraries | `lib32*` biarch packages | Debian multiarch `:i386` packages |
| Running i386 code | native | static `qemu-i386` (~14 MB) |
| Steam libraries | as-is | `LD_PRELOAD` shim (`scripts/i386-qemu-shim.c`) for two qemu gaps: robust futex lists and `/proc/cpuinfo` |

```bash
brew install container && container system start
just build          # ~10 min: SteamCMD downloads HLDS under emulation
just up             # attached, config from ./config (like compose)
just install        # or: run as a launchd agent (ops/cs-server), config in ~/.config/cs-server
just status         # agent + container state and the address to connect to
just logs           # follow output; `just rcon "status"` sends console commands
just lan            # restart with sv_lan 1 so non-Steam (Xash3D) clients can join; `just lan off` reverts
```

`just install` uses `ops/cs-server`, the macOS counterpart of the Quadlet unit: a launchd agent (`ops/launchd/com.kevintcoughlin.cs-server.plist`) that starts at login, restarts on crashes, and stops gracefully with the in-game countdown. `ops/cs-server` also has `update`, `restart`, `stop`, `start` and `uninstall`. Put `MAP=…`, `BOTS=…` etc. in `~/.config/cs-server/env`.

**Performance** (M-series, 2 vCPUs, 20 slots, 10 bots, `sys_ticrate 1000`, `pingboost 2`): ~250 server FPS, ~80% of the VM's CPU, ~340 MiB RAM. That is plenty for a LAN or friends server; for a busy public server, use a Linux x86 host. `CS_MEMORY` / `CS_CPUS` change the VM size (default 640 MB / 2 CPUs: HLDS under qemu holds ~240 MiB RSS, and the game loop is one thread). `ops/cs-server build`/`update` stop the image builder VM afterwards unless it was already running (`CS_KEEP_BUILDER=1` keeps it).

Rebuilds are incremental: the ~1 GB HLDS payload is one cached layer that only changes with the pinned versions, and maps, sounds, plugins and configs are small layers on top, so `just up` / `cs-server update` after a config or plugin edit take seconds, not a SteamCMD run.

`install.sh` (systemd/Quadlet, amd64 image from ghcr.io) does not support macOS and points you here instead.

### Configuration

Edit files in `config/` — they're bind-mounted into the container:

| File | Purpose |
|------|---------|
| `config/server.cfg` | Game settings (gravity, round time, etc.) |
| `config/mapcycle.txt` | Map rotation (default scoutzknivez variants) |
| `config/mapcycle-dust2.txt` | Dust 2 rotation (classic de_dust2) |
| `config/mapcycle-nipper.txt` | Nipper Friday (knife mode) rotation |
| `config/mapcycle-nipper-xmas.txt` | Nipper Friday Christmas rotation (Dec 1 to Jan 6) |
| `config/modes/*.cfg` | Per-mode settings, run after `server.cfg` (`knife.cfg` = Nipper Friday; `knife_he.cfg` for grenade maps) |
| `config/autoexec.cfg` | Runs on server start |

Changes to `server.cfg` take effect on the next map or via `just rcon "exec server.cfg"`.

### Friday Dust 2

Every Friday, switch to the classic de_dust2 gameplay by setting the `MAPCYCLE` environment variable:

```bash
# Podman Compose
MAPCYCLE=mapcycle-dust2.txt MAP=de_dust2 podman compose up

# Quadlet systemd
systemctl --user edit scoutzknivez
# Add these lines:
# Environment=MAPCYCLE=mapcycle-dust2.txt
# Environment=MAP=de_dust2
systemctl --user restart scoutzknivez

# Docker (from a checkout; see "Docker users" above for the profile)
docker run -d --security-opt seccomp=ops/seccomp/docker-default.json \
  -p 27015:27015/udp \
  -e MAP=de_dust2 \
  -e MAPCYCLE=mapcycle-dust2.txt \
  ghcr.io/kevintcoughlin/cs-server:latest
```

**Dust 2 Gameplay Rules:**
- No cheating/hacking (wallhacks, aimbots, etc.)
- No team killing or excessive team flashing
- No abusive behavior, hate speech, or harassment
- Terrorists must attempt to plant the bomb
- Counter-Terrorists must defuse if bomb is planted
- No delaying the round (hiding/avoiding objective)
- Respect server admins and other players
- AFK players will be automatically kicked

To switch back to scoutzknivez, set `MAPCYCLE=mapcycle.txt` or remove the override.

### Nipper Friday (knives only)

Knife-only mode: no scout, no buying, no picking up weapons, normal gravity,
and bots on knives. It switches **at the next round end, with a chat
announcement, and without restarting the server**:

```bash
just mode nipper          # knife mode on mapcycle-nipper.txt
just mode scoutz          # back to ScoutzKnivez on mapcycle.txt
just friday-enable        # opt-in schedule: knives Fri 17:00 to Sat 04:00 local
just friday-disable
```

On macOS, `cs-server mode …` and `cs-server friday enable|disable` work the same
way (a second launchd agent). On Linux, `just friday-enable` installs a systemd
user timer (`ops/systemd/`). The scheduled job does nothing while the server is
stopped and never restarts it. To start in knife mode instead, set `MODE=knife`
(with `MAPCYCLE=mapcycle-nipper.txt`).

Mode settings live in `config/modes/<mode>.cfg`. On every map the plugin runs
`server.cfg` and then the mode cfg. Mode switches happen at runtime, so a container restart goes back to `MODE`.

#### NIPPER's maps

The Nipper Friday rotation (`config/mapcycle-nipper.txt`) is `nipperhouse`,
`ka_beams`, `nippers100`, `he_dodgeball2`, `hamsters` and `de_westwood`. From
Dec 1 to Jan 6, `mode nipper` / `auto` use the Christmas rotation
(`config/mapcycle-nipper-xmas.txt`): `xmas_nipperhouse`, `x-mas_tree`,
`xmas_lodge` and `xmas_crazytank`. Set `NIPPER_SEASON=xmas` or `none` to override.

On grenade-fight maps (`he_*`) knife mode lets players and bots pick up the HE
grenades the map lays out; everything else stays knife-only
(`config/modes/knife_he.cfg` is the per-map override, exec'd after `knife.cfg`).
`xmas_crazytank` keeps its drivable tank and mounted guns: that's the map's gimmick.

They come from NIPPER's
own [complete CS 1.6 map pack](https://gamebanana.com/mods/467088) on GameBanana.
The maps aren't in git; fetch them before building:

```bash
just fetch-maps     # one 242 MB download, sha256-pinned, cached in .cache/maps/
just build
```

`maps/manifest.tsv` pins the URL, SHA-256 and license for each map, plus any
custom sounds it needs. The script extracts only those files; nothing in the pack
runs. To add another map, add a row and put its name in the mapcycle.
`tests/mapcycle_test.sh` fails CI if a mapcycle names a map that isn't bundled,
stock, or pinned. Bots need the map's `.nav`. Most of NIPPER's maps include one.
`ka_monkeybars` doesn't, so it's left out for now (ZBot would generate one at map
load, which is very slow under qemu). To add it, generate the `.nav` once on an
x86 host with `bot_nav_generate`, then pin it.

**License:** CC BY-NC-ND 4.0, maps by Nathaniel Miller (NIPPER). Credit NIPPER, no
commercial use, and don't modify the BSPs. GameBanana's checklist asks for the
author's permission before re-hosting on other sites. Until NIPPER agrees, the maps
stay off FastDL (`docs/cstrike/maps/`), and clients download them from the game
server itself. That's slower, but these maps are 0.4 to 5 MB.
For the same reason, the published ghcr.io images don't include them. Build
locally after `just fetch-maps` to play Nipper Friday on NIPPER's maps. On an
image without them, `mode nipper` refuses with "no playable map".

## Game Settings

| Setting | Value | Effect |
|---------|-------|--------|
| `sv_gravity` | 240 | Low gravity (default is 800) |
| `sv_airaccelerate` | 100 | High air control |
| `mp_freezetime` | 0 | No freeze on round start |
| `mp_buytime` | 0 | No buy menu |
| `mp_roundtime` | 3 | 3 minute rounds |
| `mp_startmoney` | 16000 | Max money (unused) |

## Plugins

| Plugin | Description |
|--------|-------------|
| `scoutzknivez.amxx` | Strips weapons on spawn, gives scout + knife with ammo |
| `autobhop.amxx` | Auto bunny hop — hold jump to bhop (essential for low-grav) |
| `AQS.amxx` | [Advanced Quake Sounds](https://github.com/ClaudiuHKS/AdvancedQuakeSounds) v8.0 — kill streaks, multi-kills, headshots, knife kills with HUD + sound announcements. Toggle with `!sounds` in chat |
| `rtv.amxx` | Rock the Vote — type `rtv` to vote for map change, `nominate <map>` to add maps |
| `websitebot.amxx` | Adds a spectator bot showing the server website in the scoreboard |
| `afkkicker.amxx` | Moves idle players to spectator after 60s, kicks after 3min |
| `highpingkicker.amxx` | Warns then kicks players exceeding 150ms average ping |
| `advertisements.amxx` | Rotating chat messages with server info and commands |
| `antiflood.amxx` | Chat spam prevention (built-in AMX Mod X) |

### Adding Quake Sounds

The AQS plugin looks for WAV files in `sound/quake/`. These are not included (copyrighted). See `sound/quake/README.md` for sourcing instructions. The plugin works in HUD-only mode without them.

## FastDL (Fast Downloads)

Custom content (maps, sounds) is served via GitHub Pages so clients download over HTTP instead of the game server's slow built-in transfer (~5 KB/s).

**How it works:** the `FASTDL_URL` environment variable sets `sv_downloadurl`, which points clients at an HTTP host that serves your `cstrike/` content. The engine tries `.bz2` compressed files first, then falls back to uncompressed. It is empty by default, so a new server sends custom content itself until you name a host:

```bash
# Compose / justfile: .env
FASTDL_URL=https://example.com/cstrike/

# Quadlet: ~/.config/containers/systemd/scoutzknivez.container
Environment=FASTDL_URL=https://example.com/cstrike/

# install.sh
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | FASTDL_URL=https://example.com/cstrike/ bash
```

Don't set `sv_downloadurl` in `server.cfg`: that file is re-run on every map and would override the variable. This project's own server uses `https://kevintcoughlin.com/cs-server/cstrike/`, which is the `docs/cstrike/` directory of this repository on GitHub Pages; a fork that enables Pages can do the same with the recipe below.

### Syncing Content

```bash
just fastdl
```

This copies files from `sound/quake/` and `maps/` into `docs/cstrike/` with `.bz2` compressed variants, then commit and push to deploy via GitHub Pages.

### Manual Workflow

1. Place maps in `maps/` and sounds in `sound/quake/`
2. Run `just fastdl` to sync and compress
3. Commit the `docs/cstrike/` changes and push to `main`
4. GitHub Pages auto-deploys from `docs/`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MAP` | `scoutzknivez` | Starting map |
| `MAXPLAYERS` | `20` | Max player slots |
| `PORT` | `27015` | Server port |
| `BOTS` | `1` | Enable bots (1=on, 0=off) |
| `NOMASTER` | `0` | Disable master server (1=on, 0=off). Enable for Docker Desktop on Windows |
| `MAPCYCLE` | `mapcycle.txt` | Mapcycle file to use (e.g. `mapcycle-dust2.txt`, `mapcycle-nipper.txt`) |
| `LAN_MODE` | `0` | LAN-only mode (1) or public server mode (0) |
| `MODE` | `scoutz` | Game mode at startup: `scoutz` (scout + knife) or `knife` (Nipper Friday) |
| `FASTDL_URL` | empty | http(s) URL serving your `cstrike/` content (`sv_downloadurl`); see [FastDL](#fastdl-fast-downloads) |
| `LOGS` | `1` | Write server log files (1=on, 0=off); see [Saved state and logs](#saved-state-and-logs) |
| `LOG_RETENTION_DAYS` | `7` | Delete log files older than this many days (`0` keeps them all) |
| `LOGADDRESS` | empty | `host:port` of a log receiver such as HLstatsX (`logaddress_add`); needs `LOGS=1` |

Startup rejects invalid booleans, out-of-range ports/player counts, unsafe
map or mapcycle filenames and malformed FastDL URLs or log addresses instead
of passing unchecked values to HLDS.

## Saved state and logs

Everything the server writes while it runs is kept in one place,
`/hlds/state` in the container, and every deployment path mounts a volume
there. Replacing the container (an upgrade, `just deploy`, a rollback) keeps:

| In the volume | What it is |
|---------------|------------|
| `banned.cfg`, `listip.cfg` | Bans by SteamID and by address (`writeid`, `writeip`, AMX Mod X `amx_ban` / `amx_banip`); loaded at every start |
| `amxmodx/users.ini` | AMX Mod X admins. Seeded with the stock file; edit it to add yourself |
| `amxmodx/csstats.dat`, `amxmodx/vault*` | Player stats and plugin storage |
| `logs/` | Server logs: joins, kills, chat, bans (`LOGS=1`) |
| `amxmodx/logs/` | AMX Mod X logs: admin commands, plugin errors |

On Podman, Docker and Compose the volume is named `cs-server-state`; on
macOS it is the folder `~/.config/cs-server/state`.

```bash
podman volume inspect cs-server-state                # where it is on disk
podman exec scoutzknivez ls /hlds/state/logs         # look inside
podman volume export cs-server-state > state.tar     # back up
podman volume import cs-server-state state.tar       # restore (server stopped)
```

A server installed before the volume existed picks it up when its unit is
regenerated: run the installer again, or add
`Volume=cs-server-state:/hlds/state` to the unit yourself. A container
started without a volume still runs and keeps its state only until it is
replaced.

**Logs.** Log files are small (with only bots playing, under 2 MB a day in
testing) but they record player names, SteamIDs and IP addresses, so files
older than `LOG_RETENTION_DAYS` (default 7) are deleted at start and once a
day. Set `LOGS=0` to write none.
`LOGADDRESS=host:port` also streams the log lines over UDP to a stats
collector.

## Bots

Bots are enabled by default using ReGameDLL_CS's built-in ZBot support — no additional plugins or downloads required.

The bot configuration in `config/server.cfg` keeps the server populated when human players aren't present:

| Cvar | Value | Effect |
|------|-------|--------|
| `bot_quota` | 10 | Target number of bots to maintain |
| `bot_quota_mode` | `fill` | Bots fill empty slots; leave as humans join |
| `bot_difficulty` | 1 | Normal difficulty |
| `bot_join_after_player` | 0 | Bots join immediately (no human player required) |
| `bot_auto_vacate` | 1 | Bots leave automatically to make room for humans |
| `bot_allow_rogues` | 0 | Bots follow orders |
| `bot_knives_only` | 0 | Bots use normal weapons (scoutzknivez plugin handles stripping) |

To disable bots, set `BOTS=0` in `compose.yml` or your environment.

## RCON

Network rcon is off by default: no `rcon_password` is set, and the engine
refuses every rcon packet without one. The host that runs the container can
still send console commands, through a private pipe inside it:

```bash
just rcon "status"          # from a checkout
cs-server rcon status       # macOS service
podman exec scoutzknivez sh -c 'echo status > /hlds/.runtime/hlds-input'
```

To administer the server from a game client, opt in. `CS_RCON=1` makes
`install.sh` (or `cs-server install` on macOS) generate a random password in
`${HOME}/.config/cs-server/server.cfg`; for a manual deployment add a strong,
unique one yourself:

```
rcon_password "your_password_here"
```

Then in-game: `rcon_password your_password_here` followed by `rcon <command>`.
Treat `server.cfg` as a secret once it holds a password, and do not commit or
publish it. `sv_rcon_maxfailures` and `sv_rcon_banpenalty` (see
[HLDS Anti-Abuse](#hlds-anti-abuse)) limit guessing.

## Adding Plugins

1. Write `.sma` source in `plugins/amxmodx/scripting/`
2. Add the `.sma` filename to the compile loop in `Containerfile`
3. Add the compiled `.amxx` filename to `plugins/amxmodx/plugins.ini`
4. Rebuild: `podman compose up --build`

## Production Deployment (Quadlet)

The server runs as a rootless Podman Quadlet unit managed by systemd.

The default configuration is public (`LAN_MODE=0`). Set `LAN_MODE=1` only for a private LAN server. In production, pin the image to a release or a digest and change it deliberately, so rollback remains possible: see [Releases, upgrade and rollback](#releases-upgrade-and-rollback).

### Setup

```bash
# Build the image (tags as localhost/cs-server:latest)
podman compose up --build -d && podman compose down

# Reload systemd and start
systemctl --user daemon-reload
systemctl --user start scoutzknivez
```

### Lifecycle

```bash
systemctl --user start scoutzknivez     # start
systemctl --user stop scoutzknivez      # graceful stop (30s countdown)
systemctl --user restart scoutzknivez   # restart
systemctl --user status scoutzknivez    # check status
podman logs -f scoutzknivez             # follow logs
```

### Rebuild Workflow

```bash
just deploy    # podman compose build && systemctl --user restart scoutzknivez
```

### Releases, upgrade and rollback

Each release is a git tag (`v1.0.0`), a [GitHub release](https://github.com/KevinTCoughlin/cs-server/releases) with the changelog, and a multi-arch image (`linux/amd64`, `linux/arm64`) on ghcr.io under these tags:

| Tag | Moves? | Use it for |
|-----|--------|------------|
| `1.0.0` | No | A fixed version |
| `1.0`, `1` | To the newest patch / minor release | Following a release line |
| `latest` | With every change on `main` | Trying the newest build |
| `nightly` | Weekly rebuild of `main` (fresh base image) | Testing |
| `@sha256:…` | Never | Exactly one build, including its base image |

**Pin** a version at install time with `CS_SERVER_VERSION` (as above), or any image reference with `CS_SERVER_IMAGE`. The installer prints the digest of what it pulled; note it down, because it is what you roll back to.

**Upgrade** by running the installer again with the new version. Config in `~/.config/cs-server/` is kept, the unit is rewritten, and a running server is restarted onto the new image (players get the 30 second countdown):

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/v1.1.0/install.sh | CS_SERVER_VERSION=1.1.0 bash
```

Or by hand: change `Image=` in `~/.config/containers/systemd/scoutzknivez.container`, then

```bash
podman pull ghcr.io/kevintcoughlin/cs-server:1.1.0
systemctl --user daemon-reload
systemctl --user restart scoutzknivez
```

**Roll back** the same way, naming the previous version or the digest you noted:

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/v1.0.0/install.sh | CS_SERVER_VERSION=1.0.0 bash
# or exactly the build you ran before
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/v1.0.0/install.sh \
  | CS_SERVER_IMAGE=ghcr.io/kevintcoughlin/cs-server@sha256:<digest> bash
```

Read the [changelog](CHANGELOG.md) before crossing a major version: a newer image may expect config that an older `server.cfg` lacks, and the installer never overwrites your files.

With Docker the installer replaces the container, so the same commands upgrade and roll back. On macOS the image is built from your checkout: `git checkout v1.0.0 && cs-server update`.

**Unattended updates (Podman, optional).** `CS_AUTO_UPDATE=1` adds `AutoUpdate=registry` to the unit and enables `podman-auto-update.timer`, which checks daily whether the tag points at a new image. Use it with a moving tag (`CS_SERVER_VERSION=1` or `1.0`), not `1.0.0`. The unit only counts as started once the server answers its health check, so if a new image does not come up, Podman puts the previous one back. An update restarts the server, countdown included, whenever the timer fires; skip this if restarts must be planned.

### Graceful Shutdown

When the server receives a stop signal, it announces the shutdown to connected players:

- **T-30s**: "Shutting down in 30 seconds..."
- **T-10s**: "Shutting down in 10 seconds..."
- **T-5s**: "Shutting down in 5 seconds..."
- **T-2s**: "Shutting down in 2 seconds..."
- **T-1s**: "Goodbye!"
- **T-0s**: `quit` command sent to HLDS

The Quadlet gives the container 45 seconds for the shutdown sequence, with a 50-second systemd timeout as a buffer.

### Auto-Start

The Quadlet is configured with `WantedBy=default.target`, so the server starts automatically on boot (after `loginctl enable-linger` is set for the user).

### Crash Recovery

`Restart=on-failure` restarts the container after 10 seconds if HLDS crashes, but stays stopped on a clean `systemctl stop`.

## Security

### Container Hardening

- **No Linux capabilities** — all capabilities dropped via `DropCapability=ALL`
- **No privilege escalation** — `NoNewPrivileges=true` prevents gaining new privileges via setuid/setgid binaries
- **Seccomp** — the server always runs under a default-deny seccomp profile.
  The Quadlet unit uses Podman's default. On Docker, the profile built into
  Docker 29 blocks the 32-bit `socket()` syscall the i386 HLDS binary needs,
  so `compose.yml` and `install.sh` pass Docker's own upstream default
  profile as a file instead
  ([`ops/seccomp/docker-default.json`](ops/seccomp/README.md); `compose.yml`
  is shared, so this also applies under `podman compose`). Earlier versions
  ran Docker with `seccomp=unconfined`; `install.sh` still falls back to
  that, with a warning, for an image older than 1.1.0, which carries no
  profile
- **Read-only root filesystem** — `ReadOnly=true` (Quadlet), `read_only: true`
  (Compose), `--read-only` (`install.sh` on Docker). The server can write to
  two places only: the [state volume](#saved-state-and-logs) and a tmpfs on
  `/tmp` that holds the console pipe. Not set on macOS (`ops/cs-server`). One
  side effect: on a map with no `.nav` file the bots' generated navigation
  mesh cannot be saved, so it is rebuilt each time that map loads; ship the
  `.nav` with the map (`maps/`) to avoid that
- **System user with nologin shell** — HLDS runs as a system user (`-r`) with `/usr/sbin/nologin`, preventing interactive login
- **Setuid/setgid bits stripped** — all setuid/setgid bits removed from the runtime image
- **Resource limits** — `MemoryMax=512M`, `CPUQuota=200%` (2 cores max)
- **Runtime health check** — the image, Compose and Quadlet run `/healthcheck.sh`:
  `hlds_linux` must be running and answer a ping query (A2A_PING) on its port,
  so a hung server turns unhealthy. Compose and Quadlet set it explicitly,
  independent of image-format health-check metadata

### HLDS Anti-Abuse

Rate limiting and anti-abuse cvars in `server.cfg`:

| Cvar | Value | Purpose |
|------|-------|---------|
| `sv_max_queries_sec` | 3 | Rate-limit server info queries (anti-amplification) |
| `sv_max_queries_window` | 30 | Query rate window in seconds |
| `sv_rcon_maxfailures` | 5 | Lock RCON after 5 bad attempts |
| `sv_rcon_banpenalty` | 60 | 60 minute RCON ban on failure |

### Firewall

The server needs one port: 27015/udp. GoldSrc does not use TCP (game, queries
and rcon are all UDP), so nothing publishes it. Use the host firewall and, for
a public server, a hosting provider with UDP DDoS protection:

```bash
# CS 1.6 server
firewall-cmd --permanent --zone=FedoraWorkstation --add-port=27015/udp
firewall-cmd --reload
```

#### Query floods

A public GoldSrc server attracts floods of server-browser queries, often with
a forged source address so that the server's replies land on someone else.
`sv_max_queries_sec` (see [HLDS Anti-Abuse](#hlds-anti-abuse)) limits the
replies, but the game thread still reads every packet.
[`ops/firewall/cs-server.nft`](ops/firewall/cs-server.nft) drops the excess in
the kernel: queries and connection attempts are limited to 10 a second per
source address (burst 20); packets from players in the game are not touched.

```bash
# Try it (gone at reboot)
sudo nft -f ops/firewall/cs-server.nft
sudo nft list table inet cs_server      # the counter shows dropped packets

# Keep it across reboots
sudo install -Dm644 ops/firewall/cs-server.nft /etc/cs-server/firewall.nft
sudo install -Dm644 ops/firewall/cs-server-firewall.service /etc/systemd/system/cs-server-firewall.service
sudo systemctl daemon-reload && sudo systemctl enable --now cs-server-firewall.service

# Remove
sudo systemctl disable --now cs-server-firewall.service   # or: sudo nft delete table inet cs_server
```

**With firewalld** (Fedora, RHEL): use the same file. The rules live in their
own nftables table, which firewalld leaves alone, and they run before
firewalld's; open the port in firewalld as shown above. firewalld's own rich
rules can only limit a port as a whole, not per source, so they would let one
flooder lock everyone else out.

The file limits port 27015; edit `define game_port` for another port. It
works for rootless Podman and for Docker alike (it hooks in before NAT).
Nothing installs or loads it for you: `install.sh` only points at it.

## Performance Tuning

The server is preconfigured with HLDS/ReHLDS network and tick-rate optimizations:

- **Network buffer sysctls** (`net.core.rmem_max`, `net.core.wmem_max`) — applied automatically per-container via compose, Quadlet, and install.sh. No admin action required.
- **Host kernel timer and CPU governor** — detected automatically by `install.sh` during installation. The script checks the current state and prints actionable commands if changes are recommended.

### Host Kernel (optional)

HLDS may benefit from a 1000 Hz host kernel timer. The installer checks `CONFIG_HZ` and reports the result, but host kernel and CPU-governor changes should be benchmarked and managed by the system administrator:

```bash
sudo apt install linux-image-lowlatency
sudo reboot
```

Or set `CONFIG_HZ=1000` in a custom kernel config.

### CPU Governor (optional)

The installer reports the active CPU frequency governor without changing it. Prefer the host's normal power-management policy; use a performance profile only when measurements show it improves tick stability.

```bash
sudo cpupower frequency-set -g performance
```

### Operations

- Keep `/etc/systemd/system` and user Quadlet units under configuration management.
- Review image updates before deploying; retain the previous digest for rollback.
- Back up `${HOME}/.config/cs-server/`, especially `server.cfg` and map cycles.
- Restore by stopping the service, replacing that directory from backup with
  owner-only permissions (`chmod 700` on the directory and `chmod 600` on its
  files), then restarting the service.
- Configure host firewall rules for UDP/TCP `27015` and monitor the service with systemd/journald.
- Set journald or Docker log retention limits appropriate for the host.

## License

[MIT](LICENSE)

### Credits

- **NIPPER's maps** (Nipper Friday) are by Nathaniel Miller
  ([NIPPER](https://steamcommunity.com/id/nipper)), from his
  [complete CS 1.6 map pack](https://gamebanana.com/mods/467088), licensed
  [CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/). This
  project doesn't distribute them: `just fetch-maps` downloads them from that
  upload and checks them against a pinned SHA-256. Servers play them unmodified
  and non-commercially, and NIPPER is credited in-game.
- **Advanced Quake Sounds** by [ClaudiuHKS](https://github.com/ClaudiuHKS/AdvancedQuakeSounds) (MIT).
