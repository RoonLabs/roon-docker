# syntax=docker/dockerfile:1

# Compiles the fchmodat compatibility shim (see fchmodat-compat.c). Separate
# stage so the toolchain does not ship in the runtime image.
FROM --platform=linux/amd64 debian:trixie-slim AS shim-builder
RUN apt-get update \
 && apt-get -y install --no-install-recommends gcc libc6-dev \
 && rm -rf /var/lib/apt/lists/*
COPY fchmodat-compat.c tests/efault-fchmodat.c /build/
RUN gcc -shared -fPIC -O2 -Wall -Wextra -Werror \
        -o /build/fchmodat-compat.so /build/fchmodat-compat.c -ldl \
 && nm -D --defined-only /build/fchmodat-compat.so | grep -qw fchmodat \
 && gcc -shared -fPIC -O2 -Wall -Wextra -Werror \
        -o /build/efault-fchmodat.so /build/efault-fchmodat.c -ldl

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
#   procps          — provides ps, required by RoonServer's self-update script
RUN apt-get update \
 && apt-get -y install --no-install-recommends \
    bash curl xz-utils bzip2 tzdata libicu76 \
    libasound2t64 libfreetype6 cifs-utils ca-certificates procps \
 && (chmod u-s /usr/sbin/mount.cifs 2>/dev/null || true) \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /var/log/apt /var/log/dpkg.log \
           /usr/share/doc /usr/share/man

RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
 && tar xf /tmp/ffmpeg.tar.xz --wildcards -C /tmp "ffmpeg*/ffmpeg" \
 && mv /tmp/ffmpeg-*/ffmpeg /usr/local/bin/ \
 && rm -rf /tmp/ffmpeg*

RUN echo "${VERSION}" > /etc/roon-image-version

# Dormant unless entrypoint.sh proves the kernel needs it — see fchmodat-compat.c.
COPY --from=shim-builder /build/fchmodat-compat.so /usr/local/lib/roon/fchmodat-compat.so
# Smoke-test fixture, never loaded by the entrypoint.
COPY --from=shim-builder /build/efault-fchmodat.so /usr/local/share/roon/testdata/efault-fchmodat.so

COPY entrypoint.sh /entrypoint.sh

# Informational only — requires --net=host for multicast discovery
EXPOSE 9003/udp 9100-9200/tcp 9200-9250/tcp 9330-9339/tcp 55000/tcp

VOLUME /Roon /RoonBackups /Music

# Healthcheck reads /proc directly rather than parsing ps/pgrep output. (procps
# is installed above for RoonServer's self-update; the probe just doesn't need it.)
#
# Two branches, because the head's name depends on the package. Current builds
# exec it via Server/.roonhost/RoonServer, so it is identifiable only by comm
# ("RoonServer", no extension); legacy shared-runtime builds exec dotnet with
# RoonServer.dll as an argument, where comm is just "dotnet".
#
# comm is a bare basename, so -x anchors it against a decoy like
# "RoonServerOld"; the cmdline branch instead relies on the "[R]" trick, since
# the probe's own shell carries this directive in its argv and would otherwise
# match itself. A comm hit must also carry a non-empty cmdline: the kernel keeps
# comm for a defunct process but empties cmdline, so matching comm alone reports
# a zombie head as healthy forever. tests/healthcheck.sh pins each of these.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD { for f in $(grep -lxE 'RoonServer(\.exe|\.dll)?' /proc/[0-9]*/comm 2>/dev/null); do \
            [ -n "$(cat "${f%comm}cmdline" 2>/dev/null)" ] && exit 0; \
          done; \
          grep -qlE '[R]oonServer\.(dll|exe)' /proc/[0-9]*/cmdline 2>/dev/null; } || exit 1

# entrypoint.sh downloads RoonServer on first run (to /Roon/app), then
# exec's into start.sh — the stock bash launcher that handles
# .NET runtime discovery, ulimit, self-update swap, and restart.
ENTRYPOINT ["/entrypoint.sh"]
