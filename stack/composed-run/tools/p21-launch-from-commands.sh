#!/bin/bash
# Version: 2026.09.08
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
# WHAT "UP" MEANS, and why it changed (#52). This script used to return as soon
# as the controller logged "Starting controller". But that shell also starts
# joy_to_target.py -- a separate python3 process -- which joins the ROS graph on
# its own schedule, and nothing waited for it. On a cold container the `verify`
# that follows could therefore sample `ros2 node list` too early and fail its
# node-graph check on a stack that was entirely healthy. The last gate is now the
# GRAPH itself: all six healthy-session nodes present, none of them twice.
#
# The waits are deliberately NOT in commands.txt: launch ORDER is a property of
# the stack (stack/launch.md 1.2) and belongs to whoever runs the commands, while
# the file is a faithful record of what the console composed. See composed-run.md.
#
# BLOCK 4, when the run was composed with disturbances on (#68). The composer
# then emits a FOURTH block, `ros2 run simulator sim_disturber` -- the
# disturbance service of stack/mapping.md 4.6, which no launch file starts. It
# is launched LAST, after the six-node graph is complete, and waited for on two
# signals (its node AND its service), because a service that is not yet
# advertised answers nothing and the console's `inject` would report a refusal
# that is really a race. The six-node criterion is UNCHANGED: /disturbance_node
# is a seventh node this script expects only when the file asked for it.
#
# Usage:
#   p21-launch-from-commands.sh [/path/to/commands.txt]
# Default path is the run the transfer script last applied:
#   ~/kennel-staging/runs/$(cat ~/kennel-staging/current-run)/commands.txt
#
# The file has THREE blocks (disturbances off, the default) or FOUR (on).
#
# Knobs (environment variables, all optional):
#   KENNEL_CONTAINER            dfki_quad   the container to launch in
#   KENNEL_STAGING              ~/kennel-staging
#   KENNEL_SETTLE_SIM_SECONDS   10   settle before the controller, in SIM seconds
#   KENNEL_TOPIC_TIMEOUT        180  iterations of the /quad_state and controller polls
#   KENNEL_LEGDRV_TIMEOUT       120  wall-second bound on the leg-driver wait
#   KENNEL_GRAPH_TIMEOUT        120  wall-second bound on the node-graph wait
#
# Exit codes:
#   0  all three are up, the controller reached "Starting controller", and the
#      six-node graph is complete with no duplicates -- plus, when the file
#      carries a fourth block, the disturber's node and service are both there
#   1  a stage did not come up, or the graph never completed -- the message names
#      the missing node and the log to read
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
# Bounds on the two readiness waits that replaced blind sleeps (#52). In WALL
# seconds, unlike SETTLE_SIM_SECONDS above: both are process startup, which the
# simulator's realtime rate does not scale. Each loop below runs TIMEOUT/2
# iterations of a 2 s poll, so the number is the bound in seconds.
LEGDRV_TIMEOUT="${KENNEL_LEGDRV_TIMEOUT:-120}"
GRAPH_TIMEOUT="${KENNEL_GRAPH_TIMEOUT:-120}"

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

# --- REGION: split commands.txt into its three or four shells
# The payload is every line that is not a comment and not blank. A block ends at
# its `ros2 launch` line -- or, for block 4 (#68), its `ros2 run` line: that is
# the blocking command the shell is FOR, and `sim_disturber` blocks exactly as
# the three launches do (it spins).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
grep -v '^[[:space:]]*#' "$CMDS" | grep -v '^[[:space:]]*$' > "$WORK/payload"

n=0
: > "$WORK/block1.sh"
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$WORK/block$((n + 1)).sh"
    case "$line" in
        ros2\ launch\ *|ros2\ run\ *) n=$((n + 1)); : > "$WORK/block$((n + 1)).sh" ;;
    esac
done < "$WORK/payload"
rm -f "$WORK/block$((n + 1)).sh"

if [ "$n" -ne 3 ] && [ "$n" -ne 4 ]; then
    fail "expected three or four shells in $CMDS, found $n." \
         "stack/launch.md 1.1: simulator, leg driver, MIT controller. The stack" \
         "does not run without the leg driver, so a two-block file is wrong." \
         "A fourth block is the disturber, composed by the console's" \
         "'disturbances' toggle (#68, mapping.md 4.6)."
    exit 2
fi

# The split must have lost nothing: concatenating the blocks has to reproduce the
# payload byte for byte. Without this the script could silently drop a `source`
# line and the failure would surface much later as a mystery CMake/DDS error.
cat_blocks() { local i; for i in $(seq 1 "$n"); do cat "$WORK/block$i.sh"; done; }
if ! cat_blocks | cmp -s - "$WORK/payload"; then
    fail "the $n blocks do not reconstruct $CMDS -- refusing to run a partial command."
    exit 2
fi
say "split            $n shells, $(wc -l < "$WORK/payload") payload lines, reconstructs the file exactly"

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
# Block 4 is the ONE other command this script will run, and it is pinned just as
# tightly: `ros2 run simulator sim_disturber`, optionally with the sim-time
# argument. Anything else in that slot is a #18 regression.
DISTURBER=0
if [ "$n" = 4 ]; then
    got="$(tail -1 "$WORK/block4.sh")"
    case "$got" in
        'ros2 run simulator sim_disturber'|'ros2 run simulator sim_disturber --ros-args -p use_sim_time:=true') ;;
        *) fail "shell 4 runs '$got'." \
                "The only fourth block this script runs is the disturbance service:" \
                "  ros2 run simulator sim_disturber [--ros-args -p use_sim_time:=true]" \
                "mapping.md 4.6; the console composes it from the 'disturbances' toggle (#68)."
           exit 2 ;;
    esac
    DISTURBER=1
fi
say "launches         the canonical three, in order (stack/launch.md 1.1)$([ "$DISTURBER" = 1 ] && echo ' + the disturber (#68)')"

# The environment prelude is every line of shell 1 except its launch -- the
# console's own source chain. Reusing it for the readiness polls means the polls
# run in exactly the environment the stack runs in, with no second copy of the
# chain to drift (stack/known-good/tools/prelude.sh is #13's copy).
head -n -1 "$WORK/block1.sh" > "$WORK/env.sh"

# --- REGION: ship the blocks into the container
# Clear the previous run's blocks first: a three-block file launched after a
# four-block one would otherwise leave /tmp/p21-block4.sh lying in the container,
# where the next reader of that directory would take it for this run's.
sudo docker exec "$CONTAINER" bash -c 'rm -f /tmp/p21-block*.sh' 2>/dev/null
for f in env $(seq 1 "$n" | sed 's/^/block/'); do
    sudo docker exec -i "$CONTAINER" bash -c "cat > /tmp/p21-$f.sh" < "$WORK/$f.sh"
done

in_ctr() { sudo docker exec "$CONTAINER" bash -c "source /tmp/p21-env.sh >/dev/null 2>&1; $1" 2>/dev/null; }

# Sim time in whole seconds, or empty if /clock is not being published yet.
sim_now() { in_ctr "timeout 10 ros2 topic echo /clock --once 2>/dev/null | awk '/sec:/{print \$2; exit}'"; }

# The six nodes of a healthy sim session -- the same list stack/verify/kennel-verify.sh
# check 1 asserts, recorded in launch.md 6 and known-good/06-healthy-graph.txt.
# Change them together. /joy_to_target is the one that arrives last: it is a
# separate python3 process started by shell 3, and it joins the graph AFTER the
# controller has logged "Starting controller" (#52).
EXPECTED_NODES="/drake_simulator /joy_linux_node /joy_to_target /leg_driver /mit_controller_node /safe_start_launcher"

# What is still wrong with the node graph: the expected names not present, then
# DUP:<name> for any name listed twice. Empty output means the graph is complete.
# Leaves the sorted reading in $WORK/nodes for the caller.
#
# `ros2 node list` goes through the ros2 daemon, which is exactly the view
# kennel-verify.sh reads a moment later -- so this wait observes what the assert
# will observe, rather than a second opinion (--no-daemon would be one).
graph_missing() {
    in_ctr "timeout 15 ros2 node list 2>/dev/null" | grep '^/' | sort > "$WORK/nodes"
    for n in $EXPECTED_NODES; do
        grep -qx "$n" "$WORK/nodes" || printf '%s ' "$n"
    done
    uniq -d "$WORK/nodes" | sed 's/^/DUP:/' | tr '\n' ' '
}

start_block() {   # $1 = block number, $2 = log name
    say "shell $1 -> /tmp/p21-$2.log  ($(tail -1 "$WORK/block$1.sh"))"
    sudo docker exec -d "$CONTAINER" bash -c "bash /tmp/p21-block$1.sh > /tmp/p21-$2.log 2>&1"
}

# The disturber's two signals (#68). Its NODE is `disturbance_node` -- the name
# the C++ constructor gives it (simulator/src/disturbance_node.cpp:16), not the
# executable's -- and its SERVICE is what the console actually calls. Both,
# because a node on the graph whose service is not yet advertised answers
# nothing, and `inject` would report a refusal that is really a race.
DISTURBER_NODE=/disturbance_node
DISTURBER_SRV=/disturb_simulation
disturber_missing() {
    local out=""
    [ "$(in_ctr "timeout 15 ros2 node list 2>/dev/null | grep -c '^$DISTURBER_NODE\$'")" = 1 ] \
        || out="$DISTURBER_NODE "
    [ "$(in_ctr "timeout 15 ros2 service list 2>/dev/null | grep -c '^$DISTURBER_SRV\$'")" = 1 ] \
        || out="$out$DISTURBER_SRV "
    printf '%s' "$out"
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
# The leg driver is ready on TWO signals and either can be last: its node has to
# join the graph, and it has to become the publisher on /joint_cmd -- the topic
# the simulator consumes and the controller never touches. launch.md 1.1 measures
# /joint_cmd at "Publisher count: 0" with only the simulator up, which is exactly
# what makes the transition observable.
#
# This replaced a `sleep 15`: the same defect as #52 one stage earlier, a wait
# that does not observe (dry-run.md F8). Being slightly early was never fatal --
# the controller blocks on the leg driver's service and proceeds when it appears
# (launch.md 1.1) -- but a fixed 15 s is a guess in both directions.
t0=$(date +%s); legdrv_ready=0
for i in $(seq 1 $((LEGDRV_TIMEOUT / 2))); do
    pubs="$(in_ctr "timeout 10 ros2 topic info /joint_cmd 2>/dev/null" | awk '/Publisher count/{print $3}')"
    case "$pubs" in ''|*[!0-9]*) pubs=0 ;; esac
    node="$(in_ctr "timeout 10 ros2 node list 2>/dev/null | grep -c '^/leg_driver\$'")"
    if [ "$pubs" -ge 1 ] && [ "$node" = 1 ]; then legdrv_ready=1; break; fi
    sleep 2
done
if [ "$legdrv_ready" != 1 ]; then
    fail "the leg driver did not come up within ${LEGDRV_TIMEOUT}s." \
         "Without it the controller blocks on its service and never starts (launch.md 1.1)." \
         "Log: sudo docker exec $CONTAINER tail -40 /tmp/p21-legdrv.log"
    exit 1
fi
say "  leg driver up ($(( $(date +%s) - t0 ))s): /leg_driver in the graph, publishing /joint_cmd"

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

# --- REGION: the last thing to become true is the GRAPH, not a log line (#52)
# "Starting controller" is the controller's own milestone. joy_to_target.py and
# safe_start_launcher are separate processes of the SAME shell and register with
# the ROS graph on their own schedule, so this script used to return 0 while
# /joy_to_target was still arriving. The `verify` that follows samples
# `ros2 node list` once, and failed check 1 on a stack that was perfectly healthy
# -- re-running verify alone against the same untouched stack gave 10/10.
#
# Cold containers are what lose the race: there is no --restart policy by design
# (vm/provisioning.md 3.2), so `reset` and a fresh `provision` both `docker start`
# seconds before the launch. Reproduced on both -- vm/snapshot/evidence/10- and
# 16-, with 11- and 17- as the re-runs -- and measured at green 2 of 4
# (vm/snapshot.md 6 F5).
#
# Duplicates are part of the criterion, not a separate check. A killed node's DDS
# participant lingers 10-20 s in `ros2 node list` (bridge.md 4.1), so right after
# the pre-launch stop the graph can hold all six names AND a stale twin. Waiting
# for "all six, none twice" converges on its own; "six present" would not.
t0=$(date +%s)
missing="$(graph_missing)"
for i in $(seq 1 $((GRAPH_TIMEOUT / 2))); do
    [ -z "$missing" ] && break
    sleep 2
    missing="$(graph_missing)"
done
if [ -n "$missing" ]; then
    fail "the node graph never completed within ${GRAPH_TIMEOUT}s -- still wrong: $missing" \
         "/joy_to_target and /safe_start_launcher belong to shell 3:" \
         "  sudo docker exec $CONTAINER tail -40 /tmp/p21-ctrl.log" \
         "A DUP: entry is a stale copy from a bad teardown (launch.md 7 trap 6):" \
         "  sudo docker exec $CONTAINER /root/k13-stop.sh   and launch again."
    exit 1
fi
say "  node graph complete ($(( $(date +%s) - t0 ))s after 'Starting controller'): the six healthy-session nodes, no duplicates"

# --- REGION: block 4, the disturbance service (#68)
# Last, and only when the composed file asked for it. It needs the simulator --
# it publishes /simulation_disturbance, which drake_simulator subscribes to
# (drake_simulator.cpp:355-358) -- and it is started after the controller so the
# six-node wait above measures the stack the other three blocks make.
if [ "$DISTURBER" = 1 ]; then
    start_block 4 disturber
    t0=$(date +%s)
    dmissing="$(disturber_missing)"
    for i in $(seq 1 $((GRAPH_TIMEOUT / 2))); do
        [ -z "$dmissing" ] && break
        sleep 2
        dmissing="$(disturber_missing)"
    done
    if [ -n "$dmissing" ]; then
        fail "the disturber did not come up within ${GRAPH_TIMEOUT}s -- still missing: $dmissing" \
             "  sudo docker exec $CONTAINER tail -40 /tmp/p21-disturber.log" \
             "It is built and installed at the pin (mapping.md 4.6); check the binary:" \
             "  sudo docker exec $CONTAINER ls -l /root/ros2_ws/install/simulator/lib/simulator/"
        exit 1
    fi
    say "  disturber up ($(( $(date +%s) - t0 ))s): $DISTURBER_NODE in the graph, $DISTURBER_SRV served"
    in_ctr "timeout 15 ros2 node list 2>/dev/null" | grep '^/' | sort > "$WORK/nodes"
fi

# Anything BEYOND the six -- or seven, with a disturber this file asked for -- is
# reported and never fatal: a rosbridge left running adds three (bridge.md 4),
# and it is `verify` that owns that verdict through KENNEL_EXPECT_BRIDGE and
# KENNEL_EXPECT_DISTURBER. Saying it here makes the next report's `extra:` line
# unsurprising rather than alarming.
ALLOWED_NODES="$EXPECTED_NODES"
[ "$DISTURBER" = 1 ] && ALLOWED_NODES="$ALLOWED_NODES $DISTURBER_NODE"
extra="$(comm -13 <(printf '%s\n' $ALLOWED_NODES | sort) <(sort -u "$WORK/nodes") | tr '\n' ' ')"
if [ -n "$extra" ]; then
    say "  NB the graph also carries: $extra"
    say "     (verify tolerates a running bridge with KENNEL_EXPECT_BRIDGE=1,"
    say "      and a composed disturber with KENNEL_EXPECT_DISTURBER=1)"
fi

say "stack is up, launched from the console's generated commands.txt"
say "logs: /tmp/p21-sim.log /tmp/p21-legdrv.log /tmp/p21-ctrl.log$([ "$DISTURBER" = 1 ] && echo ' /tmp/p21-disturber.log') (in the container)"
