#!/usr/bin/env bash
# Starts the container and validates the download/install/startup flow.
# Covers fresh installs, branch switches in BOTH directions, restart
# skipping, auto-downgrade when env unset, and ROON_DOWNLOAD_URL override.
#
# Downloads ~200MB per branch from download.roonlabs.net.
#
# Platform-aware tmpdir selection:
#
# Linux (CI):  `mktemp -d` → /tmp/... — shared with containers natively.
#
# macOS:       BSD `mktemp -d` hardcodes /var/folders/... and ignores
#              TMPDIR. Docker Desktop's default file-sharing list doesn't
#              include /var/folders, so bind mounts of those tmpdirs
#              appear empty inside containers and the tests time out on
#              files that never reach the host. Default tmp root to
#              $HOME/.cache/roon-test-tmp, which Docker Desktop shares
#              under the $HOME entry — works out of the box.
#
# Override:    Set ROON_TEST_TMP_ROOT explicitly to force any base path
#              (e.g. to opt out of the macOS default, or point somewhere
#              on a specific volume).
set -euo pipefail

IMAGE="${1:?Usage: runtime.sh <image:tag>}"
PASS=0
FAIL=0

if [ -z "${ROON_TEST_TMP_ROOT:-}" ] && [ "$(uname -s)" = "Darwin" ]; then
    ROON_TEST_TMP_ROOT="$HOME/.cache/roon-test-tmp"
fi

# Wrapper around `mktemp -d` that honors ROON_TEST_TMP_ROOT when set.
# See header comment for why macOS/Docker Desktop needs this override.
mktemp_roon_dir() {
    if [ -n "${ROON_TEST_TMP_ROOT:-}" ]; then
        mkdir -p "$ROON_TEST_TMP_ROOT"
        mktemp -d "$ROON_TEST_TMP_ROOT/roon-runtime.XXXXXX"
    else
        mktemp -d
    fi
}

# Track containers + tempdirs so the EXIT trap cleans them up even if a
# test errors out mid-run. Previous revisions had `trap - EXIT` calls
# without any matching `trap` ever being set — dead code that leaked
# containers named roon-runtime-* and orphaned tempdirs.
CLEANUP_CONTAINERS=()
CLEANUP_DIRS=()

cleanup() {
    # Size-gate iteration: under bash 3.2 + set -u (macOS /bin/bash),
    # "${arr[@]}" on a declared-but-empty array errors with "unbound
    # variable". `${#arr[@]}` is always defined and returns 0 for empty,
    # so we guard the loop and use the properly-quoted expansion inside
    # (preserves paths containing spaces — a real concern on macOS where
    # $HOME may have a space in it).
    local c
    if [ "${#CLEANUP_CONTAINERS[@]}" -gt 0 ]; then
        for c in "${CLEANUP_CONTAINERS[@]}"; do
            docker rm -f "$c" >/dev/null 2>&1 || true
        done
    fi
    local d
    if [ "${#CLEANUP_DIRS[@]}" -gt 0 ]; then
        for d in "${CLEANUP_DIRS[@]}"; do
            rm -rf "$d" 2>/dev/null || true
        done
    fi
}
trap cleanup EXIT

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

# Wait for VERSION file to appear (indicates RoonServer install complete).
# Returns non-zero on timeout so set -e halts the run — a download that
# never completes is a test failure, not something to silently continue past.
wait_for_install() {
    local dir="$1"
    local timeout="${2:-180}"
    local elapsed=0
    echo "    Waiting for RoonServer download..."
    while [ ! -f "$dir/app/RoonServer/VERSION" ]; do
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "    wait_for_install: timed out after ${timeout}s waiting for $dir/app/RoonServer/VERSION" >&2
            return 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo "    ... ${elapsed}s"
    done
}

# Wait for a specific branch to appear in the VERSION file's last line.
# Used when branch-switching — we need the new install to replace the old.
wait_for_branch() {
    local dir="$1"
    local branch="$2"
    local timeout="${3:-180}"
    local elapsed=0
    echo "    Waiting for branch switch to '$branch'..."
    while true; do
        if [ -f "$dir/app/RoonServer/VERSION" ] && \
           [ "$(tail -1 "$dir/app/RoonServer/VERSION" 2>/dev/null)" = "$branch" ]; then
            return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "    wait_for_branch: timed out after ${timeout}s (VERSION last line = $(tail -1 "$dir/app/RoonServer/VERSION" 2>/dev/null || echo '<missing>'))" >&2
            return 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo "    ... ${elapsed}s"
    done
}

# Wait for a container's HEALTHCHECK to report the desired status.
# status must be one of: "healthy", "unhealthy". Returns non-zero on timeout.
wait_for_health() {
    local container="$1"
    local target="$2"
    local timeout="${3:-240}"
    local elapsed=0
    echo "    Waiting for health status '$target'..."
    while true; do
        local status
        status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo 'missing')"
        if [ "$status" = "$target" ]; then
            return 0
        fi
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "    wait_for_health: timed out after ${timeout}s (last status: $status)" >&2
            return 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        echo "    ... ${elapsed}s (status: $status)"
    done
}

# Poll `docker logs` until $pattern appears, or $timeout seconds elapse.
# Returns non-zero on timeout with a diagnostic tail.
wait_for_log() {
    local container="$1"
    local pattern="$2"
    local timeout="${3:-30}"
    local elapsed=0
    while ! docker logs "$container" 2>&1 | grep -qE "$pattern"; do
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "    wait_for_log: timed out after ${timeout}s waiting for /$pattern/" >&2
            echo "    --- last 20 log lines ---" >&2
            docker logs --tail 20 "$container" >&2 2>&1 || true
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

# Register a container for cleanup-on-exit and start it.
# Usage: start_container <name> <roon_dir> [extra docker run args...]
start_container() {
    local name="$1"; shift
    local dir="$1"; shift
    CLEANUP_CONTAINERS+=("$name")
    docker run -d --name "$name" -v "$dir:/Roon" "$@" "$IMAGE" >/dev/null
}

# ─── Production branch (fresh install) ──────────────────────────

echo ""
echo "=== Runtime tests (production fresh install): $IMAGE ==="

CONTAINER="roon-runtime-production"
ROON_DIR="$(mktemp_roon_dir)"
CLEANUP_DIRS+=("$ROON_DIR")
echo "    Temp dir: $ROON_DIR"

start_container "$CONTAINER" "$ROON_DIR"

wait_for_install "$ROON_DIR"

check "VERSION file created" \
    test -f "$ROON_DIR/app/RoonServer/VERSION"

check "VERSION contains build info" \
    grep -q "build" "$ROON_DIR/app/RoonServer/VERSION"

check "VERSION last line is production" \
    sh -c '[ "$(tail -1 "$1")" = "production" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

check "RoonServer directory exists" \
    test -d "$ROON_DIR/app/RoonServer"

check "start.sh exists" \
    test -f "$ROON_DIR/app/RoonServer/start.sh"

check "Server/RoonServer launcher exists" \
    test -f "$ROON_DIR/app/RoonServer/Server/RoonServer"

check "RoonDotnet runtime exists" \
    test -d "$ROON_DIR/app/RoonServer/RoonDotnet"


wait_for_log "$CONTAINER" "^Branch: production"
docker logs "$CONTAINER" > "$ROON_DIR/container.log" 2>&1 || true

check "logs contain startup banner" \
    grep -q "^Roon Docker image " "$ROON_DIR/container.log"

check "logs contain image version line" \
    grep -q "^Image:" "$ROON_DIR/container.log"

check "logs contain branch" \
    grep -q "^Branch: production" "$ROON_DIR/container.log"

check "logs contain roon version" \
    grep -q "^Roon:" "$ROON_DIR/container.log"

# Record production version for later comparison
PROD_VERSION=$(sed -n '2p' "$ROON_DIR/app/RoonServer/VERSION" 2>/dev/null || echo "")

# HEALTHCHECK happy path — with RoonServer.dll running, the grep-based
# healthcheck in Dockerfile should flip to "healthy" once start_period
# elapses (120s) plus one interval (30s). Budget 240s total.
check "HEALTHCHECK reports 'healthy' when RoonServer.dll is running" \
    wait_for_health "$CONTAINER" healthy 240

echo "    Testing clean shutdown..."
docker stop -t 30 "$CONTAINER" 2>/dev/null || true
EXIT_CODE=$(docker inspect "$CONTAINER" --format '{{.State.ExitCode}}')
check "clean shutdown (exit 0 or 143, got $EXIT_CODE)" \
    test "$EXIT_CODE" -eq 0 -o "$EXIT_CODE" -eq 143

# ─── Fresh EA install ──────────────────────────────────────────

echo ""
echo "=== Runtime tests (earlyaccess fresh install): $IMAGE ==="

CONTAINER="roon-runtime-ea-fresh"
ROON_DIR="$(mktemp_roon_dir)"
CLEANUP_DIRS+=("$ROON_DIR")
echo "    Temp dir: $ROON_DIR"

start_container "$CONTAINER" "$ROON_DIR" -e ROON_INSTALL_BRANCH=earlyaccess

wait_for_install "$ROON_DIR"

check "fresh EA: VERSION file created" \
    test -f "$ROON_DIR/app/RoonServer/VERSION"

check "fresh EA: VERSION last line is earlyaccess" \
    sh -c '[ "$(tail -1 "$1")" = "earlyaccess" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

wait_for_log "$CONTAINER" "^Branch: earlyaccess"
docker logs "$CONTAINER" > "$ROON_DIR/ea-fresh.log" 2>&1 || true

check "fresh EA: logs show earlyaccess branch" \
    grep -q "^Branch: earlyaccess" "$ROON_DIR/ea-fresh.log"

check "fresh EA: logs show fresh-install decision" \
    grep -q "No install present; installing branch 'earlyaccess'" "$ROON_DIR/ea-fresh.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

# ─── Branch switch: production → earlyaccess ─────────────────

echo ""
echo "=== Runtime tests (switch production → earlyaccess): $IMAGE ==="

CONTAINER="roon-runtime-switch-prod-ea"
ROON_DIR="$(mktemp_roon_dir)"
CLEANUP_DIRS+=("$ROON_DIR")
echo "    Temp dir: $ROON_DIR"

# First: install production (no env var → default)
start_container "$CONTAINER" "$ROON_DIR"
wait_for_install "$ROON_DIR"
docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

check "production installed before switch" \
    sh -c '[ "$(tail -1 "$1")" = "production" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

# Now: switch to earlyaccess
start_container "$CONTAINER" "$ROON_DIR" -e ROON_INSTALL_BRANCH=earlyaccess
wait_for_branch "$ROON_DIR" "earlyaccess"
wait_for_log "$CONTAINER" "^Branch: earlyaccess"
docker logs "$CONTAINER" > "$ROON_DIR/switch.log" 2>&1 || true

check "prod→EA: logs show branch change detected" \
    grep -q "Branch change detected: production -> earlyaccess" "$ROON_DIR/switch.log"

check "prod→EA: extraction ran (clean reinstall)" \
    grep -q "^Extracting to " "$ROON_DIR/switch.log"

check "prod→EA: VERSION last line is earlyaccess" \
    sh -c '[ "$(tail -1 "$1")" = "earlyaccess" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

check "prod→EA: logs show earlyaccess branch" \
    grep -q "^Branch: earlyaccess" "$ROON_DIR/switch.log"

# EA version may differ from production
EA_VERSION=$(sed -n '2p' "$ROON_DIR/app/RoonServer/VERSION" 2>/dev/null || echo "")
if [ -n "$PROD_VERSION" ] && [ -n "$EA_VERSION" ]; then
    echo "    Production version: $PROD_VERSION"
    echo "    EA version:         $EA_VERSION"
fi

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

# ─── Branch switch: earlyaccess → production (regression guard) ──
#
# Regression guard: the configurator used to omit ROON_INSTALL_BRANCH=production
# from its output, leaving users stranded on earlyaccess after a "downgrade"
# attempt. The entrypoint's branch-change detection only triggers when the
# env var is set AND differs from the installed VERSION. Without this test,
# a regression that re-introduces the omission would slip through.

echo ""
echo "=== Runtime tests (switch earlyaccess → production): $IMAGE ==="

CONTAINER="roon-runtime-switch-ea-prod"
ROON_DIR="$(mktemp_roon_dir)"
CLEANUP_DIRS+=("$ROON_DIR")
echo "    Temp dir: $ROON_DIR"

# First: install earlyaccess
start_container "$CONTAINER" "$ROON_DIR" -e ROON_INSTALL_BRANCH=earlyaccess
wait_for_install "$ROON_DIR"
docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

check "earlyaccess installed before downgrade" \
    sh -c '[ "$(tail -1 "$1")" = "earlyaccess" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

# Now: downgrade to production (explicit env var required — this is the fix)
start_container "$CONTAINER" "$ROON_DIR" -e ROON_INSTALL_BRANCH=production
wait_for_branch "$ROON_DIR" "production"
wait_for_log "$CONTAINER" "^Branch: production"
docker logs "$CONTAINER" > "$ROON_DIR/downgrade.log" 2>&1 || true

check "EA→prod: logs show branch change detected" \
    grep -q "Branch change detected: earlyaccess -> production" "$ROON_DIR/downgrade.log"

check "EA→prod: VERSION last line is production" \
    sh -c '[ "$(tail -1 "$1")" = "production" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

check "EA→prod: logs show production branch" \
    grep -q "^Branch: production" "$ROON_DIR/downgrade.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

# ─── Restart with existing install: no re-download ────────────

echo ""
echo "=== Runtime tests (restart skips download): $IMAGE ==="

CONTAINER="roon-runtime-restart"
ROON_DIR="$(mktemp_roon_dir)"
CLEANUP_DIRS+=("$ROON_DIR")
echo "    Temp dir: $ROON_DIR"

# Install production first
start_container "$CONTAINER" "$ROON_DIR"
wait_for_install "$ROON_DIR"
docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Restart — should NOT re-download.
# Grep for "Extracting to " (emitted only when a download actually happens)
# rather than the substring "downloading" (brittle; phrase changes break it).
start_container "$CONTAINER" "$ROON_DIR"
wait_for_log "$CONTAINER" "^Branch: production"
docker logs "$CONTAINER" > "$ROON_DIR/restart.log" 2>&1 || true

check "restart does not re-download (no Extracting line)" \
    sh -c '! grep -q "^Extracting to " "$1"' _ "$ROON_DIR/restart.log"

# Unset env defaults to production. With production installed, the requested
# and installed branches match, so the entrypoint logs "no reinstall needed"
# rather than triggering a download.
check "restart logs 'no reinstall needed'" \
    grep -q "matches requested branch; no reinstall needed" "$ROON_DIR/restart.log"

check "restart logs branch" \
    grep -q "^Branch: production" "$ROON_DIR/restart.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Explicit ROON_INSTALL_BRANCH=production on existing production — should also skip download
start_container "$CONTAINER" "$ROON_DIR" -e ROON_INSTALL_BRANCH=production
wait_for_log "$CONTAINER" "^Branch: production"
docker logs "$CONTAINER" > "$ROON_DIR/explicit.log" 2>&1 || true

check "explicit same-branch: no re-download" \
    sh -c '! grep -q "^Extracting to " "$1"' _ "$ROON_DIR/explicit.log"

check "explicit same-branch: logs 'no reinstall needed'" \
    grep -q "matches requested branch; no reinstall needed" "$ROON_DIR/explicit.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

# ─── Auto-downgrade: unset env reinstalls as production ──────────
#
# ROON_INSTALL_BRANCH defaults to production when unset. If a user
# previously installed earlyaccess explicitly and then removes the env
# var on restart, the entrypoint reinstalls as production. This is the
# opposite of the previous "sticky-branch" behavior, chosen for clarity:
# the env var works like every other configurable (a default that can be
# overridden) rather than having state-dependent meaning.

echo ""
echo "=== Runtime tests (auto-downgrade EA → production on unset env): $IMAGE ==="

CONTAINER="roon-runtime-auto-downgrade"
ROON_DIR="$(mktemp_roon_dir)"
CLEANUP_DIRS+=("$ROON_DIR")
echo "    Temp dir: $ROON_DIR"

# Install EA first
start_container "$CONTAINER" "$ROON_DIR" -e ROON_INSTALL_BRANCH=earlyaccess
wait_for_install "$ROON_DIR"
docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Restart WITHOUT the env var — should auto-reinstall as production
start_container "$CONTAINER" "$ROON_DIR"
wait_for_branch "$ROON_DIR" "production"
wait_for_log "$CONTAINER" "^Branch: production"
docker logs "$CONTAINER" > "$ROON_DIR/auto-downgrade.log" 2>&1 || true

check "auto-downgrade: VERSION last line is production" \
    sh -c '[ "$(tail -1 "$1")" = "production" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

check "auto-downgrade: logs branch change detected" \
    grep -q "Branch change detected: earlyaccess -> production" "$ROON_DIR/auto-downgrade.log"

check "auto-downgrade: logs Branch: production" \
    grep -q "^Branch: production" "$ROON_DIR/auto-downgrade.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

# ─── ROON_DOWNLOAD_URL override ──────────────────────────────────
#
# When ROON_DOWNLOAD_URL is set, it takes precedence over ROON_INSTALL_BRANCH.
# Two paths to verify:
#   (1) Fresh install with custom URL → uses URL, doesn't derive from branch.
#   (2) Existing install + custom URL → does NOT trigger a reinstall, even if
#       ROON_INSTALL_BRANCH disagrees with the installed branch.

echo ""
echo "=== Runtime tests (ROON_DOWNLOAD_URL override): $IMAGE ==="

# Path 1: fresh install — URL points at the production tarball, but we set
# ROON_INSTALL_BRANCH=earlyaccess to prove the URL wins. The installed
# binary should be production (last line of VERSION).
CONTAINER="roon-runtime-url-override-fresh"
ROON_DIR="$(mktemp_roon_dir)"
CLEANUP_DIRS+=("$ROON_DIR")
echo "    Temp dir: $ROON_DIR"

PROD_URL="https://download.roonlabs.net/builds/production/RoonServer_linuxx64.tar.bz2"
start_container "$CONTAINER" "$ROON_DIR" \
    -e ROON_INSTALL_BRANCH=earlyaccess \
    -e ROON_DOWNLOAD_URL="$PROD_URL"
wait_for_install "$ROON_DIR"
wait_for_log "$CONTAINER" "^Branch: production"
docker logs "$CONTAINER" > "$ROON_DIR/url-override-fresh.log" 2>&1 || true

check "URL override (fresh): logs custom URL message" \
    grep -q "Custom ROON_DOWNLOAD_URL set; performing fresh install" "$ROON_DIR/url-override-fresh.log"

check "URL override (fresh): VERSION reflects URL content (production)" \
    sh -c '[ "$(tail -1 "$1")" = "production" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

check "URL override (fresh): final Branch log reflects actual install" \
    grep -q "^Branch: production" "$ROON_DIR/url-override-fresh.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Path 2: existing install with mismatched env var. Restart with
# ROON_DOWNLOAD_URL set and ROON_INSTALL_BRANCH=earlyaccess; the URL
# override should suppress the branch-change reinstall logic.
start_container "$CONTAINER" "$ROON_DIR" \
    -e ROON_INSTALL_BRANCH=earlyaccess \
    -e ROON_DOWNLOAD_URL="$PROD_URL"
wait_for_log "$CONTAINER" "^Branch: production"
docker logs "$CONTAINER" > "$ROON_DIR/url-override-existing.log" 2>&1 || true

check "URL override (existing): logs custom URL using existing install" \
    grep -q "Custom ROON_DOWNLOAD_URL set; using existing install" "$ROON_DIR/url-override-existing.log"

check "URL override (existing): no re-extract" \
    sh -c '! grep -q "^Extracting to " "$1"' _ "$ROON_DIR/url-override-existing.log"

check "URL override (existing): no branch-change reinstall" \
    sh -c '! grep -q "Branch change detected" "$1"' _ "$ROON_DIR/url-override-existing.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

# ─── HEALTHCHECK unhealthy path ──────────────────────────────────
#
# Verify the HEALTHCHECK defined in Dockerfile actually flips to
# "unhealthy" when RoonServer.dll is not running. Without this test,
# a broken grep pattern (e.g., someone silently changing the filename)
# would leave containers reporting "healthy" even after Roon crashed.
#
# Start with `--entrypoint sleep` so RoonServer.dll never runs but the
# HEALTHCHECK directive still applies. After start_period (120s) +
# 3 × interval (30s each) = 210s, status should be "unhealthy".

echo ""
echo "=== Runtime tests (HEALTHCHECK unhealthy path): $IMAGE ==="

CONTAINER="roon-runtime-health-unhealthy"
CLEANUP_CONTAINERS+=("$CONTAINER")

docker run -d --name "$CONTAINER" \
    --entrypoint sleep \
    "$IMAGE" infinity >/dev/null

# Give it up to 4 minutes: start_period 120s + 3 × 30s retries + margin.
check "HEALTHCHECK reports 'unhealthy' when RoonServer.dll is absent" \
    wait_for_health "$CONTAINER" unhealthy 240

docker stop -t 5 "$CONTAINER" 2>/dev/null || true

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
