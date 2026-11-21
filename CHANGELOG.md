# Changelog

## [Unreleased]

### Changed (behaviour)
- **FastDL URL is a setting.** `config/server.cfg` no longer sets `sv_downloadurl` to this project's site. The new `FASTDL_URL` environment variable (empty by default) sets it, on the HLDS command line so that the per-map re-run of `server.cfg` cannot override it; `entrypoint.sh` and `install.sh` reject anything that is not a plain http(s) URL. Wired into `compose.yml`, `.env.example`, `install.sh` (Quadlet unit and `docker run`) and the macOS env file. An install whose `server.cfg` already has the line keeps it. To keep the old behaviour on a rebuilt image, set `FASTDL_URL=https://kevintcoughlin.com/cs-server/cstrike/` (#75)
- **No rcon password by default.** `install.sh` and `ops/cs-server` no longer generate an `rcon_password`: the engine refuses network rcon without one, and the console FIFO (`just rcon`, `cs-server rcon`) needs none. `CS_RCON=1` at install generates one as before. Existing `server.cfg` files are not touched (#76)
- **27015/tcp is no longer published or exposed.** GoldSrc uses UDP for the game, queries and rcon; a running server has no TCP listener on the game port (checked in `tests/e2e_test.sh`). Removed from `compose.yml`, the Quadlet unit, `install.sh`, the justfile, `ops/cs-server`, `EXPOSE` and the docs. Firewall rules for 27015/tcp can go (#77)

### Fixed
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
