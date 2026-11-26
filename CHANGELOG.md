# Changelog

## [Unreleased]

### Added
- **Surf mode.** `MODE=surf` (`CS_MODE=surf`, `just mode surf`): air acceleration 100, no fall damage, bunny hop, no rounds, no bots. Surf maps have no timer buttons, so `movement.amxx` times a run between two zones kept per map in the state volume. The box around the spawn points is the start zone unless one is saved; an admin marks the end zone in game (`mv_zone end` from the client console on two opposite corners, `mv_zone show`, `mv_zone clear`), or the server console takes numbers (`mv_zone_set`). Until a map has an end zone it plays without a timer. `mapcycle-surf.txt` pins `surf_ski_5`, `surf_nice_fly_4`, `surf_srventer`, `surf_nice_fly` and `surf_colorama_beta`; like the climb maps they are not in the published image. A rotation can mix both kinds: the map's prefix picks the physics (`modes/surf_kz.cfg`, `surf_bkz.cfg`, `climb_surf.cfg`)
- **Climb mode (KZ).** `MODE=climb` (`CS_MODE=climb`, `just mode climb`) runs climb maps with stock gravity and air acceleration, no rounds, instant respawn and no bots. A new plugin, `movement.amxx`, times a run between the map's start and stop buttons, gives each player checkpoints (`/cp`, `/tp`, `/stuck`, `/start`) and keeps two top-15 lists per map in the state volume: "pro" for runs without a teleport and "cp" for the rest (`/top`). Players pass through each other and cannot hurt each other. The rotation, `mapcycle-climb.txt`, starts with four pinned maps that have the standard timer buttons: `kz_man_everest`, `bkz_goldbhop`, `bkz_toonworld` and `kz_climbers_b01`. None is redistributed: the published image does not contain them, so the mode needs a local build (`just fetch-maps && just build`), and none is cleared for FastDL, so clients fetch them through the game's own download. The metrics gain `hlds_movement_runs_total` and `hlds_movement_bests_total`. Times are this server's own; they are not records of any climbing community
- **Daily restart when a game server is empty.** `ops/restart-idle.sh` and a systemd user timer (`cs-server-restart.timer`) restart each Quadlet game server at 05:00 America/Los_Angeles, then every 20 minutes until 08:00, and only when an A2S_INFO query reports no human players (the reply's players minus its bots). A query that fails, including `NOMASTER=1`, leaves that server running. Human players still online at 08:00 leave it up until the next day. Each server restarts at most once per Los Angeles day. `Persistent=false`, so a VPS that was off at 05:00 does not restart late. `ops/bootstrap-vps.sh` installs and enables the timer (`CS_RESTART=0` or `--no-restart` removes it on a later run). `--restart-only` installs the timer on a machine that already has its servers, without the rest of the bootstrap
- **Day of Defeat 1.3 beside Counter-Strike.** `CS_DOD=1` (or `bootstrap-vps.sh --dod`) installs a second server on `27016/udp` with its own image (`GAME=dod`), Quadlet unit (`dod-server`), config directory and state volume. Counter-Strike stays on `27015/udp`. The firewall allows and rate-limits both ports, and the daily backup includes `dod-server-state`. `DOD_MODE=pub` is a 24/7 rotation of the classic maps that ship with dedicated-server app 90 (16 slots, 25-minute maps, public rates from the dodbits DoD 1.3 list). `DOD_MODE=match` is a 12-slot 6v6 setup: 20 minutes for a half, drawn from a recorded KTP Season 10 game because the league does not publish `mp_timelimit`, and `exec match-ot.cfg` for the 10-minute overtime halves in KTP rules §1.10. Switch a running server with `exec pub.cfg`, `exec match.cfg` or `exec match-ot.cfg`. `GSLT` sets `sv_setsteamaccount` (app 30 for Day of Defeat). `-insecure` and HLTV stay off unless `INSECURE=1` or `NOMASTER=1`; this image does not run an HLTV proxy. AMX Mod X's Day of Defeat addon loads DoDX. The image enables `stats.amxx` and `stats_logging.amxx`, and `dodmode.amxx` re-applies the mode file after each map because Day of Defeat resets the hostname and the clock if that file runs any earlier. Custom KTP maps are not bundled
- **A one-command VPS setup.** `ops/bootstrap-vps.sh` (root, once, idempotent, `--dry-run`) creates a deploy user, checks any SSH public key with `ssh-keygen -l`, and leaves SSH authentication unchanged. `--harden-ssh` is a separate step that turns off root and password login only when that user already has a valid authorized key and sudo access, and only after `sshd -t` succeeds. It installs Podman on Debian 13 and Ubuntu 24.04, or Docker on Debian 12 (distro Podman there is older than Quadlet), plus unattended-upgrades, fail2ban's sshd jail, and the nftables query-flood unit. SSH and `27015/udp` are allowed with nftables, or with ufw when ufw is installed, or with firewalld when firewalld is already running. It enables lingering and runs `install.sh` as that user. `CS_FASTDL=1` also opens the FastDL port. A host with under about 1.8 GB of RAM and no swap gets a 1 GiB swap file. `--no-install` prints a path to `install.sh` that still exists after the script exits
- **Daily backups of the state volume.** `ops/backup-state.sh` and a systemd user timer write `~/cs-server-backups/<volume>-<utc>.tar.gz` and keep 14 (`CS_BACKUP_KEEP`). `install.sh` installs them with `CS_BACKUP=1` and writes `~/.config/cs-server/backup.env` so the timer keeps using the engine and keep-count from that install, even if Podman and Docker are both installed. The VPS bootstrap turns backups on. `--restore` streams the mode-0600 archive on stdin into a staging volume and swaps it in only after it extracts; a bad archive leaves the live volume untouched

### Fixed
- **VPS bootstrap on a minimal Debian 13 image.** RackNerd's image has apt and no curl, so the documented one-liner installs `ca-certificates` and `curl` first, and `ops/bootstrap-vps.sh` installs them when either is missing, before it downloads anything. `CS_DOD_MODE` and `CS_DOD_PASSWORD` are passed only to the Day of Defeat install; an inherited value is removed from the Counter-Strike install, which exits when it sees one. On Podman the bootstrap runs `systemctl add-wants multi-user.target network-online.target`, so rootless Quadlets with linger are not held for the network-online timeout at boot (about two and a half minutes when nothing else pulls that target in). After it writes nftables rules it reloads `cs-server-firewall` and, when it installed the input policy, `cs-server-input`, including a second run that adds `27016/udp`. `systemctl enable --now` does not re-run an oneshot that is already active
- **A map change could crash the server inside the game library.** ReGameDLL 5.30.0.814 never initializes a navigation area's pathfinding links. `m_masterMarker` starts at 1, so when a leftover `m_openMarker` equals the live generation, `CNavArea::UpdateOnOpenList` follows a garbage pointer and the process segfaults. It showed up in the amd64 end-to-end test on the 1.4.0 and 1.4.1 release runs and upstream on hostage pathfinding with no bots. The image now builds `cs.so` from that release with those three fields value-initialized. [rehlds/ReGameDLL_CS#1202](https://github.com/rehlds/ReGameDLL_CS/pull/1202) had the same initialization and also unlinked areas in the destructor, cleared the list on map teardown, and returned early from `UpdateOnOpenList`; it was closed without being merged. Those extra changes are not included: the early return would hide a bad call, and map teardown does not read the open list. `tests/nav_openlist_repro.cpp` makes the unfixed code segfault on the first search and runs the fixed code through 10000 map changes with nothing left to crash. The 1.4.2 workaround, which keeps a bot from joining when bots are off, stays (#122)

### Changed
- **`install.sh` pins the current release instead of `:latest`.** The default tag is `DEFAULT_VERSION` in `install.sh`, kept equal to the newest `## [x.y.z]` in this file by `tests/install_test.sh`. `CS_SERVER_VERSION` and `CS_SERVER_IMAGE` still override it. `compose.yml` and the checked-in Quadlet unit stay on `localhost/cs-server:latest` (a local build)
- **Podman older than 4.4 is refused** on the Quadlet path, with a pointer to Docker. Podman 4.4 through 4.9 still install, without `Notify=healthy`, and the installer warns that an automatic update cannot roll back. The unit in the repository targets Podman 5
- **The installer enables lingering** (`loginctl enable-linger`) on the Podman/Quadlet path, and when backups are installed. When it cannot, it prints the sudo command. The server then starts at boot

## [1.4.2] - 2026-11-22

### Fixed
- **A server with `SERVER_IP` no longer crash-loops when it starts before the network.** After a reboot the service can start before Wi-Fi or DHCP has delivered the address; the engine then could not bind (`Couldn't allocate dedicated server IP port`) and was restarted until it could. The entrypoint now waits for the address to be on an interface, up to `SERVER_IP_WAIT` seconds (default 30)
- **A server with bots off could crash on a map change soon after it started.** `server.cfg` sets `bot_quota` at every map start, so with `BOTS=0` one bot joined and was kicked again half a second later, when the plugin put the quota back to 0. A map change within a second or two of that has crashed in the game library's bot navigation code (`CNavArea::UpdateOnOpenList`); it failed the amd64 end-to-end test in the 1.4.0 and 1.4.1 release runs. The plugin now holds `bot_quota` at 0 as it changes, so no bot joins at all (#122)

## [1.4.1] - 2026-11-22

### Changed
- **Docker runs the server under its built-in seccomp profile again.** The fault that made this project pass its own copy of Docker's default profile was specific to Docker Engine 29.4.2 ([moby/moby#52506](https://github.com/moby/moby/issues/52506), fixed in 29.4.3). `compose.yml` and `install.sh` no longer pass a profile, and `install.sh` refuses Docker 29.4.2 with the fix named. The image keeps the file for installers from 1.1 to 1.4, which read it out of the image. A weekly workflow starts the published image on the newest Docker under the built-in profile (#97)

## [1.4.0] - 2026-11-22

### Fixed
- **Builds no longer fail on a transient Steam download error.** SteamCMD is run up to three times when it stops with `App '90' state is 0x10E after update job`, which failed one game's image in the 1.3.0 release run

### Added
- **Metrics for Prometheus.** A new plugin in every game's image (`metrics.amxx`) keeps players, bots, slots, map, map time, uptime and server FPS in `/hlds/.runtime/metrics.prom`, from the game itself, so it works with `NOMASTER=1` too. `METRICS_PORT` (installer: `CS_METRICS_PORT`, published on loopback) serves it at `/metrics` with `hlds_up`. Nothing listens by default (#99)
- **FastDL sidecar.** `CS_FASTDL=1` makes `install.sh` also run a second container from the same image (`/fastdl.sh`, busybox httpd on `27080/tcp`) that serves the game's maps, sounds, sprites, models, gfx, overviews and `.wad` files to clients over HTTP, and points the server's `FASTDL_URL` at it. It serves nothing else (no settings, admin files or directory listings), mounts nothing and needs no internet. `CS_FASTDL_HOST` / `CS_FASTDL_PORT` set the address clients use (#75)
- **LAN kit.** `CS_LAN_KIT=<n>` (`just lan-kit <n>`) installs `n` servers (`lan1`..`lan<n>`, 1 to 8) on consecutive ports with the LAN profile, match mode, no bots and one FastDL sidecar, and removes them again with `--uninstall` (#83)
- **`CS_MODE` and `CS_BOTS` in the installer.** The mode a server starts in (`scoutz`, `knife`, `vanilla`, `match`) and whether it has bots, without editing the unit afterwards

## [1.3.0] - 2026-11-22

### Fixed
- **Nobody could join: "STEAM validation rejected".** The image carried Half-Life's Steam app id (70) in `steam_appid.txt` for every game. The engine normally corrects that file at start, but cannot on the read-only root filesystem (since 1.1.0), so a Counter-Strike server signed on to Steam as Half-Life and refused every player's ticket. Bots, the server browser and the health check were unaffected, which is why no test caught it. Each game's image now carries its own id (`GAME_APPID` in `scripts/game-env.sh`)

### Added
- **Match mode (5v5).** `MODE=match` (or `just mode match`) runs a competitive match on every map: warmup with `.ready`, a knife round whose winners choose sides (`.stay` / `.switch`), the live match (first to 16 of 30, sides swapped after 15 with the score kept and money reset) and `.pause` / `.unpause`, which holds a freeze time. Server commands (`match_start`, `match_live`, `match_reset`, `match_status`, …) do the same from the console. `plugins/amxmodx/scripting/match.sma`, `config/modes/match.cfg` (#73)
- **Vanilla mode.** `MODE=vanilla` (or `just mode vanilla` on a running server) is stock Counter-Strike: normal gravity, buying, objectives, no scout-and-knife loadout, and its own plugin list without bunny hop, kill sounds and advertisements (`plugins/amxmodx/modes/vanilla.ini`). A mode can now carry a plugin list as well as settings (#73)

### Changed
- **Gameplay settings moved from `server.cfg` to the mode files.** Gravity, air acceleration, freeze, buy and round time and start money are now in `config/modes/scoutz.cfg` (and every other mode file sets them too), so `server.cfg` holds what all modes share. Nothing changes for an existing install: its `server.cfg` keeps the ScoutzKnivez values and its mode files are not overwritten
- **One definition of the Quadlet unit.** `install.sh` is the only place the unit is written; `quadlet/scoutzknivez.container` is its output (`install.sh --print-unit`, `just quadlet`) and a test fails when the two differ (#94)

## [1.2.1] - 2026-11-22

### Added
- **Other games.** `podman build --build-arg GAME=<name>` (`just game <name>`) builds a server for Condition Zero (`czero`), Day of Defeat (`dod`), Team Fortress Classic (`tfc`), Half-Life deathmatch (`valve`), Opposing Force (`gearbox`), Deathmatch Classic (`dmc`) or Ricochet (`ricochet`) from the same Containerfile: ReHLDS, Metamod-R and AMX Mod X around the game's own library and stock maps, with the state volume, read-only root, console pipe and graceful shutdown of the Counter-Strike image. Condition Zero also gets ReGameDLL and bots. `scripts/game-env.sh` is the table of games. (#106)
- **Other games: published images and installer.** A release tag now also builds, tests and publishes every game on both architectures as `:<version>-<game>`, `:<major>.<minor>-<game>`, `:<major>-<game>` and `:<game>` (`.github/workflows/games.yml`). `CS_GAME=<game>` makes `install.sh` install that game with its own service (`<game>-server`), config directory (`~/.config/<game>-server`: the game's `server.cfg` and `mapcycle.txt`) and state volume, next to a Counter-Strike server or on its own (#108)

### Fixed
- **macOS: the image no longer built.** Apple `container` 1.7.1 refuses a Containerfile over 16 KiB (`Dockerfile size (18706 bytes) exceeds the maximum allowed size of 16384 bytes`, apple/container#735), which ours passed when the other games were added. `cs-server build` / `update` and `just build` / `up` / `deploy` now hand the builder a copy without the comment lines (about 11.7 KiB); `tests/ops_test.sh` fails if that copy reaches the limit. `cs-server install` on a Mac that still had an older image started that image instead of failing
- **Installer: the server could not read its config.** `install.sh` made the files in the config directory mode 600. The server runs as an unprivileged user inside the container, so `server.cfg` and the map cycles were silently ignored (stock settings, `Couldn't read file "mapcycle.txt"`). They are now 644, inside a directory that stays 700, so other users of the machine still cannot read them. Running the installer again repairs an existing install

## [1.2.0] - 2026-11-21

Several servers and LAN play. One host can run more than one server, a LAN-party profile shows the server in the LAN tab, and install and start work with no internet. **Upgrading from 1.1.x: pull the new image**; it also fixes a map-reload loop on two default maps.

### Added
- **Several servers on one host.** `CS_INSTANCE=<name> CS_PORT=<port>` makes `install.sh` set up an additional server with its own service (`cs-server-<name>`), config directory and state volume, on Podman and Docker; `--uninstall` with the same variable removes only that one. `compose.yml` takes `CS_CONTAINER_NAME`, `PORT` and `CS_STATE_VOLUME` for the same purpose. The default server keeps its names. Not yet on macOS (#72)
- **LAN profile.** `CS_PROFILE=lan` for `install.sh` (Quadlet and Docker) and `compose.lan.yml` (`just lan-party`) run the server on the host's network with `sv_lan 1`, so the LAN tab's broadcast query reaches it. Verified between two containers on one network; `NOMASTER=1` and `SERVER_IP` both hide a server from the LAN tab and the README says why (#81)
- **Offline start and install.** The server boots and answers server-browser queries with no network (new `--network none` case in `tests/e2e_test.sh`). `install.sh` uses an image already loaded with `podman load` / `docker load` when the registry cannot be reached; the README has the `save` / `load` steps (#82)
- `SERVER_IP`: IPv4 address for HLDS to bind and report (`+ip`). The health check queries that address.

### Fixed
- **Maps without a `.nav` file reloaded over and over with bots on** (`scoutzknivez_2k` and `scoutzknivez_bender` in the default map cycle). Since the read-only root of 1.1.0 the bots could not save the navigation mesh they build, so each load analysed the map, restarted it and analysed it again. The mesh is now saved in the state volume (`nav/`) and built once per map (#96)
- `compose.windows.yml` claimed to remove the bind mounts, capabilities and security options with empty lists, which Compose ignores when merging. The file now holds the one setting it ever applied (`NOMASTER=1`) and says so; `tests/compose_test.sh` renders the pair. Not run on Docker Desktop for Windows (#100)
- **A public server on host networking could not reach Steam** when the host's name resolved to a VPN or bridge address (seen with Tailscale): HLDS reported that address and Steam never answered, so the server was not VAC secured or listed. `SERVER_IP` names the right one; the README shows how to spot it (#98)

## [1.1.1] - 2026-11-21

Installer fixes. **A fresh install with rootless Podman did not start the server on 1.0.0 and 1.1.0.** Use the installer from this release; the image itself is unchanged apart from the version.

### Fixed
- **A fresh Podman install stopped before starting the server.** `install.sh` ran `systemctl --user enable --now` on the Quadlet unit; systemd refuses to enable a generated unit (`Unit ... is transient or generated`) and the installer exited there. It now starts the unit; the unit's `[Install]` section already makes it start at login or boot.
- **The Quadlet unit did not start on rootless Podman.** The unit, `install.sh` (Quadlet and `docker run`) and `compose.yml` asked for `net.core.rmem_max` / `net.core.wmem_max`, which belong to the host: the runtime refused with `open /proc/sys/net/core/rmem_max: Permission denied` and the service never came up. The sysctls are gone from every deployment path; the README shows how to raise them on the host. **Run the installer again** to get a unit without them (#92)

## [1.1.0] - 2026-11-21

State and hardening. What the server saves now survives a replaced container, and the container runs read-only under a seccomp profile on every engine. **Upgrading from 1.0.x: run the installer again** (or add the volume to your unit by hand, see the README); the new settings live in the unit, not in the image.

### Added
- **State volume.** Bans (`banned.cfg`, `listip.cfg`), AMX Mod X admins (`users.ini`), stats, plugin storage and logs now live under `/hlds/state`, mounted as the named volume `cs-server-state` by `compose.yml`, the Quadlet unit and `install.sh`, and as `~/.config/cs-server/state` on macOS. Before this, all of it was lost whenever the container was replaced. The ban lists are loaded at every start. `install.sh --uninstall` asks before removing the volume. An existing install gets the volume when its unit is regenerated (re-run the installer) (#71)
- **Server logs on disk.** `LOGS=1` (default) turns on HLDS file logging into the state volume; `LOG_RETENTION_DAYS` (default 7) deletes older files at start and daily; `LOGADDRESS=host:port` forwards log lines to a stats collector. Logs hold player names, SteamIDs and addresses; set `LOGS=0` to turn them off (#74)
- **Read-only root filesystem** on Quadlet, Compose and `install.sh` (Podman and Docker), with a tmpfs on `/tmp` for the console FIFO. `/hlds/.runtime` is now a link to `/tmp/hlds-runtime`; the documented FIFO path is unchanged (#80)
- `tests/e2e_test.sh` runs the server read-only on a state volume and checks that a ban survives container replacement.

- **Query-flood firewall recipe.** `ops/firewall/cs-server.nft` rate-limits connectionless packets (queries, pings, connection attempts) to the game port per source address in the kernel, leaving in-game traffic alone; `cs-server-firewall.service` loads it at boot. Works beside firewalld. Nothing applies it automatically; `install.sh` points at it. `tests/firewall_test.sh` exercises the rules in a private network namespace (#79)

### Changed
- **Docker no longer runs the server with `seccomp=unconfined`.** The profile built into Docker 29 answers the i386 binary's `socket()` with `ENOSYS`; Docker's own upstream default profile, passed as a file, does not (checked on Docker 29.4.2). `compose.yml` uses `ops/seccomp/docker-default.json`, the image carries the same file, and `install.sh` reads it out of the image for `docker run`, falling back to `unconfined` with a warning for older images. Podman is unchanged (#78)

### Fixed
- **`BOTS=0` now keeps bots off.** `server.cfg` sets `bot_quota`, and the per-map re-run of `server.cfg` brought the bots back after the first map. The entrypoint now also sets `localinfo sk_bots 0`, and `scoutzknivez.amxx` turns bots off again after it re-runs the config (#91)
- A container started without a state volume (a unit from before 1.1.0) says so in its log at start, and the README's upgrade section covers the step (#93)
- `just deploy` failed with a container-name clash while the Quadlet service was running; it now builds the image and restarts the service.
- The quickstart page still told readers to open 27015 on TCP.

## [1.0.0] - 2026-11-21

First tagged release. Images for it are on ghcr.io as `1.0.0`, `1.0` and `1` (`linux/amd64`, `linux/arm64`).

### Changed (behaviour)
- **FastDL URL is a setting.** `config/server.cfg` no longer sets `sv_downloadurl` to this project's site. The new `FASTDL_URL` environment variable (empty by default) sets it, on the HLDS command line so that the per-map re-run of `server.cfg` cannot override it; `entrypoint.sh` and `install.sh` reject anything that is not a plain http(s) URL. Wired into `compose.yml`, `.env.example`, `install.sh` (Quadlet unit and `docker run`) and the macOS env file. An install whose `server.cfg` already has the line keeps it. To keep the old behaviour on a rebuilt image, set `FASTDL_URL=https://kevintcoughlin.com/cs-server/cstrike/` (#75)
- **No rcon password by default.** `install.sh` and `ops/cs-server` no longer generate an `rcon_password`: the engine refuses network rcon without one, and the console FIFO (`just rcon`, `cs-server rcon`) needs none. `CS_RCON=1` at install generates one as before. Existing `server.cfg` files are not touched (#76)
- **27015/tcp is no longer published or exposed.** GoldSrc uses UDP for the game, queries and rcon; a running server has no TCP listener on the game port (checked in `tests/e2e_test.sh`). Removed from `compose.yml`, the Quadlet unit, `install.sh`, the justfile, `ops/cs-server`, `EXPOSE` and the docs. Firewall rules for 27015/tcp can go (#77)

### Fixed
- `install.sh` pulled `ghcr.io/KevinTCoughlin/cs-server:latest` by default, which Podman and Docker reject (`repository name must be lowercase`), so the one-line install failed unless `CS_SERVER_IMAGE` was set. The default is now lowercase; the stubbed installer test had asserted the mixed-case name
- `scripts/fetch-maps.sh`, `tests/mapcycle_test.sh` and `just fastdl` split `maps/manifest.tsv` with `IFS=tab`, which folds an empty column away and shifts the rest of the row left: a row with an empty license column passed the license check with its attribution text. All three now keep empty columns
- `mapcycle-nipper-xmas.txt` was not bind-mounted anywhere and `config/modes/` was missing from the Quadlet unit, `install.sh` and `ops/cs-server`, so edits to them needed an image rebuild. All five mount lists (`compose.yml`, Quadlet, justfile, `ops/cs-server`, `install.sh`) now carry every mapcycle and `modes/`; `tests/mounts_test.sh` keeps them in sync
- `install.sh` wrote its own `server.cfg` and mapcycles from heredocs that had drifted from `config/` (no FastDL URL, different rates). It now seeds missing files from the pulled image, so defaults match the image version; existing files are left alone
- `just fastdl` copied every `maps/*.bsp` into `docs/cstrike/`, including NIPPER's maps after `just fetch-maps`, which must not be re-hosted without permission. `maps/manifest.tsv` gains a `fastdl` column (`yes`/`no`); the recipe skips pinned maps not marked `yes`, and `tests/mapcycle_test.sh` fails if one is found under `docs/cstrike/maps/`
- `rtv.sma` read `mapcycle.txt` regardless of `MAPCYCLE`, so votes offered the wrong maps in the Dust 2 and community rotations; it now follows the `mapcyclefile` cvar
- `mapcycle-nipper.txt` (repo and `install.sh`) named four maps that don't ship (`scoutzknivez2`, `_pro`, `_winter`, `_x`), so the map change at map end failed
- The amd64 image crash-looped under Docker on x86_64 hosts (`UDP_OpenSocket … Function not implemented`, then `NET_OpenIP` fatal): Docker's default seccomp profile (Docker 29) answers the i386 binary's 32-bit `socket()` with `ENOSYS`. `compose.yml` and `install.sh` now run it with `seccomp=unconfined` (capabilities stay dropped, `no-new-privileges` stays on); the README and Friday Dust 2 `docker run` examples pass the flag. Podman, Quadlet and Apple `container` were unaffected
- `docker.yml` now starts the image and fails unless HLDS reports a Steam connection

### Changed
- Health check now runs `scripts/healthcheck.sh` (`/healthcheck.sh` in the image): `hlds_linux` must be running and answer a ping query (A2A_PING) on its port, which the engine does in every configuration, `NOMASTER=1` included (it leaves A2S_INFO unanswered). The old check only looked for the process, so a hung server stayed healthy and Quadlet's `Notify=healthy` fired before the port was open. The Quadlet unit gets `TimeoutStartSec=180` to allow for that; `docker.yml` runs the check in its smoke test
- `nightly.yml` image rebuild and Trivy scan now run weekly (Monday 00:00 UTC) instead of daily; the `nightly` tag name is unchanged
- `ci.yml` and `docker.yml` cancel superseded pull request runs
- justfile selects its engine via `CONTAINER_ENGINE` (default: Apple `container` on macOS, `podman` elsewhere). Every recipe has a `container` branch (build/run flags mirror `compose.yml`; service recipes delegate to `ops/cs-server`); the Podman commands are unchanged
- i386 library installation in both Containerfile stages moved into `scripts/i386-compat.sh` (same packages on amd64)
- `docker.yml` also triggers on `scripts/**`
- `install.sh` exits early on macOS and points to `ops/cs-server install` (it relies on systemd and the amd64-only ghcr.io image)
- `hlds` user is now created with a fixed uid/gid (10001) and `USER` references it numerically, making bind-mount ownership deterministic under rootless Podman and resolving hadolint `DL3066`
- `HEALTHCHECK` `CMD` converted to JSON/exec notation (`/bin/sh -c ...`), resolving hadolint `DL3025`
- Bumped `hadolint/hadolint-action` in `ci.yml` from v3.3.0 to v3.4.0 (hadolint 2.14.0 → 2.15.0)
- `just lint` pins `ghcr.io/hadolint/hadolint:v2.15.0-debian` instead of tracking `:latest`, so local linting and CI run the same ruleset
- Dependabot no longer opens minor/patch PRs for `actions/*`, `docker/*` and `github/codeql-action`, which are pinned at the major tag on purpose
- Bumped AMX Mod X pin from build 5478 to 5487, then to 5488
- Bumped shellcheck pin in `ci.yml` from v0.10.0 to v0.11.0
- README stack list resynced to the versions actually pinned in the Containerfile (ReHLDS 3.15.0.896, ReGameDLL_CS 5.30.0.814, ReAPI 5.29.0.358, AMX Mod X build 5488)
- Migrated base images from Debian 12 (Bookworm) to Debian 13 (Trixie) in both builder and runtime stages
- AMX Mod X plugin compile loop fails fast (`|| exit 1`) on any plugin error
- Quadlet `Volume` paths updated from hardcoded `~/Development/cs-server/` to `~/.config/cs-server/` to match `install.sh` behaviour

### Added
- Releases: pushing a `v*.*.*` tag makes `docker.yml` tag the multi-arch image `X.Y.Z`, `X.Y` and `X` and create a GitHub release whose notes are that version's section of this file (`scripts/release-notes.sh`, tested in `tests/release_notes_test.sh`) plus the image digest, with the SBOM attached (#70)
- `install.sh`: `CS_SERVER_VERSION` (`1.0.0`, `1.0` or `1`) pins a release; the installer prints the digest of the image it pulled, and re-running it on a running server restarts it onto the new image, which makes it the upgrade and rollback path. `CS_AUTO_UPDATE=1` (Podman) adds `AutoUpdate=registry` and enables `podman-auto-update.timer`. README gains "Releases, upgrade and rollback" (#70)
- `tests/e2e_test.sh` (`just e2e`, and a step in `docker.yml` on both architectures): boots the built image in LAN mode and drives the live server through its console FIFO. Checks that every Metamod and AMX Mod X plugin is running, the health check, bots joining, `sk_switchmode` in both directions (cvars, `mapcyclefile` and `localinfo sk_mode` after the changelevel) and its error paths, every mapcycle map present in the image, no AMX Mod X run-time errors, and a graceful shutdown. Player-only behaviour (loadouts, buy/pickup blocking, RTV, kickers) is not covered
- Script tests in `just test` and `ci.yml`: `mode_test.sh` (Friday window, Christmas rotation, and the systemd/launchd schedule hours matching `mode.sh`), `shutdown_test.sh` (SIGTERM/SIGINT countdown, `quit`, exit 0, FIFO permissions), `fetch_maps_test.sh` (checksum pinning, zip extraction allow-list, manifest validation), `install_test.sh` (runtime detection, config seeding, `docker run` flags, uninstall, and the generated Quadlet unit matching `quadlet/scoutzknivez.container`) and `ops_test.sh` (the launchd wrapper). Engines, `systemctl`, `launchctl`, `curl` and `date` are stubbed
- ghcr.io images are now multi-arch (`linux/amd64` + `linux/arm64`). `docker.yml` and the weekly build run one native job per architecture (arm64 on `ubuntu-24.04-arm`), smoke-test and Trivy-scan each, push by digest and publish one manifest list. The arm64 job is the first CI coverage of the `qemu-i386` path. `build-and-scan` remains as a single check that requires both
- **Nipper Friday:** a knife-only mode on NIPPER's classic CS 1.6 maps, a tribute to the Friday knife nights his maps were made for. `scoutzknivez.sma` gains modes (`scoutz` | `knife`, kept in `localinfo sk_mode`) and `sk_switchmode`, which queues a mode or rotation change for the next round end with a chat announcement and no container restart. Knife mode blocks the scout, buying and weapon pickups; on `he_*` grenade maps the map's HE grenades can be picked up (`config/modes/knife_he.cfg`)
- `config/modes/<mode>.cfg` and `<mode>_<prefix>.cfg` exec'd after `server.cfg` on every map; `MODE` env (default `scoutz`)
- `scripts/mode.sh` (`just mode`, `cs-server mode`): `nipper` | `scoutz` | `auto`; uses `mapcycle-nipper-xmas.txt` (`xmas_nipperhouse`, `x-mas_tree`, `xmas_lodge`, `xmas_crazytank`) from Dec 1 to Jan 6
- Opt-in Friday schedule (Fri 17:00 to Sat 04:00 local): launchd agent (`cs-server friday enable`) on macOS, systemd user timer (`just friday-enable`) on Linux. Does nothing while the server is stopped
- `maps/manifest.tsv` + `scripts/fetch-maps.sh` (`just fetch-maps`): third-party maps pinned by SHA-256 with a license note, downloaded once into `.cache/maps/`; only each map's files and listed sounds are extracted. NIPPER's maps come from his own GameBanana upload (CC BY-NC-ND 4.0) and are not committed, baked into published images or put on FastDL
- `tests/mapcycle_test.sh` (in `just test` and `ci.yml`): fails when a mapcycle names a map that isn't bundled, stock or pinned
- Docs site, README and CHANGELOG credit NIPPER for the Nipper Friday maps, and the switch announcement and knife-mode hostname credit him in-game
- Apple silicon support via Apple `container`: an arm64 image that runs the i386 HLDS payload under `qemu-i386` user-mode emulation (Rosetta for Linux only translates x86_64). `scripts/i386-compat.sh` installs per-arch i386 libraries plus, on non-x86, a static `qemu-i386`, a `run-i386` build helper (also used as SteamCMD's `$DEBUGGER`) and an `hlds_linux` launcher that `entrypoint.sh` hands to `hlds_run -binary`
- `scripts/i386-qemu-shim.c`: `LD_PRELOAD` shim (arm64 only) that answers `get_robust_list` and redirects `/proc/cpuinfo`, the two qemu-user gaps that crash `steamclient.so` and SteamCMD. With it, arm64 builds run SteamCMD and `amxxpc` under emulation and need nothing from ghcr.io
- Runtime image (all architectures) includes `ca-certificates`; without a CA bundle `steamclient.so` can't reach Steam and the server reports `disconnected from Steam3`
- `ops/cs-server` + `ops/launchd/com.kevintcoughlin.cs-server.plist`: launchd service for macOS (install/status/logs/restart/stop/rcon/update/uninstall), the counterpart of the Quadlet unit
- "macOS / Apple silicon" docs in README, docs site, CONTRIBUTING and CLAUDE.md
- `#pragma semicolon 1` added to all six first-party AMX Mod X plugins for forward-compatibility enforcement
- `autobhop.sma`: replaced per-frame `get_pcvar_num` call with `bind_pcvar_num`-bound integer to eliminate cvar-handle overhead in the hot physics loop
- `scoutzknivez.sma`: explicit `HAM_IGNORED` return values; all statements now carry semicolons
- Explicit `platforms: linux/amd64` on all `docker/build-push-action` calls in `docker.yml` and `nightly.yml`
- Container smoke test in `docker.yml` — verifies `hlds_linux`, `hlds_run`, and `entrypoint.sh` are present and executable after build
- `install.sh` added to shellcheck step in `ci.yml` and `just shellcheck`
- `Notify=healthy` added to Quadlet unit so systemd waits for container health before marking the service started
- Public server mode is now explicit via `LAN_MODE=0`; set `LAN_MODE=1` for LAN-only deployments
- Installer, Compose, and Quadlet runtime settings are aligned
- Installer accepts `CS_SERVER_IMAGE` for immutable digest-pinned production deployments
- Host-tuning guidance now treats kernel and CPU-governor changes as benchmarked operator decisions
- Installer generates a random RCON password for new deployments and documents host/provider DDoS responsibilities
- New `version-check.yml` workflow — runs weekly, checks ReHLDS / ReGameDLL_CS / Metamod-R / ReAPI / AMX Mod X against upstream releases and exits non-zero when any component is behind
- justfile for composable build/run/deploy commands
- GitHub Actions CI: container build, Trivy scan, SBOM, ghcr.io publish
- Dependabot for GitHub Actions and Docker base image updates
- Issue and PR templates
- OCI container labels
- Container health check
- SPDX license identifiers in source files
- .editorconfig for consistent formatting
- .env.example documenting environment variables
- Quadlet systemd unit file shipped in-repo

[Unreleased]: https://github.com/KevinTCoughlin/cs-server/compare/v1.4.2...HEAD
[1.4.2]: https://github.com/KevinTCoughlin/cs-server/compare/v1.4.1...v1.4.2
[1.4.1]: https://github.com/KevinTCoughlin/cs-server/compare/v1.4.0...v1.4.1
[1.4.0]: https://github.com/KevinTCoughlin/cs-server/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/KevinTCoughlin/cs-server/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/KevinTCoughlin/cs-server/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/KevinTCoughlin/cs-server/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/KevinTCoughlin/cs-server/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/KevinTCoughlin/cs-server/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/KevinTCoughlin/cs-server/releases/tag/v1.0.0
