# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
#
# =============================================================================
# CS 1.6 ScoutzKnivez Server — Multi-stage Debian 13 Build
# ReHLDS + ReGameDLL_CS + Metamod-R + AMX Mod X + ReAPI
# =============================================================================

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

# Download HLDS (app 90, steam_legacy beta)
# Run app_update multiple times — app 90 has a known bug where it doesn't
# download all files in a single pass
# steamcmd.sh launches the binary through $DEBUGGER (run-i386: a no-op exec
# on x86) and would pick the absent linuxarm64 build on arm64 without
# STEAM_PLATFORM=linux32 (the x86 default anyway).
RUN DEBUGGER=run-i386 STEAM_PLATFORM=linux32 /opt/steamcmd/steamcmd.sh \
        +force_install_dir /hlds \
        +login anonymous \
        +app_set_config 90 mod cstrike \
        +app_update 90 -beta steam_legacy validate \
        +app_update 90 -beta steam_legacy validate \
        +app_update 90 -beta steam_legacy validate \
        +quit

WORKDIR /hlds

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

# --- ReGameDLL_CS (game DLL replacement) ---
RUN curl -fsSL "https://github.com/rehlds/ReGameDLL_CS/releases/download/${REGAMEDLL_VERSION}/regamedll-bin-${REGAMEDLL_VERSION}.zip" \
        -o /tmp/regamedll.zip && \
    unzip -o /tmp/regamedll.zip -d /tmp/regamedll && \
    cp /tmp/regamedll/bin/linux32/cstrike/dlls/cs.so cstrike/dlls/cs.so && \
    rm -rf /tmp/regamedll /tmp/regamedll.zip

# --- Metamod-R ---
RUN curl -fsSL "https://github.com/rehlds/Metamod-R/releases/download/${METAMOD_VERSION}/metamod-bin-${METAMOD_VERSION}.zip" \
        -o /tmp/metamod.zip && \
    unzip -o /tmp/metamod.zip -d /tmp/metamod && \
    mkdir -p cstrike/addons/metamod && \
    cp /tmp/metamod/addons/metamod/metamod_i386.so cstrike/addons/metamod/ && \
    cp /tmp/metamod/addons/metamod/config.ini cstrike/addons/metamod/ && \
    rm -rf /tmp/metamod /tmp/metamod.zip

# --- AMX Mod X (base + cstrike addon) ---
RUN curl -fsSL "https://www.amxmodx.org/amxxdrop/1.10/amxmodx-1.10.0-git${AMXMODX_BUILD}-base-linux.tar.gz" \
        -o /tmp/amxmodx-base.tar.gz && \
    curl -fsSL "https://www.amxmodx.org/amxxdrop/1.10/amxmodx-1.10.0-git${AMXMODX_BUILD}-cstrike-linux.tar.gz" \
        -o /tmp/amxmodx-cs.tar.gz && \
    tar -xzf /tmp/amxmodx-base.tar.gz -C cstrike/ && \
    tar -xzf /tmp/amxmodx-cs.tar.gz -C cstrike/ && \
    rm -f /tmp/amxmodx-base.tar.gz /tmp/amxmodx-cs.tar.gz

# --- ReAPI (AMX Mod X module for ReHLDS/ReGameDLL API) ---
RUN curl -fsSL "https://github.com/rehlds/ReAPI/releases/download/${REAPI_VERSION}/reapi-bin-${REAPI_VERSION}.zip" \
        -o /tmp/reapi.zip && \
    unzip -o /tmp/reapi.zip -d /tmp/reapi && \
    cp /tmp/reapi/addons/amxmodx/modules/reapi_amxx_i386.so \
       cstrike/addons/amxmodx/modules/ && \
    cp /tmp/reapi/addons/amxmodx/scripting/include/*.inc \
       cstrike/addons/amxmodx/scripting/include/ 2>/dev/null || true && \
    rm -rf /tmp/reapi /tmp/reapi.zip

# --- CZ Bots (ZBot profiles + sounds from ReGameDLL_CS) ---
RUN curl -fsSL "https://raw.githubusercontent.com/rehlds/ReGameDLL_CS/${REGAMEDLL_VERSION}/regamedll/extra/zBot/bot_profiles.zip" \
        -o /tmp/bot_profiles.zip && \
    unzip -o /tmp/bot_profiles.zip -d . && \
    rm -f /tmp/bot_profiles.zip

# Ensure binaries are executable and set Steam app ID
RUN chmod +x hlds_linux hlds_run && \
    echo 70 > steam_appid.txt

# The builder stage ends here: /hlds is the ~1 GB engine + game payload and
# only changes with the pinned versions above. Repo content (maps, sounds,
# plugins, configs) is layered on top in the runtime stage, so editing it
# rebuilds a few small layers instead of re-copying all of /hlds.

# ---------------------------------------------------------------------------
# Stage 1b: Plugins — compile custom AMX Mod X plugins with the pinned amxxpc
# ---------------------------------------------------------------------------
FROM builder AS plugins

COPY plugins/amxmodx/scripting/*.sma /hlds/cstrike/addons/amxmodx/scripting/
WORKDIR /hlds/cstrike/addons/amxmodx/scripting
RUN chmod +x amxxpc && mkdir -p /out && \
    for sma in scoutzknivez.sma autobhop.sma AQS.sma rtv.sma websitebot.sma afkkicker.sma highpingkicker.sma advertisements.sma; do \
        run-i386 ./amxxpc "$sma" || exit 1; \
        mv "${sma%.sma}.amxx" /out/ || exit 1; \
    done

# ---------------------------------------------------------------------------
# Stage 2: Runtime — clean slim image, no build tools
# ---------------------------------------------------------------------------
# Using trixie-slim for minimal attack surface and optimal security posture
FROM debian:trixie-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# Prevent docs/man/locale from being installed (smaller image), but keep licenses
RUN printf 'path-exclude=/usr/share/doc/*\npath-include=/usr/share/doc/*/copyright\npath-include=/usr/share/doc/*/changelog.Debian*\npath-include=/usr/share/doc/*/LICENSE\npath-exclude=/usr/share/man/*\npath-exclude=/usr/share/locale/*\npath-exclude=/usr/share/bug/*\npath-exclude=/usr/share/lintian/*\npath-exclude=/usr/share/mime/*\npath-exclude=/usr/share/info/*\n' \
        > /etc/dpkg/dpkg.cfg.d/excludes

# i386 runtime libraries for this architecture; on non-x86 (arm64) also a
# static qemu-i386 + hlds_linux launcher (see scripts/i386-compat.sh)
RUN --mount=type=bind,source=scripts/i386-compat.sh,target=/usr/local/src/cs-server/i386-compat.sh \
    --mount=type=bind,source=scripts/i386-qemu-shim.c,target=/usr/local/src/cs-server/i386-qemu-shim.c \
    bash /usr/local/src/cs-server/i386-compat.sh install \
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

# Bundled default maps, then any local custom maps overlaid on top.
COPY --chown=hlds:hlds docs/cstrike/maps/*.bsp docs/cstrike/maps/*.nav /hlds/cstrike/maps/
COPY --chown=hlds:hlds maps/ /hlds/cstrike/maps/
COPY --chown=hlds:hlds sound/ /hlds/cstrike/sound/

COPY --from=plugins --chown=hlds:hlds /out/ /hlds/cstrike/addons/amxmodx/plugins/
COPY --chown=hlds:hlds plugins/amxmodx/AQS.ini     /hlds/cstrike/addons/amxmodx/configs/AQS.ini
COPY --chown=hlds:hlds plugins/amxmodx/plugins.ini /hlds/cstrike/addons/amxmodx/configs/plugins.ini
COPY --chown=hlds:hlds plugins/metamod/plugins.ini /hlds/cstrike/addons/metamod/plugins.ini

COPY --chown=hlds:hlds config/liblist.gam   /hlds/cstrike/liblist.gam
COPY --chown=hlds:hlds config/game_init.cfg /hlds/cstrike/game_init.cfg
COPY --chown=hlds:hlds config/autoexec.cfg  /hlds/cstrike/autoexec.cfg
COPY --chown=hlds:hlds config/mapcycle*.txt /hlds/cstrike/
COPY --chown=hlds:hlds config/modes/        /hlds/cstrike/modes/
COPY --chown=hlds:hlds config/server.cfg    /hlds/cstrike/server.cfg

COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY --chmod=755 scripts/healthcheck.sh /healthcheck.sh

# Everything the server writes at run time lives under /hlds/state, so one
# volume there keeps bans, admins, stats and logs across container
# replacement and the rest of the image can be mounted read-only. HLDS and
# AMX Mod X only know their own paths, so those become symlinks into it;
# entrypoint.sh creates the targets. users.ini is the one file with shipped
# content: its default is kept aside to seed a new volume. /hlds/.runtime
# (console FIFO) points into /tmp for the same reason.
RUN cs=/hlds/cstrike && amx="${cs}/addons/amxmodx" && \
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
    ln -s /hlds/state/amxmodx/csstats.dat   "${amx}/data/csstats.dat" && \
    ln -s /hlds/state/amxmodx/vault.ini     "${amx}/data/vault.ini" && \
    ln -s /hlds/state/amxmodx/vault         "${amx}/data/vault" && \
    ln -s /tmp/hlds-runtime                 /hlds/.runtime

# Docker's upstream default seccomp profile; install.sh reads it out of the
# image for `docker run` (see ops/seccomp/README.md).
COPY --chmod=644 ops/seccomp/docker-default.json /usr/local/share/cs-server/seccomp.json

# Create Steam SDK symlink for steamclient.so (fixes Docker Desktop on Windows)
RUN mkdir -p /home/hlds/.steam/sdk32 && \
    ln -s /hlds/steamclient.so /home/hlds/.steam/sdk32/steamclient.so && \
    chown -R hlds:hlds /home/hlds

LABEL org.opencontainers.image.title="CS 1.6 ScoutzKnivez Server" \
      org.opencontainers.image.description="Containerized Counter-Strike 1.6 ScoutzKnivez server using the ReHLDS stack" \
      org.opencontainers.image.source="https://github.com/KevinTCoughlin/cs-server" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="KevinTCoughlin"

USER 10001:10001
WORKDIR /hlds

EXPOSE 27015/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
