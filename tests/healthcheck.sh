#!/usr/bin/env bash
# Pins the HEALTHCHECK probe against every shape the RoonServer head has
# shipped in, without waiting on Docker's start_period or needing a real
# install.
#
# runtime.sh cannot cover this: it starts a container with `--entrypoint
# sleep`, so no process references the install path and a probe loose enough to
# match the "/Roon/app/RoonServer" directory still passes. This suite tests the
# property that matters — healthy iff a server head is actually running.
#
# The probe is read out of the built image, so it cannot drift from Dockerfile.
set -euo pipefail

IMAGE="${1:?Usage: healthcheck.sh <image:tag>}"
PASS=0
FAIL=0
CLEANUP_CONTAINERS=()

cleanup() {
    for c in ${CLEANUP_CONTAINERS+"${CLEANUP_CONTAINERS[@]}"}; do
        docker rm -f "$c" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

echo "=== Healthcheck probe tests: $IMAGE ==="

# The HEALTHCHECK directive lands in image config as ["CMD-SHELL", "<script>"].
PROBE="$(docker inspect --format '{{index .Config.Healthcheck.Test 1}}' "$IMAGE")"
if [ -z "$PROBE" ]; then
    echo "  FAIL  image declares no HEALTHCHECK"
    exit 1
fi
printf '  probe under test: %s\n\n' "$PROBE"

# Stage a fake install, then exec a spinner under the name the scenario needs.
# `sleep` stands in for the head: comm is the basename of the execve'd path
# whatever the binary is. Every scenario keeps start.sh running, since the
# regression guarded against is "supervisor alive, head dead" reading healthy.
stage() {
    cat <<'SETUP'
R=/Roon/app/RoonServer
mkdir -p "$R/Server/.roonhost" "$R/Appliance" "$R/RoonDotnet"
cp /bin/sleep "$R/Server/RoonServer.exe"
cp /bin/sleep "$R/RoonDotnet/dotnet"
ln -sf ../RoonServer.exe "$R/Server/.roonhost/RoonServer"
ln -sf dotnet "$R/RoonDotnet/RoonServer"
printf '#!/bin/bash\nsleep infinity\n' > "$R/start.sh"
chmod +x "$R/start.sh"
# The supervisor: always present, never sufficient on its own.
/bin/bash "$R/start.sh" &
SETUP
    printf '%s\n' "$1"
    printf 'wait\n'
}

# $1 = description, $2 = expected (healthy|unhealthy), $3 = head launch line
probe_case() {
    local desc="$1" expect="$2" head="$3"
    local container
    container="roon-hc-$(printf '%s' "$desc" | tr -cd '[:alnum:]' | cut -c1-24)"
    CLEANUP_CONTAINERS+=("$container")

    # Setup goes in via the environment, never argv: passed with `-c` it would
    # put literal "RoonServer.exe" into PID 1's cmdline, and the negative case
    # would match the cmdline probe and pass for the wrong reason.
    docker run -d --name "$container" \
        -e HC_SETUP="$(stage "$head")" \
        --entrypoint /bin/bash "$IMAGE" -c 'eval "$HC_SETUP"' >/dev/null

    # Wait for staging to finish and the head to exec into its final name.
    local i
    for i in $(seq 1 20); do
        if docker exec "$container" test -x /Roon/app/RoonServer/start.sh 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    sleep 1

    local actual
    if docker exec "$container" sh -c "$PROBE" >/dev/null 2>&1; then
        actual=healthy
    else
        actual=unhealthy
    fi

    if [ "$actual" = "$expect" ]; then
        echo "  PASS  $desc -> $actual"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $desc -> $actual (expected $expect)"
        printf '        | processes seen by the probe:\n'
        docker exec "$container" sh -c \
            'for p in /proc/[0-9]*/cmdline; do d=${p%/cmdline}
                 printf "        |   comm=%-16s argv=%s\n" "$(cat "$d/comm")" "$(tr "\0" " " < "$p")"
             done' 2>/dev/null || true
        FAIL=$((FAIL + 1))
    fi

    docker rm -f "$container" >/dev/null 2>&1 || true
}

R=/Roon/app/RoonServer

# ─── Package shapes that must report healthy ─────────────────────
#
# Each head is launched in a subshell that `exec`s, so no wrapper process
# lingers carrying the scenario text in its cmdline — otherwise a shape meant
# to exercise the comm probe could pass via the cmdline probe instead.

# Legacy shared-runtime: launcher symlinks dotnet under the app name and passes
# RoonServer.dll as argv[1]. comm is "RoonServer" here...
probe_case "legacy FDD (dotnet alias + RoonServer.dll)" healthy \
    "( exec -a '$R/RoonDotnet/RoonServer RoonServer.dll' '$R/RoonDotnet/RoonServer' infinity ) &"

# ...but the bare variant execs dotnet directly, leaving comm as "dotnet", so
# only the command line identifies it. This is why the cmdline branch is kept.
probe_case "bare dotnet with RoonServer.dll argument" healthy \
    "( exec -a '$R/RoonDotnet/dotnet RoonServer.dll' '$R/RoonDotnet/dotnet' infinity ) &"

# 2.71 b1680: apphost renamed to .exe, no alias and no argv[0] override.
probe_case "apphost as RoonServer.exe (no alias)" healthy \
    "cd '$R/Server' && ( exec -a './RoonServer.exe' ./RoonServer.exe infinity ) &"

# Same package with the launcher overriding argv[0] but still no alias: comm
# keeps the .exe suffix, so an extensionless-only probe would miss it.
probe_case "apphost with argv0 override, no alias" healthy \
    "cd '$R/Server' && ( exec -a '$R/Server/RoonServer' ./RoonServer.exe infinity ) &"

# 2.71 b1683+: exec'd through Server/.roonhost/RoonServer, so comm is the bare
# "RoonServer" and no process carries a .dll or .exe on its cmdline at all.
probe_case "apphost via .roonhost alias (current)" healthy \
    "( exec -a '$R/Server/RoonServer' '$R/Server/.roonhost/RoonServer' infinity ) &"

# ─── The case that must report unhealthy ─────────────────────────
#
# start.sh is alive and its argv contains "/Roon/app/RoonServer", but no head
# is running — the case an unanchored cmdline match reports healthy forever.
probe_case "head dead, start.sh still running" unhealthy \
    "true"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
