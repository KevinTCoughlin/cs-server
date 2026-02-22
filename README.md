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

## License

[MIT](LICENSE)
