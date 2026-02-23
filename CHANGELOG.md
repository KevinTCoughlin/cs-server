# Changelog

## [Unreleased]

### Changed
- Migrated base images from Debian 12 (Bookworm) to Debian 13 (Trixie) in both builder and runtime stages
- Pinned base image `FROM` lines to OCI manifest digests for fully reproducible builds
- `amxxpc` now invoked with `-O2` optimisation flag; compile loop fails fast (`|| exit 1`) on any plugin error
- Quadlet `Volume` paths updated from hardcoded `~/Development/cs-server/` to `~/.config/cs-server/` to match `install.sh` behaviour

### Added
- `#pragma semicolon 1` added to all six first-party AMX Mod X plugins for forward-compatibility enforcement
- `autobhop.sma`: replaced per-frame `get_pcvar_num` call with `bind_pcvar_num`-bound integer to eliminate cvar-handle overhead in the hot physics loop
- `scoutzknivez.sma`: explicit `HAM_IGNORED` return values; all statements now carry semicolons
- Explicit `platforms: linux/amd64` on all `docker/build-push-action` calls in `docker.yml` and `nightly.yml`
- Container smoke test in `docker.yml` — verifies `hlds_linux`, `hlds_run`, and `entrypoint.sh` are present and executable after build
- `install.sh` added to shellcheck step in `ci.yml` and `just shellcheck`
- `Notify=healthy` added to Quadlet unit so systemd waits for container health before marking the service started
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
