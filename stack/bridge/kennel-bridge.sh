#!/bin/bash
# Version: 2026.09.07
# Kennel -- issue #58: run the rosbridge WebSocket server beside the stack, so a
# browser can publish a velocity target and call the controller's services.
# Since #65 it also OBSERVES the stack and RECOVERS it, so the live regression
# suite (stack/bridge/verify-teleop-live.sh, on the host) has one guest-side
# entry point for everything it needs.
#
# Runs on the GUEST (kennel-vm), against an already-running stack.
#
# rosbridge_server has been in the pinned image since before Kennel existed
# (docker/Dockerfile:15 at the pin) and no kennel tool has ever started it. This
# script is that missing verb. It starts NOTHING else: the stack must already be
# launched, because rosbridge resolves `interfaces/msg/QuadControlTarget` out of
# the sourced workspace and has nothing to bridge otherwise.
#
# DEPENDS ON p21-launch-from-commands.sh HAVING RUN. It sources /tmp/p21-env.sh,
# which that launcher writes -- the same coupling #45 filed against
# p21-trot-hold.sh, except this script says so and exits 2 with the fix named.
#
#   kennel-bridge.sh start    # launch it, wait until it is really usable
#   kennel-bridge.sh stop     # INT, bounded wait, KILL, remove the pidfile
#   kennel-bridge.sh status   # pid / port / node, one line each
#   kennel-bridge.sh observe N [--rows] [--label L]
#                             # run k13-target-monitor.py in the container for N
#                             # SIM seconds and pass its output through: one
#                             # `KENNEL_JSON {...}` line with the rates, the
#                             # target's staleness and the gait signature. This
#                             # is how the host suite reads the stack -- every
#                             # live assertion is made against what a node in the
#                             # graph saw (kennel_console/dashboard.md §4).
#   kennel-bridge.sh recover  # put a fallen or damped robot back on its feet:
#                             # zero -> STAND -> (leave EMERGENCY_DAMPING, only
#                             # if it is down) -> /reset_sim -> wait for standing.
#                             # The same four steps the console's `reset sim`
#                             # button runs (kennel_console/teleop.md §12).
#
# WHY `recover` EXISTS. E-STOP is LegDriver::EMERGENCY_DAMPING, and until #65
# nothing ever left it: every session that pressed E-STOP relaunched the whole
# stack afterwards (kennel_console/dashboard/evidence/03b-relaunch.txt). It CAN
# be left -- only into DAMPING, by the sibling Trigger /set_damping_mode, and
# DAMPING returns to OPERATE by itself as soon as a leg command and a quad state
# arrive (leg_driver.cpp:233-237, :348-374 at the pin). That is what makes the
# live suite's E-STOP group repeatable on one stack instead of costing a launch.
#
# The pidfile is /tmp/k13-bridge.pid ON PURPOSE: k13-stop.sh signals every
# /tmp/k13-*.pid, so `kennel-demo.sh down`, the pre-launch stop and the baseline
# prep script all reap this process with no change to any of them.
#
# READINESS IS OBSERVED, TWICE. The node joining the ROS graph and the socket
# being bound are different events and either can be last (#52 is the same shape:
# a gate that watched one signal and returned before another was true), so
# `start` does not return until both hold.
#
# Knobs (environment variables):
#   KENNEL_CONTAINER      dfki_quad
#   KENNEL_BRIDGE_PORT    9090
#   KENNEL_BRIDGE_WAIT    60    SECONDS to wait for `start`'s two signals. It was
#                               an iteration count until #65 -- the same
#                               inconsistency composed-run.md §9.3 records for
#                               KENNEL_TOPIC_TIMEOUT -- and is now what it says.
#   KENNEL_BRIDGE_POLL    1     seconds between polls of those two signals. Set
#                               it to 0.1 to MEASURE the race (D.3 §8): `start`
#                               prints the window each signal became true in.
#   KENNEL_MONITOR        /tmp/k13-target-monitor.py   the observe tool, on the
#                               GUEST, staged there by kennel-demo.sh or by the
#                               live suite. It is copied into the container here.
#   KENNEL_RECOVER_DOWN_Z 0.15  below this median height the robot is "down", and
#                               only then is /set_damping_mode called. A standing
#                               robot is never touched.
#   KENNEL_WATCHDOG       1     start k13-target-watchdog.py beside the bridge
#                               (#67). 0 disables it -- the pre-#67 behaviour,
#                               kept reachable because it is what the live suite
#                               measures the watchdog AGAINST.
#   KENNEL_WATCHDOG_STALE 1.0   seconds without a target before it intervenes
#   KENNEL_WATCHDOG_REPEAT 3    zeros per intervention, one second apart
#   KENNEL_WATCHDOG_TOOL  /tmp/k13-target-watchdog.py   on the GUEST, staged
#                               there by kennel-demo.sh or by the live suite
#
# Exit codes:
#   0  the bridge is up (start/status), or is stopped (stop), or the robot is
#      standing again (recover), or the window was measured (observe)
#   1  it did not come up within the wait, status found it unhealthy, or recover
#      could not get the robot back on its feet
#   2  could not even look: no container, no stack to bridge, no observe tool
#
# `set -uo pipefail` is safe here: this script sources no ROS setup file itself.
# Everything that needs one goes through in_ctr, inside the container.

set -uo pipefail

CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
PORT="${KENNEL_BRIDGE_PORT:-9090}"
WAIT="${KENNEL_BRIDGE_WAIT:-60}"
POLL="${KENNEL_BRIDGE_POLL:-1}"
NODE_CTRL="${KENNEL_CONTROLLER_NODE:-/mit_controller_node}"
MONITOR="${KENNEL_MONITOR:-/tmp/k13-target-monitor.py}"
WATCHDOG="${KENNEL_WATCHDOG:-1}"
WATCHDOG_TOOL="${KENNEL_WATCHDOG_TOOL:-/tmp/k13-target-watchdog.py}"
WATCHDOG_STALE="${KENNEL_WATCHDOG_STALE:-1.0}"
WATCHDOG_REPEAT="${KENNEL_WATCHDOG_REPEAT:-3}"
RECOVER_DOWN_Z="${KENNEL_RECOVER_DOWN_Z:-0.15}"
# simulator_params_go2.yaml initial_robot_height at the pin. The composer never
# touches it (composer-scope.md), so this is the stock spawn.
RECOVER_SPAWN_Z="${KENNEL_RECOVER_SPAWN_Z:-0.4}"
# Ten one-sim-second looks, not six: a robot reset from a tumble sometimes needs
# longer to settle than one reset from standing, and a `recover` that gives up
# early costs a whole relaunch.
RECOVER_TRIES="${KENNEL_RECOVER_TRIES:-10}"
TARGET_Z="${KENNEL_TARGET_Z:-0.30}"
PIDFILE=/tmp/k13-bridge.pid
LOG=/tmp/k13-bridge.log
# The launch file declares two nodes (rosbridge_websocket_launch.xml:60 and :86)
# but spawns THREE graph entries: rosapi_node registers /rosapi and
# /rosapi_params. Observed, not read off the XML -- kennel-verify.sh's
# KENNEL_EXPECT_BRIDGE knob adds the same three to check 1.
NODE=/rosbridge_websocket
BRIDGE_NODES="/rosapi /rosapi_params /rosbridge_websocket"
# The dead man's switch (#67). Its pidfile is /tmp/k13-*.pid ON PURPOSE, for the
# same reason the bridge's is: k13-stop.sh signals every one of them, so `down`,
# the pre-launch stop and the baseline prep script all reap it for free.
WD_NODE=/k13_target_watchdog
WD_PIDFILE=/tmp/k13-watchdog.pid
WD_LOG=/tmp/k13-watchdog.log
WD_STATE=/tmp/k13-watchdog.state
# The children are matched by executable PATH, never by name: their comm is
# `python3`. The [] brackets are load-bearing -- they stop the pattern matching
# the docker-exec cmdline that carries it.
CHILD_WS='rosbridge_server/rosbridge_websocke[t]'
CHILD_API='rosapi/rosapi_nod[e]'
CHILD_RE='rosbridge_server/rosbridge_websocke[t]\|rosapi/rosapi_nod[e]'
INT_GRACE="${KENNEL_BRIDGE_INT_GRACE:-3}"

say()  { echo "[kennel-bridge] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

# --- REGION: the container source chain (#45)
# The block between the CHAIN markers is IDENTICAL to
# stack/known-good/tools/prelude.sh, which is also what shell 1 of the console's
# commands.txt emits (launch.md 2). The markers are load-bearing: the check in
# stack/composed-run.md 9.2 diffs between them against prelude.sh, so the copies
# are proven identical rather than assumed to be. Sourcing the WRONG workspace
# setup silently partitions the ROS graph (launch.md 2.1).
#
# It is never written back to /tmp/p21-env.sh: the launcher stays the only writer
# of that file, so its presence keeps meaning "the launcher ran".
# --- CHAIN BEGIN (identical to stack/known-good/tools/prelude.sh)
ENV_CHAIN='source /opt/ros/humble/setup.bash
[ -f /root/unitree_ros2/install/setup.bash ] && source /root/unitree_ros2/install/setup.bash
source /root/ros2_ws/install/setup.bash
export PATH="/opt/drake/bin:${PATH}"
export PYTHONPATH="/opt/drake/lib/python3.10/site-packages:${PYTHONPATH}"
export LD_LIBRARY_PATH="/opt/drake/lib:${LD_LIBRARY_PATH}"
export ROS_PACKAGE_PATH="/root/ros2_ws/src"
source /root/setup_ulab_workspace.bash
cd /root/ros2_ws'
# --- CHAIN END
# ${...} inside ENV_CHAIN stays literal: bash does not re-expand a variable's
# value, so these reach the container's shell unexpanded, as they do in
# commands.txt.
ENV_PRELUDE="if [ -f /tmp/p21-env.sh ]; then source /tmp/p21-env.sh; else $ENV_CHAIN; fi >/dev/null 2>&1"

in_ctr() { sudo docker exec "$CONTAINER" bash -c "$ENV_PRELUDE; $1" 2>/dev/null; }
# Same, but stderr survives. Used by `observe` and `recover`, whose whole output
# is the evidence -- a service call that failed has to say so. FastRTPS writes
# RTPS_TRANSPORT_SHM warnings there (launch.md §7 trap 7), which is exactly why
# the monitor marks its result line with KENNEL_JSON instead of being "the last
# line": callers grep for the marker.
in_ctr_v() { sudo docker exec "$CONTAINER" bash -c "$ENV_PRELUDE; $1"; }

env_source() {
    if sudo docker exec "$CONTAINER" test -f /tmp/p21-env.sh 2>/dev/null
    then echo "/tmp/p21-env.sh (written by p21-launch-from-commands.sh)"
    else echo "built-in chain (no /tmp/p21-env.sh -- the stack was launched some other way)"
    fi
}

# The container runs --network host, so a socket it opens IS a socket in the
# guest (meshcat-exposure.md §2.1) -- ss on the guest sees it, no docker exec
# needed, and `ss` is in the guest image while it is not in the container's.
port_bound()  { ss -ltn 2>/dev/null | awk -v p=":$PORT\$" '$4 ~ p {found=1} END {exit !found}'; }
port_line()   { ss -ltn 2>/dev/null | awk -v p=":$PORT\$" '$4 ~ p {print $4; exit}'; }
node_listed() { [ "$(in_ctr "timeout 15 ros2 node list 2>/dev/null | grep -c '^$NODE\$'")" = 1 ]; }
# The pidfile lives in the CONTAINER's /tmp -- the same path exists on the guest
# and is NOT the same file. Every read of it goes through docker exec, or the
# checks below silently report "not running" for a healthy bridge.
ctr_pid()     { sudo docker exec "$CONTAINER" cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]'; }
pid_alive()   { local p; p="$(ctr_pid)"; [ -n "$p" ] && sudo docker exec "$CONTAINER" kill -0 "$p" 2>/dev/null; }
# The launch's two children, by executable path -- see the note in `stop`.
children_alive() { [ "$(sudo docker exec "$CONTAINER" ps ax -o args --no-headers 2>/dev/null | grep -c "$CHILD_RE")" != 0 ]; }
reap_children() {
    sudo docker exec "$CONTAINER" pkill -INT -f "$CHILD_WS"   2>/dev/null
    sudo docker exec "$CONTAINER" pkill -INT -f "$CHILD_API"  2>/dev/null
    for _ in $(seq 1 "$INT_GRACE"); do
        children_alive || return 0
        sleep 1
    done
    sudo docker exec "$CONTAINER" pkill -KILL -f "$CHILD_WS"  2>/dev/null
    sudo docker exec "$CONTAINER" pkill -KILL -f "$CHILD_API" 2>/dev/null
}

# --- REGION: helpers the observing verbs share (#65)
# Seconds since T0, two decimals, without bc: `date +%s.%N` and awk.
T0="$(date +%s.%N)"
elapsed() { awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}'; }
# Float comparison, the same way p21-* does arithmetic: awk, never bash.
lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }
in_range() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'; }

controller_in_graph() {
    [ "$(in_ctr "timeout 15 ros2 node list 2>/dev/null | grep -c '^$NODE_CTRL\$'")" = 1 ]
}

# "Is there a stack to talk to?" -- the question every verb below has to ask, and
# the one #45 is about: name the cause and the fix, never let `ros2` name itself.
need_stack() {
    [ "$container_state" = running ] || {
        fail "container '$CONTAINER' is '$container_state', not running." \
             "Start the stack:  demo/tools/kennel-demo.sh launch"
        exit 2
    }
    controller_in_graph || {
        fail "no $NODE_CTRL in the ROS graph -- there is no stack to observe." \
             "Launch first:  demo/tools/kennel-demo.sh launch"
        exit 2
    }
}

# Copy the monitor in and run it. Everything it prints comes straight through:
# the CSV rows are the transcript, the KENNEL_JSON line is the result.
run_monitor() {   # $1 = sim seconds, $2.. = extra args
    [ -f "$MONITOR" ] || {
        fail "the observe tool is not on this guest: $MONITOR" \
             "Stage it first (kennel-demo.sh and the live suite both do):" \
             "  scp stack/bridge/tools/k13-target-monitor.py guest:/tmp/" \
             "Or point KENNEL_MONITOR at it."
        exit 2
    }
    sudo docker cp "$MONITOR" "$CONTAINER:/root/k13-target-monitor.py" >/dev/null || {
        fail "could not copy $MONITOR into '$CONTAINER'."; exit 2; }
    local secs="$1"; shift
    in_ctr_v "python3 /root/k13-target-monitor.py --sim-seconds $secs $*"
}

# One number out of the monitor's JSON line, without a JSON parser on the guest.
# The line is emitted with sorted keys and json.dumps' default `": "` separator,
# so this is a stable read of a top-level float -- and if it ever is not, the
# caller gets an empty string and says so rather than believing a wrong number.
# --- REGION: the watchdog (#67)
wd_pid()       { sudo docker exec "$CONTAINER" cat "$WD_PIDFILE" 2>/dev/null | tr -d '[:space:]'; }
wd_alive()     { local p; p="$(wd_pid)"; [ -n "$p" ] && sudo docker exec "$CONTAINER" kill -0 "$p" 2>/dev/null; }
wd_listed()    { [ "$(in_ctr "timeout 15 ros2 node list 2>/dev/null | grep -c '^$WD_NODE\$'")" = 1 ]; }
wd_ready()     { sudo docker exec "$CONTAINER" grep -q '^\[watchdog\] ready' "$WD_LOG" 2>/dev/null; }
wd_state()     { sudo docker exec "$CONTAINER" cat "$WD_STATE" 2>/dev/null | tr -d '\r'; }
wd_interventions() { wd_state | sed -n 's/.*interventions=\([0-9]*\).*/\1/p'; }

start_watchdog() {
    [ "$WATCHDOG" = 0 ] && { say "watchdog        disabled (KENNEL_WATCHDOG=0)"; return 0; }
    if wd_alive; then say "watchdog        already up (pid $(wd_pid))"; return 0; fi
    [ -f "$WATCHDOG_TOOL" ] || {
        fail "the watchdog tool is not on this guest: $WATCHDOG_TOOL" \
             "Stage it (kennel-demo.sh teleop and the live suite both do):" \
             "  scp stack/bridge/tools/k13-target-watchdog.py guest:/tmp/" \
             "or run without it:  KENNEL_WATCHDOG=0 $0 start"
        exit 2
    }
    sudo docker cp "$WATCHDOG_TOOL" "$CONTAINER:/root/k13-target-watchdog.py" >/dev/null || {
        fail "could not copy $WATCHDOG_TOOL into '$CONTAINER'."; exit 2; }
    sudo docker exec "$CONTAINER" rm -f "$WD_STATE" "$WD_LOG" 2>/dev/null
    say "starting the target watchdog (stale ${WATCHDOG_STALE}s, ${WATCHDOG_REPEAT} zeros)"
    # The recorded PID is python3's own -- `echo $!` after a background start.
    # NOT `$$` inside a subshell, which is the parent's (launch.md 7 trap 4);
    # k13-stop.sh has to be able to signal exactly this process.
    sudo docker exec -d "$CONTAINER" bash -c \
        "$ENV_PRELUDE
         KENNEL_WATCHDOG_STALE=$WATCHDOG_STALE KENNEL_WATCHDOG_REPEAT=$WATCHDOG_REPEAT \
           python3 /root/k13-target-watchdog.py > $WD_LOG 2>&1 &
         echo \$! > $WD_PIDFILE"
    # Two signals again, for the reason 3 gives about the bridge: being in the
    # graph and being ready to work are different events.
    local node=0 ready=0 iters
    iters="$(awk -v w="$WAIT" -v p="$POLL" 'BEGIN{n=w/p; printf "%d", (n<1?1:n)}')"
    for _ in $(seq 1 "$iters"); do
        [ "$node"  = 1 ] || { wd_listed && { node=1;  say "  $WD_NODE in the graph"; }; }
        [ "$ready" = 1 ] || { wd_ready  && { ready=1; say "  watchdog ready, waiting for the first target"; }; }
        [ "$node" = 1 ] && [ "$ready" = 1 ] && break
        sleep "$POLL"
    done
    if [ "$node" != 1 ] || [ "$ready" != 1 ]; then
        fail "the watchdog did not come up (node=$node ready=$ready)." \
             "Log: sudo docker exec $CONTAINER cat $WD_LOG"
        sudo docker exec "$CONTAINER" tail -10 "$WD_LOG" 2>/dev/null
        return 1
    fi
    say "watchdog up (pid $(wd_pid))"
}

stop_watchdog() {
    wd_alive || { sudo docker exec "$CONTAINER" rm -f "$WD_PIDFILE" "$WD_STATE" 2>/dev/null; return 0; }
    # WAIT FOR IT TO BE DONE FIRST. The bridge has already gone down by the time
    # this runs, and the seconds right after that are the whole point of the
    # node: a page that was mid-hold is now silent, and the target it left is
    # stale and non-zero. Stopping the watchdog here would throw away the one
    # intervention it exists to make.
    local bound st=""
    bound="$(awk -v s="$WATCHDOG_STALE" -v r="$WATCHDOG_REPEAT" 'BEGIN{printf "%d", (s+r+2)*2}')"
    for _ in $(seq 1 "$bound"); do
        st="$(wd_state)"
        case "$st" in idle*|"") break ;; esac
        sleep 0.5
    done
    case "$st" in
        armed*) say "watchdog still armed after the wait -- something else is holding a"
                say "  non-zero target (a walk?). Stopping it anyway: it never fires"
                say "  against a publisher that is still publishing." ;;
    esac
    local p; p="$(wd_pid)"
    sudo docker exec "$CONTAINER" kill -INT "$p" 2>/dev/null
    for _ in $(seq 1 "$INT_GRACE"); do
        sudo docker exec "$CONTAINER" kill -0 "$p" 2>/dev/null || break
        sleep 1
    done
    sudo docker exec "$CONTAINER" kill -KILL "$p" 2>/dev/null
    sudo docker exec "$CONTAINER" rm -f "$WD_PIDFILE" "$WD_STATE" 2>/dev/null
    say "watchdog stopped (interventions this session: ${1:-see $WD_LOG})"
}

json_num() {   # $1 = file, $2 = key
    grep '^KENNEL_JSON ' "$1" | tail -1 \
        | sed -n "s/.*\"$2\": \(-\?[0-9][0-9.e-]*\).*/\1/p"
}

# --- REGION: preconditions shared by start and status
container_state="$(sudo docker inspect --type container -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null | tr -d '[:space:]')"
[ -n "$container_state" ] || {
    fail "no container named '$CONTAINER'." "Provision the guest first (vm/provisioning.md)."
    exit 2
}

case "${1:-status}" in

start)
    [ "$container_state" = running ] || {
        say "container is '$container_state' -- starting it"
        sudo docker start "$CONTAINER" >/dev/null || { fail "could not start '$CONTAINER'."; exit 2; }
    }
    say "env              $(env_source)"
    # "Is there a stack to bridge?" used to be asked as "does /tmp/p21-env.sh
    # exist?", which conflated two different facts: how the stack was launched,
    # and whether it is running at all. Since #45 the env file is no longer
    # required -- so ask the real question, of the ROS graph.
    [ "$(in_ctr "timeout 15 ros2 node list 2>/dev/null | grep -c '^/mit_controller_node\$'")" = 1 ] || {
        fail "no /mit_controller_node in the ROS graph -- there is no stack to bridge." \
             "rosbridge resolves interfaces/msg/QuadControlTarget out of the sourced" \
             "workspace, and has nothing to serve until the stack is up." \
             "Launch first:  demo/tools/kennel-demo.sh launch" \
             "If the stack IS running, the graph is not visible from this shell:" \
             "  sudo docker exec $CONTAINER bash -c '$ENV_PRELUDE; ros2 node list'"
        exit 2
    }
    [ -n "$(in_ctr "timeout 15 ros2 pkg prefix rosbridge_server 2>/dev/null")" ] || {
        fail "rosbridge_server is not installed in the image." \
             "It is expected at the pin (docker/Dockerfile:15). Check the image:" \
             "  sudo docker exec $CONTAINER bash -c '$ENV_PRELUDE; ros2 pkg list | grep rosbridge'"
        exit 2
    }

    if pid_alive && port_bound; then
        say "already up: pid $(ctr_pid) on port $PORT ($(port_line))"
        exit 0
    fi
    # A pidfile whose process is gone is stale -- a previous run that k13-stop.sh
    # reaped. Clear it rather than refusing to start.
    pid_alive || sudo docker exec "$CONTAINER" rm -f "$PIDFILE" 2>/dev/null

    say "starting rosbridge on port $PORT"
    # Detached and endless, exactly as p21-trot-hold.sh starts its publisher: the
    # PID is kept so the process can be signalled by identity, never by a pkill
    # pattern (launch.md §7 trap 6).
    #
    # address is left at the launch file's default (empty = every interface).
    # Binding loopback-only would make the guest->host hop impossible, which is
    # the failure verify-bridge-host.sh reports as exit 5.
    sudo docker exec -d "$CONTAINER" bash -c \
        "$ENV_PRELUDE
         ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:=$PORT > $LOG 2>&1 &
         echo \$! > $PIDFILE"

    # Wait on the stack, never on a clock (dry-run.md F8). Two signals, both
    # required: the node in the graph and the socket bound.
    #
    # Each is reported as the WINDOW it became true in, not as an instant. The
    # two probes cost very different amounts -- `ss` on the guest is a few
    # milliseconds, `ros2 node list` inside the container is closer to a second --
    # so a single timestamp each would say more about the measurement than about
    # the stack. With KENNEL_BRIDGE_POLL=0.1 these windows are the observation
    # behind the two-signal wait (#65, plan/teleop-joystick.md D.3 §8).
    T0="$(date +%s.%N)"
    graph=0; sock=0
    iters="$(awk -v w="$WAIT" -v p="$POLL" 'BEGIN{n=w/p; printf "%d", (n<1?1:n)}')"
    for _ in $(seq 1 "$iters"); do
        if [ "$graph" != 1 ]; then
            a="$(elapsed)"
            node_listed && { graph=1; say "  $NODE in the graph  (+$a .. +$(elapsed) s)"; }
        fi
        if [ "$sock" != 1 ]; then
            a="$(elapsed)"
            port_bound && { sock=1; say "  port $PORT bound ($(port_line))  (+$a .. +$(elapsed) s)"; }
        fi
        [ "$graph" = 1 ] && [ "$sock" = 1 ] && break
        sleep "$POLL"
    done
    if [ "$graph" != 1 ] || [ "$sock" != 1 ]; then
        fail "the bridge did not come up within ${WAIT}s (node=$graph port=$sock)." \
             "Log: sudo docker exec $CONTAINER tail -40 $LOG"
        sudo docker exec "$CONTAINER" tail -20 "$LOG" 2>/dev/null
        exit 1
    fi
    say "bridge up on port $PORT (pid $(ctr_pid))"
    # The bridge first, then the thing that guards it (#67). A watchdog with no
    # bridge is harmless; a bridge with no watchdog is exactly the gap the live
    # suite measured -- 13 m of uncommanded walking after a killed tab.
    start_watchdog || exit 1
    say "the URL is the host's to compose -- vm/test/verify-bridge-host.sh prints it"
    ;;

stop)
    # Deliberately does NOT touch the gait or the velocity target. Killing the
    # bridge under a browser that is mid-hold would leave the controller with a
    # non-zero target and no publisher -- the robot would walk away. Zeroing the
    # target is p21-trot-hold.sh stop's job, and `kennel-demo.sh teleop stop`
    # runs it FIRST, in that order.
    #
    # MEASURED 2026-08-30: SIGINT to the recorded `ros2 launch` PID does nothing
    # at all -- 15 s later the launch and both children were still running and
    # the port was still bound. A detached `docker exec -d bash -c '... &'` has
    # no controlling terminal and no foreground process group, which is what
    # ros2 launch's Ctrl-C handling actually watches for. So the polite signal
    # gets a SHORT grace and the children are then reaped by identity.
    p="$(ctr_pid)"
    if [ -z "$p" ] && ! children_alive && ! port_bound; then
        say "no pidfile and nothing listening -- nothing to stop"
        exit 0
    fi
    if [ -n "$p" ]; then
        sudo docker exec "$CONTAINER" kill -INT "$p" 2>/dev/null
        for _ in $(seq 1 "$INT_GRACE"); do
            sudo docker exec "$CONTAINER" kill -0 "$p" 2>/dev/null || break
            sleep 1
        done
        sudo docker exec "$CONTAINER" kill -KILL "$p" 2>/dev/null
    else
        say "no pidfile -- reaping by identity only"
    fi
    # The two children outlive the launch process and keep the port. Their comm
    # is `python3` (not their node name), so `pkill -x` can never match them --
    # the same trap k13-stop.sh records for joy_to_target.py, and the same fix:
    # match the executable PATH. The [] brackets keep the pattern from matching
    # the very docker-exec cmdline that carries it (launch.md §7 trap 6).
    reap_children
    sudo docker exec "$CONTAINER" rm -f "$PIDFILE" 2>/dev/null
    # ORDER: the bridge is down NOW, and only now is the watchdog stopped -- and
    # not until it says it is idle. See stop_watchdog.
    n_int="$(wd_interventions)"
    stop_watchdog "${n_int:-0}"
    for _ in $(seq 1 10); do
        port_bound || break
        sleep 1
    done
    if port_bound; then
        fail "port $PORT is still bound after the stop." \
             "Look at what holds it:" \
             "  sudo docker exec $CONTAINER ps ax | grep -i rosbridge"
        exit 1
    fi
    say "bridge stopped"
    ;;

status)
    rc=0
    if pid_alive; then say "pid       $(ctr_pid) alive"
    else               say "pid       not running"; rc=1; fi
    if port_bound; then say "port      $PORT bound ($(port_line))"
    else                say "port      $PORT not bound"; rc=1; fi
    if [ "$container_state" = running ] && node_listed; then say "node      $NODE in the graph"
    else                                                     say "node      $NODE absent"; rc=1; fi
    if wd_alive; then
        say "watchdog  pid $(wd_pid) alive · $(wd_state | cut -c1-70)"
    elif [ "$WATCHDOG" = 0 ]; then
        say "watchdog  disabled (KENNEL_WATCHDOG=0)"
    else
        say "watchdog  not running"; rc=1
    fi
    [ "$rc" = 0 ] && say "bridge is up" || say "bridge is NOT up  (start it: $0 start)"
    exit $rc
    ;;

observe)
    # Read the stack for a window and print what it saw. The window is in SIM
    # seconds: the guest runs composed realtime rates, and a wall-clock window
    # measures a different amount of robot at each one (verify.md §1.1).
    shift
    need_stack
    secs="${1:-5}"
    case "$secs" in
        ''|*[!0-9.]*) fail "observe needs a window in SIM seconds." \
                           "  $0 observe 20 [--rows] [--label drive]"; exit 2 ;;
    esac
    shift || true
    run_monitor "$secs" "$@"
    exit $?
    ;;

recover)
    # Put a fallen or damped robot back on its feet, in the order measured for
    # #66 (kennel_console/teleop.md §12): the zero first, because the controller
    # keeps the last target it received forever and a reset does not clear it
    # (mit_controller_node.cpp:793-798 copies only what arrives).
    need_stack
    tmpj="$(mktemp)"
    trap 'rm -f "$tmpj"' EXIT
    say "recover: zero -> STAND -> (leave EMERGENCY_DAMPING only if down) -> /reset_sim"

    say "1/5 zeroing the velocity target (world_z $TARGET_Z kept -- launch.md §4.2)"
    in_ctr "timeout 20 ros2 topic pub --times 10 -r 10 /quad_control_target \
            interfaces/msg/QuadControlTarget \
            '{body_x_dot: 0.0, body_y_dot: 0.0, world_z: $TARGET_Z, hybrid_theta_dot: 0.0, roll: 0.0, pitch: 0.0}'" \
        >/dev/null

    say "2/5 gait -> STAND"
    in_ctr "timeout 20 ros2 param set $NODE_CTRL simple_gait_sequencer.gait STAND" >/dev/null

    say "3/5 reading the body height"
    run_monitor 1 --label recover-before > "$tmpj" 2>/dev/null
    z="$(json_num "$tmpj" z_median)"

    # ONLY when it is down. /set_damping_mode moves the leg driver EMERGENCY_DAMPING
    # -> DAMPING, and DAMPING returns to OPERATE on its own once a leg command and
    # a quad state arrive. Calling it on a robot that is walking would drop it.
    if [ -n "$z" ] && lt "$z" "$RECOVER_DOWN_Z"; then
        say "4/5 the robot is DOWN (z median $z m < $RECOVER_DOWN_Z) -- leaving EMERGENCY_DAMPING"
        in_ctr_v "timeout 30 ros2 service call /set_damping_mode std_srvs/srv/Trigger" \
            2>/dev/null | sed 's/^/[kennel-bridge]      /'
    else
        say "4/5 the robot is up (z median ${z:-unknown} m) -- emergency damping not touched"
    fi

    say "5/5 /reset_sim to the stock spawn (z $RECOVER_SPAWN_Z, the simulator's own joint positions)"
    in_ctr_v "timeout 60 ros2 service call /reset_sim interfaces/srv/ResetSimulation \
              '{pose: {position: {x: 0.0, y: 0.0, z: $RECOVER_SPAWN_Z}, orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}}, joint_positions: []}'" \
        2>/dev/null | sed 's/^/[kennel-bridge]      /'

    # Wait for the ROBOT, never for a clock: the service answers the moment the
    # context is replaced, and the body still has to fall the spawn height and
    # settle (measured: about one sim-second).
    for i in $(seq 1 "$RECOVER_TRIES"); do
        run_monitor 1 --label recover-after > "$tmpj" 2>/dev/null
        z="$(json_num "$tmpj" z_median)"
        say "  z median ${z:-unknown} m"
        if [ -n "$z" ] && in_range "$z" 0.25 0.35; then
            say "recovered: standing at $z m, gait STAND, target zero"
            exit 0
        fi
        # Half way through, ask once more. A reset that landed the robot badly
        # is fixed by another reset; waiting longer for it is not.
        if [ "$i" = "$((RECOVER_TRIES / 2))" ]; then
            say "  still not standing -- resetting once more"
            in_ctr_v "timeout 60 ros2 service call /reset_sim interfaces/srv/ResetSimulation \
                      '{pose: {position: {x: 0.0, y: 0.0, z: $RECOVER_SPAWN_Z}, orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}}, joint_positions: []}'" \
                >/dev/null 2>&1
        fi
    done
    fail "the robot did not reach a standing height within $RECOVER_TRIES tries (last z median ${z:-unknown} m)." \
         "Look at it in Meshcat, then relaunch:  demo/tools/kennel-demo.sh launch"
    exit 1
    ;;

*)
    echo "usage: $0 [start|stop|status|observe N [--rows] [--label L]|recover]" >&2
    exit 2 ;;
esac
