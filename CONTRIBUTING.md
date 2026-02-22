# Contributing to CS Server

PRs welcome! This is a community Counter-Strike 1.6 server project. Keep changes focused and tested.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Podman](https://podman.io/getting-started/installation) | 4.0+ | Container runtime |
| [Podman Compose](https://github.com/containers/podman-compose) | latest | Multi-container orchestration |
| [just](https://github.com/casey/just#installation) | latest | Task runner |
| [shellcheck](https://github.com/koalaman/shellcheck#installing) | latest | Shell script linter |
| [hadolint](https://github.com/hadolint/hadolint#install) | latest | Containerfile linter (optional) |

## Setup

```bash
git clone https://github.com/KevinTCoughlin/cs-server.git
cd cs-server
cp .env.example .env
```

You'll need map files (`.bsp`) in the `maps/` directory — these are gitignored due to size. See the README for details.

## Common Commands

```bash
just build       # build container image
just up          # build and start server (attached)
just up-d        # build and start server (detached)
just down        # stop server
just logs        # follow server logs
just shell       # exec into running container
just check       # run all linters (hadolint + shellcheck)
just clean       # remove built images
```

## Project Layout

```
Containerfile              Multi-stage build (SteamCMD + ReHLDS stack)
compose.yml                Podman Compose service definition
entrypoint.sh              Container startup and graceful shutdown
config/                    Server configuration files
maps/                      BSP map files (gitignored)
plugins/amxmodx/           AMX Mod X plugin config and source
plugins/metamod/           Metamod plugin list
quadlet/                   Systemd Quadlet unit file
```

## Plugin Development

Custom gameplay is implemented via AMX Mod X plugins (Pawn language):

1. Edit `plugins/amxmodx/scripting/scoutzknivez.sma`
2. Rebuild the container — the builder stage compiles `.sma` → `.amxx` automatically
3. Test with `just up`

To add a new plugin:

1. Add the `.sma` source to `plugins/amxmodx/scripting/`
2. Add a `COPY` + compile step to `Containerfile` (follow the existing `scoutzknivez.sma` pattern)
3. Register it in `plugins/amxmodx/plugins.ini`

## Submitting Changes

1. Fork the repo and create a branch from `main`.
2. Make your changes — keep diffs small and focused.
3. Run `just check` to verify linting passes.
4. Test by building and running the server locally (`just up`).
5. Open a pull request against `main`.

CI runs hadolint, shellcheck, container build, and Trivy security scan automatically on every PR.

## Style Guide

- Shell scripts must be shellcheck-clean (`just shellcheck`).
- Containerfile must be hadolint-clean (`just lint`).
- Add SPDX license headers to new source files.
- Pin dependency versions as `ARG` in Containerfile — never use `latest` tags for upstream components.
- Keep configs minimal — only set values that differ from defaults.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
