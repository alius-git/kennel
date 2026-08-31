#!/bin/bash
# Version: 2026.08.30
# Kennel -- issue #58: run the rosbridge WebSocket server beside the stack, so a
# browser can publish a velocity target and call the controller's services.
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
# Exit codes:
#   0  the bridge is up (start/status), or is stopped (stop)
#   1  it did not come up within the wait, or status found it unhealthy
#   2  could not even look: no container, or no stack to bridge
#
# `set -uo pipefail` is safe here: this script sources no ROS setup file itself.
# Everything that needs one goes through in_ctr, inside the container.

set -uo pipefail

CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
PORT="${KENNEL_BRIDGE_PORT:-9090}"
WAIT="${KENNEL_BRIDGE_WAIT:-60}"
PIDFILE=/tmp/k13-bridge.pid
LOG=/tmp/k13-bridge.log
# The launch file declares two nodes (rosbridge_websocket_launch.xml:60 and :86)
# but spawns THREE graph entries: rosapi_node registers /rosapi and
# /rosapi_params. Observed, not read off the XML -- kennel-verify.sh's
# KENNEL_EXPECT_BRIDGE knob adds the same three to check 1.
NODE=/rosbridge_websocket
BRIDGE_NODES="/rosapi /rosapi_params /rosbridge_websocket"
# The children are matched by executable PATH, never by name: their comm is
# `python3`. The [] brackets are load-bearing -- they stop the pattern matching
# the docker-exec cmdline that carries it.
CHILD_WS='rosbridge_server/rosbridge_websocke[t]'
CHILD_API='rosapi/rosapi_nod[e]'
CHILD_RE='rosbridge_server/rosbridge_websocke[t]\|rosapi/rosapi_nod[e]'
INT_GRACE="${KENNEL_BRIDGE_INT_GRACE:-3}"

say()  { echo "[kennel-bridge] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

in_ctr() { sudo docker exec "$CONTAINER" bash -c "source /tmp/p21-env.sh >/dev/null 2>&1; $1" 2>/dev/null; }

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
    # The env file is the launcher's output, and without it nothing below can
    # even find ros2. Naming the fix here is the whole of #45's lesson.
    sudo docker exec "$CONTAINER" test -f /tmp/p21-env.sh 2>/dev/null || {
        fail "no /tmp/p21-env.sh in the container -- the stack has not been launched." \
             "rosbridge resolves interfaces/msg/QuadControlTarget out of the sourced" \
             "workspace, so there is nothing to bridge yet." \
             "Launch first:  demo/tools/kennel-demo.sh launch"
        exit 2
    }
    [ -n "$(in_ctr "timeout 15 ros2 pkg prefix rosbridge_server 2>/dev/null")" ] || {
        fail "rosbridge_server is not installed in the image." \
             "It is expected at the pin (docker/Dockerfile:15). Check the image:" \
             "  sudo docker exec $CONTAINER bash -c 'source /tmp/p21-env.sh; ros2 pkg list | grep rosbridge'"
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
        "source /tmp/p21-env.sh >/dev/null 2>&1
         ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:=$PORT > $LOG 2>&1 &
         echo \$! > $PIDFILE"

    # Wait on the stack, never on a clock (dry-run.md F8). Two signals, both
    # required: the node in the graph and the socket bound.
    graph=0; sock=0
    for _ in $(seq 1 "$WAIT"); do
        [ "$graph" = 1 ] || { node_listed && { graph=1; say "  $NODE in the graph"; }; }
        [ "$sock"  = 1 ] || { port_bound  && { sock=1;  say "  port $PORT bound ($(port_line))"; }; }
        [ "$graph" = 1 ] && [ "$sock" = 1 ] && break
        sleep 1
    done
    if [ "$graph" != 1 ] || [ "$sock" != 1 ]; then
        fail "the bridge did not come up within ${WAIT}s (node=$graph port=$sock)." \
             "Log: sudo docker exec $CONTAINER tail -40 $LOG"
        sudo docker exec "$CONTAINER" tail -20 "$LOG" 2>/dev/null
        exit 1
    fi
    say "bridge up on port $PORT (pid $(ctr_pid))"
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
    [ "$rc" = 0 ] && say "bridge is up" || say "bridge is NOT up  (start it: $0 start)"
    exit $rc
    ;;

*)
    echo "usage: $0 [start|stop|status]" >&2
    exit 2 ;;
esac
