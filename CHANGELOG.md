# Changelog

## [Unreleased]

### Changed
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
- Bumped AMX Mod X pin from build 5478 to 5487
- Bumped shellcheck pin in `ci.yml` from v0.10.0 to v0.11.0
- README stack list resynced to the versions actually pinned in the Containerfile (ReHLDS 3.15.0.896, ReGameDLL_CS 5.30.0.814, ReAPI 5.29.0.358, AMX Mod X build 5487)
- Migrated base images from Debian 12 (Bookworm) to Debian 13 (Trixie) in both builder and runtime stages
- AMX Mod X plugin compile loop fails fast (`|| exit 1`) on any plugin error
- Quadlet `Volume` paths updated from hardcoded `~/Development/cs-server/` to `~/.config/cs-server/` to match `install.sh` behaviour

### Added
- Apple silicon support via Apple `container`: an arm64 image that runs the i386 HLDS payload under `qemu-i386` user-mode emulation (Rosetta for Linux only translates x86_64). `scripts/i386-compat.sh` installs per-arch i386 libraries plus, on non-x86, a static `qemu-i386`, a `run-i386` build helper (also used as SteamCMD's `$DEBUGGER`) and an `hlds_linux` launcher that `entrypoint.sh` hands to `hlds_run -binary`
- `scripts/i386-qemu-shim.c`: `LD_PRELOAD` shim (arm64 only) that answers `get_robust_list` and redirects `/proc/cpuinfo`, the two qemu-user gaps that crash `steamclient.so` and SteamCMD. With it, arm64 builds run SteamCMD and `amxxpc` under emulation and need nothing from ghcr.io
- arm64 runtime includes `ca-certificates`; without them `steamclient.so` can't reach Steam (`disconnected from Steam3`)
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
