# CS 1.6 ScoutzKnivez Server

Containerized Counter-Strike 1.6 scoutzknivez server using the ReHLDS stack.

## Stack

- **ReHLDS** 3.14.0.857 — reverse-engineered engine
- **ReGameDLL_CS** 5.28.0.756 — reverse-engineered game DLL
- **Metamod-R** 1.3.0.149 — plugin loader
- **AMX Mod X** 1.10 — scripting platform
- **ReAPI** 5.26.0.338 — extended API

## Quick Start

### 1. Add maps

Place `.bsp` files into the `maps/` directory. They get baked into the image at build time.

Maps are not included in the repo due to file size. You can find them on sites like [GameBanana](https://gamebanana.com/mods/cats/5568) or [17buddies](https://www.17buddies.rocks/).

### 2. Build and run

```bash
podman compose up --build
```

The server starts on port **27015**. Connect with your CS 1.6 client:

```
connect <your-lan-ip>:27015
```

### 3. Configuration

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

## How It Works

The `scoutzknivez.sma` AMX Mod X plugin auto-strips weapons on spawn and gives each player a knife + scout with ammo. No buy menu interaction needed.

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
2. Add the compiled `.amxx` filename to `plugins/amxmodx/plugins.ini`
3. Rebuild: `podman compose up --build`

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

- **Read-only root filesystem** — container runs with `ReadOnly=true`, only `/tmp` is writable (for the shutdown FIFO)
- **No Linux capabilities** — all capabilities dropped via `DropCapability=ALL`
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

## License

[MIT](LICENSE)
