#!/bin/bash
# Version: 2026.08.06
# Kennel -- issue #21: launch the stack from the console's GENERATED command
# block, rather than from a hand-written launch recipe.
#
# Runs on the GUEST (kennel-vm). It reads a run folder's commands.txt, splits it
# into its three shells, proves the split lost nothing, and runs each one
# detached inside the container with the readiness waits between them.
#
# Why this exists at all: commands.txt is the one console output no issue had
# ever executed. #13 established the launch surface by hand and #14/#20 drove it
# through stack/verify/tools/k14-stack-up.sh, which is a hand-written copy of the
# same three commands. Running the generated file closes that gap -- it is
# issue #21's "launch with the generated command block" work item.
#
# It also answers #24's "non-blocking launch pattern over SSH" work item: the
# three ros2 launches block forever, so each is started with `docker exec -d` and
# waited for by OBSERVING THE STACK, never by sleeping and hoping.
#
# The waits are deliberately NOT in commands.txt: launch ORDER is a property of
# the stack (stack/launch.md 1.2) and belongs to whoever runs the commands, while
# the file is a faithful record of what the console composed. See composed-run.md.
#
# Usage:
#   p21-launch-from-commands.sh [/path/to/commands.txt]
# Default path is the run the transfer script last applied:
#   ~/kennel-staging/runs/$(cat ~/kennel-staging/current-run)/commands.txt
#
# Exit codes:
#   0  all three are up; the controller reached "Starting controller"
#   1  a stage did not come up (its log is named in the message)
#   2  infrastructure or parse error (no container, unreadable or unexpected file)
#
# `set -u` is safe here: this script sources no ROS setup file itself -- the
# blocks it runs do that, inside the container (stack/transfer.md 8).

set -uo pipefail

CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
STAGING="${KENNEL_STAGING:-$HOME/kennel-staging}"
# Sim-seconds to let the robot settle from its 0.4 m spawn before the controller
# runs safe_start(). In SIM seconds, so it is invariant under
# simulator_realtime_rate -- #21 composes 0.5, which doubles the wall time.
SETTLE_SIM_SECONDS="${KENNEL_SETTLE_SIM_SECONDS:-10}"
TOPIC_TIMEOUT="${KENNEL_TOPIC_TIMEOUT:-180}"

say()  { echo "[p21-launch] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

# --- REGION: locate commands.txt
CMDS="${1:-}"
if [ -z "$CMDS" ]; then
    run="$(cat "$STAGING/current-run" 2>/dev/null)"
    [ -n "$run" ] || {
        fail "no run is applied, so there is no commands.txt to launch." \
             "Apply one first:  stack/transfer/kennel-transfer.sh apply <run-folder>" \
             "Or name the file: $0 /path/to/commands.txt"
        exit 2
    }
    CMDS="$STAGING/runs/$run/commands.txt"
fi
[ -f "$CMDS" ] || { fail "no commands.txt at $CMDS"; exit 2; }
say "commands.txt     $CMDS"

cstate="$(sudo docker inspect --type container -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"
[ -n "$cstate" ] || { fail "no container named '$CONTAINER'." "Provision it first (issue #10)."; exit 2; }
[ "$cstate" = running ] || { say "container is '$cstate' -- starting it"; sudo docker start "$CONTAINER" >/dev/null; }

# --- REGION: split commands.txt into its three shells
# The payload is every line that is not a comment and not blank. A block ends at
# its `ros2 launch` line -- that is the blocking command the shell is FOR.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
grep -v '^[[:space:]]*#' "$CMDS" | grep -v '^[[:space:]]*$' > "$WORK/payload"

n=0
: > "$WORK/block1.sh"
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$WORK/block$((n + 1)).sh"
    case "$line" in ros2\ launch\ *) n=$((n + 1)); : > "$WORK/block$((n + 1)).sh" ;; esac
done < "$WORK/payload"
rm -f "$WORK/block$((n + 1)).sh"

if [ "$n" -ne 3 ]; then
    fail "expected three shells in $CMDS, found $n." \
         "stack/launch.md 1.1: simulator, leg driver, MIT controller. The stack" \
         "does not run without the leg driver, so a two-block file is wrong."
    exit 2
fi

# The split must have lost nothing: concatenating the blocks has to reproduce the
# payload byte for byte. Without this the script could silently drop a `source`
# line and the failure would surface much later as a mystery CMake/DDS error.
if ! cat "$WORK"/block1.sh "$WORK"/block2.sh "$WORK"/block3.sh | cmp -s - "$WORK/payload"; then
    fail "the three blocks do not reconstruct $CMDS -- refusing to run a partial command."
    exit 2
fi
say "split            3 shells, $(wc -l < "$WORK/payload") payload lines, reconstructs the file exactly"

# Assert the launches are the canonical three of stack/launch.md 1.1, in order.
# A generated file that launched something else is a #18 regression, and running
# it anyway would report a green stack for the wrong stack.
expect1='ros2 launch simulator simulator.launch.py sim:=go2'
expect2='ros2 launch drivers leg_driver_launch.py sim:=go2'
expect3='ros2 launch controllers mit_controller.launch.py sim:=go2'
for i in 1 2 3; do
    got="$(tail -1 "$WORK/block$i.sh")"
    eval "want=\$expect$i"
    [ "$got" = "$want" ] || {
        fail "shell $i launches '$got', expected '$want'." \
             "stack/launch.md 1.1 is the canonical set; #18 generates it."
        exit 2
    }
done
say "launches         the canonical three, in order (stack/launch.md 1.1)"

# The environment prelude is every line of shell 1 except its launch -- the
# console's own source chain. Reusing it for the readiness polls means the polls
# run in exactly the environment the stack runs in, with no second copy of the
# chain to drift (stack/known-good/tools/prelude.sh is #13's copy).
head -n -1 "$WORK/block1.sh" > "$WORK/env.sh"

# --- REGION: ship the blocks into the container
for f in env block1 block2 block3; do
    sudo docker exec -i "$CONTAINER" bash -c "cat > /tmp/p21-$f.sh" < "$WORK/$f.sh"
done

in_ctr() { sudo docker exec "$CONTAINER" bash -c "source /tmp/p21-env.sh >/dev/null 2>&1; $1" 2>/dev/null; }

# Sim time in whole seconds, or empty if /clock is not being published yet.
sim_now() { in_ctr "timeout 10 ros2 topic echo /clock --once 2>/dev/null | awk '/sec:/{print \$2; exit}'"; }

start_block() {   # $1 = block number, $2 = log name
    say "shell $1 -> /tmp/p21-$2.log  ($(tail -1 "$WORK/block$1.sh"))"
    sudo docker exec -d "$CONTAINER" bash -c "bash /tmp/p21-block$1.sh > /tmp/p21-$2.log 2>&1"
}

# --- REGION: run them, in order, waiting on the stack rather than on a clock
say "stopping anything already running"
sudo docker exec "$CONTAINER" bash -c '[ -x /root/k13-stop.sh ] && /root/k13-stop.sh' >/dev/null 2>&1
sleep 3

start_block 1 sim
for i in $(seq 1 "$TOPIC_TIMEOUT"); do
    [ "$(in_ctr "timeout 5 ros2 topic list 2>/dev/null | grep -c '^/quad_state$'")" = 1 ] && break
    sleep 2
done
if [ "$(in_ctr "timeout 5 ros2 topic list 2>/dev/null | grep -c '^/quad_state$'")" != 1 ]; then
    fail "the simulator never published /quad_state." "Log: sudo docker exec $CONTAINER tail -40 /tmp/p21-sim.log"
    exit 1
fi
say "  /quad_state up"

# Settle in SIM seconds. At simulator_realtime_rate 0.5 this is twice the wall
# time it is at 1.0, which is the entire reason it is not a `sleep 10`.
t0="$(sim_now)"
if [ -n "$t0" ]; then
    say "  settling ${SETTLE_SIM_SECONDS} sim-s (sim clock at ${t0}s)"
    for i in $(seq 1 "$TOPIC_TIMEOUT"); do
        t1="$(sim_now)"
        [ -n "$t1" ] && [ "$((t1 - t0))" -ge "$SETTLE_SIM_SECONDS" ] && break
        sleep 2
    done
    say "  settled at sim ${t1:-?}s"
else
    # /clock unreadable -- fall back to wall time, doubled, and say so rather
    # than pretending the sim-time guarantee still holds.
    say "  WARNING: could not read /clock; falling back to $((SETTLE_SIM_SECONDS * 2)) s wall"
    sleep $((SETTLE_SIM_SECONDS * 2))
fi

start_block 2 legdrv
sleep 15
say "  leg driver started"

start_block 3 ctrl
for i in $(seq 1 "$TOPIC_TIMEOUT"); do
    sudo docker exec "$CONTAINER" grep -q "Starting controller" /tmp/p21-ctrl.log 2>/dev/null && break
    sleep 2
done
if ! sudo docker exec "$CONTAINER" grep -q "Starting controller" /tmp/p21-ctrl.log 2>/dev/null; then
    fail "the controller never reached 'Starting controller'." \
         "Log: sudo docker exec $CONTAINER tail -40 /tmp/p21-ctrl.log"
    sudo docker exec "$CONTAINER" tail -30 /tmp/p21-ctrl.log 2>/dev/null
    exit 1
fi
say "  controller started"

say "stack is up, launched from the console's generated commands.txt"
say "logs: /tmp/p21-sim.log /tmp/p21-legdrv.log /tmp/p21-ctrl.log (in the container)"
