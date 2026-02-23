# FastDL Content

This directory is served via GitHub Pages at:

    https://kevintcoughlin.com/cs-server/cstrike/

CS 1.6 clients download custom content (maps, sounds) from here instead of the game server's slow (~5 KB/s) built-in transfer.

## Populating

Run `just fastdl` from the project root to sync files:

```bash
# Place your content in the source directories first:
#   sound/quake/*.wav   — Quake sound effects
#   maps/*.bsp          — Map files
#   maps/*.nav          — Bot navigation meshes

just fastdl
```

This copies files into `docs/cstrike/` and creates `.bz2` compressed variants (GoldSrc clients try `.bz2` first, ~70% smaller).

## Directory Structure

```
docs/cstrike/
  sound/quake/
    headshot.wav
    headshot.wav.bz2
    ...
  maps/
    scoutzknivez.bsp
    scoutzknivez.bsp.bz2
    ...
```

## Deploying

Commit and push to `main` — GitHub Pages auto-deploys from `docs/`.

## Notes

- These files are NOT affected by the root `.gitignore` (those patterns match `maps/*.bsp` and `sound/quake/*.wav` relative to root, not `docs/cstrike/`)
- Sound files may be copyrighted — your call what to commit
- Community maps (scoutzknivez variants) are generally freely redistributable
