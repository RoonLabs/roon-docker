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
    while [ ! -f "$dir/app/.installed" ] && [ "$elapsed" -lt "$timeout" ]; do
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

check "sentinel file created" \
    test -f "$ROON_DIR/app/.installed"

check "sentinel contains version info" \
    grep -q "build" "$ROON_DIR/app/.installed"

check "RoonServer directory exists" \
    test -d "$ROON_DIR/app/RoonServer"

check "start.sh exists" \
    test -f "$ROON_DIR/app/RoonServer/start.sh"

check "Server/RoonServer launcher exists" \
    test -f "$ROON_DIR/app/RoonServer/Server/RoonServer"

check "RoonDotnet runtime exists" \
    test -d "$ROON_DIR/app/RoonServer/RoonDotnet"

check "VERSION file present in tarball" \
    test -f "$ROON_DIR/app/RoonServer/VERSION"

check "libfreetype.so.6 symlink created" \
    test -L "$ROON_DIR/app/RoonServer/Appliance/libfreetype.so.6"

docker logs "$CONTAINER" > "$ROON_DIR/container.log" 2>&1 || true

check "logs contain image version" \
    grep -q "^Image:" "$ROON_DIR/container.log"

check "logs contain channel" \
    grep -q "^Channel: production" "$ROON_DIR/container.log"

check "logs contain roon version" \
    grep -q "^Roon:" "$ROON_DIR/container.log"

check "channel sentinel file created" \
    test -f "$ROON_DIR/app/.channel"

check "channel sentinel contains production" \
    grep -q "production" "$ROON_DIR/app/.channel"

# Record production version for later comparison
PROD_VERSION=$(cat "$ROON_DIR/app/.installed" 2>/dev/null || echo "")

echo "    Testing clean shutdown..."
docker stop -t 30 "$CONTAINER" 2>/dev/null || true
EXIT_CODE=$(docker inspect "$CONTAINER" --format '{{.State.ExitCode}}')
check "clean shutdown (exit 0 or 143, got $EXIT_CODE)" \
    test "$EXIT_CODE" -eq 0 -o "$EXIT_CODE" -eq 143

cleanup_production
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
    grep -q "production" "$ROON_DIR/app/.channel"

# Now: switch to earlyaccess
# The entrypoint detects .channel=production vs ROON_CHANNEL=earlyaccess, removes old binaries,
# and re-downloads. We wait for .channel to change to earlyaccess as the completion signal.
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    -e ROON_CHANNEL=earlyaccess \
    "$IMAGE"

echo "    Waiting for channel switch..."
TIMEOUT=180
ELAPSED=0
while ! grep -q "earlyaccess" "$ROON_DIR/app/.channel" 2>/dev/null && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "    ... ${ELAPSED}s"
done

docker logs "$CONTAINER" > "$ROON_DIR/switch.log" 2>&1 || true

check "logs show channel change detected" \
    grep -q "Channel change detected" "$ROON_DIR/switch.log"

check "channel sentinel updated to earlyaccess" \
    grep -q "earlyaccess" "$ROON_DIR/app/.channel"

check "logs show earlyaccess channel" \
    grep -q "^Channel: earlyaccess" "$ROON_DIR/switch.log"

check "RoonServer reinstalled after switch" \
    test -f "$ROON_DIR/app/.installed"

# EA version may differ from production
EA_VERSION=$(cat "$ROON_DIR/app/.installed" 2>/dev/null || echo "")
if [ -n "$PROD_VERSION" ] && [ -n "$EA_VERSION" ]; then
    echo "    Production version: $(echo "$PROD_VERSION" | head -2 | tail -1)"
    echo "    EA version:     $(echo "$EA_VERSION" | head -2 | tail -1)"
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

cleanup_restart
trap - EXIT

# ─── Pre-channel upgrade: .installed exists, no .channel ───────

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

# Simulate pre-channel image: remove .channel but keep .installed
rm -f "$ROON_DIR/app/.channel"

# Restart without setting ROON_CHANNEL — should default to production and backfill .channel
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    "$IMAGE"

sleep 5

check "backfills .channel on pre-channel install" \
    test -f "$ROON_DIR/app/.channel"

check "backfilled channel is production" \
    grep -q "production" "$ROON_DIR/app/.channel"

docker logs "$CONTAINER" > "$ROON_DIR/upgrade.log" 2>&1 || true

check "pre-channel restart does not re-download" \
    sh -c '! grep -q "downloading" "$1"' _ "$ROON_DIR/upgrade.log"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true

# Now simulate: pre-channel install + user wants EA
rm -f "$ROON_DIR/app/.channel"

docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    -e ROON_CHANNEL=earlyaccess \
    "$IMAGE"

echo "    Waiting for EA reinstall..."
TIMEOUT=180
ELAPSED=0
while ! grep -q "earlyaccess" "$ROON_DIR/app/.channel" 2>/dev/null && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "    ... ${ELAPSED}s"
done

check "pre-channel install switches to EA when requested" \
    grep -q "earlyaccess" "$ROON_DIR/app/.channel"

docker stop -t 10 "$CONTAINER" 2>/dev/null || true

cleanup_upgrade
trap - EXIT

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
