# syntax=docker/dockerfile:1

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
#   libfreetype6    — provides libfreetype.so.6 soname that bundled libharfbuzz links against
#   cifs-utils      — SMB/CIFS network share mounting
#   ca-certificates — HTTPS for streaming services and cloud APIs
RUN apt-get update \
 && apt-get -y install --no-install-recommends \
    bash curl xz-utils bzip2 tzdata libicu76 \
    libasound2t64 libfreetype6 cifs-utils ca-certificates \
 && (chmod u-s /usr/sbin/mount.cifs 2>/dev/null || true) \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /var/log/apt /var/log/dpkg.log \
           /usr/share/doc /usr/share/man

RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
 && tar xf /tmp/ffmpeg.tar.xz --wildcards -C /tmp "ffmpeg*/ffmpeg" \
 && mv /tmp/ffmpeg-*/ffmpeg /usr/local/bin/ \
 && rm -rf /tmp/ffmpeg*

RUN echo "${VERSION}" > /etc/roon-image-version

COPY entrypoint.sh /entrypoint.sh

# Informational only — requires --net=host for multicast discovery
EXPOSE 9003/udp 9100-9200/tcp 9200-9250/tcp 9330-9339/tcp 55000/tcp

VOLUME /Roon /RoonBackups /Music

# Healthcheck uses /proc directly instead of pgrep to avoid procps dependency
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD grep -ql '[R]oonServer.dll' /proc/[0-9]*/cmdline 2>/dev/null || exit 1

# entrypoint.sh downloads RoonServer on first run (to /Roon/app), then
# exec's into start.sh — the stock bash launcher that handles
# .NET runtime discovery, ulimit, self-update swap, and restart.
ENTRYPOINT ["/entrypoint.sh"]
