# syntax=docker/dockerfile:1

#--------------------------------------------
# Stage 1: Download and verify ffmpeg
#--------------------------------------------
FROM --platform=linux/amd64 debian:trixie-slim AS ffmpeg-downloader

ARG FFMPEG_URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-03-27-13-10/ffmpeg-n7.1.3-43-g5a1f107b4c-linux64-gpl-7.1.tar.xz
ARG FFMPEG_SHA256=198fbc39a8a14641149d38f2a093058b2305b276229d70f6e089c6438627f7ab

RUN apt-get update \
    && apt-get -y install --no-install-recommends curl xz-utils ca-certificates \
    && curl -L -o /tmp/ffmpeg.tar.xz "$FFMPEG_URL" \
    && echo "$FFMPEG_SHA256  /tmp/ffmpeg.tar.xz" | sha256sum -c - \
    && tar -xf /tmp/ffmpeg.tar.xz -C /tmp \
    && cp /tmp/ffmpeg-*/bin/ffmpeg /usr/local/bin/

#--------------------------------------------
# Stage 2: Final runtime image
#--------------------------------------------
FROM --platform=linux/amd64 debian:trixie-slim

ARG VERSION=dev
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="RoonServer"
LABEL org.opencontainers.image.authors="Roon Labs"
LABEL org.opencontainers.image.vendor="Roon Labs"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.description="Official RoonServer Docker Image"
LABEL org.opencontainers.image.source="https://github.com/RoonLabs/roon-docker"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.url="https://roon.app"
LABEL org.opencontainers.image.licenses="Proprietary"

# Runtime dependencies:
#   curl            — downloads RoonServer on first run
#   bzip2           — extracts the .tar.bz2 tarball
#   tzdata          — IANA timezone data for TZ environment variable
#   libicu76        — .NET globalization (Debian Trixie specific)
#   libasound2t64   — ALSA audio, required by libraatmanager.so
#   cifs-utils      — SMB/CIFS network share mounting
#   ca-certificates — HTTPS for streaming services and cloud APIs
RUN apt-get update \
    && apt-get -y install --no-install-recommends \
       bash curl bzip2 tzdata libicu76 libasound2t64 cifs-utils ca-certificates \
    && (chmod u-s /usr/sbin/mount.cifs 2>/dev/null || true) \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/log/apt /var/log/dpkg.log \
       /usr/share/doc /usr/share/man

# Pre-built ffmpeg from the downloader stage
COPY --from=ffmpeg-downloader /usr/local/bin/ffmpeg /usr/local/bin/

RUN echo "${VERSION}" > /etc/roon-image-version

COPY entrypoint.sh /entrypoint.sh

# Informational only — requires --net=host for multicast discovery
EXPOSE 9003/udp 9100-9200/tcp 9200-9250/tcp 9330-9339/tcp 55000/tcp

# Healthcheck uses /proc directly instead of pgrep to avoid procps dependency
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD grep -ql '[R]oonServer.dll' /proc/[0-9]*/cmdline 2>/dev/null || exit 1

# entrypoint.sh downloads RoonServer on first run (to /Roon/app), then
# exec's into start.sh — the stock bash launcher that handles
# .NET runtime discovery, ulimit, self-update swap, and restart.
ENTRYPOINT ["/entrypoint.sh"]
