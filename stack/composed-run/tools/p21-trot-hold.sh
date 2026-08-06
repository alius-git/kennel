#!/bin/bash
# Version: 2026.08.06
# Kennel -- issue #21: hold the robot in a commanded trot, so the Meshcat view
# can be photographed mid-stride.
#
# Runs on the GUEST, against an already-running stack.
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

set -uo pipefail

CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
NODE="${KENNEL_CONTROLLER_NODE:-/mit_controller_node}"
GAIT="${KENNEL_GAIT:-WALKING_TROT}"
VX="${KENNEL_TARGET_VX:-0.3}"
Z="${KENNEL_TARGET_Z:-0.30}"
MSG="interfaces/msg/QuadControlTarget"
PIDFILE=/tmp/p21-trot-pub.pid

say() { echo "[p21-trot] $*"; }
in_ctr() { sudo docker exec "$CONTAINER" bash -c "source /tmp/p21-env.sh >/dev/null 2>&1; $1"; }

target() { echo "{body_x_dot: $1, body_y_dot: 0.0, world_z: $Z, hybrid_theta_dot: 0.0, roll: 0.0, pitch: 0.0}"; }

case "${1:-start}" in
start)
    say "commanding $GAIT at body_x_dot=$VX world_z=$Z"
    in_ctr "timeout 25 ros2 param set $NODE simple_gait_sequencer.gait $GAIT" || exit 1
    # Detached and endless -- `stop` is what ends it. Its PID is kept so the
    # publisher can be killed by identity rather than by a pkill pattern, which
    # is the trap stack/launch.md 7 records (a pattern matches the calling shell).
    sudo docker exec -d "$CONTAINER" bash -c \
        "source /tmp/p21-env.sh >/dev/null 2>&1
         ros2 topic pub -r 10 /quad_control_target $MSG '$(target "$VX")' > /tmp/p21-trot-pub.log 2>&1 &
         echo \$! > $PIDFILE"
    sleep 3
    say "holding -- the robot is trotting. Stop it with: $0 stop"
    ;;
stop)
    say "stopping the velocity target"
    in_ctr "[ -f $PIDFILE ] && kill \$(cat $PIDFILE) 2>/dev/null; rm -f $PIDFILE" >/dev/null 2>&1
    # Zero the target before STAND, in the recipe's order: a gait change with a
    # non-zero target still standing in the controller leaves it leaning.
    in_ctr "timeout 20 ros2 topic pub --times 10 -r 10 /quad_control_target $MSG '$(target 0.0)'" >/dev/null 2>&1
    in_ctr "timeout 20 ros2 param set $NODE simple_gait_sequencer.gait STAND" >/dev/null 2>&1
    say "gait returned to STAND, target zeroed"
    ;;
*)
    echo "usage: $0 [start|stop]" >&2; exit 2 ;;
esac
