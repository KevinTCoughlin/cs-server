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
ARG AMXMODX_BUILD=5479

# ---------------------------------------------------------------------------
# Stage 1: Builder — SteamCMD + HLDS + ReHLDS stack
# ---------------------------------------------------------------------------
# Runtime choice: Debian 13 "Trixie" is optimal for CS 1.6 servers in 2026:
# - 5-year security support (until ~2030) ensures long-term maintenance
# - Latest kernel (6.12 LTS) provides improved performance and security
# - Full i386/32-bit support required for HLDS binaries
# - Minimal image size (~25-30MB for slim variant)
# - glibc compatibility (Alpine's musl would require workarounds)
# Alternatives rejected: Bookworm (shorter support), Ubuntu (larger), Alpine (glibc issues)
FROM debian:trixie AS builder

ARG REHLDS_VERSION
ARG REGAMEDLL_VERSION
ARG METAMOD_VERSION
ARG REAPI_VERSION
ARG AMXMODX_BUILD

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3008
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        lib32stdc++6 \
        lib32z1 \
        libc6-i386 \
        patchelf \
        unzip \
        tar \
    && rm -rf /var/lib/apt/lists/*

# Install SteamCMD
RUN mkdir -p /opt/steamcmd && \
    curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        | tar -xz -C /opt/steamcmd

# Download HLDS (app 90, steam_legacy beta)
# Run app_update multiple times — app 90 has a known bug where it doesn't
# download all files in a single pass
RUN /opt/steamcmd/steamcmd.sh \
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

# Copy custom maps
COPY maps/*.bsp cstrike/maps/
COPY maps/*.nav cstrike/maps/

# Compile custom AMX Mod X plugins
COPY plugins/amxmodx/scripting/*.sma cstrike/addons/amxmodx/scripting/
WORKDIR /hlds/cstrike/addons/amxmodx/scripting
RUN chmod +x amxxpc compile.sh && \
    for sma in scoutzknivez.sma autobhop.sma AQS.sma rtv.sma websitebot.sma afkkicker.sma highpingkicker.sma advertisements.sma; do \
        ./amxxpc "$sma" || exit 1; \
        mv "${sma%.sma}.amxx" ../plugins/ || exit 1; \
    done
WORKDIR /hlds

# Copy AQS config and quake sound files
COPY plugins/amxmodx/AQS.ini cstrike/addons/amxmodx/configs/AQS.ini
COPY sound/quake/ cstrike/sound/quake/

# --- CZ Bots (ZBot profiles + sounds from ReGameDLL_CS) ---
RUN curl -fsSL "https://raw.githubusercontent.com/rehlds/ReGameDLL_CS/refs/heads/master/regamedll/extra/zBot/bot_profiles.zip" \
        -o /tmp/bot_profiles.zip && \
    unzip -o /tmp/bot_profiles.zip -d . && \
    rm -f /tmp/bot_profiles.zip

# Copy config files into image
COPY config/server.cfg     cstrike/server.cfg
COPY config/mapcycle*.txt  cstrike/
COPY config/autoexec.cfg   cstrike/autoexec.cfg
COPY config/game_init.cfg  cstrike/game_init.cfg
COPY config/liblist.gam    cstrike/liblist.gam
COPY plugins/metamod/plugins.ini   cstrike/addons/metamod/plugins.ini
COPY plugins/amxmodx/plugins.ini   cstrike/addons/amxmodx/configs/plugins.ini

# Ensure binaries are executable and set Steam app ID
RUN chmod +x hlds_linux hlds_run && \
    echo 70 > steam_appid.txt

# ---------------------------------------------------------------------------
# Stage 2: Runtime — clean slim image, no build tools
# ---------------------------------------------------------------------------
# Using trixie-slim for minimal attack surface and optimal security posture
FROM debian:trixie-slim AS runtime

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Prevent docs/man/locale from being installed (smaller image), but keep licenses
RUN printf 'path-exclude=/usr/share/doc/*\npath-include=/usr/share/doc/*/copyright\npath-include=/usr/share/doc/*/changelog.Debian*\npath-include=/usr/share/doc/*/LICENSE\npath-exclude=/usr/share/man/*\npath-exclude=/usr/share/locale/*\npath-exclude=/usr/share/bug/*\npath-exclude=/usr/share/lintian/*\npath-exclude=/usr/share/mime/*\npath-exclude=/usr/share/info/*\n' \
        > /etc/dpkg/dpkg.cfg.d/excludes

# hadolint ignore=DL3008
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        lib32gcc-s1 \
        lib32stdc++6 \
        lib32z1 \
        libc6-i386 \
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

COPY --from=builder --chown=hlds:hlds /hlds /hlds
COPY --chmod=755 entrypoint.sh /entrypoint.sh

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

EXPOSE 27015/udp 27015/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["/bin/sh", "-c", "grep -qs hlds_linux /proc/[0-9]*/comm || exit 1"]

ENTRYPOINT ["/entrypoint.sh"]
