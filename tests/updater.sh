#!/bin/bash
# End-to-end test for roon-docker-updater.
#
# Exercises the four-file handshake twice (to verify subsequent cycles also
# work) in two invocation modes (compose and `docker run`). The test must
# run on a machine with Docker and enough network to pull debian:trixie-slim
# once; Roon binaries are downloaded into a test-scoped volume on first run.
#
# Usage:
#   tests/updater.sh               # run from repo root; tears down on exit
#
# Env overrides:
#   KEEP_ROON=1                    # keep the test /Roon volume across runs
#                                  # (faster reruns: skips the ~200MB download)
#   ROON_BRANCH=earlyaccess        # default: production
#
# Names and tags are prefixed `rdu-test-` so the test cannot collide with a
# production roonserver on the same host.

set -euo pipefail

# ---- Config -----------------------------------------------------------------

TEST_ROON_IMAGE=rdu-test-roonserver:latest
TEST_UPDATER_IMAGE=rdu-test-updater:latest
PROJECT=rdu-test
ROON_NAME=rdu-test-roonserver
UPDATER_NAME=rdu-test-updater
STATE_VOL=rdu-test-update-state
ROON_VOL=rdu-test-roonstate
COMPOSE_FILE=tests/updater-compose.yml
KEEP_ROON=${KEEP_ROON:-0}
ROON_BRANCH=${ROON_BRANCH:-production}

# ---- Output helpers ---------------------------------------------------------

G=$'\033[32m' R=$'\033[31m' B=$'\033[34m' D=$'\033[2m' N=$'\033[0m'
step() { echo; echo "${B}==>${N} $*"; }
ok()   { echo "  ${G}OK${N} — $*"; }
fail() { echo "  ${R}FAIL${N} — $*" >&2; exit 1; }

# ---- Cleanup ----------------------------------------------------------------

cleanup() {
  # Restore Dockerfile if the sed-based rebuild step left a .bak file.
  [ -f Dockerfile.bak ] && mv Dockerfile.bak Dockerfile
  # Tear down either invocation mode.
  docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v 2>/dev/null || true
  docker rm -f "$ROON_NAME" "$UPDATER_NAME" 2>/dev/null || true
  docker volume rm "$STATE_VOL" 2>/dev/null || true
  # Remove test-built images only if the user didn't pre-provide them.
  docker rmi "$TEST_ROON_IMAGE" "$TEST_UPDATER_IMAGE" 2>/dev/null || true
  if [ "$KEEP_ROON" = "0" ]; then
    docker volume rm "$ROON_VOL" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---- Helpers used by the cycle ---------------------------------------------

state_file() {
  # Cat a file inside the update-state volume from the updater container.
  docker exec "$UPDATER_NAME" cat "/roon-docker-update-state/$1" 2>/dev/null
}
state_present() {
  docker exec "$UPDATER_NAME" test -f "/roon-docker-update-state/$1" 2>/dev/null
}
state_touch() {
  # Touch a control file from inside the roonserver container, the way Roon
  # will eventually touch it from its own process.
  docker exec "$ROON_NAME" touch "/roon-docker-update-state/$1"
}
wait_for_state() {
  # wait_for_state <filename> <timeout-seconds> [expect=present|absent]
  local file=$1 timeout=$2 want=${3:-present} i
  for i in $(seq 1 "$timeout"); do
    if [ "$want" = "present" ] && state_present "$file"; then return 0; fi
    if [ "$want" = "absent"  ] && ! state_present "$file"; then return 0; fi
    sleep 1
  done
  return 1
}
wait_for_roon_running() {
  # Polls the container's /proc for the RoonServer.dll cmdline, matching the
  # image's healthcheck logic. Returns when detected, or fails after timeout.
  local timeout=${1:-180} i
  for i in $(seq 1 "$timeout"); do
    if docker exec "$ROON_NAME" sh -c "grep -q '[R]oonServer.dll' /proc/*/cmdline" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}
container_image_id()  { docker inspect -f '{{.Image}}' "$1" 2>/dev/null; }
container_id()        { docker inspect -f '{{.Id}}'    "$1" 2>/dev/null; }
roon_version_file()   { docker exec "$ROON_NAME" cat /Roon/app/RoonServer/VERSION 2>/dev/null; }

# ---- Simulate "a new image is available" ------------------------------------

# Rebuild the Roon image with a Dockerfile change that invalidates the cache
# and produces a new local image ID. Uses sed to edit the Dockerfile in
# place, rebuild, then restores the original. The edit is a trivial LABEL
# bump; RoonServer behavior is unchanged.
simulate_new_image() {
  local marker=$1
  sed -i.bak "s|^FROM --platform=linux/amd64 debian:trixie-slim.*$|&\nLABEL roon.test.marker=\"$marker\"|" Dockerfile
  docker build -q -t "$TEST_ROON_IMAGE" . >/dev/null
  mv Dockerfile.bak Dockerfile
}

# ---- One full cycle of the four-file protocol ------------------------------

run_cycle() {
  local cycle_label=$1
  step "[$cycle_label] simulate a new image and wait for detection"
  local running_before new_marker="cycle-$cycle_label-$(date +%s)"
  running_before=$(container_image_id "$ROON_NAME")
  simulate_new_image "$new_marker"
  ok "rebuilt $TEST_ROON_IMAGE with marker=$new_marker"

  wait_for_state update-available 30 present \
    || fail "updater did not write update-available within 30s"
  local advertised
  advertised=$(state_file update-available)
  ok "update-available appeared: ${advertised:7:12}"
  [ "$advertised" != "$running_before" ] \
    || fail "advertised digest equals running image — not a real update"

  step "[$cycle_label] Roon opts in to download"
  state_touch ready-to-pull
  ok "touched ready-to-pull"
  wait_for_state update-pulled 60 present \
    || fail "updater never wrote update-pulled within 60s"
  ok "update-pulled appeared after pull"
  wait_for_state ready-to-pull 10 absent \
    || fail "updater did not clear ready-to-pull after successful pull"
  ok "ready-to-pull cleared"

  step "[$cycle_label] Roon opts in to restart"
  local roon_version_before old_cid
  roon_version_before=$(roon_version_file || echo '')
  old_cid=$(container_id "$ROON_NAME")
  state_touch ready-to-restart
  ok "touched ready-to-restart"

  # Wait for the container ID to change, which means the updater has
  # finished the stop+rm+create+start sequence.
  local i new_cid=""
  for i in $(seq 1 60); do
    new_cid=$(container_id "$ROON_NAME" 2>/dev/null || echo "")
    if [ -n "$new_cid" ] && [ "$new_cid" != "$old_cid" ]; then break; fi
    sleep 1
    new_cid=""
  done
  [ -n "$new_cid" ] || fail "container was not recreated within 60s"
  ok "container recreated: ${new_cid:0:12} (was ${old_cid:0:12})"

  wait_for_roon_running 180 \
    || fail "RoonServer process did not appear in /proc within 180s after recreate"
  ok "RoonServer process is running in new container"

  local roon_version_after
  roon_version_after=$(roon_version_file || echo '')
  [ -n "$roon_version_before" ] || { ok "no prior VERSION file (first boot)"; }
  if [ -n "$roon_version_before" ]; then
    [ "$roon_version_after" = "$roon_version_before" ] \
      || fail "/Roon/VERSION changed across recreate: '$roon_version_before' -> '$roon_version_after' (re-download?)"
    ok "/Roon/VERSION preserved across recreate (no re-download)"
  fi

  # Flag cleanup: after a successful recreate, none of the protocol files
  # should still be present.
  for f in update-available update-pulled ready-to-pull ready-to-restart; do
    if state_present "$f"; then fail "protocol file '$f' not cleared after recreate"; fi
  done
  ok "all four protocol files cleared"
}

# ---- Mode harnesses ---------------------------------------------------------

bring_up_compose() {
  step "Starting stack via docker compose"
  TEST_ROON_IMAGE=$TEST_ROON_IMAGE TEST_UPDATER_IMAGE=$TEST_UPDATER_IMAGE \
    docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d >/dev/null
  wait_for_roon_running 180 \
    || fail "RoonServer did not start within 180s after compose up"
  ok "roonserver + updater running under compose"
}

tear_down_compose() {
  step "Tearing down compose stack"
  docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
  # Keep KEEP_ROON semantics: if we want to preserve /Roon between modes/runs,
  # recreate the volume marker so Docker knows about it.
  if [ "$KEEP_ROON" = "1" ]; then docker volume create "$ROON_VOL" >/dev/null || true; fi
}

bring_up_run() {
  step "Starting stack via docker run"
  docker volume create "$STATE_VOL" >/dev/null
  [ "$KEEP_ROON" = "1" ] || docker volume create "$ROON_VOL" >/dev/null
  docker run -d \
    --name "$ROON_NAME" \
    -v "$ROON_VOL:/Roon" \
    -v "$STATE_VOL:/roon-docker-update-state" \
    --restart unless-stopped \
    "$TEST_ROON_IMAGE" >/dev/null
  docker run -d \
    --name "$UPDATER_NAME" \
    -e "WATCH_CONTAINER=$ROON_NAME" \
    -e "POLL_INTERVAL=15" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$STATE_VOL:/roon-docker-update-state" \
    --restart unless-stopped \
    "$TEST_UPDATER_IMAGE" >/dev/null
  wait_for_roon_running 180 \
    || fail "RoonServer did not start within 180s after docker run"
  ok "roonserver + updater running under docker run"
}

tear_down_run() {
  step "Tearing down docker run stack"
  docker rm -f "$ROON_NAME" "$UPDATER_NAME" >/dev/null 2>&1 || true
  docker volume rm "$STATE_VOL" >/dev/null 2>&1 || true
  if [ "$KEEP_ROON" != "1" ]; then docker volume rm "$ROON_VOL" >/dev/null 2>&1 || true; fi
}

# ---- Main -------------------------------------------------------------------

[ -f Dockerfile ] && [ -d roon-docker-updater ] \
  || fail "run this from the roon-docker repo root"

step "Building test images"
docker build -q -t "$TEST_ROON_IMAGE" . >/dev/null
docker build -q -t "$TEST_UPDATER_IMAGE" roon-docker-updater/ >/dev/null
ok "roonserver: $TEST_ROON_IMAGE"
ok "updater:   $TEST_UPDATER_IMAGE"

# --- Mode 1: docker compose ---
bring_up_compose
run_cycle "compose#1"
run_cycle "compose#2"
tear_down_compose

# --- Mode 2: docker run ---
bring_up_run
run_cycle "run#1"
run_cycle "run#2"
tear_down_run

echo
echo "${G}=== ALL CHECKS PASSED (two cycles × two invocation modes) ===${N}"
echo "(cleanup on exit will remove test images and volumes)"
