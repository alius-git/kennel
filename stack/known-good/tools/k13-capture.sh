#!/bin/bash
# Kennel issue #13 -- run the canonical go2 sim stack end to end, headless, and
# capture a known-good log of a healthy session (reference for #14).
#
# Runs INSIDE the dfki_quad container. Each component is launched detached with
# its own log, which is the scripted stand-in for the three separate container
# shells (new_docker_shell.sh) an operator would use.
#
# Usage: k13-capture.sh [outdir]
# NB: deliberately NOT `set -u`. ROS 2 humble's /opt/ros/humble/setup.bash
# dereferences AMENT_TRACE_SETUP_FILES unset, so `set -u` aborts every shell
# that sources the workspace. Found the hard way -- the first capture run
# launched fine and then silently no-op'd every ros2 call after it.
set -o pipefail
OUT="${1:-/tmp/k13-known-good}"
rm -rf "$OUT"; mkdir -p "$OUT"

TROT_SECONDS="${TROT_SECONDS:-60}"
TARGET_VX="${TARGET_VX:-0.3}"
TARGET_Z="${TARGET_Z:-0.30}"   # MUST match initial_height in mit_controller_sim_go2.yaml

say() { echo "[k13] $*"; }

# --- 0. clean slate
/root/k13-stop.sh >/dev/null 2>&1
sleep 3

# --- 1. simulator
say "shell 1: ros2 launch simulator simulator.launch.py sim:=go2"
/root/k13-launch.sh sim ros2 launch simulator simulator.launch.py sim:=go2 &
for i in $(seq 1 60); do
  n=$(source /root/kennel13-prelude.sh >/dev/null 2>&1; timeout 5 ros2 topic list 2>/dev/null | grep -c '^/quad_state$')
  [ "${n:-0}" -ge 1 ] && break
  sleep 2
done
say "  /quad_state present after ${i} polls"
sleep 10   # let the robot settle so mit_controller's safe_start() can pass

# --- 2. leg driver
say "shell 2: ros2 launch drivers leg_driver_launch.py sim:=go2"
/root/k13-launch.sh legdrv ros2 launch drivers leg_driver_launch.py sim:=go2 &
sleep 15

# --- 3. controller (runs safe_start() inline before launching)
say "shell 3: ros2 launch controllers mit_controller.launch.py sim:=go2"
/root/k13-launch.sh ctrl ros2 launch controllers mit_controller.launch.py sim:=go2 &
for i in $(seq 1 60); do
  grep -q "Starting controller" /tmp/k13-ctrl.log 2>/dev/null && break
  sleep 2
done
if ! grep -q "Starting controller" /tmp/k13-ctrl.log 2>/dev/null; then
  say "FAILED: controller never reached 'Starting controller'"
  tail -40 /tmp/k13-ctrl.log
  /root/k13-stop.sh; exit 1
fi
say "  controller started after ${i} polls"
sleep 5

# --- 4. standing baseline
say "baseline: standing (gait=STAND, no target published)"
( source /root/kennel13-prelude.sh; python3 /root/k13-monitor.py 10 standing ) \
  > "$OUT/02-stand-baseline.csv" 2>&1

# --- 5. trot in place
say "gait -> WALKING_TROT"
( source /root/kennel13-prelude.sh; ros2 param set /mit_controller_node simple_gait_sequencer.gait WALKING_TROT ) \
  | tee "$OUT/03-gait-set.txt"
( source /root/kennel13-prelude.sh; python3 /root/k13-monitor.py 15 trot-in-place ) \
  > "$OUT/04-trot-in-place.csv" 2>&1

# --- 6. forward trot
say "target -> body_x_dot=${TARGET_VX} world_z=${TARGET_Z} at 20 Hz"
( echo $BASHPID > /tmp/k13-target.pid   # NB: $$ inside ( ) is the PARENT's pid
  source /root/kennel13-prelude.sh
  exec ros2 topic pub -r 20 /quad_control_target interfaces/msg/QuadControlTarget \
    "{body_x_dot: ${TARGET_VX}, body_y_dot: 0.0, world_z: ${TARGET_Z}, hybrid_theta_dot: 0.0, roll: 0.0, pitch: 0.0}" \
  > /tmp/k13-target.log 2>&1 ) &
sleep 3
( source /root/kennel13-prelude.sh; python3 /root/k13-monitor.py "$TROT_SECONDS" forward-trot ) \
  > "$OUT/05-forward-trot.csv" 2>&1

# --- 7. healthy-session snapshot (the contracts #14 will assert on)
say "capturing graph snapshot"
( source /root/kennel13-prelude.sh
  echo "=== ros2 node list ==="; ros2 node list
  echo; echo "=== ros2 topic list ==="; ros2 topic list
  echo; echo "=== rates ==="
  for t in /quad_state /joint_cmd /gait_state /controller_heartbeat; do
    echo "--- $t"; timeout 6 ros2 topic hz "$t" 2>&1 | grep 'average rate' | tail -1
  done
  echo; echo "=== /controller_heartbeat ==="; timeout 8 ros2 topic echo /controller_heartbeat --once 2>&1
  echo; echo "=== gait params ==="
  ros2 param get /mit_controller_node gait_sequencer
  ros2 param get /mit_controller_node simple_gait_sequencer.gait
) > "$OUT/06-healthy-graph.txt" 2>&1

# --- 8. realtime rate is reported by the monitor itself (sim header stamps vs
# wall clock). Measuring it with `ros2 topic echo --field` proved unusable:
# FastRTPS writes an RTPS_TRANSPORT_SHM warning into the captured stream.

# --- 9. collect the launch logs BEFORE teardown. k13-stop.sh reaps the whole
# process group and takes this script with it, so anything after it never runs.
say "collecting launch logs"
for f in sim legdrv ctrl; do
  cp "/tmp/k13-$f.log" "$OUT/01-launch-$f.log" 2>/dev/null
done
ls -la "$OUT"

# --- 10. teardown
say "teardown"
p=$(cat /tmp/k13-target.pid 2>/dev/null); [ -n "$p" ] && kill -INT "$p" 2>/dev/null
/root/k13-stop.sh >/dev/null 2>&1
say "done -> $OUT"
