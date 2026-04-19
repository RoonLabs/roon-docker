FROM --platform=linux/amd64 debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq \
 && rm -rf /var/lib/apt/lists/*

COPY <<'SCRIPT' /usr/local/bin/roon-docker-updater
#!/bin/bash
# roon-docker-updater: polls a Docker registry for a newer image digest and
# coordinates a privilege-separated update with the watched container via
# four files on a shared volume. The watched container never needs the
# Docker socket; this container does, and runs only this script.
#
# Protocol (files live at /roon-docker-update-state/):
#   update-available    shim -> app   set on detection, cleared on recreate
#   ready-to-pull       app  -> shim  cleared only after successful pull
#   update-pulled       shim -> app   set after pull success, cleared on recreate
#   ready-to-restart    app  -> shim  cleared only after successful recreate
#
# Shim-internal state (same volume, not part of the protocol):
#   pending-recreate.json   container config cached at start of recreate;
#                           presence means "resume recreate on startup".
set -euo pipefail

: "${WATCH_CONTAINER:?must be set (one container name)}"
: "${POLL_INTERVAL:=3600}"

API="http://docker/v1.43"
SOCK=/var/run/docker.sock
STATE=/roon-docker-update-state
CACHE="$STATE/pending-recreate.json"

log()   { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
api()   { curl -sS --unix-socket "$SOCK" "$@"; }

# Atomic write: tmp + rename. Readers never see partial content.
atomic_write() {
  local target=$1 content=$2 tmp
  tmp=$(mktemp "$target.XXXXXX")
  printf '%s' "$content" > "$tmp"
  mv "$tmp" "$target"
}

inspect_c() { api "$API/containers/$1/json" 2>/dev/null; }

# Remote manifest digest — no blob download.
remote_digest() { api "$API/distribution/$1/json" 2>/dev/null | jq -r '.Descriptor.digest // empty'; }

# Registry-format digest of the running container's image, from local cache.
running_repo_digest() {
  local id
  id=$(inspect_c "$1" | jq -r '.Image // empty')
  [ -n "$id" ] || return 0
  api "$API/images/$id/json" 2>/dev/null \
    | jq -r '(.RepoDigests // []) | .[0] // "" | split("@") | .[1] // empty'
}

# Fallback for local-only images (no reachable registry): compare image IDs.
local_image_id()   { api "$API/images/$1/json" 2>/dev/null | jq -r '.Id // empty'; }
running_image_id() { inspect_c "$1" | jq -r '.Image // empty'; }

# ---- Detection ----

poll_one() {
  local c=$1 image remote running
  image=$(inspect_c "$c" | jq -r '.Config.Image // empty')
  if [ -z "$image" ]; then log "[$c] not running"; return 0; fi

  remote=$(remote_digest "$image")
  if [ -n "$remote" ]; then
    running=$(running_repo_digest "$c")
    if [ "$remote" != "$running" ]; then
      announce_update "$remote"
    fi
    return 0
  fi

  # Registry unreachable or image never pushed: compare local IDs.
  remote=$(local_image_id "$image")
  running=$(running_image_id "$c")
  if [ -n "$remote" ] && [ "$running" != "$remote" ]; then
    announce_update "$remote"
  fi
  return 0
}

announce_update() {
  local digest=$1 flag=$STATE/update-available
  if [ ! -f "$flag" ] || [ "$(cat "$flag" 2>/dev/null)" != "$digest" ]; then
    log "[$WATCH_CONTAINER] update available: $digest"
    atomic_write "$flag" "$digest"
  fi
}

# ---- Pull (triggered by ready-to-pull) ----

do_pull() {
  local image imgname tag
  image=$(inspect_c "$WATCH_CONTAINER" | jq -r '.Config.Image // empty')
  [ -n "$image" ] || { log "[$WATCH_CONTAINER] pull requested but container gone"; return 1; }
  case "$image" in *:*) imgname=${image%:*}; tag=${image##*:} ;; *) imgname=$image; tag=latest ;; esac
  log "[$WATCH_CONTAINER] pulling $imgname:$tag"
  if ! api -X POST "$API/images/create?fromImage=$imgname&tag=$tag" >/dev/null 2>&1; then
    log "[$WATCH_CONTAINER] pull failed (registry unreachable or image local-only)"
    return 1
  fi
  local pulled
  pulled=$(running_repo_digest "$WATCH_CONTAINER")
  [ -n "$pulled" ] || pulled=$(local_image_id "$image")
  atomic_write "$STATE/update-pulled" "$pulled"
  log "[$WATCH_CONTAINER] pull complete: $pulled"
  return 0
}

process_pull_request() {
  local req=$STATE/ready-to-pull
  [ -f "$req" ] || return 0
  if do_pull; then
    # Clear only on success; a failed attempt leaves the flag so we retry.
    rm -f "$req"
  fi
}

# ---- Recreate (triggered by ready-to-restart, with crash recovery) ----

# Build the POST /containers/create body from a container inspect document.
build_create_body() {
  jq '.Config + {
    HostConfig: .HostConfig,
    NetworkingConfig: { EndpointsConfig: (.NetworkSettings.Networks | with_entries(.value = {Aliases: .value.Aliases})) }
  }'
}

container_exists()  { [ "$(api -o /dev/null -w '%{http_code}' "$API/containers/$1/json" 2>/dev/null)" = "200" ]; }
container_running() { [ "$(inspect_c "$1" | jq -r '.State.Running // false')" = "true" ]; }

do_recreate() {
  local name=$WATCH_CONTAINER info body new_id

  # Step 1: inspect + cache config (only if we don't already have one from a
  # previous interrupted attempt — recovery path uses the existing cache).
  if [ ! -f "$CACHE" ]; then
    info=$(inspect_c "$name") || { log "[$name] inspect failed"; return 1; }
    body=$(printf '%s' "$info" | build_create_body) || { log "[$name] body construction failed"; return 1; }
    atomic_write "$CACHE" "$body"
    log "[$name] cached config for recreate"
  else
    body=$(cat "$CACHE")
    log "[$name] resuming recreate from cached config"
  fi

  # Step 2/3: stop + rm (idempotent via -f-equivalent: swallow errors).
  if container_exists "$name" && container_running "$name"; then
    api -X POST "$API/containers/$name/stop?t=10" >/dev/null 2>&1 || true
  fi
  if container_exists "$name"; then
    # Check whether this is still the old container or a partially-created new one.
    # If its image matches the pulled digest, assume it's the new one and skip delete.
    local existing_image
    existing_image=$(inspect_c "$name" | jq -r '.Image // empty')
    local pulled
    pulled=$(cat "$STATE/update-pulled" 2>/dev/null || echo '')
    if [ -n "$pulled" ] && [ "$existing_image" = "$pulled" ]; then
      log "[$name] new container already exists; skipping stop/delete"
    else
      api -X POST "$API/containers/$name/stop?t=10" >/dev/null 2>&1 || true
      api -X DELETE "$API/containers/$name" >/dev/null 2>&1 || true
    fi
  fi

  # Step 4/5: create (if absent) + start (if not running).
  if ! container_exists "$name"; then
    new_id=$(printf '%s' "$body" \
             | api -X POST -H 'Content-Type: application/json' --data-binary @- \
                   "$API/containers/create?name=$name" \
             | jq -r '.Id // empty')
    if [ -z "$new_id" ]; then log "[$name] create failed"; return 1; fi
    log "[$name] created (${new_id:0:12})"
  fi
  if ! container_running "$name"; then
    api -X POST "$API/containers/$name/start" >/dev/null 2>&1 || { log "[$name] start failed"; return 1; }
  fi

  # Step 6/7: success — clear cache + update-available + update-pulled.
  rm -f "$CACHE" "$STATE/update-available" "$STATE/update-pulled"
  log "[$name] recreate complete"
  return 0
}

process_restart_request() {
  local req=$STATE/ready-to-restart
  [ -f "$req" ] || return 0
  if do_recreate; then
    rm -f "$req"
  fi
}

# ---- Startup recovery ----

# If we find a cache file from a previous run, resume the recreate. The
# recreate function itself is idempotent and inspects Docker state to decide
# which steps still need to happen, so this just kicks it off.
recover_on_startup() {
  if [ -f "$CACHE" ]; then
    log "found $CACHE from previous run — resuming recreate"
    do_recreate || log "recovery attempt failed; will retry on next ready-to-restart tick"
  fi
}

# ---- Main loop ----

mkdir -p "$STATE"
log "roon-docker-updater up; watching: $WATCH_CONTAINER; poll=${POLL_INTERVAL}s"
recover_on_startup

last=0
while true; do
  now=$(date +%s)
  if [ $((now - last)) -ge "$POLL_INTERVAL" ]; then
    poll_one "$WATCH_CONTAINER"
    last=$now
  fi
  process_pull_request
  process_restart_request
  sleep 2
done
SCRIPT

RUN chmod +x /usr/local/bin/roon-docker-updater

ENTRYPOINT ["/usr/local/bin/roon-docker-updater"]
