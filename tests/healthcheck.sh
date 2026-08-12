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
    # Size-gated for bash 3.2 + set -u — see runtime.sh's cleanup() for why.
    # `-v` because the image's VOLUME directive gives every container three
    # anonymous volumes, which a plain `docker rm -f` would leave behind.
    local c
    if [ "${#CLEANUP_CONTAINERS[@]}" -gt 0 ]; then
        for c in "${CLEANUP_CONTAINERS[@]}"; do
            docker rm -fv "$c" >/dev/null 2>&1 || true
        done
    fi
}
trap cleanup EXIT

echo "=== Healthcheck probe tests: $IMAGE ==="

# The HEALTHCHECK directive lands in image config as ["CMD-SHELL", "<script>"].
# Both guards are load-bearing under `set -e`: a bare `index` aborts the script
# outright when the image declares no healthcheck at all (no Healthcheck key)
# and when one is disabled with HEALTHCHECK NONE (Test is ["NONE"], so index 1
# is out of range) — killing it on a Go template error instead of the message
# below.
PROBE="$(docker inspect --format \
    '{{if .Config.Healthcheck}}{{if gt (len .Config.Healthcheck.Test) 1}}{{index .Config.Healthcheck.Test 1}}{{end}}{{end}}' \
    "$IMAGE" 2>/dev/null || true)"
if [ -z "$PROBE" ]; then
    echo "  FAIL  image declares no usable HEALTHCHECK"
    exit 1
fi
printf '  probe under test: %s\n\n' "$PROBE"

# Stage a fake install, then exec a spinner under the name the scenario needs.
# `sleep` stands in for every binary: comm is the basename of the execve'd path
# whatever the binary is. Every scenario keeps start.sh running, since the
# regression guarded against is "supervisor alive, head dead" reading healthy.
stage() {
    cat <<'SETUP'
R=/Roon/app/RoonServer
mkdir -p "$R/Server/.roonhost" "$R/Appliance" "$R/RoonDotnet"
cp /bin/sleep "$R/Server/RoonServer.exe"
cp /bin/sleep "$R/Server/RoonServerOld"
cp /bin/sleep "$R/Appliance/RoonAppliance"
cp /bin/sleep "$R/Appliance/RAATServer"
cp /bin/sleep "$R/RoonDotnet/dotnet"
ln -sf ../RoonServer.exe "$R/Server/.roonhost/RoonServer"
ln -sf dotnet "$R/RoonDotnet/RoonServer"
printf '#!/bin/bash\nsleep infinity\n' > "$R/start.sh"
chmod +x "$R/start.sh"
# The supervisor: always present, never sufficient on its own.
/bin/bash "$R/start.sh" &
# Scenarios that launch a process set this to the pid whose exec must complete
# before the probe runs; it stays empty for the ones that launch nothing.
HEAD_PID=
SETUP
    printf '%s\n' "$1"
    # Ground-truth readiness. Waiting on a file the setup writes would race the
    # exec (every path above is created before anything is launched), and
    # waiting on the probe's own answer would beg the question — so wait for
    # the pid to stop being the forking shell, then signal.
    cat <<'READY'
if [ -n "$HEAD_PID" ]; then
    i=0
    while [ "$(cat /proc/$HEAD_PID/comm 2>/dev/null)" = "bash" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
fi
touch /tmp/hc-staged
wait
READY
}

# $1 = description, $2 = expected (healthy|unhealthy), $3 = head launch line
probe_case() {
    local desc="$1" expect="$2" head="$3"
    local container
    container="roon-hc-$(printf '%s' "$desc" | tr -cd '[:alnum:]' | cut -c1-24)"
    CLEANUP_CONTAINERS+=("$container")

    # The name is derived from the description, so a run killed mid-flight (CI
    # timeout, Ctrl-C before the EXIT trap, SIGKILL) leaves it behind and the
    # next `docker run` dies on a name conflict — under `set -e` that aborts
    # the suite before a single case executes. Clear it first.
    docker rm -fv "$container" >/dev/null 2>&1 || true

    # Setup goes in via the environment, never argv: passed with `-c` it would
    # put literal "RoonServer.exe" into PID 1's cmdline, and the negative cases
    # would match the cmdline probe and pass for the wrong reason.
    docker run -d --name "$container" \
        -e HC_SETUP="$(stage "$head")" \
        --entrypoint /bin/bash "$IMAGE" -c 'eval "$HC_SETUP"' >/dev/null

    local actual=""
    local _
    for _ in $(seq 1 40); do
        if docker exec "$container" test -f /tmp/hc-staged 2>/dev/null; then
            break
        fi
        sleep 0.5
    done

    # Preconditions, checked before the probe's answer is believed. Without
    # them any staging failure — container already exited, syntax error on line
    # one — makes `docker exec` exit non-zero, which reads as "unhealthy" and
    # silently passes every negative case. The supervisor is the premise those
    # cases are named for, so assert it rather than infer it. ("start[.]sh"
    # keeps this exec's own argv from satisfying the grep.)
    if ! docker exec "$container" test -f /tmp/hc-staged 2>/dev/null; then
        actual="error: staging never completed"
    elif ! docker exec "$container" sh -c 'grep -ql "start[.]sh" /proc/[0-9]*/cmdline' 2>/dev/null; then
        actual="error: supervisor (start.sh) not running"
    fi

    if [ -z "$actual" ]; then
        # Run the probe in a subshell so its `exit 1` cannot take the reporting
        # `echo` down with it, and so a failure to exec at all stays
        # distinguishable from the probe answering "unhealthy".
        local out
        out="$(docker exec "$container" sh -c "( $PROBE ) >/dev/null 2>&1; echo rc=\$?" 2>/dev/null)" || out=""
        case "$out" in
            *rc=0*) actual=healthy ;;
            *rc=*)  actual=unhealthy ;;
            *)      actual="error: probe could not be run" ;;
        esac
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

    docker rm -fv "$container" >/dev/null 2>&1 || true
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
    "( exec -a '$R/RoonDotnet/RoonServer RoonServer.dll' '$R/RoonDotnet/RoonServer' infinity ) & HEAD_PID=\$!"

# ...but the bare variant execs dotnet directly, leaving comm as "dotnet", so
# only the command line identifies it. This is why the cmdline branch is kept.
probe_case "bare dotnet with RoonServer.dll argument" healthy \
    "( exec -a '$R/RoonDotnet/dotnet RoonServer.dll' '$R/RoonDotnet/dotnet' infinity ) & HEAD_PID=\$!"

# 2.71 b1680: apphost renamed to .exe, no alias and no argv[0] override.
probe_case "apphost as RoonServer.exe (no alias)" healthy \
    "( cd '$R/Server' && exec -a './RoonServer.exe' ./RoonServer.exe infinity ) & HEAD_PID=\$!"

# Same package with the launcher overriding argv[0] but still no alias: comm
# keeps the .exe suffix, so an extensionless-only probe would miss it.
probe_case "apphost with argv0 override, no alias" healthy \
    "( cd '$R/Server' && exec -a '$R/Server/RoonServer' ./RoonServer.exe infinity ) & HEAD_PID=\$!"

# 2.71 b1683+: exec'd through Server/.roonhost/RoonServer, so comm is the bare
# "RoonServer" and no process carries a .dll or .exe on its cmdline at all.
probe_case "apphost via .roonhost alias (current)" healthy \
    "( exec -a '$R/Server/RoonServer' '$R/Server/.roonhost/RoonServer' infinity ) & HEAD_PID=\$!"

# ─── Cases that must report unhealthy ────────────────────────────

# start.sh is alive and its argv contains "/Roon/app/RoonServer", but no head
# is running — the case an unanchored cmdline match reports healthy forever.
probe_case "head dead, start.sh still running" unhealthy \
    "true"

# The real-world crash shape: the head dies while the processes it supervises
# outlive it. Neither may be mistaken for the head.
probe_case "appliance + RAATServer alive, head dead" unhealthy \
    "( exec -a '$R/Appliance/RoonAppliance' '$R/Appliance/RoonAppliance' infinity ) &
     ( exec -a '$R/Appliance/RAATServer' '$R/Appliance/RAATServer' infinity ) & HEAD_PID=\$!"

# Pins the -x anchor on the comm branch. comm is a bare basename, so nothing
# else in this suite would notice if the anchor were dropped: unanchored, this
# decoy satisfies the RoonServer pattern and the case flips to healthy.
probe_case "decoy process named RoonServerOld" unhealthy \
    "( cd '$R/Server' && exec -a './RoonServerOld' ./RoonServerOld infinity ) & HEAD_PID=\$!"

# Pins the non-empty-cmdline requirement. The kernel keeps comm for a defunct
# process and empties cmdline, so a comm-only match reports a crashed head as
# healthy indefinitely — the exact failure the HEALTHCHECK exists to catch,
# since a supervisor wedged badly enough to stop reaping is also one that will
# never restart the head. The parent execs into sleep and so never reaps.
# Launched via the extensionless alias: a path carrying .exe/.dll would sit in
# the forking shell's argv and satisfy the cmdline branch while it lived.
probe_case "head defunct (zombie), parent never reaps" unhealthy \
    "( exec /bin/bash -c '\"\$0\" 0.3 & exec /bin/sleep 300' '$R/Server/.roonhost/RoonServer' ) & HEAD_PID=\$!; sleep 1.5"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
