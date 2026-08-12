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

# --- Broken fchmodat2 workaround (RRD-2830) ---------------------------------
#
# glibc 2.39+ uses syscall 452 (fchmodat2) for fchmodat with AT_SYMLINK_NOFOLLOW
# — directories, files, and symlinks. Some vendor kernels (QNAP 5.10 is the
# known case) put a private syscall on that number; it returns EFAULT, glibc
# will not fall back (it only does on ENOSYS), and tar treats EFAULT as fatal.
#
# Detected by extracting a tiny archive with the real tar and looking for
# "Bad address". No syscall numbers or vendor matching. The wrapper lives in
# the container's writable layer, so a restart keeps it; it is a no-op once
# 452 is really fchmodat2. Recreating the container re-probes.
#
# Preload is scoped to tar via PATH so RoonServer never loads it.
# RoonServer/start.sh invokes `tar` unqualified, so self-update is covered too.
install_fchmodat_shim_if_needed() {
    local shim_lib=/usr/local/lib/roon/fchmodat-compat.so
    local shim_bin=/usr/local/bin/tar
    local probe out
    test -f "$shim_lib" || return 0

    # Restart: only our wrapper plus the .so is "already active". Any other
    # executable at this path is left alone. A leftover from a failed verify
    # is removed so the next start can retry instead of reporting success.
    if [ -x "$shim_bin" ] && grep -qF "$shim_lib" "$shim_bin" 2>/dev/null && [ -f "$shim_lib" ]; then
        echo "fchmodat2 compatibility shim already active for tar (see RRD-2830)."
        return 0
    fi
    if [ -e "$shim_bin" ]; then
        if grep -qF "$shim_lib" "$shim_bin" 2>/dev/null; then
            rm -f "$shim_bin" 2>/dev/null || true
            hash -r
        else
            echo "fchmodat2 shim not installed: $shim_bin already exists and is not this wrapper."
            return 0
        fi
    fi

    # Every filesystem step below is best-effort. This is a workaround for
    # someone else's kernel bug and must never be the reason a container fails
    # to start, so anything unexpected — full /tmp, read-only rootfs, --user
    # without write access to /usr/local — degrades to "no shim" instead of
    # tripping set -e and killing the entrypoint.
    #
    # Probed in /tmp, not /Roon: the fault is in the syscall, not the
    # filesystem (it reproduces identically on overlayfs and on a bind mount),
    # so there is no reason to leave probe debris in the user's data directory.
    probe="$(mktemp -d 2>/dev/null)" || return 0
    if ! mkdir -p "$probe/src" "$probe/out" 2>/dev/null \
       || ! : > "$probe/src/file" 2>/dev/null \
       || ! ln -s file "$probe/src/link" 2>/dev/null \
       || ! /usr/bin/tar cf "$probe/archive.tar" -C "$probe" src 2>/dev/null; then
        rm -rf "$probe" 2>/dev/null || true
        return 0
    fi

    # Stock tar, not PATH: a leftover or operator /usr/local/bin/tar must
    # not decide whether the kernel is broken.
    out="$(/usr/bin/tar xf "$probe/archive.tar" -C "$probe/out" 2>&1)" || true

    # Only an extract that reports "Bad address" (EFAULT). Other failures
    # must surface as themselves rather than being papered over by a preload.
    case "$out" in
        *"Bad address"*) ;;
        *) rm -rf "$probe" 2>/dev/null || true; return 0 ;;
    esac

    echo "Detected a kernel where fchmodat2 (syscall 452) returns EFAULT."
    echo "  That breaks tar when restoring modes (dirs, files, symlinks) and is a"
    echo "  known QNAP kernel issue. Enabling a compatibility shim for tar only."

    # LD_PRELOAD is prepended rather than assigned so an inherited preload set
    # by the operator survives every tar invocation, self-update included.
    if ! mkdir -p "$(dirname "$shim_bin")" 2>/dev/null \
       || ! printf '%s\n' \
              '#!/bin/sh' \
              '# Installed by entrypoint.sh — see fchmodat-compat.c.' \
              "LD_PRELOAD=\"$shim_lib\${LD_PRELOAD:+:\$LD_PRELOAD}\" exec /usr/bin/tar \"\$@\"" \
              > "$shim_bin" 2>/dev/null \
       || ! chmod +x "$shim_bin" 2>/dev/null; then
        echo "  Could not install it — /usr/local is not writable here."
        echo "  Continuing without; tar will still fail when restoring modes."
        rm -rf "$probe" 2>/dev/null || true
        return 0
    fi

    # Unqualified tar must resolve through PATH so the wrapper we just wrote
    # is what the verify extract (and later install) use.
    hash -r

    # Prove it took, rather than announcing it did. ld.so treats an unloadable
    # LD_PRELOAD as a warning and carries on, so a mismatched or missing .so
    # would otherwise leave a log claiming the workaround is engaged while
    # extraction still dies with "Bad address". Re-running the same probe now
    # exercises PATH resolution, the preload, and the shim together.
    rm -rf "$probe/out" 2>/dev/null || true
    if mkdir -p "$probe/out" 2>/dev/null \
       && out="$(tar xf "$probe/archive.tar" -C "$probe/out" 2>&1)" && [ -z "$out" ]; then
        echo "  Shim verified: probe extract now succeeds."
    else
        echo "  WARNING: extraction still fails (${out:-unknown error}); removing the wrapper so the next start can retry."
        rm -f "$shim_bin" 2>/dev/null || true
        hash -r
    fi
    rm -rf "$probe" 2>/dev/null || true
}

install_fchmodat_shim_if_needed

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
