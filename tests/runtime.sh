#!/usr/bin/env bash
# Starts the container and validates the download/install/startup flow.
# Tests production install, EA install, and channel switching.
# Downloads ~200MB per channel from download.roonlabs.net.
set -euo pipefail

IMAGE="${1:?Usage: runtime.sh <image:tag>}"
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

wait_for_install() {
    local dir="$1"
    local timeout="${2:-120}"
    local elapsed=0
    echo "    Waiting for RoonServer download..."
    while [ ! -f "$dir/app/RoonServer/VERSION" ] && [ "$elapsed" -lt "$timeout" ]; do
        sleep 5
        elapsed=$((elapsed + 5))
        echo "    ... ${elapsed}s"
    done
}

# ─── Production channel ────────────────────────────────────────

echo "=== Runtime tests (production): $IMAGE ==="

CONTAINER="roon-runtime-production"
ROON_DIR="$(mktemp -d)"
echo "    Temp dir: $ROON_DIR"

cleanup_production() {
    docker rm -f "$CONTAINER" 2>/dev/null || true
    rm -rf "$ROON_DIR"
}
trap cleanup_production EXIT

docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    "$IMAGE"

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


sleep 5
docker logs "$CONTAINER" > "$ROON_DIR/container.log" 2>&1 || true

check "logs contain image version" \
    grep -q "^Image:" "$ROON_DIR/container.log"

check "logs contain channel" \
    grep -q "^Channel: production" "$ROON_DIR/container.log"

check "logs contain roon version" \
    grep -q "^Roon:" "$ROON_DIR/container.log"

# Record production version for later comparison
PROD_VERSION=$(sed -n '2p' "$ROON_DIR/app/RoonServer/VERSION" 2>/dev/null || echo "")

echo "    Testing clean shutdown..."
docker stop -t 30 "$CONTAINER" 2>/dev/null || true
EXIT_CODE=$(docker inspect "$CONTAINER" --format '{{.State.ExitCode}}')
check "clean shutdown (exit 0 or 143, got $EXIT_CODE)" \
    test "$EXIT_CODE" -eq 0 -o "$EXIT_CODE" -eq 143

cleanup_production
trap - EXIT

# ─── Fresh EA install ──────────────────────────────────────────

echo ""
echo "=== Runtime tests (fresh EA install): $IMAGE ==="

CONTAINER="roon-runtime-ea-fresh"
ROON_DIR="$(mktemp -d)"
echo "    Temp dir: $ROON_DIR"

cleanup_ea_fresh() {
    docker rm -f "$CONTAINER" 2>/dev/null || true
    rm -rf "$ROON_DIR"
}
trap cleanup_ea_fresh EXIT

docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    -e ROON_INSTALL_BRANCH=earlyaccess \
    "$IMAGE"

wait_for_install "$ROON_DIR"

check "fresh EA: VERSION file created" \
    test -f "$ROON_DIR/app/RoonServer/VERSION"

check "fresh EA: VERSION last line is earlyaccess" \
    sh -c '[ "$(tail -1 "$1")" = "earlyaccess" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

sleep 3
docker logs "$CONTAINER" > "$ROON_DIR/ea-fresh.log" 2>&1 || true

check "fresh EA: logs show earlyaccess channel" \
    grep -q "^Channel: earlyaccess" "$ROON_DIR/ea-fresh.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

cleanup_ea_fresh
trap - EXIT

# ─── Channel switch: production → earlyaccess ─────────────────

echo ""
echo "=== Runtime tests (channel switch → earlyaccess): $IMAGE ==="

CONTAINER="roon-runtime-switch"
ROON_DIR="$(mktemp -d)"
echo "    Temp dir: $ROON_DIR"

cleanup_switch() {
    docker rm -f "$CONTAINER" 2>/dev/null || true
    rm -rf "$ROON_DIR"
}
trap cleanup_switch EXIT

# First: install production
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    "$IMAGE"

wait_for_install "$ROON_DIR"
docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

check "production installed before switch" \
    sh -c '[ "$(tail -1 "$1")" = "production" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

# Now: switch to earlyaccess
# The entrypoint detects VERSION branch=production vs ROON_INSTALL_BRANCH=earlyaccess,
# removes old binaries, and re-downloads. We wait for the VERSION file to reappear with earlyaccess.
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    -e ROON_INSTALL_BRANCH=earlyaccess \
    "$IMAGE"

echo "    Waiting for channel switch..."
TIMEOUT=180
ELAPSED=0
while ! tail -1 "$ROON_DIR/app/RoonServer/VERSION" 2>/dev/null | grep -q "earlyaccess" && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "    ... ${ELAPSED}s"
done

sleep 3
docker logs "$CONTAINER" > "$ROON_DIR/switch.log" 2>&1 || true

check "logs show branch change detected" \
    grep -q "Branch change detected" "$ROON_DIR/switch.log"

check "VERSION last line is earlyaccess" \
    sh -c '[ "$(tail -1 "$1")" = "earlyaccess" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

check "logs show earlyaccess channel" \
    grep -q "^Channel: earlyaccess" "$ROON_DIR/switch.log"

# EA version may differ from production
EA_VERSION=$(sed -n '2p' "$ROON_DIR/app/RoonServer/VERSION" 2>/dev/null || echo "")
if [ -n "$PROD_VERSION" ] && [ -n "$EA_VERSION" ]; then
    echo "    Production version: $PROD_VERSION"
    echo "    EA version:         $EA_VERSION"
fi

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

cleanup_switch
trap - EXIT

# ─── Restart: existing install skips re-download ───────────────

echo ""
echo "=== Runtime tests (restart skips download): $IMAGE ==="

CONTAINER="roon-runtime-restart"
ROON_DIR="$(mktemp -d)"
echo "    Temp dir: $ROON_DIR"

cleanup_restart() {
    docker rm -f "$CONTAINER" 2>/dev/null || true
    rm -rf "$ROON_DIR"
}
trap cleanup_restart EXIT

# Install production first
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    "$IMAGE"

wait_for_install "$ROON_DIR"
docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Restart — should NOT re-download
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    "$IMAGE"

# Give it a few seconds to start
sleep 5

docker logs "$CONTAINER" > "$ROON_DIR/restart.log" 2>&1 || true

check "restart does not re-download" \
    sh -c '! grep -q "downloading" "$1"' _ "$ROON_DIR/restart.log"

check "restart logs channel" \
    grep -q "^Channel: production" "$ROON_DIR/restart.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Explicit ROON_INSTALL_BRANCH=production on existing production — should also skip download
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    -e ROON_INSTALL_BRANCH=production \
    "$IMAGE"

sleep 5

docker logs "$CONTAINER" > "$ROON_DIR/explicit.log" 2>&1 || true

check "explicit production on existing production skips download" \
    sh -c '! grep -q "downloading" "$1"' _ "$ROON_DIR/explicit.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

cleanup_restart
trap - EXIT

# ─── Pre-channel upgrade: VERSION exists, user requests EA ─────

echo ""
echo "=== Runtime tests (pre-channel upgrade): $IMAGE ==="

CONTAINER="roon-runtime-upgrade"
ROON_DIR="$(mktemp -d)"
echo "    Temp dir: $ROON_DIR"

cleanup_upgrade() {
    docker rm -f "$CONTAINER" 2>/dev/null || true
    rm -rf "$ROON_DIR"
}
trap cleanup_upgrade EXIT

# Install production first
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    "$IMAGE"

wait_for_install "$ROON_DIR"
docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Restart without setting ROON_INSTALL_BRANCH — should keep production
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    "$IMAGE"

sleep 5

docker logs "$CONTAINER" > "$ROON_DIR/upgrade.log" 2>&1 || true

check "unset ROON_INSTALL_BRANCH keeps existing install" \
    sh -c '! grep -q "downloading" "$1"' _ "$ROON_DIR/upgrade.log"

check "unset ROON_INSTALL_BRANCH logs production" \
    grep -q "^Channel: production" "$ROON_DIR/upgrade.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Now request EA on existing production install
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    -e ROON_INSTALL_BRANCH=earlyaccess \
    "$IMAGE"

echo "    Waiting for EA reinstall..."
TIMEOUT=180
ELAPSED=0
while ! tail -1 "$ROON_DIR/app/RoonServer/VERSION" 2>/dev/null | grep -q "earlyaccess" && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "    ... ${ELAPSED}s"
done

check "explicit ROON_INSTALL_BRANCH switches to EA" \
    sh -c '[ "$(tail -1 "$1")" = "earlyaccess" ]' _ "$ROON_DIR/app/RoonServer/VERSION"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

cleanup_upgrade
trap - EXIT

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
