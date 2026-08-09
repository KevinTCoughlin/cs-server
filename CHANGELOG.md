# Changelog

## [Unreleased]

### Changed
- `hlds` user is now created with a fixed uid/gid (10001) and `USER` references it numerically, making bind-mount ownership deterministic under rootless Podman and resolving hadolint `DL3066`
- `HEALTHCHECK` `CMD` converted to JSON/exec notation (`/bin/sh -c ...`), resolving hadolint `DL3025`
- Bumped `hadolint/hadolint-action` in `ci.yml` from v3.3.0 to v3.4.0 (hadolint 2.14.0 → 2.15.0)
- `just lint` pins `ghcr.io/hadolint/hadolint:v2.15.0-debian` instead of tracking `:latest`, so local linting and CI run the same ruleset
- Dependabot no longer opens minor/patch PRs for `actions/*`, `docker/*` and `github/codeql-action`, which are pinned at the major tag on purpose
- Bumped AMX Mod X pin from build 5478 to 5479
- Bumped shellcheck pin in `ci.yml` from v0.10.0 to v0.11.0
- README stack list resynced to the versions actually pinned in the Containerfile (ReHLDS 3.15.0.896, ReGameDLL_CS 5.30.0.814, ReAPI 5.29.0.358, AMX Mod X build 5479)
- Migrated base images from Debian 12 (Bookworm) to Debian 13 (Trixie) in both builder and runtime stages
- AMX Mod X plugin compile loop fails fast (`|| exit 1`) on any plugin error
- Quadlet `Volume` paths updated from hardcoded `~/Development/cs-server/` to `~/.config/cs-server/` to match `install.sh` behaviour

### Added
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
