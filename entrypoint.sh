#!/usr/bin/env bash
set -euo pipefail

export ROON_DATAROOT="/Roon/database"
export ROON_ID_DIR="/Roon/database"

ROON_APP_DIR="/Roon/app"
VERSION_FILE="${ROON_APP_DIR}/RoonServer/VERSION"

# Verify /Roon is mounted and writable
if test ! -w /Roon; then
    echo "The Roon folder doesn't exist or is not writable"
    exit 1
fi

# Ensure directory structure exists
mkdir -p /Roon/{app,database}

# Read the installed branch from the VERSION file (last line)
INSTALLED_BRANCH=""
if [ -f "$VERSION_FILE" ]; then
    INSTALLED_BRANCH="$(tail -1 "$VERSION_FILE")"
fi

# Determine what to do based on ROON_INSTALL_BRANCH and current install state
NEEDS_INSTALL=false

if [ -z "${ROON_INSTALL_BRANCH+x}" ]; then
    # ROON_INSTALL_BRANCH is not set
    if [ -z "$INSTALLED_BRANCH" ]; then
        # No VERSION file — fresh install, default to production
        ROON_INSTALL_BRANCH="production"
        NEEDS_INSTALL=true
    else
        # VERSION file exists — keep what's installed
        ROON_INSTALL_BRANCH="$INSTALLED_BRANCH"
    fi
else
    # ROON_INSTALL_BRANCH is explicitly set — normalize
    ROON_INSTALL_BRANCH="$(echo "$ROON_INSTALL_BRANCH" | tr '[:upper:]' '[:lower:]')"
    ROON_INSTALL_BRANCH="${ROON_INSTALL_BRANCH:-production}"

    case "$ROON_INSTALL_BRANCH" in
        production|earlyaccess) ;;
        *) echo "Invalid ROON_INSTALL_BRANCH='$ROON_INSTALL_BRANCH'. Must be 'production' or 'earlyaccess'."; exit 1 ;;
    esac

    if [ -z "$INSTALLED_BRANCH" ]; then
        # No VERSION file — fresh install
        NEEDS_INSTALL=true
    elif [ "$INSTALLED_BRANCH" != "$ROON_INSTALL_BRANCH" ]; then
        # Branch mismatch — reinstall
        echo "Branch change detected: $INSTALLED_BRANCH -> $ROON_INSTALL_BRANCH"
        echo "Removing old RoonServer binaries..."
        rm -rf "${ROON_APP_DIR}/RoonServer"
        NEEDS_INSTALL=true
    fi
fi

# Download and install RoonServer if needed
if [ "$NEEDS_INSTALL" = true ]; then
    ROON_DOWNLOAD_URL="${ROON_DOWNLOAD_URL:-https://download.roonlabs.net/builds/${ROON_INSTALL_BRANCH}/RoonServer_linuxx64.tar.bz2}"

    echo "RoonServer not found — downloading..."
    curl -fL --retry 2 --progress-bar -o /tmp/RoonServer.tar.bz2 "$ROON_DOWNLOAD_URL"
    echo "Extracting..."
    tar xjf /tmp/RoonServer.tar.bz2 -C "$ROON_APP_DIR" --no-same-permissions --no-same-owner
    rm -f /tmp/RoonServer.tar.bz2

    echo "RoonServer installed successfully."
fi

# libharfbuzz.so links against libfreetype.so.6 but the bundled lib has no
# soname suffix. Prefer a symlink; fall back to a copy on host filesystems
# that reject symlinks on the /Roon bind mount (e.g. CIFS without mfsymlinks).
# Runs on every start so existing volumes from images that omitted the alias,
# and any self-update that replaces Appliance/, still get a working alias.
FREETYPE_SRC="${ROON_APP_DIR}/RoonServer/Appliance/libfreetype.so"
FREETYPE_DST="${ROON_APP_DIR}/RoonServer/Appliance/libfreetype.so.6"
if [ -f "$FREETYPE_SRC" ] && [ ! -e "$FREETYPE_DST" ]; then
    ln -s "$FREETYPE_SRC" "$FREETYPE_DST" 2>/dev/null || cp "$FREETYPE_SRC" "$FREETYPE_DST"
fi

# Log versions at startup
echo "Image:   $(cat /etc/roon-image-version 2>/dev/null || echo 'unknown')"
echo "Branch: $ROON_INSTALL_BRANCH"
echo "Roon:    $(sed -n '2p' "$VERSION_FILE" 2>/dev/null || echo 'unknown')"

ROON_DEFAULT_MUSIC_FOLDER_WATCH_PATH=/Music
export ROON_DEFAULT_MUSIC_FOLDER_WATCH_PATH
HOME=/
export HOME

# start.sh handles restarts internally without a full container restart
exec "${ROON_APP_DIR}/RoonServer/start.sh"
