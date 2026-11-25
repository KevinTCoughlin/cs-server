# CS 1.6 ScoutzKnivez Server

[![GHCR](https://img.shields.io/badge/ghcr.io-cs--server-blue?style=flat-square&logo=github)](https://ghcr.io/kevintcoughlin/cs-server)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/KevinTCoughlin/cs-server/badge)](https://scorecard.dev/viewer/?uri=github.com/KevinTCoughlin/cs-server)

Containerized Counter-Strike 1.6 scoutzknivez server using the ReHLDS stack.

## Stack

- **ReHLDS** 3.15.0.896 — reverse-engineered engine
- **ReGameDLL_CS** 5.30.0.814 — reverse-engineered game DLL, rebuilt so a navigation area's pathfinding links start empty ([rehlds/ReGameDLL_CS#1202](https://github.com/rehlds/ReGameDLL_CS/pull/1202) was closed unmerged; this is the initialization from that change)
- **Metamod-R** 1.3.0.149 — plugin loader
- **AMX Mod X** 1.10.0 (build 5488) — scripting platform
- **ReAPI** 5.29.0.358 — extended API

## Install

[![Install with Podman](https://img.shields.io/badge/Install_with-Podman-892CA0?style=for-the-badge&logo=podman&logoColor=white)](https://github.com/KevinTCoughlin/cs-server#install)

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash
```

Requires [Podman](https://podman.io/getting-started/installation) 4.4 or newer (5 or newer for health-gated updates) or [Docker](https://docs.docker.com/get-docker/). The script pulls the image from ghcr.io, creates config files, and starts the server on port 27015. With Podman it installs a systemd Quadlet unit for auto-start; with Docker it creates a container with restart policy.

That runs the current release (`1.4.2`, the newest version in [CHANGELOG.md](CHANGELOG.md); `DEFAULT_VERSION` in `install.sh`). `CS_SERVER_VERSION` and `CS_SERVER_IMAGE` override it. A digest pin is `CS_SERVER_IMAGE=ghcr.io/kevintcoughlin/cs-server@sha256:…`. The moving `main` build is `CS_SERVER_IMAGE=ghcr.io/kevintcoughlin/cs-server:latest`. See [Releases, upgrade and rollback](#releases-upgrade-and-rollback). The installer from the release tag, with the version named:

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/v1.4.2/install.sh | CS_SERVER_VERSION=1.4.2 bash
```

On a new VPS, use [Deploy on a fresh VPS](#deploy-on-a-fresh-vps) instead of this one-liner.

To uninstall: `curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash -s -- --uninstall`

## Deploy on a fresh VPS

One script on a new KVM VPS. A minimal image needs `ca-certificates` and `curl` installed first, so the script can be fetched. It creates an unprivileged user, installs the container engine, turns on unattended upgrades and fail2ban, opens the firewall, and runs `install.sh`.

| Host | Engine | Notes |
|------|--------|-------|
| Debian 13 | Distro Podman 5 | Recommended. A failed automatic update is rolled back |
| Ubuntu 24.04 | Distro Podman 4.9 | Quadlet works. No `Notify=healthy`, so a bad automatic update stays |
| Debian 12 | Distro Docker | Distro Podman is 4.3, which has no Quadlet |

A 1 GB VPS is enough for the server's 512 MB limit. When RAM is under about 1.8 GB and there is no swap, the bootstrap adds a 1 GiB swap file so pulling the image can finish. Ubuntu 24.04 restricts unprivileged user namespaces; the bootstrap relaxes that so rootless Podman can start.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/ops/bootstrap-vps.sh \
  | sudo bash -s -- --ssh-key "ssh-ed25519 AAAA... you@host"
```

A minimal image such as RackNerd's Debian 13 has apt and no `curl`, so the two `apt-get` lines are what make the fetch work. When either package is still missing, the bootstrap installs it before downloading anything else, which covers a checkout or a copied script on that image.

`--ssh-key` (or `--ssh-key-file`, or `CS_SSH_PUBLIC_KEY`) installs a public key for the deploy user. `ssh-keygen -l` checks the key; a malformed key is rejected. The bootstrap does not change how SSH accepts logins. Root and password login stay as the VPS image left them.

The deploy user is `cs` (`--user` or `CS_DEPLOY_USER`) and is added to the `sudo` group. The server listens on `27015/udp`. `CS_DOD=1` (or `--dod`) also installs Day of Defeat on `27016/udp`; see [Day of Defeat 1.3](#day-of-defeat-13). `CS_DOD_MODE` and `CS_DOD_PASSWORD` are passed only to that install. An inherited value is removed from the Counter-Strike install, which exits if it sees one. `CS_FASTDL=1` also opens `27080/tcp`. Daily backups of the state volume (bans, admins, stats, logs) go to `~cs/cs-server-backups` and keep 14 (`CS_BACKUP=0` or `--no-backup` turns them off). The timer records the engine this install selected (`podman` or `docker`) and the keep count in `~cs/.config/cs-server/backup.env`, so a later backup does not switch engines.

On Podman the bootstrap also runs `systemctl add-wants multi-user.target network-online.target`. Rootless Quadlet units wait for `network-online.target`, and with linger that wait sat at the network-online timeout (about two and a half minutes on a RackNerd Debian 13 image) when nothing else pulled the target into boot. Repeating the command leaves the existing dependency in place. After the nftables rules are written, the bootstrap reloads `cs-server-firewall` and, when it owns the input policy, `cs-server-input`. A second run that adds a port (Day of Defeat's `27016/udp`) applies it without a reboot. `enable --now` on those oneshot units does not reload a unit that is already active, which is why the reload is separate.

`--dry-run` prints the plan and changes nothing. `--no-install` does the host setup and prints an `install.sh` command. From a git checkout that path is the file in the checkout. From `curl | bash` the script saves a copy at `/usr/local/lib/cs-server/install.sh` and prints that path, which is still there after the bootstrap exits.

### Turn off SSH passwords

Do this only after a second terminal can log in with the key and use sudo. On the second terminal:

```bash
ssh cs@<this-host>
sudo -v
```

Leave that session open. On the first terminal:

```bash
sudo bash ops/bootstrap-vps.sh --harden-ssh
```

`--harden-ssh` refuses to run unless `cs` has a valid `authorized_keys` (`ssh-keygen -l -f`) and is allowed to sudo. It writes the sshd drop-in, runs `sshd -t`, and reloads sshd only when that check passes. A failed check removes the drop-in and does not reload.

### Provider firewall

In the provider panel (SolusVM, Virtualizor, RackNerd), allow SSH (`22/tcp`, or the port sshd uses) and `27015/udp`. With Day of Defeat, also allow `27016/udp`. That filter sits in front of the VM. With FastDL, also allow its TCP port. GoldSrc uses UDP for the game, queries and rcon.

### Steam game server token

A public server needs a Game Server Login Token or Steam will not list it. Create one at <https://steamcommunity.com/dev/managegameservers> for App ID **10** (Counter-Strike), one token per server. Pass it to the installer as `CS_GSLT` (a 32-character hex token), which the unit sets as `sv_setsteamaccount`. Or add it to `~cs/.config/cs-server/server.cfg`:

```
sv_setsteamaccount "YOUR_TOKEN"
```

Restart the service. `CS_PROFILE=lan` does not log in to Steam and needs no token. Day of Defeat uses a different token, for App ID **30**.

### DDoS

The bootstrap loads [`ops/firewall/cs-server.nft`](ops/firewall/cs-server.nft), which rate-limits connectionless query packets per source address. That stops a query flood from tying up the game thread. A volumetric UDP flood fills a cheap VPS's uplink before that filter can help. For that, put a filtered host in front (an OVH VPS, which includes game DDoS filtering, over WireGuard) or a UDP game-filtering provider, and publish the protected address.

### Restore a backup

```bash
sudo -u cs systemctl --user stop scoutzknivez
sudo -u cs env XDG_RUNTIME_DIR=/run/user/$(id -u cs) \
  /home/cs/.local/bin/cs-server-backup \
  --restore /home/cs/cs-server-backups/cs-server-state-YYYYMMDDTHHMMSSZ.tar.gz
sudo -u cs systemctl --user start scoutzknivez
```

Stop the server first. The archive is mode 0600 and owned by `cs`. Restore streams it into a staging volume on stdin (the game image runs as UID 10001 and cannot read that file from a bind mount), checks that it extracted, then swaps it into `cs-server-state`. A malformed or truncated archive leaves the volume as it was. Config in `~cs/.config/cs-server/` is not inside the volume; copy that directory separately when you want it kept.

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

> **Docker users:** replace `podman` with `docker` in the commands below.
> Docker Engine 29.4.2 cannot run this server (its seccomp profile blocked
> every 32-bit socket; fixed in 29.4.3): update Docker if you are on it.

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
| `config/server.cfg` | Settings shared by every mode (rates, bots, limits, hostname) |
| `config/mapcycle.txt` | Map rotation (default scoutzknivez variants) |
| `config/mapcycle-dust2.txt` | Dust 2 rotation (classic de_dust2) |
| `config/mapcycle-nipper.txt` | Nipper Friday (knife mode) rotation |
| `config/mapcycle-nipper-xmas.txt` | Nipper Friday Christmas rotation (Dec 1 to Jan 6) |
| `config/modes/*.cfg` | Per-mode gameplay (gravity, round time, money), run after `server.cfg`: `scoutz.cfg`, `knife.cfg` (Nipper Friday; `knife_he.cfg` for grenade maps), `vanilla.cfg`, `match.cfg` |
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
docker run -d \
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

### Vanilla (stock Counter-Strike)

`MODE=vanilla` is the game as it shipped: normal gravity, buying, the map's
objectives, $800 start money, and no scout-and-knife loadout. It starts on
`de_dust2` with `mapcycle-dust2.txt` unless `MAP` and `MAPCYCLE` say
otherwise (the Compose file, Quadlet unit and installer set both, so change
them there). Switch a running server the same way as the other modes:

```bash
just mode vanilla         # stock rules on mapcycle-dust2.txt, at the next round end
just mode scoutz          # back to ScoutzKnivez
```

Vanilla has its own plugin list, `plugins/amxmodx/modes/vanilla.ini`: the
admin and map-vote plugins without bunny hop, kill sounds and advertisements.
A mode without such a file uses `plugins.ini`. Bots need a navigation mesh for
each map; on a stock map they build one the first time it is played (a
minute or two) and it is kept in the state volume.

### Match (5v5)

`MODE=match` (or `just mode match` on a running server) runs a competitive
match: first to 16 of 30 rounds, 1:45 rounds, 15 s freeze time, $800,
friendly fire on, and sides swapped after 15 rounds with the score carried
over and money reset. Every map goes through these steps:

| Step | What happens | Chat |
|------|--------------|------|
| Warmup | Everyone respawns with full money; rounds do not end | `.ready`, `.notready` |
| Knife round | Starts when 10 players are ready. Knives only, one round | |
| Side choice | The knife winners pick within 30 s, otherwise sides stay | `.stay`, `.switch` |
| Live | The match, after a restart | `.pause`, `.unpause` |

A pause holds the next freeze time (or the current one) until someone says
`.unpause`. Commands also work with `!` or `/`.

From the server console (`just rcon "<command>"`): `match_start` starts the
knife round without waiting for players to ready up, `match_live` skips
straight to live, `match_stay` / `match_switch`, `match_pause` /
`match_unpause`, `match_reset` goes back to warmup and `match_status` prints
where the match is. `match_players` (10), `match_half` (15) and
`match_choose_time` (30) are cvars; set them in `config/modes/match.cfg`.
For a 2v2: `match_players 4`.

The mode's plugin list (`plugins/amxmodx/modes/match.ini`) has no map votes
and no AFK or ping kicks. There is no overtime: 15-15 is a draw. Set `BOTS=0`
for a real match; with bots, `match_start` gives a practice run.

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

### FastDL from the same machine

No web host of your own? The image can serve its maps itself. `CS_FASTDL=1`
adds a sidecar: a second small container from the same image that runs a
static web server on `27080/tcp` and points the game server at it.

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | CS_FASTDL=1 bash
```

- It serves the game's `maps`, `sound`, `sprites`, `models`, `gfx`,
  `overviews` and `.wad` files, and nothing else: no settings, ban lists,
  admin files or plugins, and no directory listings. It mounts nothing, runs
  read-only with every capability dropped, and needs no internet.
- Clients are sent to `http://<this machine's first address>:27080/cstrike/`.
  `CS_FASTDL_HOST` names another address or host name (a public server
  behind a router needs its public one, and `27080/tcp` forwarded);
  `CS_FASTDL_PORT` changes the port. An explicit `FASTDL_URL` still wins.
- Open `27080/tcp` in the host firewall for the players' network.
- One sidecar (`cs-server-fastdl`) serves every Counter-Strike server on the
  machine. `CS_FASTDL=1 bash install.sh --uninstall` removes it along with
  the server; without `CS_FASTDL=1` it stays for the others.
- By hand: `podman run -d --entrypoint /fastdl.sh -p 27080:27080 --read-only --cap-drop ALL <image>`
  and `FASTDL_URL=http://<host>:27080/cstrike/` on the server.

The sidecar needs an image from 1.4.0 or newer; the installer says so when
the image has none. It serves what is in the image. Maps you add later go into the image with a
rebuild (`just fetch-maps && just build`), as they do for the game server.

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
| `NOMASTER` | `0` | Disable master server (1=on, 0=off). Enable for Docker Desktop on Windows. Also passes `-insecure` |
| `INSECURE` | `0` | Pass `-insecure` without `-nomaster`. Off by default. Installer: `CS_INSECURE=1` |
| `GSLT` | empty | 32-character hex Steam game server token (`sv_setsteamaccount`). Installer: `CS_GSLT` |
| `DOD_MODE` | `pub` on a Day of Defeat image | `pub` or `match`. Ignored by every other game. An explicit `MODE=pub` or `MODE=match` selects it too. Installer: `CS_DOD_MODE` |
| `DOD_PASSWORD` | empty | Day of Defeat `sv_password`. Ignored by every other game. Installer: `CS_DOD_PASSWORD` |
| `MAPCYCLE` | `mapcycle.txt` | Mapcycle file to use (e.g. `mapcycle-dust2.txt`, `mapcycle-nipper.txt`) |
| `LAN_MODE` | `0` | LAN-only mode (1) or public server mode (0) |
| `MODE` | `scoutz` | Game mode at startup: `scoutz` (scout + knife), `knife` (Nipper Friday), `vanilla` (stock Counter-Strike) or `match` (5v5: warmup, knife round, pause) |
| `METRICS_PORT` | empty | Serve Prometheus metrics on this port inside the container; see [Metrics](#metrics). `METRICS_BIND` (default `0.0.0.0`) is the address it listens on |
| `FASTDL_URL` | empty | http(s) URL serving your `cstrike/` content (`sv_downloadurl`); see [FastDL](#fastdl-fast-downloads) |
| `LOGS` | `1` | Write server log files (1=on, 0=off); see [Saved state and logs](#saved-state-and-logs) |
| `LOG_RETENTION_DAYS` | `7` | Delete log files older than this many days (`0` keeps them all) |
| `LOGADDRESS` | empty | `host:port` of a log receiver such as HLstatsX (`logaddress_add`); needs `LOGS=1` |
| `SERVER_IP` | empty | IPv4 address to bind and report to Steam (`+ip`); see [Host networking and Steam](#host-networking-and-steam) |
| `SERVER_IP_WAIT` | `30` | Seconds to wait at start for `SERVER_IP` to be on an interface (after a reboot the service can start before the network has it); 0 does not wait |

Startup rejects invalid booleans, out-of-range ports/player counts, unsafe
map or mapcycle filenames and malformed FastDL URLs or log addresses instead
of passing unchecked values to HLDS.

## Several servers on one host

Each extra server is an **instance** with its own name, port, config directory
and saved state. The first (unnamed) one keeps the names it always had.

```bash
# A second server on port 27016
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | CS_INSTANCE=match2 CS_PORT=27016 bash
```

| | Default | `CS_INSTANCE=match2` |
|---|---|---|
| Service / container | `scoutzknivez` | `cs-server-match2` |
| Config | `~/.config/cs-server/` | `~/.config/cs-server-match2/` |
| Saved state (volume) | `cs-server-state` | `cs-server-state-match2` |
| Port | `27015/udp` | `CS_PORT` (required to differ) |

- The port is the same inside and outside the container, because GoldSrc tells
  clients its own port. Open each one in the firewall.
- Manage an instance by its name: `systemctl --user restart cs-server-match2`,
  `podman logs -f cs-server-match2`. `scripts/mode.sh` takes
  `CS_CONTAINER_NAME=cs-server-match2`.
- Uninstall one with the same variable: `CS_INSTANCE=match2 bash install.sh --uninstall`.
  The others are left alone.
- Budget about 350 MB of RAM and one busy CPU thread per server with bots.
- From a checkout, Compose takes the same three values and a project name:
  `CS_CONTAINER_NAME=cs-b PORT=27016 CS_STATE_VOLUME=cs-server-state-b podman compose -p cs-b up -d`.
- macOS (`ops/cs-server`) runs one server; instances there are not supported yet.

## LAN party

A LAN server has to be found in the game's **LAN** tab, and the tab finds
servers by broadcast. A broadcast never reaches a container behind a published
port, so the LAN profile puts the server on the host's network and sets
`sv_lan 1`:

```bash
# Installer (Podman Quadlet, or Docker)
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | CS_PROFILE=lan bash

# From a checkout
just lan-party      # podman compose -f compose.yml -f compose.lan.yml up --build -d
```

In an existing Quadlet unit, replace `PublishPort=27015:27015/udp` with
`Network=host` and set `Environment=LAN_MODE=1`.

- Open `27015/udp` in the host's firewall for the LAN.
- `sv_lan 1` means no Steam login, no VAC and no master-server listing. The
  server needs no internet connection, and non-Steam clients can join.
- Do not set `NOMASTER=1`: the server then answers no server-browser queries
  and stays out of the LAN tab. Do not set `SERVER_IP` either: a socket bound
  to one address hears no broadcasts.
- Apple `container` has no host networking. On a Mac, clients connect by
  address (`connect <mac-ip>:27015`).
- Tested here between two containers on one network (broadcast query answered,
  with and without an uplink). Whether a given client's LAN tab lists it also
  depends on that client and on the switch or access point passing broadcasts.

### LAN kit: several match servers in one command

For an event with more than ten players: `CS_LAN_KIT=<n>` installs `n`
servers (1 to 8) named `lan1` to `lan<n>` on consecutive ports from
`CS_PORT` (default 27015), each with the LAN profile, [match mode](#match-5v5)
and no bots, plus one [FastDL sidecar](#fastdl-from-the-same-machine) for
all of them.

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | CS_LAN_KIT=4 bash
# from a checkout: just lan-kit 4
```

Each server is an ordinary [instance](#several-servers-on-one-host)
(`cs-server-lan1`, `~/.config/cs-server-lan1`, its own bans and stats), so
`systemctl --user restart cs-server-lan2` and the other commands work per
server. `CS_MODE=vanilla` (or `scoutz`) and `CS_BOTS=1` change what the kit
runs. Open the game ports (UDP) and `27080/tcp` in the host firewall.
`CS_LAN_KIT=4 bash install.sh --uninstall` removes all four and the sidecar,
asking about each server's config and saved state.

The LAN tab only looks at a handful of ports from 27015 up. If a server on
a higher port does not show there, players join it with
`connect <address>:<port>`.

### No internet

The server starts and plays with no network at all (`tests/e2e_test.sh` boots
it with `--network none`). To install on a machine that cannot reach the
registry, carry the image over:

```bash
# On a machine with internet
podman pull ghcr.io/kevintcoughlin/cs-server:1
podman save -o cs-server.tar ghcr.io/kevintcoughlin/cs-server:1

# On the LAN box (docker save / docker load work the same way)
podman load -i cs-server.tar
CS_SERVER_VERSION=1 CS_PROFILE=lan bash install.sh
```

When the pull fails and the image is already in local storage, the installer
says so and uses that copy. Copy `install.sh` over with the tarball; it needs
nothing else from the network.

### Host networking and Steam

Without `+ip`, HLDS reports the address its hostname resolves to. On host
networking that can be a VPN or bridge address (a Tailscale `100.x` address,
for example), and the server then logs `Could not establish connection to
Steam servers.` and is neither VAC secured nor on the master list. Look for
`Server IP address` in the log. For a **public** server on host networking,
set `SERVER_IP` to the address clients reach; the health check follows it.
A LAN-profile server does not talk to Steam and needs no `SERVER_IP`.

## Other games

The same Containerfile builds a server for the other Valve games on this
engine: the same ReHLDS, Metamod-R and AMX Mod X around that game's own
library, with its stock maps, map cycle and settings.

| `GAME` | Game | Starts on | Notes |
|--------|------|-----------|-------|
| `czero` | Condition Zero | `de_dust2_cz` | ReGameDLL, ReAPI and bots (`BOTS`), stats |
| `dod` | Day of Defeat | `dod_anzio` | Pub and 6v6 configs, AMX Mod X DoDX stats. See below |
| `tfc` | Team Fortress Classic | `2fort` | AMX Mod X TFC modules and stats |
| `valve` | Half-Life deathmatch | `crossfire` | |
| `gearbox` | Opposing Force | `op4_bootcamp` | |
| `dmc` | Deathmatch Classic | `dmc_dm2` | |
| `ricochet` | Ricochet | `rc_arena` | |

Each release publishes them next to the Counter-Strike image, under the
game's name: `ghcr.io/kevintcoughlin/cs-server:<version>-<game>` (also
`<major>.<minor>-<game>` and `<major>-<game>`), and `:<game>` for the newest
release. The first release with these tags is 1.2.1.

Install one with the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | CS_GAME=dod bash
```

| | Counter-Strike | `CS_GAME=dod` |
|---|---|---|
| Service / container | `scoutzknivez` | `dod-server` |
| Config directory | `~/.config/cs-server` | `~/.config/dod-server` |
| State volume | `cs-server-state` | `dod-server-state` |
| Image | pinned release (`1.4.2`) | `1.4.2-dod` |

The config directory holds the game's `server.cfg` and `mapcycle.txt`, copied
from the image on the first install and mounted read-only; edit them and
restart the service. `CS_SERVER_VERSION`, `CS_PORT`, `CS_INSTANCE`
(`dod-server-<name>`), `CS_PROFILE=lan`, `SERVER_IP`, `CS_RCON` and
`--uninstall` work as they do for Counter-Strike. A game server next to a
Counter-Strike server needs its own `CS_PORT`.

Or build and run one by hand:

```bash
podman build --build-arg GAME=dod -t localhost/cs-server:dod .   # or: just game dod
podman run -d --name dod \
    --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp \
    -p 27015:27015/udp -v dod-state:/hlds/state \
    localhost/cs-server:dod
```

The Compose files and the macOS `ops/cs-server` path still assume
Counter-Strike.

`MAP`, `MAXPLAYERS`, `PORT`, `LAN_MODE`, `NOMASTER`, `SERVER_IP`, `FASTDL_URL`
and the log settings work as they do for Counter-Strike; the state volume,
read-only root and console pipe are the same. Each image except Day of Defeat
keeps the game's stock `server.cfg` with a hostname and this repo's rate and
security settings appended (`config/games/common.cfg`). Day of Defeat ships
`config/dod/` instead. To change settings without the installer, mount your
own files over `/hlds/<game>/server.cfg` and `/hlds/<game>/mapcycle.txt`.

Only Counter-Strike and Condition Zero have bots (they are part of
ReGameDLL). `MODE` and the ScoutzKnivez plugins are Counter-Strike only.
Day of Defeat uses `DOD_MODE` instead. Each game is about 1.1 to 1.5 GB.
CI builds and tests each one on x86-64 and arm64 (`tests/e2e_game_test.sh`).

## Day of Defeat 1.3

A second server, on UDP **27016**, next to Counter-Strike on 27015. It is the
same Containerfile with `--build-arg GAME=dod`: ReHLDS, Metamod-R and AMX Mod X
around Valve's Day of Defeat library (`+game dod`). The dedicated-server files
come from Steam app **90**. Clients are app **30**, which is the id in
`steam_appid.txt`. It has its own image tag (`:<version>-dod`), Quadlet unit
(`dod-server`), config directory (`~/.config/dod-server`) and state volume
(`dod-server-state`). Counter-Strike's unit, config and volume are not changed.

On a VPS the bootstrap installs both, opens `27016/udp`, rate-limits queries
to both ports, and the daily backup archives `dod-server-state` along with
`cs-server-state`. Lingering is the same linger the Counter-Strike install
already turns on, so both units start at boot.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/ops/bootstrap-vps.sh \
  | sudo bash -s -- --dod --ssh-key "ssh-ed25519 AAAA... you@host"
```

Or, on a host that already runs Counter-Strike:

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh \
  | CS_GAME=dod CS_PORT=27016 bash
```

`CS_DOD_PORT` changes 27016 when that port is taken (a Counter-Strike instance
on 27016, for example). In the RackNerd (or other provider) panel, allow
`27016/udp` as well as `27015/udp`. Each unit is capped at 512 MB and 2 CPUs.
`config/dod/server.cfg` sets `sys_ticrate 300` so this process does not ask for
the 1000 the Counter-Strike server keeps.

### Public server and 6v6

`CS_DOD_MODE=pub` (the default) or `match` is passed only to the Day of Defeat install. The Counter-Strike install does not receive it. The container reads `DOD_MODE`.
On a running server the console takes the same files:

```bash
# pub, 6v6, or a 10-minute overtime half
podman exec dod-server sh -c 'printf "%s\n" "exec match.cfg" > /hlds/.runtime/hlds-input'
podman exec dod-server sh -c 'printf "%s\n" "exec match-ot.cfg" > /hlds/.runtime/hlds-input'
podman exec dod-server sh -c 'printf "%s\n" "changelevel dod_anzio" > /hlds/.runtime/hlds-input'
```

Slot count is fixed until a restart. Pub launches with 16. Match launches
with 12. `MAXPLAYERS` overrides either.

These files are not an official KTP config. [KTP](https://ktpleague.gg/)
(Keep the Practice, Season 10, Fall 2026) is the active NA six-a-side league.
Rule §1.4 says an official game uses the league's config for that map, on an
approved server, and that config is not published. Rule §1.5 also requires a
separate HLTV proxy with at least a 120-second delay. This image does not
start HLTV, and `-insecure` is off unless you set `INSECURE=1` or `NOMASTER=1`.

What the files do use, and where it comes from:

| Setting | Value | Source |
|---------|-------|--------|
| Pub map clock | 25 min | dodbits, DoD 1.3 commands, 26 September 2023: `mp_timelimit` default is 25. <https://www.dodbits.com/dods/?Itemid=100035&id=41%3Adods-cvars-commands&layout=default&option=com_content&view=category> |
| Pub rates | max 25000, min 7500, updaterate 20–66 | The same page: public recommendations. 25000 is their low-slot figure, used here because the host also runs Counter-Strike |
| Match slots | 12 | KTP is six-a-side (rules §2.10). The server list shows 12 slots. <https://ktpleague.gg/servers> |
| Match half | 20 min | Not published. One Season 10 `dod_anzio` game is listed as "2 halves · 40:08". <https://ktpleague.gg/stats/matches/1791162528-CHI1> |
| Overtime half | 10 min | Rules §1.10: 10-minute halves, switch sides, continue until there is a winner. `exec match-ot.cfg` then `changelevel` |
| Match rates | max 100000, updaterate up to 100, floor 7500 / 20 | dodbits popular "good server" max rate and updaterate; the public floor from the same page. KTP does not publish rates |
| Friendly fire | on | The HLDS.pl DoD 1.3 example sets `mp_friendlyfire 1`. <http://hlds.pl/Serwer_Day_of_Defeat_1.3>. KTP does not publish it |
| Class limits | unlimited (`-1`) | Engine default. KTP does not publish class limits, so none are invented here |
| Logging | on | Rules §1.5, for a server that would host a league game |

There is no ready-up plugin. KTP's `.ready`, `.ktp` and `.tech` commands belong
to the league's match plugin (<https://ktpleague.gg/servers>), which is not
included. To hold the clock, set `mp_timelimit 0`. When both teams are in,
`exec match.cfg` and `changelevel` the map. That starts a fresh half. KTP
plays each half as its own map load; the home team picks the first side
(rules §2.3.a). A match password is `CS_DOD_PASSWORD` at install, or
`sv_password` from the console. `exec match.cfg` does not clear it.

The pub rotation is classic maps that ship with app 90: `dod_anzio`,
`dod_avalanche`, `dod_caen`, `dod_charlie`, `dod_donner`, `dod_flash`,
`dod_forest`, `dod_jagd`, `dod_kalt`, `dod_saints`. `dod_palermo` is not in
the dedicated-server download, so it is not in the rotation.

The Season 10 pool, from the schedule's command-map list and the weekly
maps (<https://ktpleague.gg/schedule>) and the Gold playoff note
(<https://ktpleague.gg/news/6>), is `dod_anzio`, `dod_armory_b7`,
`dod_harrington`, `dod_lennon5_b1`, `dod_railroad2_s10b`, `dod_saints2_b5e`,
`dod_thunder2`, plus regular-season `dod_anjou_a5` and `dod_solitude2`.
Only `dod_anzio` is in the dedicated server, so `mapcycle-match.txt` is that
map alone. The others are custom. KTP serves them from `fastdl.ktpdod.com`
(<https://ktpleague.gg/files>). They are not bundled. Add the `.bsp` files
with a new image build, and confirm the FastDL path in a browser before
setting `FASTDL_URL`. Do not point it at a host you have not checked: a wrong
URL makes every custom download fail.

### GSLT and GameTracker

Create a token for App ID **30** (one per server; the Counter-Strike token
cannot be reused) and install with `CS_DOD_GSLT`. The unit passes it as
`sv_setsteamaccount`. Leave `NOMASTER` and `INSECURE` unset so the server is
neither hidden nor marked insecure.

GameTracker lists it once the port answers a query from the internet.
Log in at <https://www.gametracker.com/servers/>, choose **Add a Server**,
and pick **Day of Defeat** (not Day of Defeat: Source). Enter the public IP
with no port, and join port `27016`. The server has to be up and reachable.

### Plugins

AMX Mod X and the Day of Defeat addon (DoDX) are already in the `GAME=dod`
image. [Sturmbot's April 2026 guide](https://www.sturmbot.org/index.php/dod-articles/day-of-defeat-server-guides/134-amx-mod-x-for-dod-1-3-installation-fixes-and-plugin-review-2026)
describes that stack on Steam DoD 1.3. The glibc 2.41 executable-stack failure
in their LAN guide is for Fedora, Nobara and Arch, not Debian. This image is
Debian 13. DoDX is left in AMX Mod X's auto-load list: naming it again makes
Metamod refuse the second copy. The image enables `stats.amxx` and
`stats_logging.amxx` only, plus `dodmode.amxx`, which re-applies the mode
file after each map starts (Day of Defeat resets the hostname and the clock
if the file runs any earlier). Stats are written to `dodstats.dat` in the
state volume. `tests/e2e_game_test.sh` requires the DoDX module to load.

## Saved state and logs

Everything the server writes while it runs is kept in one place,
`/hlds/state` in the container, and every deployment path mounts a volume
there. Replacing the container (an upgrade, `just deploy`, a rollback) keeps:

| In the volume | What it is |
|---------------|------------|
| `banned.cfg`, `listip.cfg` | Bans by SteamID and by address (`writeid`, `writeip`, AMX Mod X `amx_ban` / `amx_banip`); loaded at every start |
| `amxmodx/users.ini` | AMX Mod X admins. Seeded with the stock file; edit it to add yourself |
| `amxmodx/csstats.dat`, `amxmodx/vault*` | Player stats and plugin storage |
| `nav/` | Bot navigation meshes built for maps that ship without a `.nav` |
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

## Metrics

Every server keeps a small set of numbers in Prometheus text format: players
and bots, slots, the running map, time on the map, uptime and server frames
per second. They come from the game itself (the `metrics.amxx` plugin, in
every game's image), so they are the same with and without Steam
(`NOMASTER=1`), where the server-browser query goes unanswered.

Nothing listens by default. Read them without opening a port:

```bash
podman exec scoutzknivez cat /hlds/.runtime/metrics.prom
```

For Prometheus, give the server a metrics port. The installer publishes it
on this machine's loopback address only:

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | CS_METRICS_PORT=9137 bash
curl -s http://127.0.0.1:9137/metrics
```

```text
hlds_players{type="human"} 3
hlds_players{type="bot"} 7
hlds_max_players 20
hlds_map_info{map="scoutzknivez"} 1
hlds_map_seconds 412
hlds_uptime_seconds 86012
hlds_server_fps 870.4
hlds_updated_timestamp_seconds 1795385631
hlds_up 1
```

- `hlds_up` is 0 when the game has not reported for 30 seconds (down, hung
  or still loading its first map); the other lines are then left out.
- `CS_METRICS_BIND=<address>` publishes on another address of this machine,
  for a Prometheus that runs elsewhere. The endpoint has no authentication:
  keep it off the internet.
- In a unit or Compose file the settings are `METRICS_PORT` (the endpoint
  inside the container) and, on host networking, `METRICS_BIND`. Publish the
  port yourself: `PublishPort=127.0.0.1:9137:9137/tcp`.
- With `CS_LAN_KIT`, each server gets the next port (`9137`, `9138`, ...).
- The frame counter runs on every server frame and costs under 3% of the
  frame rate in this project's own measurement; `metrics_fps 0` in
  `server.cfg` turns it off (from the next map) and drops `hlds_server_fps`.
  `metrics_interval` (5 s) is how often the numbers are refreshed.

A scrape job:

```yaml
scrape_configs:
  - job_name: cs-server
    static_configs:
      - targets: ['127.0.0.1:9137']
```

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

**Pin.** A fresh `install.sh` runs the release named by `DEFAULT_VERSION` in that script (currently `1.4.2`, kept equal to the newest `## [x.y.z]` heading in [CHANGELOG.md](CHANGELOG.md)). `CS_SERVER_VERSION` and `CS_SERVER_IMAGE` still override it. `:latest` moves with every push to `main` and is not the default; set `CS_SERVER_IMAGE=ghcr.io/kevintcoughlin/cs-server:latest` to run it. `compose.yml` and [`quadlet/scoutzknivez.container`](quadlet/scoutzknivez.container) stay on `localhost/cs-server:latest` because those are local builds (`just quadlet`). The checked-in unit's `Notify=healthy` needs Podman 5; on Podman 4.4 through 4.9 the installer omits that line. The installer prints the digest of what it pulled; note it down, because it is what you roll back to.

A release tag's copy of `install.sh` is the script from that tag. Pass `CS_SERVER_VERSION` when you curl a tag. The copy on `main` carries `DEFAULT_VERSION`.

**Upgrade** by running the installer again with the new version. Config in `~/.config/cs-server/` is kept, the unit is rewritten, and a running server is restarted onto the new image (players get the 30 second countdown):

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/v1.4.2/install.sh | CS_SERVER_VERSION=1.4.2 bash
```

**From 1.0.x to 1.1.0, re-run the installer** rather than editing `Image=`:
1.1.0 adds a state volume, a read-only root filesystem and, on Docker, a
seccomp profile, and those live in the unit (or the `docker run` command), not
in the image. An old unit still starts a new image, but nothing the server
saves outlives the container; the server log says so at start
(`NOTE: /hlds/state is not a volume`). To do it by hand, add to `[Container]`:

```ini
Volume=cs-server-state:/hlds/state
ReadOnly=true
Tmpfs=/tmp
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

**Unattended updates (Podman, optional).** `CS_AUTO_UPDATE=1` adds `AutoUpdate=registry` to the unit and enables `podman-auto-update.timer`, which checks daily whether the tag points at a new image. Use it with a moving tag (`CS_SERVER_VERSION=1` or `1.0`), not `1.0.0`. On Podman 5 the unit only counts as started once the server answers its health check, so if a new image does not come up, Podman puts the previous one back. Podman 4.4 through 4.9 still pull and restart, and the installer says that a bad image stays. An update restarts the server, countdown included, whenever the timer fires; skip this if restarts must be planned.

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

The Quadlet is configured with `WantedBy=default.target`. `install.sh` runs `loginctl enable-linger` for the user (or prints `sudo loginctl enable-linger <user>` when it cannot), so the server starts at boot.

### Crash Recovery

`Restart=on-failure` restarts the container after 10 seconds if HLDS crashes, but stays stopped on a clean `systemctl stop`.

## Security

### Container Hardening

- **No Linux capabilities** — all capabilities dropped via `DropCapability=ALL`
- **No privilege escalation** — `NoNewPrivileges=true` prevents gaining new privileges via setuid/setgid binaries
- **Seccomp** — the server runs under the engine's built-in default-deny
  seccomp profile on Podman and Docker; no deployment path names a profile
  or turns seccomp off. Docker Engine 29.4.2 is the one release whose profile
  breaks 32-bit programs
  ([moby/moby#52506](https://github.com/moby/moby/issues/52506)); `install.sh`
  refuses it. See [`ops/seccomp/README.md`](ops/seccomp/README.md) for the
  profile the image still carries for older installers
- **Read-only root filesystem** — `ReadOnly=true` (Quadlet), `read_only: true`
  (Compose), `--read-only` (`install.sh` on Docker). The server can write to
  two places only: the [state volume](#saved-state-and-logs) and a tmpfs on
  `/tmp` that holds the console pipe. Not set on macOS (`ops/cs-server`). For a
  map with no `.nav` file the bots build a navigation mesh on first load; it
  is saved in the state volume (`nav/`) and reused
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
`install.sh` only points at it. [`ops/bootstrap-vps.sh`](ops/bootstrap-vps.sh) installs and enables the unit on a new VPS, reloads it after writing the rules (and reloads `cs-server-input` when that policy is the one in use), and adds an input policy for SSH and `27015/udp` when the host has neither firewalld nor ufw. A later run that opens another game port reloads those units so the new rule is applied.

## Performance Tuning

The server is preconfigured with HLDS/ReHLDS network and tick-rate optimizations:

- **Network buffers** — the container sets no sysctls. `net.core.rmem_max` and `net.core.wmem_max` belong to the host, and a rootless container that asks for them does not start. A busy host can raise them itself (`sudo sysctl -w net.core.rmem_max=26214400 net.core.wmem_max=26214400`); a single server does not need it.
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
- Back up `${HOME}/.config/cs-server/`, especially `server.cfg` and map cycles. `CS_BACKUP=1` (on for the VPS bootstrap) also archives the state volume daily; see [Restore a backup](#restore-a-backup).
- Restore by stopping the service, replacing that directory from backup with
  owner-only permissions (`chmod 700` on the directory and `chmod 600` on its
  files), then restarting the service.
- Allow `27015/udp` on the host firewall and monitor the service with systemd/journald.
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
