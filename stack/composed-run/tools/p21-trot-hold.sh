#!/bin/bash
# Version: 2026.09.06
# Kennel -- issue #21: hold the robot in a commanded trot, so the Meshcat view
# can be photographed mid-stride.
#
# Runs on the GUEST, against an already-running stack -- launched BY ANY MEANS.
# That qualifier is #45: this tool used to say "against an already-running stack"
# and then silently require that the stack had been launched by
# p21-launch-from-commands.sh, because every in-container call sourced
# /tmp/p21-env.sh and only that launcher writes it. Launched any other way --
# launch.md 1.1 by hand, k14-stack-up.sh, a Yuruna step -- every call failed as
#   timeout: failed to run command 'ros2': No such file or directory
# which points at ros2 rather than at the cause. It now uses the launcher's env
# file when it is there and builds the same environment itself when it is not,
# and says which of the two it did.
#
# stack/verify/kennel-verify.sh commands its own trot and always returns the
# gait to STAND on the way out, including on its failure paths -- correctly, but
# it means the trot is gone by the time the recipe's verdict is printed. The
# acceptance evidence for #21 includes a screenshot of the robot WALKING, so the
# trot has to be commanded again, separately, and held while the shot is taken.
#
# Deliberately a second command rather than a change to the recipe: perturbing
# #14's measurement windows to get a photograph would trade evidence for a prop.
#
#   p21-trot-hold.sh start   # command WALKING_TROT and hold the velocity target
#   p21-trot-hold.sh stop    # zero the target and return the gait to STAND
#
# The target must be republished continuously: the controller consumes
# /quad_control_target as a stream, and a single latched message is not enough.
#
# `stop` is deliberately TOLERANT. Three driver paths call it unconditionally --
# `walk stop`, `teleop` in both directions, and `down` -- so on a guest with
# nothing running it must be a quiet no-op, never a red line.
#
# Knobs (environment variables):
#   KENNEL_CONTAINER        dfki_quad
#   KENNEL_CONTROLLER_NODE  /mit_controller_node
#   KENNEL_GAIT             WALKING_TROT
#   KENNEL_TARGET_VX        0.3      commanded body_x_dot, m/s
#   KENNEL_TARGET_Z         0.30     commanded world_z, m (never leave unset --
#                                    a partially filled target commands the body
#                                    into the floor, launch.md 7 trap 2)
#
# Exit codes:
#   0  the trot was commanded (start), or there is nothing left holding one (stop)
#   1  the gait parameter or the velocity publisher would not take
#   2  could not even look: no running container, no ros2 in the container's
#      shell, or no LIVE controller (nothing is launched, or it has just been
#      stopped -- graph presence alone is not liveness, see controller_alive)
#
# `set -uo pipefail` is safe here: this script sources no ROS setup file in its
# own shell -- everything that needs one goes through in_ctr, inside the
# container (stack/launch.md 7 trap 3).

set -uo pipefail

CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
NODE="${KENNEL_CONTROLLER_NODE:-/mit_controller_node}"
GAIT="${KENNEL_GAIT:-WALKING_TROT}"
VX="${KENNEL_TARGET_VX:-0.3}"
Z="${KENNEL_TARGET_Z:-0.30}"
MSG="interfaces/msg/QuadControlTarget"
PIDFILE=/tmp/p21-trot-pub.pid

say()  { echo "[p21-trot] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

# --- REGION: the container source chain (#45)
# The block between the CHAIN markers is IDENTICAL to
# stack/known-good/tools/prelude.sh, which is also what shell 1 of the console's
# commands.txt emits (launch.md 2). The markers are load-bearing: the check in
# stack/composed-run.md 9.2 diffs between them against prelude.sh, so the copies
# are proven identical rather than assumed to be. Sourcing the WRONG workspace
# setup silently partitions the ROS graph (launch.md 2.1), which is why this is a
# copy under test and not a paraphrase.
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

in_ctr() { sudo docker exec "$CONTAINER" bash -c "$ENV_PRELUDE; $1"; }

env_source() {
    if sudo docker exec "$CONTAINER" test -f /tmp/p21-env.sh 2>/dev/null
    then echo "/tmp/p21-env.sh (written by p21-launch-from-commands.sh)"
    else echo "built-in chain (no /tmp/p21-env.sh -- the stack was launched some other way)"
    fi
}

# `ros2 node list` is NOT a liveness signal, and this tool learned it the hard
# way. A killed node's DDS participant lingers 10-20 s in the graph
# (stack/verify.md 4.1, bridge.md 4.1), so a graph entry proves only that a
# controller existed recently. Gating `start` on graph presence meant that
# straight after `kennel-demo.sh down` this tool still found /mit_controller_node,
# went on to `ros2 param set`, and reported "Wait for service timed out" with exit
# 1 -- the same class of unhelpful message #45 is about, one layer further in.
controller_in_graph() {
    [ "$(in_ctr "timeout 15 ros2 node list 2>/dev/null | grep -c '^$NODE\$'" 2>/dev/null)" = 1 ]
}

# The live signal is the heartbeat: 2 Hz for as long as the controller is
# actually running, and what kennel-verify.sh check 4 gates on. One message is
# enough to answer "is there something to command a gait on".
#
# The grep is load-bearing. With no publisher, `ros2 topic echo` does not stay
# silent -- it prints
#     WARNING: topic [/controller_heartbeat] does not appear to be published yet
# ON STDOUT (72 bytes, measured), so a test for "any output" reports a dead
# controller as alive. That is precisely how the first version of this check
# passed straight after a `down`. Strip the warnings, then require something left.
controller_alive() {
    [ -n "$(in_ctr "timeout 8 ros2 topic echo /controller_heartbeat --once 2>/dev/null" 2>/dev/null \
            | grep -v '^WARNING')" ]
}

target() { echo "{body_x_dot: $1, body_y_dot: 0.0, world_z: $Z, hybrid_theta_dot: 0.0, roll: 0.0, pitch: 0.0}"; }

# --type container is not optional: the IMAGE is called dfki_quad too, and
# without it the inspect resolves the image and exits 0 with an empty status
# (vm/provisioning.md 5a).
cstate="$(sudo docker inspect --type container -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"

case "${1:-start}" in
start)
    # --- Preflight, in order of what each can tell you. Each names the cause and
    # the fix, which is the whole of #45's lesson: the old failure named `ros2`.
    [ -n "$cstate" ] || {
        fail "no container named '$CONTAINER' on this guest." \
             "Provision it first, or check the name:  sudo docker ps -a"
        exit 2
    }
    [ "$cstate" = running ] || {
        fail "container '$CONTAINER' is '$cstate', not running." \
             "Start the stack:  demo/tools/kennel-demo.sh launch"
        exit 2
    }
    say "env              $(env_source)"
    in_ctr "command -v ros2 >/dev/null 2>&1" || {
        fail "no ros2 on PATH inside '$CONTAINER' -- the source chain did not resolve." \
             "Neither /tmp/p21-env.sh nor the built-in chain produced a usable ROS." \
             "Is this the dfki_quad image? Both of these should exist:" \
             "  sudo docker exec $CONTAINER ls /opt/ros/humble/setup.bash" \
             "  sudo docker exec $CONTAINER ls /root/ros2_ws/install/setup.bash"
        exit 2
    }
    controller_alive || {
        # Two different situations, two different diagnoses. The graph check is
        # only good for telling them apart -- it is never the liveness test.
        if controller_in_graph; then
            fail "$NODE is in the ROS graph but is not publishing /controller_heartbeat." \
                 "That is what a stack that has just been STOPPED looks like: the node is" \
                 "gone but its DDS participant lingers 10-20 s (stack/verify.md 4.1)." \
                 "Relaunch it:  demo/tools/kennel-demo.sh launch"
        else
            fail "no $NODE in the ROS graph -- the stack is not launched." \
                 "There is nothing to command a gait on yet." \
                 "Launch it:  demo/tools/kennel-demo.sh launch"
        fi
        exit 2
    }

    say "commanding $GAIT at body_x_dot=$VX world_z=$Z"
    in_ctr "timeout 25 ros2 param set $NODE simple_gait_sequencer.gait $GAIT" || exit 1
    # Detached and endless -- `stop` is what ends it. Its PID is kept so the
    # publisher can be killed by identity rather than by a pkill pattern, which
    # is the trap stack/launch.md 7 records (a pattern matches the calling shell).
    sudo docker exec -d "$CONTAINER" bash -c \
        "$ENV_PRELUDE
         ros2 topic pub -r 10 /quad_control_target $MSG '$(target "$VX")' > /tmp/p21-trot-pub.log 2>&1 &
         echo \$! > $PIDFILE"

    # Observe the publisher, never sleep for it (dry-run.md F8). Two signals,
    # both required and either able to be last: OUR process is alive (by pidfile,
    # so a console publishing at the same time cannot be mistaken for it), and
    # the topic actually carries a publisher.
    pub_up=0
    for _ in $(seq 1 30); do
        p="$(sudo docker exec "$CONTAINER" cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$p" ] && sudo docker exec "$CONTAINER" kill -0 "$p" 2>/dev/null; then
            n="$(in_ctr "timeout 10 ros2 topic info /quad_control_target 2>/dev/null" 2>/dev/null \
                 | awk '/Publisher count/{print $3}')"
            case "$n" in ''|*[!0-9]*) n=0 ;; esac
            [ "$n" -ge 1 ] && { pub_up=1; break; }
        fi
        sleep 0.5
    done
    if [ "$pub_up" != 1 ]; then
        fail "the velocity publisher did not come up." \
             "Log: sudo docker exec $CONTAINER cat /tmp/p21-trot-pub.log"
        exit 1
    fi
    say "holding -- the robot is trotting (publisher pid $p). Stop it with: $0 stop"
    ;;
stop)
    # Nothing here is an error: see the header. A guest with no container, or a
    # container with no stack, simply has no held trot to release.
    if [ "$cstate" != running ]; then
        say "container is '${cstate:-absent}' -- nothing to stop"
        exit 0
    fi
    # Our publisher goes first, whatever else is true: it is named by a pidfile,
    # it is ours, and it must not outlive this call.
    in_ctr "[ -f $PIDFILE ] && kill \$(cat $PIDFILE) 2>/dev/null; rm -f $PIDFILE" >/dev/null 2>&1
    if ! controller_alive; then
        say "no live controller ($NODE is not publishing /controller_heartbeat) --"
        say "publisher cleared, nothing else to stop"
        exit 0
    fi
    say "stopping the velocity target"
    # Zero the target before STAND, in the recipe's order: a gait change with a
    # non-zero target still standing in the controller leaves it leaning.
    in_ctr "timeout 20 ros2 topic pub --times 10 -r 10 /quad_control_target $MSG '$(target 0.0)'" >/dev/null 2>&1
    in_ctr "timeout 20 ros2 param set $NODE simple_gait_sequencer.gait STAND" >/dev/null 2>&1
    say "gait returned to STAND, target zeroed"
    ;;
*)
    echo "usage: $0 [start|stop]" >&2; exit 2 ;;
esac
