#!/usr/bin/env bash
set -euo pipefail

export ROON_DATAROOT="/Roon/database"
export ROON_ID_DIR="/Roon/database"

ROON_APP_DIR="/Roon/app"
VERSION_FILE="${ROON_APP_DIR}/RoonServer/VERSION"
IMAGE_VERSION="$(cat /etc/roon-image-version 2>/dev/null || echo 'unknown')"

echo "Roon Docker image ${IMAGE_VERSION} starting."

# Verify /Roon is mounted and writable
if test ! -w /Roon; then
    echo "Error: The /Roon directory is not writable."
    echo "       Check that your volume mount points at a writable host path."
    exit 1
fi

# Ensure directory structure exists
mkdir -p /Roon/{app,database}

# Read the installed branch from the VERSION file (last line).
# Strip all whitespace: a corrupt/empty VERSION file (e.g., a failed prior
# extraction) would otherwise yield a blank branch that falls through to
# the "no existing install" path *silently* while still having a
# half-populated RoonServer directory on disk. Treating blank content as
# "no install" is correct, but we log it distinctly so the confusing
# "Detected existing install (branch: )" line never appears in logs.
INSTALLED_BRANCH=""
if [ -f "$VERSION_FILE" ]; then
    INSTALLED_BRANCH="$(tail -1 "$VERSION_FILE" | tr -d '[:space:]')"
    if [ -n "$INSTALLED_BRANCH" ]; then
        echo "Detected existing RoonServer install (branch: ${INSTALLED_BRANCH})."
    else
        echo "VERSION file at ${VERSION_FILE} is empty — treating as no existing install."
    fi
else
    echo "No existing RoonServer install found under ${ROON_APP_DIR}/RoonServer."
fi

# --- Branch resolution ------------------------------------------------------
#
# When the configurator generates a compose file or docker run command, it
# always sets ROON_INSTALL_BRANCH explicitly (for both production and
# earlyaccess), so the branch-change path below always fires and switches
# are immediate.
#
# When ROON_INSTALL_BRANCH is NOT set — hand-crafted compose files, other
# tools, or users who removed the variable — we default to "keep what's
# installed" so a routine restart doesn't surprise a running deployment.
# That stickiness is by design, but we log it clearly so users who
# intended to switch branches can see what the container decided.

NEEDS_INSTALL=false

if [ -z "${ROON_INSTALL_BRANCH+x}" ]; then
    # ROON_INSTALL_BRANCH is not set in the environment.
    if [ -z "$INSTALLED_BRANCH" ]; then
        ROON_INSTALL_BRANCH="production"
        NEEDS_INSTALL=true
        echo "ROON_INSTALL_BRANCH not set and no existing install; using default branch '${ROON_INSTALL_BRANCH}'."
    else
        ROON_INSTALL_BRANCH="$INSTALLED_BRANCH"
        echo "ROON_INSTALL_BRANCH not set; keeping installed branch '${ROON_INSTALL_BRANCH}'."
        echo "  To switch branches, set ROON_INSTALL_BRANCH=production or ROON_INSTALL_BRANCH=earlyaccess in your container config."
    fi
else
    # ROON_INSTALL_BRANCH is explicitly set — normalize (strip surrounding
    # whitespace then lowercase) and validate. Stripping whitespace is
    # forgiving for copy-paste errors from YAML or docker-run command lines
    # where a newline or trailing space sneaks in; internal whitespace
    # (e.g., "Early Access") still errors out since it's a distinct class
    # of typo.
    ROON_INSTALL_BRANCH="$(echo "$ROON_INSTALL_BRANCH" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
    ROON_INSTALL_BRANCH="${ROON_INSTALL_BRANCH:-production}"

    case "$ROON_INSTALL_BRANCH" in
        production|earlyaccess) ;;
        *)
            echo "Error: Invalid ROON_INSTALL_BRANCH='${ROON_INSTALL_BRANCH}'."
            echo "       Must be 'production' or 'earlyaccess'."
            exit 1
            ;;
    esac

    if [ -z "$INSTALLED_BRANCH" ]; then
        NEEDS_INSTALL=true
        echo "Requested branch '${ROON_INSTALL_BRANCH}' — fresh install."
    elif [ "$INSTALLED_BRANCH" != "$ROON_INSTALL_BRANCH" ]; then
        echo "Branch change detected: ${INSTALLED_BRANCH} -> ${ROON_INSTALL_BRANCH}"
        echo "Removing old RoonServer binaries from ${ROON_APP_DIR}/RoonServer..."
        rm -rf "${ROON_APP_DIR}/RoonServer"
        NEEDS_INSTALL=true
    else
        echo "Installed branch '${INSTALLED_BRANCH}' matches requested branch; no reinstall needed."
    fi
fi

# --- Install (if needed) ----------------------------------------------------

if [ "$NEEDS_INSTALL" = true ]; then
    ROON_DOWNLOAD_URL="${ROON_DOWNLOAD_URL:-https://download.roonlabs.net/builds/${ROON_INSTALL_BRANCH}/RoonServer_linuxx64.tar.bz2}"

    echo "RoonServer not found — downloading from ${ROON_DOWNLOAD_URL}..."
    curl -fL --retry 2 --progress-bar -o /tmp/RoonServer.tar.bz2 "$ROON_DOWNLOAD_URL"
    echo "Extracting to ${ROON_APP_DIR}..."
    tar xjf /tmp/RoonServer.tar.bz2 -C "$ROON_APP_DIR" --no-same-permissions --no-same-owner
    rm -f /tmp/RoonServer.tar.bz2

    echo "RoonServer installed successfully."
fi

# --- Final state log --------------------------------------------------------
# Line format is contract-ish: runtime tests grep for "^Branch: production"
# and "^Branch: earlyaccess". Don't change the prefix or spacing without
# updating tests/runtime.sh to match.

echo "Image:   ${IMAGE_VERSION}"
echo "Branch: ${ROON_INSTALL_BRANCH}"
echo "Roon:    $(sed -n '2p' "$VERSION_FILE" 2>/dev/null || echo 'unknown')"

ROON_DEFAULT_MUSIC_FOLDER_WATCH_PATH=/Music
export ROON_DEFAULT_MUSIC_FOLDER_WATCH_PATH
HOME=/
export HOME

# start.sh handles restarts internally without a full container restart
exec "${ROON_APP_DIR}/RoonServer/start.sh"
