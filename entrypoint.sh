#!/usr/bin/env bash
set -euo pipefail

ROON_APP_DIR="/Roon/app"
ROON_INSTALLED="${ROON_APP_DIR}/.installed"
ROON_CHANNEL_FILE="${ROON_APP_DIR}/.channel"

# Channel selection: production (default) or earlyaccess.
# If a channel file exists from a previous install and the user hasn't explicitly
# set ROON_CHANNEL, honor the existing channel to avoid unwanted downgrades.
if [ -z "${ROON_CHANNEL+x}" ] && [ -f "$ROON_CHANNEL_FILE" ]; then
    ROON_CHANNEL="$(cat "$ROON_CHANNEL_FILE")"
fi
ROON_CHANNEL="${ROON_CHANNEL:-production}"
ROON_CHANNEL="$(echo "$ROON_CHANNEL" | tr '[:upper:]' '[:lower:]')"

case "$ROON_CHANNEL" in
    production)  _DEFAULT_URL="https://download.roonlabs.net/builds/RoonServer_linuxx64.tar.bz2" ;;
    earlyaccess) _DEFAULT_URL="https://download.roonlabs.net/builds/earlyaccess/RoonServer_linuxx64.tar.bz2" ;;
    *) echo "Invalid ROON_CHANNEL='$ROON_CHANNEL'. Must be 'production' or 'earlyaccess'."; exit 1 ;;
esac

ROON_DOWNLOAD_URL="${ROON_DOWNLOAD_URL:-$_DEFAULT_URL}"

# Verify /Roon is mounted and writable
if test ! -w /Roon; then
    echo "The Roon folder doesn't exist or is not writable"
    exit 1
fi

# Ensure directory structure exists
mkdir -p /Roon/{app,data,backup}

# Detect channel switch on existing install
if [ -f "$ROON_INSTALLED" ] && [ -f "$ROON_CHANNEL_FILE" ]; then
    INSTALLED_CHANNEL="$(cat "$ROON_CHANNEL_FILE")"
    if [ "$INSTALLED_CHANNEL" != "$ROON_CHANNEL" ]; then
        echo "Channel change detected: $INSTALLED_CHANNEL -> $ROON_CHANNEL"
        echo "Removing old RoonServer binaries..."
        rm -rf "${ROON_APP_DIR}/RoonServer"
        rm -f "$ROON_INSTALLED" "$ROON_CHANNEL_FILE"
    fi
fi

# Upgrade path: existing install from pre-channel image (no .channel file).
# If ROON_CHANNEL is explicitly set to something other than production, force reinstall.
if [ -f "$ROON_INSTALLED" ] && [ ! -f "$ROON_CHANNEL_FILE" ] && [ "$ROON_CHANNEL" != "production" ]; then
    echo "No channel file found — reinstalling for $ROON_CHANNEL channel..."
    rm -rf "${ROON_APP_DIR}/RoonServer"
    rm -f "$ROON_INSTALLED"
fi

# Download and install RoonServer on first run
if [ ! -f "$ROON_INSTALLED" ]; then
    echo "RoonServer not found — downloading..."
    curl -fL --progress-bar -o /tmp/RoonServer.tar.bz2 "$ROON_DOWNLOAD_URL"
    echo "Extracting..."
    tar xjf /tmp/RoonServer.tar.bz2 -C "$ROON_APP_DIR" --no-same-permissions --no-same-owner
    rm -f /tmp/RoonServer.tar.bz2

    # libharfbuzz.so links against libfreetype.so.6 but bundled lib has no soname suffix
    ln -sf "${ROON_APP_DIR}/RoonServer/Appliance/libfreetype.so" \
           "${ROON_APP_DIR}/RoonServer/Appliance/libfreetype.so.6"

    # Record the installed Roon version from the tarball's VERSION file
    if [ -f "${ROON_APP_DIR}/RoonServer/VERSION" ]; then
        cp "${ROON_APP_DIR}/RoonServer/VERSION" "$ROON_INSTALLED"
    else
        echo "unknown" > "$ROON_INSTALLED"
    fi

    echo "$ROON_CHANNEL" > "$ROON_CHANNEL_FILE"
    echo "RoonServer installed successfully."
fi

# Backfill channel file for pre-channel installs that are staying on production
if [ ! -f "$ROON_CHANNEL_FILE" ]; then
    echo "$ROON_CHANNEL" > "$ROON_CHANNEL_FILE"
fi

# Log versions at startup
echo "Image:   $(cat /etc/roon-image-version 2>/dev/null || echo 'unknown')"
echo "Channel: $ROON_CHANNEL"
echo "Roon:    $(sed -n '2p' "$ROON_INSTALLED" 2>/dev/null || echo 'unknown')"

# start.sh handles restart-on-exit-122 without a full container restart
exec "${ROON_APP_DIR}/RoonServer/start.sh"
