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
# ROON_INSTALL_BRANCH is treated as an env-variable-with-a-default. Unset or
# empty means "production" — same as setting it explicitly. Previous
# revisions had a "sticky" mode that kept the installed branch when the env
# var was unset; that was clever but produced different meanings for "no
# spec" depending on install state, which was confusing and made downgrades
# unreliable. The simpler "always default to production" model means the
# env var works like every other configurable: a default value the user
# can override.

# Normalize: strip surrounding whitespace, lowercase, default to production.
# Forgiving of YAML/docker-run copy-paste artifacts. Internal whitespace
# (e.g. "Early Access") still errors out via the validation case below.
ROON_INSTALL_BRANCH="$(printf '%s' "${ROON_INSTALL_BRANCH:-production}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
ROON_INSTALL_BRANCH="${ROON_INSTALL_BRANCH:-production}"

case "$ROON_INSTALL_BRANCH" in
    production|earlyaccess) ;;
    *)
        echo "Error: Invalid ROON_INSTALL_BRANCH='${ROON_INSTALL_BRANCH}'."
        echo "       Must be 'production' or 'earlyaccess'."
        exit 1
        ;;
esac

# Echo the resolved (post-normalization) value once so users can confirm
# whitespace stripping / casing produced what they expected. Logged before
# the install decision so it appears even if a subsequent download fails.
echo "Resolved ROON_INSTALL_BRANCH='${ROON_INSTALL_BRANCH}'."

# --- Install decision -------------------------------------------------------
#
# When ROON_DOWNLOAD_URL is set explicitly, the user is supplying their own
# binary source (typically a local mirror). The URL overrides the branch:
# we use it as-is and skip branch-mismatch reinstall logic, since the URL
# may serve any branch and the user is responsible for that consistency.
# Otherwise we derive the URL from the branch and enforce reinstalls when
# the requested branch differs from what's on disk.

NEEDS_INSTALL=false

if [ -n "${ROON_DOWNLOAD_URL+x}" ]; then
    if [ -z "$INSTALLED_BRANCH" ]; then
        NEEDS_INSTALL=true
        echo "Custom ROON_DOWNLOAD_URL set; performing fresh install from override URL."
    else
        echo "Custom ROON_DOWNLOAD_URL set; using existing install (branch '${INSTALLED_BRANCH}')."
    fi
else
    ROON_DOWNLOAD_URL="https://download.roonlabs.net/builds/${ROON_INSTALL_BRANCH}/RoonServer_linuxx64.tar.bz2"
    if [ -z "$INSTALLED_BRANCH" ]; then
        NEEDS_INSTALL=true
        echo "No install present; installing branch '${ROON_INSTALL_BRANCH}'."
    elif [ "$INSTALLED_BRANCH" != "$ROON_INSTALL_BRANCH" ]; then
        echo "Branch change detected: ${INSTALLED_BRANCH} -> ${ROON_INSTALL_BRANCH}"
        NEEDS_INSTALL=true
    else
        echo "Installed branch '${INSTALLED_BRANCH}' matches requested branch; no reinstall needed."
    fi
fi

# --- Install (if needed) ----------------------------------------------------

if [ "$NEEDS_INSTALL" = true ]; then
    # Always wipe before extracting. Handles three cases uniformly:
    # branch-switch (need to remove the old branch's binaries), corrupt
    # prior install (RoonServer/ exists but VERSION is missing/empty), and
    # fresh install (no-op). Cheaper than detecting which case applies.
    rm -rf "${ROON_APP_DIR}/RoonServer"

    echo "Downloading from ${ROON_DOWNLOAD_URL}..."
    curl -fL --retry 2 --progress-bar -o /tmp/RoonServer.tar.bz2 "$ROON_DOWNLOAD_URL"
    echo "Extracting to ${ROON_APP_DIR}..."
    tar xjf /tmp/RoonServer.tar.bz2 -C "$ROON_APP_DIR" --no-same-permissions --no-same-owner
    rm -f /tmp/RoonServer.tar.bz2

    echo "RoonServer installed successfully."
fi

# --- Patch start.sh for in-container update durability ---------------------
# RoonServer's start.sh handles in-container upgrades by extracting a new
# build tarball into RoonServer/.update.tmp/. The bundled script uses bare
# `tar xf "$PKG"` (no --no-same-owner / --no-same-permissions), and the
# build tarballs store files as uid 1001 (the Azure Pipelines build agent).
# That combination fails on hosts with restricted chown semantics — userns-
# remapped Docker daemons, NFS mounts with root_squash, TrueNAS bind
# mounts with strict ACLs — because tar tries to chown extracted files
# to a uid the host filesystem rejects, exits non-zero, and start.sh's
# `|| doerror` catches the failure as "ERROR: failed to tar xf $PKG".
# Result: initial install succeeds (entrypoint extract uses the right
# flags); auto-updates silently fail.
#
# Fix the running on-disk start.sh to mirror our entrypoint extract flags.
# Idempotent: skip when the flag is already present (avoids double-patches
# on restart, and makes upstream's eventual fix a no-op here). Re-runs on
# every container start so each upgrade — which replaces start.sh with
# the unpatched upstream version — gets re-patched on the next restart.

START_SH="${ROON_APP_DIR}/RoonServer/start.sh"
if [ -f "$START_SH" ] && ! grep -q -- "--no-same-owner" "$START_SH"; then
    if sed -i 's|tar xf "$PKG"|tar xf --no-same-owner --no-same-permissions "$PKG"|' "$START_SH" \
       && grep -q -- "--no-same-owner" "$START_SH"; then
        echo "Patched RoonServer/start.sh for in-container update compatibility."
    fi
fi

# --- Final state log --------------------------------------------------------
# Line format is contract-ish: runtime tests grep for "^Branch: production"
# and "^Branch: earlyaccess". Don't change the prefix or spacing without
# updating tests/runtime.sh to match. The branch reported here is read
# from VERSION (post-install) so a custom ROON_DOWNLOAD_URL pulling a
# different branch than ROON_INSTALL_BRANCH shows the *actual* installed
# branch, not the requested label.

ACTUAL_BRANCH="$ROON_INSTALL_BRANCH"
if [ -f "$VERSION_FILE" ]; then
    POST_INSTALL_BRANCH="$(tail -1 "$VERSION_FILE" | tr -d '[:space:]')"
    if [ -n "$POST_INSTALL_BRANCH" ]; then
        ACTUAL_BRANCH="$POST_INSTALL_BRANCH"
    fi
fi

echo "Image:   ${IMAGE_VERSION}"
echo "Branch: ${ACTUAL_BRANCH}"
echo "Roon:    $(sed -n '2p' "$VERSION_FILE" 2>/dev/null || echo 'unknown')"

ROON_DEFAULT_MUSIC_FOLDER_WATCH_PATH=/Music
export ROON_DEFAULT_MUSIC_FOLDER_WATCH_PATH
HOME=/
export HOME

# start.sh handles restarts internally without a full container restart
exec "${ROON_APP_DIR}/RoonServer/start.sh"
