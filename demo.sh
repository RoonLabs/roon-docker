#!/bin/bash
# Human-facing walkthrough of the roon-docker-updater four-file handshake.
#
# Builds the two images locally, brings up a compose stack with test-scoped
# names/volumes, narrates each stage of one full update cycle, and tears
# everything down at exit. For automated pass/fail assertions across both
# invocation modes and multiple cycles, use tests/updater.sh instead.
#
# Usage:
#   ./demo.sh                 # run from repo root
#
# Env overrides:
#   KEEP_ROON=1               # preserve the test /Roon volume across runs
set -euo pipefail

TEST_ROON_IMAGE=rdu-demo-roonserver:latest
TEST_UPDATER_IMAGE=rdu-demo-updater:latest
PROJECT=rdu-demo
ROON_NAME=rdu-demo-roonserver
UPDATER_NAME=rdu-demo-updater
STATE_VOL=rdu-demo-update-state
ROON_VOL=rdu-demo-roonstate
COMPOSE_FILE=tests/updater-compose.yml
KEEP_ROON=${KEEP_ROON:-0}

G=$'\033[32m' B=$'\033[34m' C=$'\033[36m' Y=$'\033[33m' D=$'\033[2m' N=$'\033[0m'
hdr()  { echo; echo "${B}━━━━━ $* ━━━━━${N}"; }
note() { echo "${Y}→${N} $*"; }
dim()  { sed "s/^/  ${D}/;s/\$/${N}/"; }

cleanup() {
  [ -f Dockerfile.bak ] && mv Dockerfile.bak Dockerfile
  echo
  hdr "Teardown"
  docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v 2>&1 | dim || true
  docker volume rm "$STATE_VOL" 2>/dev/null || true
  [ "$KEEP_ROON" = "0" ] && docker volume rm "$ROON_VOL" 2>/dev/null
  docker rmi "$TEST_ROON_IMAGE" "$TEST_UPDATER_IMAGE" 2>/dev/null || true
  true
}
trap cleanup EXIT

state_file()    { docker exec "$UPDATER_NAME" cat "/roon-docker-update-state/$1" 2>/dev/null; }
state_present() { docker exec "$UPDATER_NAME" test -f "/roon-docker-update-state/$1" 2>/dev/null; }
state_touch()   { docker exec "$ROON_NAME" touch "/roon-docker-update-state/$1"; }
wait_state()    {
  local file=$1 timeout=$2 want=${3:-present} i
  for i in $(seq 1 "$timeout"); do
    if [ "$want" = "present" ] && state_present "$file"; then return 0; fi
    if [ "$want" = "absent"  ] && ! state_present "$file"; then return 0; fi
    sleep 1
  done
  return 1
}
wait_roon() {
  local t=${1:-180} i
  for i in $(seq 1 "$t"); do
    if docker exec "$ROON_NAME" sh -c "grep -q '[R]oonServer.dll' /proc/*/cmdline" 2>/dev/null; then return 0; fi
    sleep 1
  done
  return 1
}

[ -f Dockerfile ] && [ -d roon-docker-updater ] || { echo "Run from repo root." >&2; exit 1; }

hdr "1. Build test images"
note "docker build . -t $TEST_ROON_IMAGE"
docker build -q -t "$TEST_ROON_IMAGE" . >/dev/null
note "docker build roon-docker-updater/ -t $TEST_UPDATER_IMAGE"
docker build -q -t "$TEST_UPDATER_IMAGE" roon-docker-updater/ >/dev/null

hdr "2. Bring up the stack"
TEST_ROON_IMAGE=$TEST_ROON_IMAGE TEST_UPDATER_IMAGE=$TEST_UPDATER_IMAGE \
  docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d 2>&1 | tail -5 | dim
note "Waiting for RoonServer to start (can take ~60s on first boot while binaries download)..."
wait_roon 240 || { echo "RoonServer did not start in time"; exit 1; }
original_cid=$(docker inspect -f '{{.Id}}' "$ROON_NAME")
original_img=$(docker inspect -f '{{.Image}}' "$ROON_NAME")
original_at=$( docker inspect -f '{{.State.StartedAt}}' "$ROON_NAME")
echo "${G}Running:${N}"
echo "  roonserver: container=${original_cid:0:12} image=${original_img:7:12}"
echo "  updater:    container=$(docker inspect -f '{{.Id}}' "$UPDATER_NAME" | cut -c1-12)"
echo "  /Roon/VERSION: $(docker exec "$ROON_NAME" cat /Roon/app/RoonServer/VERSION 2>/dev/null || echo '(not yet written)')"

hdr "3. Simulate a new image (rebuild with a marker label)"
marker="demo-$(date +%s)"
note "sed: add LABEL roon.test.marker=\"$marker\" to Dockerfile"
sed -i.bak "s|^FROM --platform=linux/amd64 debian:trixie-slim.*$|&\nLABEL roon.test.marker=\"$marker\"|" Dockerfile
note "docker build . -t $TEST_ROON_IMAGE"
docker build -q -t "$TEST_ROON_IMAGE" . >/dev/null
mv Dockerfile.bak Dockerfile

hdr "4. Detection (updater writes update-available; no pull yet)"
note "Polling /roon-docker-update-state/update-available (shim polls every 15s)..."
wait_state update-available 30 present || { echo "update-available never appeared"; exit 1; }
digest=$(state_file update-available)
echo "  ${G}detected${N} — digest=${digest:7:12}"
note "updater log:"
docker logs "$UPDATER_NAME" --since 45s 2>&1 | sed "s/^/  ${C}[updater]${N} /"

hdr "5. Roon opts in to download"
note "touch /roon-docker-update-state/ready-to-pull (simulating Roon's eventual decision)"
state_touch ready-to-pull
wait_state update-pulled 60 present || { echo "update-pulled did not appear"; exit 1; }
note "updater log after pull:"
docker logs "$UPDATER_NAME" --since 30s 2>&1 | sed "s/^/  ${C}[updater]${N} /"
note "Files now present:"
docker exec "$UPDATER_NAME" ls /roon-docker-update-state/ 2>/dev/null | sed "s/^/  ${C}[volume]${N}   /"

hdr "6. Capture old RoonServer state before recreate"
old_version=$(docker exec "$ROON_NAME" cat /Roon/app/RoonServer/VERSION 2>/dev/null || echo '')
old_log=$(docker logs "$ROON_NAME" 2>&1 | tail -5)
echo "  Captured /Roon/VERSION=$old_version plus last 5 log lines."

hdr "7. Roon opts in to restart"
note "touch /roon-docker-update-state/ready-to-restart"
state_touch ready-to-restart
note "Waiting for shim to recreate the container..."
new_cid=""
for i in $(seq 1 60); do
  cur=$(docker inspect -f '{{.Id}}' "$ROON_NAME" 2>/dev/null || echo "")
  if [ -n "$cur" ] && [ "$cur" != "$original_cid" ]; then new_cid=$cur; break; fi
  sleep 1
done
[ -n "$new_cid" ] || { echo "container was not recreated"; exit 1; }
echo "  ${G}recreated${N} — new container=${new_cid:0:12}"
note "Waiting for RoonServer process in the new container..."
wait_roon 180 || { echo "RoonServer did not come back"; exit 1; }
new_img=$(docker inspect -f '{{.Image}}' "$ROON_NAME")
new_at=$( docker inspect -f '{{.State.StartedAt}}' "$ROON_NAME")
new_version=$(docker exec "$ROON_NAME" cat /Roon/app/RoonServer/VERSION 2>/dev/null || echo '')

hdr "8. Before vs. after"
printf "  %-18s %-14s %-14s\n" ""              "BEFORE"               "AFTER"
printf "  %-18s %-14s %-14s\n" "container ID"  "${original_cid:0:12}" "${new_cid:0:12}"
printf "  %-18s %-14s %-14s\n" "image ID"      "${original_img:7:12}" "${new_img:7:12}"
printf "  %-18s %-14s %-14s\n" "started (UTC)" "${original_at:11:8}"  "${new_at:11:8}"
printf "  %-18s %-14s %-14s\n" "/Roon/VERSION" "${old_version:-(n/a)}" "${new_version:-(n/a)}"
if [ -n "$old_version" ] && [ "$old_version" != "$new_version" ]; then
  echo "  ${R}WARNING:${N} /Roon/VERSION changed — this suggests Roon re-downloaded; volume may not be persisting."
fi

hdr "9. Old RoonServer logs (captured before recreate)"
printf '%s\n' "$old_log" | sed "s/^/  ${C}[old]${N} /"

hdr "10. New RoonServer logs (first lines after recreate)"
docker logs "$ROON_NAME" 2>&1 | head -10 | sed "s/^/  ${C}[new]${N} /"

hdr "11. Updater's full log for this cycle"
docker logs "$UPDATER_NAME" 2>&1 | sed "s/^/  ${C}[updater]${N} /"

hdr "Summary"
echo "${G}The update was applied under Roon's own control:${N}"
echo "  • updater detected the new image digest via registry API (no blob download)"
echo "  • Roon approved download by touching ready-to-pull"
echo "  • updater pulled, signalled update-pulled; Roon saw the image was ready"
echo "  • Roon approved restart by touching ready-to-restart"
echo "  • updater recreated the container; /Roon persisted; RoonServer came back"
echo "  • the RoonServer container never held the Docker socket"
echo
echo "${Y}For assertion-style output and subsequent-cycle verification, run tests/updater.sh${N}"
