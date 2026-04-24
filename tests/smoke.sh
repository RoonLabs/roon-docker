#!/usr/bin/env bash
# Quick checks against the built image — no container start, no network.
# Verifies image contract: binaries, libraries, labels, env, entrypoint
# validation behavior. Does not exercise the actual install flow (see
# runtime.sh for that).
set -euo pipefail

IMAGE="${1:?Usage: smoke.sh <image:tag>}"
PASS=0
FAIL=0

# Run $@ quietly; on failure, replay captured stderr indented under the
# FAIL line so CI logs show *why* the check failed instead of just what.
# stdout is always discarded (most checks call docker inspect/cat/etc. and
# the stdout would be noise); stderr is captured via `2>&1 >/dev/null`.
check() {
    local desc="$1"; shift
    local err
    if err=$("$@" 2>&1 >/dev/null); then
        echo "  PASS  $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $desc"
        if [ -n "$err" ]; then
            printf '        | %s\n' "$err"
        fi
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Smoke tests: $IMAGE ==="

# ─── Entrypoint + binaries ───────────────────────────────────────

check "entrypoint exists and is executable" \
    docker run --rm --entrypoint stat "$IMAGE" -c '%a' /entrypoint.sh

for bin in bash curl bzip2 tar ffmpeg; do
    check "$bin is available" \
        docker run --rm --entrypoint which "$IMAGE" "$bin"
done

# FFmpeg is a static binary from johnvansickle.com — verify it actually
# executes on this image's glibc/kernel ABI, not just that the file exists.
check "ffmpeg runs (static binary ABI-compatible)" \
    docker run --rm --entrypoint ffmpeg "$IMAGE" -hide_banner -version

# ─── Runtime library presence (.NET stack for RoonServer) ─────────
# Dockerfile installs these via apt. Without them, RoonServer fails to
# start with cryptic errors. One ldconfig check per library catches a
# silent Debian base-image drift (Trixie → Forky, libicu76 → libicu77).

check "libicu (for .NET globalization)" \
    docker run --rm --entrypoint sh "$IMAGE" -c 'ldconfig -p | grep -q libicuuc.so'

check "libasound (ALSA — required by libraatmanager.so)" \
    docker run --rm --entrypoint sh "$IMAGE" -c 'ldconfig -p | grep -q libasound'

check "libfreetype (linked by bundled libharfbuzz)" \
    docker run --rm --entrypoint sh "$IMAGE" -c 'ldconfig -p | grep -q libfreetype.so'

check "libbz2 (bzip2 for tarball extraction)" \
    docker run --rm --entrypoint sh "$IMAGE" -c 'ldconfig -p | grep -q libbz2.so'

check "tzdata (zoneinfo available)" \
    docker run --rm --entrypoint test "$IMAGE" -d /usr/share/zoneinfo

check "ca-certificates (HTTPS to download.roonlabs.net)" \
    docker run --rm --entrypoint test "$IMAGE" -f /etc/ssl/certs/ca-certificates.crt

# ─── Environment hygiene ─────────────────────────────────────────

# ROON_DATAROOT and ROON_ID_DIR are set by entrypoint, not the image
check "ROON_DATAROOT not leaked in image env" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ -z "$ROON_DATAROOT" ]'

check "ROON_ID_DIR not leaked in image env" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ -z "$ROON_ID_DIR" ]'

# No common secret/credential env names leaked into the image
check "no credential-looking env vars baked in" \
    docker run --rm --entrypoint sh "$IMAGE" -c '! env | grep -iE "(password|secret|token|api[_-]?key)="'

# ─── Image-version contract ──────────────────────────────────────

check "/etc/roon-image-version exists" \
    docker run --rm --entrypoint cat "$IMAGE" /etc/roon-image-version

# Content is non-empty and not the fallback "unknown" string
check "/etc/roon-image-version has real content" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ -s /etc/roon-image-version ] && [ "$(cat /etc/roon-image-version)" != "unknown" ]'

# Image-version file matches the OCI version label (same ARG feeds both)
FILE_VERSION=$(docker run --rm --entrypoint cat "$IMAGE" /etc/roon-image-version 2>/dev/null || echo '')
LABEL_VERSION=$(docker inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' 2>/dev/null || echo '')
check "image-version file matches OCI version label (file=$FILE_VERSION label=$LABEL_VERSION)" \
    test -n "$FILE_VERSION" -a "$FILE_VERSION" = "$LABEL_VERSION"

# ─── OCI labels ──────────────────────────────────────────────────
# The Dockerfile sets 10 OCI image labels. Missing any of them at runtime
# means the LABEL directive was removed or the CI metadata action drifted.

for label in title authors vendor version description source revision created url licenses; do
    # Capture value first — check() doesn't handle shell pipes (each arg
    # becomes a separate exec argument, not a pipeline).
    LABEL_VALUE=$(docker inspect "$IMAGE" --format "{{ index .Config.Labels \"org.opencontainers.image.${label}\" }}" 2>/dev/null || echo '')
    check "OCI label: $label (=$LABEL_VALUE)" \
        test -n "$LABEL_VALUE"
done

# ─── Image hygiene ───────────────────────────────────────────────

check "apt lists cleaned" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ -z "$(ls /var/lib/apt/lists/)" ]'

check "SUID stripped from mount.cifs" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ ! -u /usr/sbin/mount.cifs ]'

check "entrypoint uses --no-same-permissions (QNAP extract-perm safety)" \
    docker run --rm --entrypoint grep "$IMAGE" -- '--no-same-permissions' /entrypoint.sh

# ─── Entrypoint validation: ROON_INSTALL_BRANCH ──────────────────
# Each of these uses -e ROON_DOWNLOAD_URL=http://localhost:1 so the download
# fails fast after the branch-resolution phase. We check both the exit code
# AND a positive log signal for the resolved branch — stronger than the old
# "not Invalid" negative grep, which passed on unrelated errors too.

INVALID_EXIT=0
INVALID_TMP=$(mktemp -d)
INVALID_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=invalid -v "$INVALID_TMP:/Roon" "$IMAGE" 2>&1) || INVALID_EXIT=$?
rm -rf "$INVALID_TMP"
check "invalid ROON_INSTALL_BRANCH: exits non-zero" \
    test "$INVALID_EXIT" -ne 0
check "invalid ROON_INSTALL_BRANCH: prints error message" \
    sh -c 'echo "$1" | grep -q "Invalid ROON_INSTALL_BRANCH"' _ "$INVALID_OUTPUT"

MIXED_TMP=$(mktemp -d)
MIXED_EXIT=0
MIXED_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=EarlyAccess -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$MIXED_TMP:/Roon" "$IMAGE" 2>&1) || MIXED_EXIT=$?
rm -rf "$MIXED_TMP"
check "mixed-case ROON_INSTALL_BRANCH: accepted (resolves to earlyaccess)" \
    sh -c 'echo "$1" | grep -qF "Requested branch '\''earlyaccess'\''"' _ "$MIXED_OUTPUT"

EMPTY_TMP=$(mktemp -d)
EMPTY_EXIT=0
EMPTY_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH= -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$EMPTY_TMP:/Roon" "$IMAGE" 2>&1) || EMPTY_EXIT=$?
rm -rf "$EMPTY_TMP"
check "empty ROON_INSTALL_BRANCH: defaults to production" \
    sh -c 'echo "$1" | grep -qF "Requested branch '\''production'\''"' _ "$EMPTY_OUTPUT"

EXPLICIT_TMP=$(mktemp -d)
EXPLICIT_EXIT=0
EXPLICIT_OUTPUT=$(docker run --rm -e ROON_INSTALL_BRANCH=production -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$EXPLICIT_TMP:/Roon" "$IMAGE" 2>&1) || EXPLICIT_EXIT=$?
rm -rf "$EXPLICIT_TMP"
check "explicit ROON_INSTALL_BRANCH=production: resolves correctly" \
    sh -c 'echo "$1" | grep -qF "Requested branch '\''production'\''"' _ "$EXPLICIT_OUTPUT"

# Whitespace tolerance: leading, trailing, and newline variants should
# normalize to the clean value. Copy-paste from YAML or docker-run command
# lines easily introduces these; erroring out on them is an unfriendly
# trap that's easy to avoid with a sed trim.
LEAD_TMP=$(mktemp -d)
LEAD_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH= earlyaccess" -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$LEAD_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$LEAD_TMP"
check "leading whitespace in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -qF "Requested branch '\''earlyaccess'\''"' _ "$LEAD_OUTPUT"

TRAIL_TMP=$(mktemp -d)
TRAIL_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH=earlyaccess  " -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$TRAIL_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$TRAIL_TMP"
check "trailing whitespace in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -qF "Requested branch '\''earlyaccess'\''"' _ "$TRAIL_OUTPUT"

NEWLINE_TMP=$(mktemp -d)
NEWLINE_OUTPUT=$(docker run --rm -e "ROON_INSTALL_BRANCH=$(printf 'earlyaccess\n')" -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$NEWLINE_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$NEWLINE_TMP"
check "trailing newline in ROON_INSTALL_BRANCH: stripped" \
    sh -c 'echo "$1" | grep -qF "Requested branch '\''earlyaccess'\''"' _ "$NEWLINE_OUTPUT"

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
    sh -c 'echo "$1" | grep -qF "using default branch '\''production'\''"' _ "$UNSET_OUTPUT"

# Empty VERSION file (corrupt prior install) → entrypoint should NOT log
# "Detected existing install (branch: )" with a blank, and should fall
# through to the no-install path cleanly. This guards the whitespace-strip
# in the installed-branch detection.
#
# Pre-seed the empty VERSION file from inside docker so the test doesn't
# depend on host file-sharing config (Docker Desktop on macOS only shares
# a subset of host paths; `mktemp -d` defaults may not be in that set).
EMPTY_VER_TMP=$(mktemp -d)
# Pre-seed's stderr is NOT suppressed: a silent failure here would make the
# negative assertion below pass trivially (no VERSION file inside the
# container → fresh-install path → no "Detected existing install" line),
# masking a regression in the whitespace-strip code path this test is
# meant to exercise. set -euo pipefail aborts the run if docker run fails.
docker run --rm --entrypoint sh -v "$EMPTY_VER_TMP:/Roon" "$IMAGE" \
    -c 'mkdir -p /Roon/app/RoonServer && : > /Roon/app/RoonServer/VERSION' >/dev/null
EMPTY_VER_OUTPUT=$(docker run --rm -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$EMPTY_VER_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$EMPTY_VER_TMP" 2>/dev/null || true
check "empty VERSION file: no blank-branch log line" \
    sh -c '! echo "$1" | grep -q "Detected existing RoonServer install (branch: )"' _ "$EMPTY_VER_OUTPUT"
check "empty VERSION file: logs distinct empty-file message" \
    sh -c 'echo "$1" | grep -q "VERSION file.*is empty"' _ "$EMPTY_VER_OUTPUT"

# Whitespace-only VERSION file → same path as empty. Guards against someone
# refactoring `tr -d '[:space:]'` (which collapses any whitespace-only
# content to empty string) into something narrower like `sed s/ //g` that
# would leave newlines behind and let a blank sneak through.
WS_VER_TMP=$(mktemp -d)
docker run --rm --entrypoint sh -v "$WS_VER_TMP:/Roon" "$IMAGE" \
    -c 'mkdir -p /Roon/app/RoonServer && printf "\n  \n\t\n" > /Roon/app/RoonServer/VERSION' >/dev/null
WS_VER_OUTPUT=$(docker run --rm -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$WS_VER_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$WS_VER_TMP" 2>/dev/null || true
check "whitespace-only VERSION file: treated as empty" \
    sh -c 'echo "$1" | grep -q "VERSION file.*is empty"' _ "$WS_VER_OUTPUT"

# Multi-line VERSION: branch is on the LAST line (tail -1), not the first.
# Pins the contract against a refactor to head/sed '1p'/etc. Pre-seed a
# VERSION whose first line says "earlyaccess" and last line says
# "production"; the entrypoint's sticky-branch path should keep production.
MULTI_VER_TMP=$(mktemp -d)
docker run --rm --entrypoint sh -v "$MULTI_VER_TMP:/Roon" "$IMAGE" \
    -c 'mkdir -p /Roon/app/RoonServer && printf "earlyaccess\n9999\nproduction\n" > /Roon/app/RoonServer/VERSION' >/dev/null
MULTI_VER_OUTPUT=$(docker run --rm -e ROON_DOWNLOAD_URL=http://localhost:1 -v "$MULTI_VER_TMP:/Roon" "$IMAGE" 2>&1) || true
rm -rf "$MULTI_VER_TMP" 2>/dev/null || true
check "multi-line VERSION: last line wins (sticky keeps production)" \
    sh -c 'echo "$1" | grep -qF "keeping installed branch '\''production'\''"' _ "$MULTI_VER_OUTPUT"

# Image runs as root by default (no USER directive). TrueNAS deployments
# need `user: "0:0"` override because TrueNAS Apps defaults containers to
# UID 568; if a future Dockerfile change added a USER line, the
# configurator's TrueNAS override would silently conflict with it.
check "image has no USER directive (runs as root)" \
    sh -c '[ -z "$(docker inspect --format "{{.Config.User}}" "$1")" ]' _ "$IMAGE"

# Startup banner is always emitted (regardless of branch resolution outcome)
check "startup banner always logged" \
    sh -c 'echo "$1" | grep -q "^Roon Docker image "' _ "$UNSET_OUTPUT"

# ─── Entrypoint validation: /Roon mount ──────────────────────────

RO_TMP=$(mktemp -d)
RO_EXIT=0
RO_OUTPUT=$(docker run --rm -v "$RO_TMP:/Roon:ro" "$IMAGE" 2>&1) || RO_EXIT=$?
rm -rf "$RO_TMP"
check "read-only /Roon: exits non-zero" \
    test "$RO_EXIT" -ne 0
check "read-only /Roon: prints not-writable error" \
    sh -c 'echo "$1" | grep -q "not writable"' _ "$RO_OUTPUT"

# ─── Timezone ────────────────────────────────────────────────────

TZ_OUTPUT=$(docker run --rm --entrypoint sh -e TZ=America/Denver "$IMAGE" -c 'date +%Z' 2>/dev/null)
check "TZ=America/Denver produces MDT or MST (got $TZ_OUTPUT)" \
    sh -c '[ "$1" = "MDT" ] || [ "$1" = "MST" ]' _ "$TZ_OUTPUT"

# ─── Bad download URL (fail-fast path) ───────────────────────────

BAD_TMP=$(mktemp -d)
BAD_EXIT=0
BAD_OUTPUT=$(docker run --rm -e ROON_DOWNLOAD_URL=https://download.roonlabs.net/nonexistent -v "$BAD_TMP:/Roon" "$IMAGE" 2>&1) || BAD_EXIT=$?
rm -rf "$BAD_TMP"
check "bad download URL: exits non-zero" \
    test "$BAD_EXIT" -ne 0
check "bad download URL: curl error message present" \
    sh -c 'echo "$1" | grep -q "curl: ("' _ "$BAD_OUTPUT"
check "bad download URL: no extraction attempted" \
    sh -c '! echo "$1" | grep -q "^Extracting to "' _ "$BAD_OUTPUT"

# ─── NAS compatibility: required binaries ───────────────────────

check "mount.cifs binary exists" \
    docker run --rm --entrypoint which "$IMAGE" mount.cifs

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
