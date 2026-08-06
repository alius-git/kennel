#!/bin/bash
# Evidence harness for issue #14 -- NOT part of the verification recipe.
#
# Brings the canonical go2 sim stack up and LEAVES it up, so kennel-verify.sh
# has something to verify. This is the first half of
# stack/known-good/tools/k13-capture.sh with the capture and teardown removed;
# it depends on that directory's k13-launch.sh, k13-stop.sh and
# kennel13-prelude.sh already being in the container's /root (see
# stack/launch.md §8).
#
# Runs INSIDE the dfki_quad container:
#     sudo docker exec dfki_quad /root/k14-stack-up.sh
#     sudo docker exec -e EXTRA_ARGS=mpc_solver:=PARTIAL_CONDENSING_OSQP \
#          dfki_quad /root/k14-stack-up.sh
#
# EXTRA_ARGS is appended to the controller launch, which is how the composed
# config of evidence run 02 was produced.
#
# NB: not `set -u` -- /opt/ros/humble/setup.bash aborts under it
# (stack/launch.md §7 trap 3).
set -o pipefail
say() { echo "[k14-up] $*"; }

/root/k13-stop.sh >/dev/null 2>&1
sleep 3

say "shell 1: simulator"
/root/k13-launch.sh sim ros2 launch simulator simulator.launch.py sim:=go2 &
for i in $(seq 1 60); do
  n=$(source /root/kennel13-prelude.sh >/dev/null 2>&1; timeout 5 ros2 topic list 2>/dev/null | grep -c '^/quad_state$')
  [ "${n:-0}" -ge 1 ] && break
  sleep 2
done
say "  /quad_state present after ${i} polls"
# Let the robot settle from its 0.4 m spawn height before the controller runs
# safe_start() -- launch order matters, stack/launch.md §1.2.
sleep 10

say "shell 2: leg driver"
/root/k13-launch.sh legdrv ros2 launch drivers leg_driver_launch.py sim:=go2 &
sleep 15

say "shell 3: controller ${EXTRA_ARGS}"
/root/k13-launch.sh ctrl ros2 launch controllers mit_controller.launch.py sim:=go2 $EXTRA_ARGS &
for i in $(seq 1 90); do
  grep -q "Starting controller" /tmp/k13-ctrl.log 2>/dev/null && break
  sleep 2
done
if ! grep -q "Starting controller" /tmp/k13-ctrl.log 2>/dev/null; then
  say "FAILED: controller never reached 'Starting controller'"
  tail -30 /tmp/k13-ctrl.log
  exit 1
fi
say "  controller started after ${i} polls"
sleep 5
say "stack is up"
