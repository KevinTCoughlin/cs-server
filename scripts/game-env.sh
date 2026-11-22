#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# The table of games the Containerfile can build (--build-arg GAME=<name>):
#
#   scripts/game-env.sh <game>
#
# prints shell assignments for that game. The build reads them to decide what
# to install, and the image keeps them at /usr/local/share/cs-server/game.env
# for entrypoint.sh. To add a game, add a row here and a `game-<name>` line
# in the Containerfile.
#
#   GAME            game directory under /hlds (SteamCMD's `mod` value)
#   GAME_TITLE      default hostname
#   GAME_MAP        default map
#   GAME_AMXX       AMX Mod X game package (empty: the base package only)
#   GAME_REGAMEDLL  1: ReGameDLL_CS and ReAPI replace the game library
#   GAME_BOTS       1: the game library has bots (bot_quota)
#   GAME_STATS      stats file a stats module writes under amxmodx/data
set -euo pipefail

game="${1:-}"
amxx="" regamedll=0 bots=0 stats=""
case "${game}" in
    cstrike)  title="Counter-Strike";     map=scoutzknivez; amxx=cstrike; regamedll=1; bots=1; stats=csstats.dat ;;
    czero)    title="Condition Zero";     map=de_dust2_cz;  amxx=cstrike; regamedll=1; bots=1; stats=csstats.dat ;;
    dod)      title="Day of Defeat";      map=dod_anzio;    amxx=dod;     stats=dodstats.dat ;;
    tfc)      title="Team Fortress Classic"; map=2fort;     amxx=tfc;     stats=tfcstats.dat ;;
    valve)    title="Half-Life";          map=crossfire ;;
    gearbox)  title="Opposing Force";     map=op4_bootcamp ;;
    dmc)      title="Deathmatch Classic"; map=dmc_dm2 ;;
    ricochet) title="Ricochet";           map=rc_arena ;;
    *)
        echo "game-env.sh: unknown game '${game}' (cstrike, czero, dod, tfc, valve, gearbox, dmc, ricochet)" >&2
        exit 1
        ;;
esac

cat <<ENV
GAME=${game}
GAME_TITLE="${title}"
GAME_MAP=${map}
GAME_AMXX=${amxx}
GAME_REGAMEDLL=${regamedll}
GAME_BOTS=${bots}
GAME_STATS=${stats}
ENV
