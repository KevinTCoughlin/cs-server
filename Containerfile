# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# =============================================================================
# CS 1.6 ScoutzKnivez Server — Multi-stage Debian 13 Build
# ReHLDS + ReGameDLL_CS + Metamod-R + AMX Mod X + ReAPI
#
# --build-arg GAME=<name> builds another GoldSrc game instead (czero, dod,
# tfc, valve, gearbox, dmc, ricochet): the same engine, Metamod-R and AMX Mod X
# around that game's library, with its stock maps and settings and without
# the ScoutzKnivez content. scripts/game-env.sh is the table of games.
# =============================================================================

# The game directory under /hlds.
ARG GAME=cstrike

# Pinned versions
ARG REHLDS_VERSION=3.15.0.896
ARG REGAMEDLL_VERSION=5.30.0.814
ARG METAMOD_VERSION=1.3.0.149
ARG REAPI_VERSION=5.29.0.358
ARG AMXMODX_BUILD=5488

# ---------------------------------------------------------------------------
# Stage 1: Builder — SteamCMD + HLDS + ReHLDS stack
# ---------------------------------------------------------------------------
# Runtime choice: Debian 13 "Trixie" is optimal for CS 1.6 servers in 2026:
# - 5-year security support (until ~2030) ensures long-term maintenance
# - Runs on the host's kernel; the container only supplies user-space libraries
# - Full i386/32-bit support required for HLDS binaries
# - Minimal image size (~25-30MB for slim variant)
# - glibc compatibility (Alpine's musl would require workarounds)
# Alternatives rejected: Bookworm (shorter support), Ubuntu (larger), Alpine (glibc issues)
FROM debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6 AS builder

ARG REHLDS_VERSION
ARG REGAMEDLL_VERSION
ARG METAMOD_VERSION
ARG REAPI_VERSION
ARG AMXMODX_BUILD

ENV DEBIAN_FRONTEND=noninteractive

# i386 libraries are arch-specific. --runner adds run-i386, which executes
# build-time i386 tools (SteamCMD, amxxpc): a plain exec on x86, qemu-i386
# with the Steam compatibility shim on arm64 (see scripts/i386-compat.sh).
# Bind only the two files it reads: a bind mount's contents are part of the
# cache key, so mounting all of scripts/ made an edit to mode.sh or
# fetch-maps.sh re-run SteamCMD and the whole HLDS download below.
RUN --mount=type=bind,source=scripts/i386-compat.sh,target=/usr/local/src/cs-server/i386-compat.sh \
    --mount=type=bind,source=scripts/i386-qemu-shim.c,target=/usr/local/src/cs-server/i386-qemu-shim.c \
    bash /usr/local/src/cs-server/i386-compat.sh install --runner \
        ca-certificates \
        curl \
        patchelf \
        unzip \
        tar \
    && rm -rf /var/lib/apt/lists/*

# Install SteamCMD
RUN mkdir -p /opt/steamcmd && \
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        -o /opt/steamcmd/steamcmd_linux.tar.gz && \
    tar -xzf /opt/steamcmd/steamcmd_linux.tar.gz -C /opt/steamcmd && \
    rm -f /opt/steamcmd/steamcmd_linux.tar.gz

# Declared here, not at the top of the stage, so the layers above are shared
# by both games.
ARG GAME

# Download HLDS (app 90, steam_legacy beta)
# Run app_update multiple times — app 90 has a known bug where it doesn't
# download all files in a single pass
# steamcmd.sh launches the binary through $DEBUGGER (run-i386: a no-op exec
# on x86) and would pick the absent linuxarm64 build on arm64 without
# STEAM_PLATFORM=linux32 (the x86 default anyway).
# Steam's content servers now and then fail a download part way ("App '90'
# state is 0x10E after update job"); a second run picks up where it stopped.
RUN for attempt in 1 2 3; do \
        if DEBUGGER=run-i386 STEAM_PLATFORM=linux32 /opt/steamcmd/steamcmd.sh \
            +force_install_dir /hlds \
            +login anonymous \
            +app_set_config 90 mod "${GAME}" \
            +app_update 90 -beta steam_legacy validate \
            +app_update 90 -beta steam_legacy validate \
            +app_update 90 -beta steam_legacy validate \
            +quit; then \
            exit 0; \
        fi; \
        echo "SteamCMD failed (attempt ${attempt} of 3)" >&2; \
        sleep 15; \
    done; \
    exit 1

WORKDIR /hlds

# This game's row of the table; the runtime image keeps it for entrypoint.sh.
# Mounted after the download so editing the table does not repeat it.
RUN --mount=type=bind,source=scripts/game-env.sh,target=/usr/local/src/cs-server/game-env.sh \
    install -d /usr/local/share/cs-server && \
    bash /usr/local/src/cs-server/game-env.sh "${GAME}" > /usr/local/share/cs-server/game.env && \
    test -d "/hlds/${GAME}"

# --- ReHLDS (engine replacement) ---
RUN curl -fsSL "https://github.com/rehlds/ReHLDS/releases/download/${REHLDS_VERSION}/rehlds-bin-${REHLDS_VERSION}.zip" \
        -o /tmp/rehlds.zip && \
    unzip -o /tmp/rehlds.zip -d /tmp/rehlds && \
    cp /tmp/rehlds/bin/linux32/engine_i486.so \
       /tmp/rehlds/bin/linux32/hlds_linux \
       /tmp/rehlds/bin/linux32/core.so \
       /tmp/rehlds/bin/linux32/filesystem_stdio.so \
       /tmp/rehlds/bin/linux32/demoplayer.so \
       . && \
    patchelf --clear-execstack engine_i486.so && \
    patchelf --clear-execstack core.so && \
    rm -rf /tmp/rehlds /tmp/rehlds.zip

# --- ReGameDLL_CS (game DLL replacement; Counter-Strike and Condition Zero) ---
RUN . /usr/local/share/cs-server/game.env && [ "${GAME_REGAMEDLL}" != 1 ] || { curl -fsSL "https://github.com/rehlds/ReGameDLL_CS/releases/download/${REGAMEDLL_VERSION}/regamedll-bin-${REGAMEDLL_VERSION}.zip" \
        -o /tmp/regamedll.zip && \
    unzip -o /tmp/regamedll.zip -d /tmp/regamedll && \
    cp /tmp/regamedll/bin/linux32/cstrike/dlls/cs.so "${GAME}/dlls/cs.so" && \
    rm -rf /tmp/regamedll /tmp/regamedll.zip; }

# --- Metamod-R ---
RUN curl -fsSL "https://github.com/rehlds/Metamod-R/releases/download/${METAMOD_VERSION}/metamod-bin-${METAMOD_VERSION}.zip" \
        -o /tmp/metamod.zip && \
    unzip -o /tmp/metamod.zip -d /tmp/metamod && \
    mkdir -p "${GAME}/addons/metamod" && \
    cp /tmp/metamod/addons/metamod/metamod_i386.so "${GAME}/addons/metamod/" && \
    cp /tmp/metamod/addons/metamod/config.ini "${GAME}/addons/metamod/" && \
    rm -rf /tmp/metamod /tmp/metamod.zip

# --- AMX Mod X (base + the game's package, where there is one) ---
RUN . /usr/local/share/cs-server/game.env && curl -fsSL "https://www.amxmodx.org/amxxdrop/1.10/amxmodx-1.10.0-git${AMXMODX_BUILD}-base-linux.tar.gz" \
        -o /tmp/amxmodx-base.tar.gz && \
    tar -xzf /tmp/amxmodx-base.tar.gz -C "${GAME}/" && \
    if [ -n "${GAME_AMXX}" ]; then \
        curl -fsSL "https://www.amxmodx.org/amxxdrop/1.10/amxmodx-1.10.0-git${AMXMODX_BUILD}-${GAME_AMXX}-linux.tar.gz" \
            -o /tmp/amxmodx-game.tar.gz && \
        tar -xzf /tmp/amxmodx-game.tar.gz -C "${GAME}/" || exit 1; \
    fi && \
    rm -f /tmp/amxmodx-base.tar.gz /tmp/amxmodx-game.tar.gz

# --- ReAPI (AMX Mod X module for the ReHLDS/ReGameDLL API) ---
RUN . /usr/local/share/cs-server/game.env && [ "${GAME_REGAMEDLL}" != 1 ] || { curl -fsSL "https://github.com/rehlds/ReAPI/releases/download/${REAPI_VERSION}/reapi-bin-${REAPI_VERSION}.zip" \
        -o /tmp/reapi.zip && \
    unzip -o /tmp/reapi.zip -d /tmp/reapi && \
    cp /tmp/reapi/addons/amxmodx/modules/reapi_amxx_i386.so \
       "${GAME}/addons/amxmodx/modules/" && \
    cp /tmp/reapi/addons/amxmodx/scripting/include/*.inc \
       "${GAME}/addons/amxmodx/scripting/include/" 2>/dev/null || true && \
    rm -rf /tmp/reapi /tmp/reapi.zip; }

# --- CZ Bots (ZBot profiles + sounds from ReGameDLL_CS; Condition Zero has its own) ---
RUN [ "${GAME}" != cstrike ] || { curl -fsSL "https://raw.githubusercontent.com/rehlds/ReGameDLL_CS/${REGAMEDLL_VERSION}/regamedll/extra/zBot/bot_profiles.zip" \
        -o /tmp/bot_profiles.zip && \
    unzip -o /tmp/bot_profiles.zip -d . && \
    rm -f /tmp/bot_profiles.zip; }

# Every game but Counter-Strike (whose files come from config/ and plugins/)
# keeps its stock files with three changes: liblist.gam loads Metamod, which
# finds the game library itself; Metamod loads AMX Mod X; and server.cfg gets
# a hostname and the shared settings appended. A stock bot_quota line goes:
# server.cfg runs on every map and would undo the entrypoint's BOTS setting.
RUN --mount=type=bind,source=config/games/common.cfg,target=/usr/local/src/cs-server/common.cfg \
    . /usr/local/share/cs-server/game.env && \
    [ "${GAME}" = cstrike ] || { \
    sed -i 's|^gamedll_linux .*|gamedll_linux "addons/metamod/metamod_i386.so"|' "${GAME}/liblist.gam" && \
    grep -q '^gamedll_linux "addons/metamod/metamod_i386.so"' "${GAME}/liblist.gam" && \
    echo 'linux addons/amxmodx/dlls/amxmodx_mm_i386.so' > "${GAME}/addons/metamod/plugins.ini" && \
    printf '\n; cs-server\nmetrics.amxx\n' >> "${GAME}/addons/amxmodx/configs/plugins.ini" && \
    touch "${GAME}/server.cfg" "${GAME}/mapcycle.txt" && \
    sed -i -e '/^[[:space:]]*hostname[[:space:]]/d' -e '/^[[:space:]]*bot_quota[[:space:]]/d' "${GAME}/server.cfg" && \
    { printf '\nhostname "%s"\n' "${GAME_TITLE}"; cat /usr/local/src/cs-server/common.cfg; \
      [ "${GAME_BOTS}" != 1 ] || printf '\n// Bots play without waiting for a person to join\nbot_join_after_player 0\nbot_quota_mode "fill"\n'; \
    } >> "${GAME}/server.cfg" && \
    test -f "${GAME}/maps/${GAME_MAP}.bsp"; }

# tfc.so needs a newer C++ runtime (CXXABI_1.3.8) than the libstdc++ HLDS
# ships beside its binary, which the loader finds first. Without that copy it
# uses the system's 32-bit one, installed by i386-compat.sh.
#
# Valve's files are not all lower case (tfc/events/wpn/Tf_sg.sc) and the
# game asks for them in lower case. On x86 the engine finds them anyway; under
# qemu-i386 on arm64 it does not, and the server dies precaching the first
# map. A lower-case link next to each such file serves both.
RUN if [ "${GAME}" = tfc ]; then rm -f libstdc++.so.6 libgcc_s.so.1; fi && \
    if [ "${GAME}" != cstrike ]; then \
        find "${GAME}" -path "${GAME}/addons" -prune -o -type f -name '*[A-Z]*' -exec sh -c '\
            for file; do \
                name=${file##*/}; \
                link="${file%/*}/$(printf "%s" "${name}" | tr "[:upper:]" "[:lower:]")"; \
                [ -e "${link}" ] || ln -s "${name}" "${link}"; \
            done' sh {} +; \
    fi

# Ensure binaries are executable and set the game's Steam app id. The engine
# would write it at start, but the root filesystem is read-only: with
# Half-Life's 70 left here a Counter-Strike server signs on to Steam as the
# wrong game and every player is turned away ("STEAM validation rejected").
RUN . /usr/local/share/cs-server/game.env && \
    chmod +x hlds_linux hlds_run && \
    echo "${GAME_APPID}" > steam_appid.txt && \
    grep -qx '[0-9][0-9]' steam_appid.txt

# The builder stage ends here: /hlds is the ~1 GB engine + game payload and
# only changes with the pinned versions above. Repo content (maps, sounds,
# plugins, configs) is layered on top in the runtime stage, so editing it
# rebuilds a few small layers instead of re-copying all of /hlds.

# ---------------------------------------------------------------------------
# Stage 1b: Plugins — compile custom AMX Mod X plugins with the pinned amxxpc
# ---------------------------------------------------------------------------
FROM builder AS plugins

ARG GAME

# The custom plugins are Counter-Strike plugins, except metrics.sma, which
# every game gets on top of the stock AMX Mod X set.
COPY plugins/amxmodx/scripting/*.sma /usr/local/src/cs-server/scripting/
WORKDIR /hlds/${GAME}/addons/amxmodx/scripting
RUN chmod +x amxxpc && mkdir -p /out && \
    plugins="metrics.sma" && \
    if [ "${GAME}" = cstrike ]; then \
        plugins="scoutzknivez.sma match.sma autobhop.sma AQS.sma rtv.sma websitebot.sma afkkicker.sma highpingkicker.sma advertisements.sma metrics.sma"; \
    elif [ "${GAME}" = dod ]; then \
        plugins="metrics.sma dodmode.sma"; \
    fi && \
    for sma in ${plugins}; do \
        cp "/usr/local/src/cs-server/scripting/${sma}" . || exit 1; \
        run-i386 ./amxxpc "$sma" || exit 1; \
        mv "${sma%.sma}.amxx" /out/ || exit 1; \
    done

# ---------------------------------------------------------------------------
# Stage 2: Runtime — clean slim image, no build tools
# ---------------------------------------------------------------------------
# Using trixie-slim for minimal attack surface and optimal security posture
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS runtime-base

ENV DEBIAN_FRONTEND=noninteractive

# Prevent docs/man/locale from being installed (smaller image), but keep licenses
RUN printf 'path-exclude=/usr/share/doc/*\npath-include=/usr/share/doc/*/copyright\npath-include=/usr/share/doc/*/changelog.Debian*\npath-include=/usr/share/doc/*/LICENSE\npath-exclude=/usr/share/man/*\npath-exclude=/usr/share/locale/*\npath-exclude=/usr/share/bug/*\npath-exclude=/usr/share/lintian/*\npath-exclude=/usr/share/mime/*\npath-exclude=/usr/share/info/*\n' \
        > /etc/dpkg/dpkg.cfg.d/excludes

# i386 runtime libraries for this architecture; on non-x86 (arm64) also a
# static qemu-i386 + hlds_linux launcher (see scripts/i386-compat.sh)
RUN --mount=type=bind,source=scripts/i386-compat.sh,target=/usr/local/src/cs-server/i386-compat.sh \
    --mount=type=bind,source=scripts/i386-qemu-shim.c,target=/usr/local/src/cs-server/i386-qemu-shim.c \
    bash /usr/local/src/cs-server/i386-compat.sh install busybox-static \
    && rm -rf /var/lib/apt/lists/* \
              /var/cache/apt/archives/* \
              /var/log/dpkg.log \
              /var/log/apt \
              /var/log/bootstrap.log \
              /var/log/alternatives.log \
              /tmp/* \
              /var/tmp/* \
    && (find / -xdev -perm /6000 -type f -exec chmod a-s {} + 2>/dev/null || true)

# Fixed uid/gid so bind-mount ownership is deterministic under rootless Podman
RUN groupadd --system --gid 10001 hlds && \
    useradd --no-log-init --system --uid 10001 --gid 10001 -s /usr/sbin/nologin hlds

# Stable ~1 GB base first, then repo content ordered from least to most
# often edited, each its own small layer (see the end of the builder stage).
COPY --from=builder --chown=hlds:hlds /hlds /hlds

# ---------------------------------------------------------------------------
# Stage 2a: repo content for Counter-Strike
# ---------------------------------------------------------------------------
FROM runtime-base AS game-cstrike

# Bundled default maps, then any local custom maps overlaid on top.
COPY --chown=hlds:hlds docs/cstrike/maps/*.bsp docs/cstrike/maps/*.nav /hlds/cstrike/maps/
COPY --chown=hlds:hlds maps/ /hlds/cstrike/maps/
COPY --chown=hlds:hlds sound/ /hlds/cstrike/sound/

COPY --from=plugins --chown=hlds:hlds /out/ /hlds/cstrike/addons/amxmodx/plugins/
COPY --chown=hlds:hlds plugins/amxmodx/AQS.ini     /hlds/cstrike/addons/amxmodx/configs/AQS.ini
COPY --chown=hlds:hlds plugins/amxmodx/plugins.ini /hlds/cstrike/addons/amxmodx/configs/plugins.ini
COPY --chown=hlds:hlds plugins/amxmodx/modes/      /hlds/cstrike/addons/amxmodx/configs/modes/
COPY --chown=hlds:hlds plugins/metamod/plugins.ini /hlds/cstrike/addons/metamod/plugins.ini

COPY --chown=hlds:hlds config/liblist.gam   /hlds/cstrike/liblist.gam
COPY --chown=hlds:hlds config/game_init.cfg /hlds/cstrike/game_init.cfg
COPY --chown=hlds:hlds config/autoexec.cfg  /hlds/cstrike/autoexec.cfg
COPY --chown=hlds:hlds config/mapcycle*.txt /hlds/cstrike/
COPY --chown=hlds:hlds config/modes/        /hlds/cstrike/modes/
COPY --chown=hlds:hlds config/server.cfg    /hlds/cstrike/server.cfg

# core.ini names the plugin list (amxx_plugins) and would overwrite the one
# entrypoint.sh passes for a mode with its own list. Without the line AMX Mod X
# keeps a value that is already set and falls back to plugins.ini otherwise.
RUN sed -i '/^amxx_plugins[[:space:]]/d' /hlds/cstrike/addons/amxmodx/configs/core.ini && \
    ! grep -q '^amxx_plugins[[:space:]]' /hlds/cstrike/addons/amxmodx/configs/core.ini

# ---------------------------------------------------------------------------
# Stage 2b: the other games run their stock content, prepared in the builder.
# Day of Defeat replaces server.cfg and the map cycles with config/dod and
# turns on the DoD stats plugins (DoDX). The other games stay stock.
# ---------------------------------------------------------------------------
FROM runtime-base AS game-czero
FROM runtime-base AS game-dod
COPY --chown=hlds:hlds config/dod/server.cfg config/dod/pub.cfg config/dod/match.cfg config/dod/match-ot.cfg /hlds/dod/
COPY --chown=hlds:hlds config/dod/mapcycle.txt config/dod/mapcycle-match.txt /hlds/dod/
# Compiled for every game so this stage can copy it; only Day of Defeat loads it.
COPY --from=plugins --chown=hlds:hlds /out/dodmode.amxx /hlds/dod/addons/amxmodx/plugins/dodmode.amxx
# stats.amxx and stats_logging.amxx need DoDX. The addon ships them commented
# out; DoDX itself is in the auto-load section of modules.ini and loads when
# those plugins are enabled. Listing dodx a second time makes Metamod refuse
# it ("already loaded"), so it stays commented. Fail the build if a listed
# map is not in app 90, and say which check failed.
RUN set -eu; \
    ini=/hlds/dod/addons/amxmodx/configs/plugins.ini; \
    modules=/hlds/dod/addons/amxmodx/configs/modules.ini; \
    plug=/hlds/dod/addons/amxmodx/plugins; \
    for name in stats.amxx stats_logging.amxx; do \
        if [ ! -f "${plug}/${name}" ]; then \
            echo "Day of Defeat addon has no ${name}" >&2; \
            exit 1; \
        fi; \
        if grep -q "^${name}" "${ini}"; then \
            :; \
        elif grep -q "^;[[:space:]]*${name}" "${ini}"; then \
            sed -i "s/^;[[:space:]]*${name}/${name}/" "${ini}"; \
        else \
            printf '%s\n' "${name}" >> "${ini}"; \
        fi; \
    done; \
    grep -q "^stats.amxx" "${ini}"; \
    grep -q "^;dodx$" "${modules}"; \
    test -f /hlds/dod/addons/amxmodx/modules/dodx_amxx_i386.so; \
    grep -q '^dodmode.amxx' "${ini}" || printf '%s\n' dodmode.amxx >> "${ini}"; \
    for cycle in mapcycle.txt mapcycle-match.txt; do \
        while IFS= read -r map || [ -n "${map}" ]; do \
            case "${map}" in \
                "" | //*) continue ;; \
            esac; \
            map=${map%%[[:space:]]*}; \
            if [ ! -f "/hlds/dod/maps/${map}.bsp" ]; then \
                echo "mapcycle ${cycle} lists ${map}, which app 90 did not install" >&2; \
                exit 1; \
            fi; \
        done < "/hlds/dod/${cycle}"; \
    done
FROM runtime-base AS game-tfc
FROM runtime-base AS game-valve
FROM runtime-base AS game-gearbox
FROM runtime-base AS game-dmc
FROM runtime-base AS game-ricochet

# ---------------------------------------------------------------------------
# Stage 3: the image — the chosen game's content plus what both share
# ---------------------------------------------------------------------------
# A stage of this file, not a registry image.
# hadolint ignore=DL3006
FROM game-${GAME} AS runtime

# entrypoint.sh reads the game's row of the table from game.env.
ARG GAME
COPY --from=builder /usr/local/share/cs-server/game.env /usr/local/share/cs-server/game.env

COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 scripts/healthcheck.sh /healthcheck.sh
COPY --chmod=755 scripts/fastdl.sh /fastdl.sh
COPY --chmod=755 scripts/metrics.pl /metrics.pl
# Counter-Strike has it from its own plugin copy above; same file.
COPY --from=plugins --chown=hlds:hlds /out/metrics.amxx /hlds/${GAME}/addons/amxmodx/plugins/metrics.amxx

# Everything the server writes at run time lives under /hlds/state, so one
# volume there keeps bans, admins, stats and logs across container
# replacement and the rest of the image can be mounted read-only. HLDS and
# AMX Mod X only know their own paths, so those become symlinks into it;
# entrypoint.sh creates the targets. users.ini is the one file with shipped
# content: its default is kept aside to seed a new volume. /hlds/.runtime
# (console FIFO) points into /tmp for the same reason. The bots write a
# navigation mesh for any map that ships without one, straight to
# <game>/maps/<map>.nav: each such map gets a link, so the mesh is built
# once and kept. Without it the save fails and the map reloads in a loop.
RUN . /usr/local/share/cs-server/game.env && \
    cs="/hlds/${GAME}" && amx="${cs}/addons/amxmodx" && \
    install -d -o hlds -g hlds /hlds/state && \
    install -d /usr/local/share/cs-server && \
    mv "${amx}/configs/users.ini" /usr/local/share/cs-server/users.ini && \
    chmod 644 /usr/local/share/cs-server/users.ini && \
    rm -rf "${amx}/logs" "${cs}/logs" && \
    ln -s /hlds/state/banned.cfg            "${cs}/banned.cfg" && \
    ln -s /hlds/state/listip.cfg            "${cs}/listip.cfg" && \
    ln -s /hlds/state/logs                  "${cs}/logs" && \
    ln -s /hlds/state/amxmodx/users.ini     "${amx}/configs/users.ini" && \
    ln -s /hlds/state/amxmodx/cmdaccess.ini "${amx}/configs/cmdaccess.ini" && \
    ln -s /hlds/state/amxmodx/logs          "${amx}/logs" && \
    { [ -z "${GAME_STATS}" ] || ln -s "/hlds/state/amxmodx/${GAME_STATS}" "${amx}/data/${GAME_STATS}"; } && \
    ln -s /hlds/state/amxmodx/vault.ini     "${amx}/data/vault.ini" && \
    ln -s /hlds/state/amxmodx/vault         "${amx}/data/vault" && \
    ln -s /tmp/hlds-runtime                 /hlds/.runtime && \
    ln -s /hlds/.runtime/metrics.prom       "${amx}/data/metrics.prom" && \
    if [ "${GAME_BOTS}" = 1 ]; then \
        for bsp in "${cs}"/maps/*.bsp; do \
            nav="${bsp%.bsp}.nav"; \
            [ -e "${nav}" ] || ln -s "/hlds/state/nav/${nav##*/}" "${nav}"; \
        done; \
    fi

# Docker's upstream default seccomp profile. Nothing current uses it:
# install.sh from 1.1 to 1.4 reads it out of the image for `docker run` and
# would otherwise run unconfined (see ops/seccomp/README.md).
COPY --chmod=644 ops/seccomp/docker-default.json /usr/local/share/cs-server/seccomp.json

# Create Steam SDK symlink for steamclient.so (fixes Docker Desktop on Windows)
#
# The FastDL tree (scripts/fastdl.sh serves it): links to what a client
# downloads from a server and to nothing else. No settings, ban lists, admin
# files or plugins.
RUN . /usr/local/share/cs-server/game.env && \
    mkdir -p /home/hlds/.steam/sdk32 && \
    ln -s /hlds/steamclient.so /home/hlds/.steam/sdk32/steamclient.so && \
    chown -R hlds:hlds /home/hlds && \
    fastdl="/usr/local/share/cs-server/fastdl/${GAME}" && \
    mkdir -p "${fastdl}" && \
    for dir in maps sound sprites models gfx overviews; do \
        [ ! -d "/hlds/${GAME}/${dir}" ] || ln -s "/hlds/${GAME}/${dir}" "${fastdl}/${dir}"; \
    done && \
    for wad in "/hlds/${GAME}"/*.wad; do \
        [ ! -e "${wad}" ] || ln -s "${wad}" "${fastdl}/"; \
    done && \
    test -e "${fastdl}/maps/${GAME_MAP}.bsp"

LABEL io.github.kevintcoughlin.cs-server.game="${GAME}" \
      org.opencontainers.image.title="cs-server (${GAME})" \
      org.opencontainers.image.description="Containerized GoldSrc dedicated server (Counter-Strike 1.6 ScoutzKnivez by default) using the ReHLDS stack" \
      org.opencontainers.image.source="https://github.com/KevinTCoughlin/cs-server" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="KevinTCoughlin"

USER 10001:10001
WORKDIR /hlds

EXPOSE 27015/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
