#!/usr/bin/env bash
# Quick checks against the built image — no container start, no network.
set -euo pipefail

IMAGE="${1:?Usage: smoke.sh <image:tag>}"
PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS  $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Smoke tests: $IMAGE ==="

# Entrypoint
check "entrypoint exists and is executable" \
    docker run --rm --entrypoint stat "$IMAGE" -c '%a' /entrypoint.sh

# Required binaries
for bin in bash curl bzip2 tar ffmpeg; do
    check "$bin is available" \
        docker run --rm --entrypoint which "$IMAGE" "$bin"
done

# Environment variables (ROON_DATAROOT and ROON_ID_DIR are set by entrypoint, not the image)
check "ROON_DATAROOT not leaked in image env" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ -z "$ROON_DATAROOT" ]'

check "ROON_ID_DIR not leaked in image env" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ -z "$ROON_ID_DIR" ]'

# Image version file
check "/etc/roon-image-version exists" \
    docker run --rm --entrypoint cat "$IMAGE" /etc/roon-image-version

# OCI labels
check "image has version label" \
    docker inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.version" }}'

check "image has source label" \
    docker inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.source" }}'

# Cleanup was effective
check "apt lists cleaned" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ -z "$(ls /var/lib/apt/lists/)" ]'

# SUID stripped from mount.cifs
check "mount.cifs has no SUID bit" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ ! -u /usr/sbin/mount.cifs ]'

# Failure path: container should exit non-zero without /Roon mounted
FAIL_EXIT=0
FAIL_OUTPUT=$(docker run --rm "$IMAGE" 2>&1) || FAIL_EXIT=$?
check "exits with error when /Roon not mounted" \
    test "$FAIL_EXIT" -ne 0

check "prints writable error when /Roon not mounted" \
    sh -c 'echo "$1" | grep -q "not writable"' _ "$FAIL_OUTPUT"

# Invalid channel should exit with error
CHAN_EXIT=0
CHAN_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=invalid -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || CHAN_EXIT=$?
check "rejects invalid ROON_INSTALL_BRANCH" \
    sh -c 'echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$CHAN_OUTPUT"

# Mixed-case channel should be accepted (use bad URL so it fails fast after validation)
MIXED_EXIT=0
MIXED_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=EarlyAccess -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || MIXED_EXIT=$?
check "accepts mixed-case ROON_INSTALL_BRANCH" \
    sh -c '! echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$MIXED_OUTPUT"

# Empty channel should default to production (use bad URL so it fails fast after validation)
EMPTY_EXIT=0
EMPTY_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH= -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || EMPTY_EXIT=$?
check "empty ROON_INSTALL_BRANCH defaults to production" \
    sh -c '! echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$EMPTY_OUTPUT"

# Explicit ROON_INSTALL_BRANCH=production should pass validation (use bad URL so it fails fast after validation)
EXPLICIT_EXIT=0
EXPLICIT_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=production -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || EXPLICIT_EXIT=$?
check "explicit ROON_INSTALL_BRANCH=production passes validation" \
    sh -c '! echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$EXPLICIT_OUTPUT"

# Read-only /Roon mount should fail with writable error
RO_EXIT=0
RO_OUTPUT=$(docker run --rm -v "$(mktemp -d):/Roon:ro" "$IMAGE" 2>&1) || RO_EXIT=$?
check "exits with error when /Roon is read-only" \
    test "$RO_EXIT" -ne 0

check "prints writable error when /Roon is read-only" \
    sh -c 'echo "$1" | grep -q "not writable"' _ "$RO_OUTPUT"

# Timezone: verify TZ env var is honored by the container
TZ_OUTPUT=$(docker run --rm --entrypoint sh -e TZ=America/Denver "$IMAGE" -c 'date +%Z' 2>/dev/null)
check "TZ=America/Denver produces MDT or MST (got $TZ_OUTPUT)" \
    sh -c '[ "$1" = "MDT" ] || [ "$1" = "MST" ]' _ "$TZ_OUTPUT"

# Bad download URL should fail
BAD_EXIT=0
BAD_OUTPUT=$(docker run --rm -e ROON_DOWNLOAD_URL=https://download.roonlabs.net/nonexistent -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || BAD_EXIT=$?
check "exits with error on bad download URL" \
    test "$BAD_EXIT" -ne 0

# NAS compatibility: required libraries and binaries
check "mount.cifs binary exists" \
    docker run --rm --entrypoint which "$IMAGE" mount.cifs

check "libasound is available" \
    docker run --rm --entrypoint sh "$IMAGE" -c 'ldconfig -p | grep -q libasound'

check "entrypoint uses --no-same-permissions for QNAP" \
    docker run --rm --entrypoint grep "$IMAGE" -- '--no-same-permissions' /entrypoint.sh

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
