# CS 1.6 ScoutzKnivez Server

[![GHCR](https://img.shields.io/badge/ghcr.io-cs--server-blue?style=flat-square&logo=github)](https://ghcr.io/kevintcoughlin/cs-server)

Containerized Counter-Strike 1.6 scoutzknivez server using the ReHLDS stack.

## Stack

- **ReHLDS** 3.14.0.857 — reverse-engineered engine
- **ReGameDLL_CS** 5.28.0.756 — reverse-engineered game DLL
- **Metamod-R** 1.3.0.149 — plugin loader
- **AMX Mod X** 1.10 — scripting platform
- **ReAPI** 5.26.0.338 — extended API

## Install

[![Install with Podman](https://img.shields.io/badge/Install_with-Podman-892CA0?style=for-the-badge&logo=podman&logoColor=white)](https://github.com/KevinTCoughlin/cs-server#install)

```bash
curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash
```

Requires [Podman](https://podman.io/getting-started/installation) (rootless) or [Docker](https://docs.docker.com/get-docker/). The script pulls the image from ghcr.io, creates config files, and starts the server on port 27015. With Podman it installs a systemd Quadlet unit for auto-start; with Docker it creates a container with restart policy.

To uninstall: `curl -fsSL https://raw.githubusercontent.com/KevinTCoughlin/cs-server/main/install.sh | bash -s -- --uninstall`

## Quick Start

### Option 1: Pull from ghcr.io (fastest)

Pre-built images are available on GitHub Container Registry:

```bash
podman pull ghcr.io/kevintcoughlin/cs-server:latest
podman run -d -p 27015:27015/udp -p 27015:27015/tcp \
  --name scoutzknivez ghcr.io/kevintcoughlin/cs-server:latest
```

The server starts on port **27015**. Connect with your CS 1.6 client:

```
connect <your-lan-ip>:27015
```

> **Docker users:** replace `podman` with `docker` in the commands below.

### Option 2: Build from source

If you need custom maps or configurations:

#### 1. Add maps

Place `.bsp` files into the `maps/` directory. They get baked into the image at build time.

Maps are not included in the repo due to file size. You can find them on sites like [GameBanana](https://gamebanana.com/mods/cats/5568) or [17buddies](https://www.17buddies.rocks/).

#### 2. Build and run

```bash
podman compose up --build
```

The server starts on port **27015**. Connect with your CS 1.6 client:

```
connect <your-lan-ip>:27015
```

### Configuration

Edit files in `config/` — they're bind-mounted into the container:

| File | Purpose |
|------|---------|
| `config/server.cfg` | Game settings (gravity, round time, etc.) |
| `config/mapcycle.txt` | Map rotation |
| `config/autoexec.cfg` | Runs on server start |

Changes to `server.cfg` take effect next round or via `rcon exec server.cfg`.

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

**How it works:** `sv_downloadurl` in `server.cfg` points clients to `https://kevintcoughlin.com/cs-server/cstrike/`. The engine tries `.bz2` compressed files first, then falls back to uncompressed.

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

Set an RCON password by adding to `config/server.cfg`:

```
rcon_password "your_password_here"
```

Then in-game: `rcon_password your_password_here` followed by `rcon <command>`.

## Adding Plugins

1. Write `.sma` source in `plugins/amxmodx/scripting/`
2. Add the `.sma` filename to the compile loop in `Containerfile`
3. Add the compiled `.amxx` filename to `plugins/amxmodx/plugins.ini`
4. Rebuild: `podman compose up --build`

## Production Deployment (Quadlet)

The server runs as a rootless Podman Quadlet unit managed by systemd.

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
podman compose up --build -d && podman compose down
systemctl --user restart scoutzknivez
```

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
- **System user with nologin shell** — HLDS runs as a system user (`-r`) with `/usr/sbin/nologin`, preventing interactive login
- **Setuid/setgid bits stripped** — all setuid/setgid bits removed from the runtime image
- **Resource limits** — `MemoryMax=512M`, `CPUQuota=200%` (2 cores max)

### HLDS Anti-Abuse

Rate limiting and anti-abuse cvars in `server.cfg`:

| Cvar | Value | Purpose |
|------|-------|---------|
| `sv_max_queries_sec` | 3 | Rate-limit server info queries (anti-amplification) |
| `sv_max_queries_window` | 30 | Query rate window in seconds |
| `sv_rcon_maxfailures` | 5 | Lock RCON after 5 bad attempts |
| `sv_rcon_banpenalty` | 60 | 60 minute RCON ban on failure |

### Firewall

Only the required ports should be open:

```bash
# CS 1.6 server
firewall-cmd --permanent --zone=FedoraWorkstation --add-port=27015/udp
firewall-cmd --permanent --zone=FedoraWorkstation --add-port=27015/tcp
firewall-cmd --reload
```

## Performance Tuning

The server is preconfigured with HLDS/ReHLDS network and tick-rate optimizations. Network buffer sysctl tuning (`net.core.rmem_max`, `net.core.wmem_max`) is applied automatically per-container via compose, Quadlet, and install.sh — no admin action required.

The following **host-level** settings are optional and must be applied manually by the admin:

### Host Kernel

HLDS benefits from a 1000 Hz kernel timer. On Debian/Ubuntu:

```bash
apt install linux-image-lowlatency
```

Reboot required after installation. Or set `CONFIG_HZ=1000` in a custom kernel config.

### CPU Governor

Disable power saving on the host to avoid frequency scaling during gameplay:

```bash
cpupower frequency-set -g performance
```

## License

[MIT](LICENSE)
