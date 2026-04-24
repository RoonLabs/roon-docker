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

# Invalid branch should exit with error
BRANCH_EXIT=0
BRANCH_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=invalid -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || BRANCH_EXIT=$?
check "rejects invalid ROON_INSTALL_BRANCH" \
    sh -c 'echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$BRANCH_OUTPUT"

# Mixed-case branch should be accepted (use bad URL so it fails fast after validation)
MIXED_EXIT=0
MIXED_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=EarlyAccess -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || MIXED_EXIT=$?
check "accepts mixed-case ROON_INSTALL_BRANCH" \
    sh -c '! echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$MIXED_OUTPUT"

# Empty branch should default to production (use bad URL so it fails fast after validation)
EMPTY_EXIT=0
EMPTY_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH= -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || EMPTY_EXIT=$?
check "empty ROON_INSTALL_BRANCH defaults to production" \
    sh -c '! echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$EMPTY_OUTPUT"

# Explicit ROON_INSTALL_BRANCH=production should pass validation (use bad URL so it fails fast after validation)
EXPLICIT_EXIT=0
EXPLICIT_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=production -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$(mktemp -d):/Roon" "$IMAGE" 2>&1) || EXPLICIT_EXIT=$?
check "explicit ROON_INSTALL_BRANCH=production passes validation" \
    sh -c '! echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$EXPLICIT_OUTPUT"

# Whitespace tolerance: leading, trailing, and newline variants should
# normalize to the clean value. Copy-paste from YAML or docker-run command
# lines easily introduces these; erroring out on them is an unfriendly
# trap that's easy to avoid with a sed trim.
LEAD_TMP=$(mktemp -d)
LEAD_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH= earlyaccess" -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$LEAD_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$LEAD_TMP"
check "leading whitespace in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -q "Requested branch .earlyaccess."' _ "$LEAD_OUTPUT"

TRAIL_TMP=$(mktemp -d)
TRAIL_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH=earlyaccess  " -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$TRAIL_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$TRAIL_TMP"
check "trailing whitespace in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -q "Requested branch .earlyaccess."' _ "$TRAIL_OUTPUT"

NEWLINE_TMP=$(mktemp -d)
NEWLINE_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH=$(printf 'earlyaccess\n')" -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$NEWLINE_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$NEWLINE_TMP"
check "trailing newline in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -q "Requested branch .earlyaccess."' _ "$NEWLINE_OUTPUT"

# Internal whitespace is still a user error — don't silently merge tokens.
INTERNAL_TMP=$(mktemp -d)
INTERNAL_EXIT=0
INTERNAL_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH=Early Access" -v "$INTERNAL_TMP:/Roon" "$IMAGE" 2>&1) || INTERNAL_EXIT=$?
rm -rf "$INTERNAL_TMP"
check "internal whitespace in ROON_INSTALL_BRANCH: still rejected" \
    test "$INTERNAL_EXIT" -ne 0

# Whitespace tolerance: leading, trailing, and newline variants should
# normalize to the clean value. Copy-paste from YAML or docker-run command
# lines easily introduces these; erroring out on them is an unfriendly
# trap that's easy to avoid with a sed trim.
LEAD_TMP=$(mktemp -d)
LEAD_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH= earlyaccess" -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$LEAD_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$LEAD_TMP"
check "leading whitespace in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -q "Requested branch .earlyaccess."' _ "$LEAD_OUTPUT"

TRAIL_TMP=$(mktemp -d)
TRAIL_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH=earlyaccess  " -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$TRAIL_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$TRAIL_TMP"
check "trailing whitespace in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -q "Requested branch .earlyaccess."' _ "$TRAIL_OUTPUT"

NEWLINE_TMP=$(mktemp -d)
NEWLINE_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH=$(printf 'earlyaccess\n')" -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$NEWLINE_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$NEWLINE_TMP"
check "trailing newline in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -q "Requested branch .earlyaccess."' _ "$NEWLINE_OUTPUT"

# Internal whitespace is still a user error — don't silently merge tokens.
INTERNAL_TMP=$(mktemp -d)
INTERNAL_EXIT=0
INTERNAL_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH=Early Access" -v "$INTERNAL_TMP:/Roon" "$IMAGE" 2>&1) || INTERNAL_EXIT=$?
rm -rf "$INTERNAL_TMP"
check "internal whitespace in ROON_INSTALL_BRANCH: still rejected" \
    test "$INTERNAL_EXIT" -ne 0

# Unset ROON_INSTALL_BRANCH with no VERSION file → defaults to production
UNSET_TMP=$(mktemp -d)
UNSET_EXIT=0
UNSET_OUTPUT=$(docker run --rm -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$UNSET_TMP:/Roon" "$IMAGE" 2>&1) || UNSET_EXIT=$?
rm -rf "$UNSET_TMP"
check "unset ROON_INSTALL_BRANCH + no install: uses default branch 'production'" \
    sh -c 'echo "$1" | grep -q "using default branch .production."' _ "$UNSET_OUTPUT"

# Empty VERSION file (corrupt prior install) → entrypoint should NOT log
# "Detected existing install (branch: )" with a blank, and should fall
# through to the no-install path cleanly. This guards the whitespace-strip
# in the installed-branch detection.
EMPTY_VER_TMP=$(mktemp -d)
mkdir -p "$EMPTY_VER_TMP/app/RoonServer"
: > "$EMPTY_VER_TMP/app/RoonServer/VERSION"
EMPTY_VER_OUTPUT=$(docker run --rm -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$EMPTY_VER_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$EMPTY_VER_TMP" 2>/dev/null || true
check "empty VERSION file: no blank-branch log line" \
    sh -c '! echo "$1" | grep -q "Detected existing RoonServer install (branch: )"' _ "$EMPTY_VER_OUTPUT"
check "empty VERSION file: logs distinct empty-file message" \
    sh -c 'echo "$1" | grep -q "VERSION file.*is empty"' _ "$EMPTY_VER_OUTPUT"

# Startup banner is always emitted (regardless of branch resolution outcome)
check "startup banner always logged" \
    sh -c 'echo "$1" | grep -q "^Roon Docker image "' _ "$UNSET_OUTPUT"

# ─── Entrypoint validation: /Roon mount ──────────────────────────

RO_TMP=$(mktemp -d)
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
