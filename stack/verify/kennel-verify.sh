#!/bin/bash
# kennel-verify.sh -- the CLI walking/health verification recipe (issue #14).
#
# Decides "healthy and walking" for the dfki-quad go2 sim stack from a VM shell
# alone: the MVP's substitute for the console/rosbridge dashboard asserts
# (bypass, tracking issue #5), and the exact assert step issue #24's Yuruna
# sequence runs.
#
# Run it on the GUEST (kennel-vm). It copies itself into the dfki_quad
# container, re-executes there, runs ten checks, and exits:
#
#     0  every assert passed
#     1  at least one assert failed  -- the stack is up but not healthy/walking
#     2  infrastructure error        -- could not even look (no container, no
#                                       ROS workspace, unusable arguments)
#
# The recipe COMMANDS the trot itself (gait parameter + velocity target): in
# #24's sequence nothing else does, and "walking" cannot be observed without a
# command. It always returns the gait to STAND and zeroes the target on the way
# out, including on failure.
#
# See stack/verify.md for the observable/threshold/provenance table, and
# stack/launch.md for the launch surface this verifies.
#
# NB: deliberately NOT `set -u`. /opt/ros/humble/setup.bash dereferences
# AMENT_TRACE_SETUP_FILES while unset, so `set -euo pipefail` aborts every shell
# that sources the workspace (stack/launch.md §7 trap 3).
set -o pipefail

# ---------------------------------------------------------------- knobs
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
NODE="${KENNEL_CONTROLLER_NODE:-/mit_controller_node}"
GAIT="${KENNEL_GAIT:-WALKING_TROT}"

# Observation windows are in SIMULATION seconds, never wall seconds: guest wall
# clock is unreliable (vm/provisioning.md §6a) and #21 runs this stack at
# simulator_realtime_rate 0.5, which halves every wall-clock rate. Every rate
# and duration below is per sim-second and therefore realtime-rate invariant.
OBSERVE_SIM_SECONDS="${OBSERVE_SIM_SECONDS:-5}"
TROT_SETTLE_SIM_SECONDS="${TROT_SETTLE_SIM_SECONDS:-5}"
TROT_SIM_SECONDS="${TROT_SIM_SECONDS:-15}"      # issue #14 asks for >= 10 s

TARGET_VX="${TARGET_VX:-0.3}"
TARGET_Z="${TARGET_Z:-0.30}"                    # MUST be filled -- see launch.md §4.2
VX_MIN="${VX_MIN:-0.20}"                        # tuned for TARGET_VX=0.3
VX_MAX="${VX_MAX:-0.35}"
X_ADVANCE_MIN_MPS="${X_ADVANCE_MIN_MPS:-0.15}"
Z_MIN="${Z_MIN:-0.20}"
Z_MAX="${Z_MAX:-0.45}"
TILT_MAX_RAD="${TILT_MAX_RAD:-0.5}"
FALL_TOLERANCE="${FALL_TOLERANCE:-0.02}"   # sustained-violation fraction, check 9
STATE_HZ_MIN="${STATE_HZ_MIN:-900}"
STATE_HZ_MAX="${STATE_HZ_MAX:-1100}"
HB_HZ_MIN="${HB_HZ_MIN:-1.5}"
HB_HZ_MAX="${HB_HZ_MAX:-2.5}"
OVERTIME_BUDGET="${OVERTIME_BUDGET:-20}"
CLOCK_WAIT_WALL_SECONDS="${CLOCK_WAIT_WALL_SECONDS:-20}"

EXPECT_SOLVER="${KENNEL_EXPECT_SOLVER:-}"
CTRL_LOG="${KENNEL_CONTROLLER_LOG:-}"
OUT="${KENNEL_OUT:-/tmp/kennel-verify}"

PASSTHROUGH_ENV="KENNEL_CONTAINER KENNEL_CONTROLLER_NODE KENNEL_GAIT
  OBSERVE_SIM_SECONDS TROT_SETTLE_SIM_SECONDS TROT_SIM_SECONDS TARGET_VX
  TARGET_Z VX_MIN VX_MAX X_ADVANCE_MIN_MPS Z_MIN Z_MAX TILT_MAX_RAD FALL_TOLERANCE
  STATE_HZ_MIN STATE_HZ_MAX HB_HZ_MIN HB_HZ_MAX OVERTIME_BUDGET
  CLOCK_WAIT_WALL_SECONDS KENNEL_EXPECT_SOLVER KENNEL_CONTROLLER_LOG
  KENNEL_EXPECT_BRIDGE"

usage() {
  cat <<'EOF'
Usage: kennel-verify.sh [options]        (run on the guest, kennel-vm)

  --expect-solver NAME   assert the running controller's mpc_solver equals NAME
                         (e.g. PARTIAL_CONDENSING_OSQP). Without it, check 10
                         reports the active solver instead of asserting it.
  --controller-log PATH  path INSIDE the container to the controller launch log,
                         used to corroborate the solver at construction time
                         (default /tmp/k13-ctrl.log if it exists).
  --out DIR              where to leave the report on the guest (default
                         /tmp/kennel-verify).
  -h, --help             this text.

  KENNEL_EXPECT_BRIDGE=1 tolerate the three nodes a running rosbridge adds
                         (/rosapi, /rosapi_params, /rosbridge_websocket) in
                         check 1. Without it a bridge left up reports `extra:`,
                         which is the intended signal. Never REQUIRES them.
                         `kennel-demo.sh verify` sets it when the bridge is up.

Exit codes: 0 all asserts passed, 1 an assert failed, 2 infrastructure error.
Thresholds are environment knobs; see the header of this file.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --expect-solver)  EXPECT_SOLVER="$2"; shift 2 ;;
    --controller-log) CTRL_LOG="$2"; shift 2 ;;
    --out)            OUT="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "kennel-verify: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
export KENNEL_EXPECT_SOLVER="$EXPECT_SOLVER"
export KENNEL_CONTROLLER_LOG="$CTRL_LOG"

# ================================================================= stage 1
# Guest side: relocate into the container and re-execute there.
# ==========================================================================
if [ -z "$KENNEL_IN_CONTAINER" ]; then
  SELF="$(readlink -f "$0")"
  # yuuser24 is not in the docker group (vm/provisioning.md §5), so every
  # docker call from a Yuruna step is sudo docker.
  DOCKER="docker"
  docker ps >/dev/null 2>&1 || DOCKER="sudo docker"
  if ! $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "kennel-verify: container '$CONTAINER' not found on this guest" >&2
    exit 2
  fi
  if [ "$($DOCKER inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    echo "kennel-verify: container '$CONTAINER' is not running" >&2
    exit 2
  fi
  $DOCKER cp "$SELF" "$CONTAINER:/root/kennel-verify.sh" >/dev/null 2>&1 || {
    echo "kennel-verify: could not copy the recipe into '$CONTAINER'" >&2; exit 2; }

  ENVARGS=(-e KENNEL_IN_CONTAINER=1)
  for v in $PASSTHROUGH_ENV; do
    eval "val=\${$v}"
    [ -n "$val" ] && ENVARGS+=(-e "$v=$val")
  done

  $DOCKER exec "${ENVARGS[@]}" "$CONTAINER" bash /root/kennel-verify.sh
  rc=$?

  mkdir -p "$OUT"
  $DOCKER cp "$CONTAINER:/tmp/kennel-verify/." "$OUT/" >/dev/null 2>&1
  # The guest user must be able to read what root wrote inside the container.
  [ "$DOCKER" = "sudo docker" ] && sudo chown -R "$(id -u):$(id -g)" "$OUT" 2>/dev/null
  echo "kennel-verify: report in $OUT (exit $rc)"
  exit $rc
fi

# ================================================================= stage 2
# Container side.
# ==========================================================================
# The source chain. A non-interactive `docker exec ... bash -c` never reads
# /root/.bashrc (it returns early on [ -z "$PS1" ]), so everything .bashrc would
# have set has to be set here. Kept identical to
# stack/known-good/tools/prelude.sh -- change both together.
source /opt/ros/humble/setup.bash
[ -f /root/unitree_ros2/install/setup.bash ] && source /root/unitree_ros2/install/setup.bash
source /root/ros2_ws/install/setup.bash
export PATH="/opt/drake/bin:${PATH}"
export PYTHONPATH="/opt/drake/lib/python3.10/site-packages:${PYTHONPATH}"
export LD_LIBRARY_PATH="/opt/drake/lib:${LD_LIBRARY_PATH}"
export ROS_PACKAGE_PATH="/root/ros2_ws/src"
# DDS + domain. setup_ulab_workspace.bash is the SIM setup despite its name
# (fastrtps, ROS_DOMAIN_ID=100); setup_go2_workspace.bash is the real-hardware
# path and pins CycloneDDS to a NIC that does not exist here (launch.md §2.1).
source /root/setup_ulab_workspace.bash
cd /root/ros2_ws || exit 2

if ! command -v ros2 >/dev/null 2>&1; then
  echo "kennel-verify: no ros2 on PATH inside the container -- source chain failed" >&2
  exit 2
fi

# The checker is a separate process, so every knob it reads has to be in the
# environment, not just in this shell.
export KENNEL_GAIT="$GAIT"
export OBSERVE_SIM_SECONDS TROT_SETTLE_SIM_SECONDS TROT_SIM_SECONDS TARGET_VX \
  TARGET_Z VX_MIN VX_MAX X_ADVANCE_MIN_MPS Z_MIN Z_MAX TILT_MAX_RAD FALL_TOLERANCE \
  STATE_HZ_MIN STATE_HZ_MAX HB_HZ_MIN HB_HZ_MAX OVERTIME_BUDGET \
  CLOCK_WAIT_WALL_SECONDS

WORK=/tmp/kennel-verify
rm -rf "$WORK"; mkdir -p "$WORK" || exit 2
RESULTS="$WORK/results.psv"
: > "$RESULTS"
export KENNEL_RESULTS="$RESULTS"

[ -z "$CTRL_LOG" ] && [ -f /tmp/k13-ctrl.log ] && CTRL_LOG=/tmp/k13-ctrl.log

GAIT_COMMANDED=0
cleanup() {
  # Never leave the robot trotting -- this runs on the failure paths too.
  if [ "$GAIT_COMMANDED" = 1 ]; then
    timeout 20 ros2 topic pub --times 10 -r 10 /quad_control_target \
      interfaces/msg/QuadControlTarget \
      "{body_x_dot: 0.0, body_y_dot: 0.0, world_z: ${TARGET_Z}, hybrid_theta_dot: 0.0, roll: 0.0, pitch: 0.0}" \
      >/dev/null 2>&1
    timeout 20 ros2 param set "$NODE" simple_gait_sequencer.gait STAND >/dev/null 2>&1
  fi
}
trap cleanup EXIT INT TERM

# record <status> <name> <observable> <measured> <required>
record() {
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RESULTS"
  printf '[%-4s] %-22s -- %s: measured %s, required %s\n' "$1" "$2" "$3" "$4" "$5"
}

echo "=== kennel-verify -- CLI walking/health recipe (issue #14) ==="
echo "container=$CONTAINER node=$NODE gait=$GAIT"
echo "windows(sim s): observe=$OBSERVE_SIM_SECONDS settle=$TROT_SETTLE_SIM_SECONDS trot=$TROT_SIM_SECONDS"
echo "target: body_x_dot=$TARGET_VX world_z=$TARGET_Z"
echo

# --------------------------------------------------------------- check 1
# Node graph. Exactly the six nodes of a healthy sim session, no duplicates.
# launch.md §6 / known-good/06-healthy-graph.txt.
#
# This is a completeness check, NOT the liveness gate: `ros2 node list` reports
# a killed node for as long as its DDS participant takes to time out, so a
# controller that died seconds ago still appears here. Checks 2-4 measure
# message rates, which go to zero immediately, and those are what gate the rest.
EXPECTED_NODES="/drake_simulator
/joy_linux_node
/joy_to_target
/leg_driver
/mit_controller_node
/safe_start_launcher"

# KENNEL_EXPECT_BRIDGE=1 makes the three nodes `kennel-demo.sh teleop` adds
# TOLERATED, never required: the bridge is optional beside the stack, and a run
# with one up is still a healthy six-node session plus a bridge. Tolerated
# rather than expected on purpose -- the entries also linger 10-20 s after the
# bridge is stopped (a dead DDS participant times out, the same effect this
# check's own comment describes), so requiring them would turn a correct
# teardown into a red run. See stack/bridge.md §4.
BRIDGE_NODES="/rosapi
/rosapi_params
/rosbridge_websocket"
TOLERATED_NODES=""
[ "${KENNEL_EXPECT_BRIDGE:-0}" = 1 ] && TOLERATED_NODES="$BRIDGE_NODES"

timeout 25 ros2 node list 2>/dev/null | grep '^/' | sort > "$WORK/nodes.txt"
printf '%s\n' "$EXPECTED_NODES" | sort > "$WORK/nodes.expected"
{ printf '%s\n' "$EXPECTED_NODES"
  [ -n "$TOLERATED_NODES" ] && printf '%s\n' "$TOLERATED_NODES"
} | grep '^/' | sort > "$WORK/nodes.allowed"
sort -u "$WORK/nodes.txt" > "$WORK/nodes.uniq"
missing="$(comm -23 "$WORK/nodes.expected" "$WORK/nodes.uniq" | tr '\n' ' ')"
extra="$(comm -13 "$WORK/nodes.allowed" "$WORK/nodes.uniq" | tr '\n' ' ')"
# Stale joy_to_target copies survive a bad teardown and show up as duplicates
# (launch.md §7 trap 6); two nodes of the same name is not a healthy graph.
dups="$(uniq -d "$WORK/nodes.txt" | tr '\n' ' ')"
node_detail="$(tr '\n' ' ' < "$WORK/nodes.txt")"
NODE_CRITERION="exactly the six healthy-session nodes, no duplicates"
[ -n "$TOLERATED_NODES" ] && NODE_CRITERION="the six healthy-session nodes plus the three rosbridge nodes (KENNEL_EXPECT_BRIDGE=1), no duplicates"
if [ -n "$missing" ] || [ -n "$extra" ] || [ -n "$dups" ]; then
  record FAIL "1 node-graph" "ros2 node list" \
    "${node_detail:-<empty>}[missing: ${missing:-none}][extra: ${extra:-none}][duplicate: ${dups:-none}]" \
    "$NODE_CRITERION"
else
  record PASS "1 node-graph" "ros2 node list" "the six expected nodes, no duplicates" \
    "$NODE_CRITERION"
fi

# ------------------------------------------------------------- checks 2-4
# Liveness, read from an rclpy subscriber. CLI text is NOT parsed for message
# fields: FastRTPS writes RTPS_TRANSPORT_SHM warnings into captured output and
# corrupts `ros2 topic echo --field` (launch.md §7 trap 7).
cat > "$WORK/check.py" <<'KENNEL_PY'
#!/usr/bin/env python3
"""kennel-verify checker -- the rclpy half of the #14 recipe.

Two phases, both driven off SIMULATION time taken from /clock, so every rate and
duration is invariant to simulator_realtime_rate (#21 runs this at 0.5).

    check.py observe   -> checks 2 (sim-clock) 3 (state-stream) 4 (controller-alive)
    check.py walk      -> checks 6 (gait-active) 7 (solver-health) 8 (walking) 9 (no-fall)

Exit 0 if every check it owns passed, 1 otherwise, 2 if it could not look.
"""
import math
import os
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from rosgraph_msgs.msg import Clock
from interfaces.msg import QuadState, GaitState, ControllerInfo, QuadControlTarget

RESULTS = os.environ.get("KENNEL_RESULTS", "/tmp/kennel-verify/results.psv")


def envf(key, default):
    v = os.environ.get(key)
    return float(v) if v not in (None, "") else float(default)


OBSERVE_SIM = envf("OBSERVE_SIM_SECONDS", 5)
SETTLE_SIM = envf("TROT_SETTLE_SIM_SECONDS", 5)
TROT_SIM = envf("TROT_SIM_SECONDS", 15)
TARGET_VX = envf("TARGET_VX", 0.3)
TARGET_Z = envf("TARGET_Z", 0.30)
VX_MIN = envf("VX_MIN", 0.20)
VX_MAX = envf("VX_MAX", 0.35)
X_ADV = envf("X_ADVANCE_MIN_MPS", 0.15)
Z_MIN = envf("Z_MIN", 0.20)
Z_MAX = envf("Z_MAX", 0.45)
TILT_MAX = envf("TILT_MAX_RAD", 0.5)
FALL_TOL = envf("FALL_TOLERANCE", 0.02)
STATE_HZ_MIN = envf("STATE_HZ_MIN", 900)
STATE_HZ_MAX = envf("STATE_HZ_MAX", 1100)
HB_HZ_MIN = envf("HB_HZ_MIN", 1.5)
HB_HZ_MAX = envf("HB_HZ_MAX", 2.5)
OVERTIME_BUDGET = envf("OVERTIME_BUDGET", 20)
CLOCK_WAIT = envf("CLOCK_WAIT_WALL_SECONDS", 20)
GAIT = os.environ.get("KENNEL_GAIT") or "WALKING_TROT"

PUB_HZ = 20.0  # matches joy_to_target's update_freq (launch.md §4.2)

RELIABLE = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                      history=HistoryPolicy.KEEP_LAST)
BEST = QoSProfile(depth=10, reliability=ReliabilityPolicy.BEST_EFFORT,
                  history=HistoryPolicy.KEEP_LAST)

# GaitDatabase::getGait at the pin (controllers/src/mit_controller/gait.cpp):
# name -> (period T, duty factor, phase offsets FL/FR/BL/BR). This is what a
# gait IS on the wire -- /gait_state carries no gait name.
GAIT_TABLE = {
    "STAND":           (0.5,  1.0, (0.0, 0.0,    0.0,    0.0)),
    "STATIC_WALK":     (1.25, 0.8, (0.0, 0.5,    0.75,   0.25)),
    "WALKING_TROT":    (0.5,  0.6, (0.0, 0.5,    0.5,    0.0)),
    "TROT":            (0.5,  0.5, (0.0, 0.5,    0.5,    0.0)),
    "FLYING_TROT":     (0.4,  0.4, (0.0, 0.5,    0.5,    0.0)),
    "PACE":            (0.35, 0.5, (0.0, 0.5,    0.0,    0.5)),
    "BOUND":           (0.4,  0.4, (0.0, 0.0,    0.5,    0.5)),
    "ROTARY_GALLOP":   (0.4,  0.2, (0.0, 0.8571, 0.3571, 0.5)),
    "TRAVERSE_GALLOP": (0.5,  0.2, (0.0, 0.8571, 0.3571, 0.5)),
    "PRONK":           (0.5,  0.5, (0.0, 0.0,    0.0,    0.0)),
}


def record(status, name, observable, measured, required):
    with open(RESULTS, "a") as fh:
        fh.write("%s|%s|%s|%s|%s\n" % (status, name, observable, measured, required))
    print("[%-4s] %-22s -- %s: measured %s, required %s"
          % (status, name, observable, measured, required), flush=True)


def say(msg):
    print("       %s" % msg, flush=True)


def roll_pitch(q):
    """Body roll and pitch in radians from the quaternion."""
    roll = math.atan2(2.0 * (q.w * q.x + q.y * q.z),
                      1.0 - 2.0 * (q.x * q.x + q.y * q.y))
    sinp = max(-1.0, min(1.0, 2.0 * (q.w * q.y - q.z * q.x)))
    return roll, math.asin(sinp)


class Base(Node):
    """Common plumbing: /clock is the one sim-time source."""

    def __init__(self, name):
        super().__init__(name)
        self.sim = None
        self.create_subscription(Clock, "/clock", self._cb_clock, BEST)

    def _cb_clock(self, msg):
        self.sim = msg.clock.sec + msg.clock.nanosec / 1e9


class Observe(Base):
    def __init__(self):
        super().__init__("kennel_verify_observe")
        self.n_state = 0
        self.n_hb = 0
        self.hb = None
        self.counting = False
        self.create_subscription(QuadState, "/quad_state", self._cb_state, RELIABLE)
        self.create_subscription(ControllerInfo, "/controller_heartbeat", self._cb_hb, BEST)

    def _cb_state(self, msg):
        if self.counting:
            self.n_state += 1

    def _cb_hb(self, msg):
        self.hb = msg
        if self.counting:
            self.n_hb += 1


def spin_until(node, done, wall_budget):
    """Spin until done() or the wall budget runs out. Returns True if done()."""
    deadline = time.monotonic() + wall_budget
    while time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.02)
        if done():
            return True
    return done()


def phase_observe():
    node = Observe()
    say("waiting for /clock ...")
    if not spin_until(node, lambda: node.sim is not None, CLOCK_WAIT):
        record("FAIL", "2 sim-clock", "/clock",
               "no message in %.0f s wall" % CLOCK_WAIT, "sim clock advancing")
        record("FAIL", "3 state-stream", "/quad_state rate",
               "not measurable, no sim clock", "%.0f-%.0f Hz per sim-second" % (STATE_HZ_MIN, STATE_HZ_MAX))
        record("FAIL", "4 controller-alive", "/controller_heartbeat rate",
               "not measurable, no sim clock", "%.2f-%.2f Hz per sim-second" % (HB_HZ_MIN, HB_HZ_MAX))
        return 1

    sim0, wall0 = node.sim, time.monotonic()
    node.n_state = node.n_hb = 0
    node.counting = True
    budget = OBSERVE_SIM * 4 + 20
    say("observing %.0f sim-s (wall budget %.0f s) ..." % (OBSERVE_SIM, budget))
    spin_until(node, lambda: (node.sim - sim0) >= OBSERVE_SIM, budget)
    node.counting = False
    sim_el = node.sim - sim0
    wall_el = time.monotonic() - wall0
    rate = sim_el / wall_el if wall_el > 0 else 0.0

    ok = 0
    if sim_el >= 0.9 * OBSERVE_SIM:
        record("PASS", "2 sim-clock", "/clock",
               "advanced %.2f sim-s in %.1f s wall" % (sim_el, wall_el),
               ">= %.2f sim-s within %.0f s wall" % (0.9 * OBSERVE_SIM, budget))
    else:
        ok = 1
        record("FAIL", "2 sim-clock", "/clock",
               "advanced only %.2f sim-s in %.1f s wall" % (sim_el, wall_el),
               ">= %.2f sim-s within %.0f s wall" % (0.9 * OBSERVE_SIM, budget))
    record("INFO", "  realtime-rate", "/clock vs monotonic wall clock",
           "%.3f" % rate, "informative, #21 runs this at 0.5")

    if sim_el <= 0:
        record("FAIL", "3 state-stream", "/quad_state rate", "sim clock frozen",
               "%.0f-%.0f Hz per sim-second" % (STATE_HZ_MIN, STATE_HZ_MAX))
        record("FAIL", "4 controller-alive", "/controller_heartbeat rate", "sim clock frozen",
               "%.2f-%.2f Hz per sim-second" % (HB_HZ_MIN, HB_HZ_MAX))
        return 1

    shz = node.n_state / sim_el
    if STATE_HZ_MIN <= shz <= STATE_HZ_MAX:
        record("PASS", "3 state-stream", "/quad_state rate", "%.1f Hz per sim-second" % shz,
               "%.0f-%.0f Hz per sim-second" % (STATE_HZ_MIN, STATE_HZ_MAX))
    else:
        ok = 1
        record("FAIL", "3 state-stream", "/quad_state rate",
               "%.1f Hz per sim-second (%d msgs / %.2f sim-s)" % (shz, node.n_state, sim_el),
               "%.0f-%.0f Hz per sim-second" % (STATE_HZ_MIN, STATE_HZ_MAX))

    hhz = node.n_hb / sim_el
    if HB_HZ_MIN <= hhz <= HB_HZ_MAX:
        record("PASS", "4 controller-alive", "/controller_heartbeat rate",
               "%.2f Hz per sim-second" % hhz,
               "%.2f-%.2f Hz per sim-second" % (HB_HZ_MIN, HB_HZ_MAX))
    else:
        ok = 1
        record("FAIL", "4 controller-alive", "/controller_heartbeat rate",
               "%.2f Hz per sim-second (%d msgs / %.2f sim-s)" % (hhz, node.n_hb, sim_el),
               "%.2f-%.2f Hz per sim-second" % (HB_HZ_MIN, HB_HZ_MAX))
    if node.hb is not None:
        record("INFO", "  heartbeat-counters", "/controller_heartbeat cumulative",
               "early_contacts=%d mpc_overtime=%d wbc_overtime=%d mpc_fail=%d wbc_fail=%d model_updates=%d"
               % (node.hb.num_early_contacts, node.hb.num_mpc_solver_overtime,
                  node.hb.num_wbc_overtime, node.hb.num_mpc_solver_fail,
                  node.hb.num_wbc_solver_fail, node.hb.num_model_updates),
               "informative, deltas are asserted by check 7")
    return ok


class Walk(Base):
    def __init__(self):
        super().__init__("kennel_verify_walk")
        self.target = QuadControlTarget()
        self.target.body_x_dot = TARGET_VX
        self.target.body_y_dot = 0.0
        # world_z is MANDATORY: the first target that arrives overwrites the
        # controller's internal target wholesale, so an omitted world_z (0.0)
        # commands the body into the floor (launch.md §7 trap 2).
        self.target.world_z = TARGET_Z
        self.target.hybrid_theta_dot = 0.0
        self.target.roll = 0.0
        self.target.pitch = 0.0
        self.pub = self.create_publisher(QuadControlTarget, "/quad_control_target", RELIABLE)
        self.create_timer(1.0 / PUB_HZ, self._cb_pub)
        self.publishing = False
        self.n_published = 0

        self.gait = None
        self.hb = None
        self.hb_first = None
        self.hb_last = None
        self.n_hb = 0

        self.measuring = False
        self.n_meas = 0
        self.sum_vx = 0.0
        self.z_all = []
        self.tilt_max = 0.0
        self.n_tilt_over = 0
        self.belly_hits = 0
        self.x_first = None
        self.x_last = None
        self.trace = []          # (sim_t, x), subsampled
        self._sub = 0

        self.create_subscription(QuadState, "/quad_state", self._cb_state, RELIABLE)
        self.create_subscription(GaitState, "/gait_state", self._cb_gait, BEST)
        self.create_subscription(ControllerInfo, "/controller_heartbeat", self._cb_hb, BEST)

    def _cb_pub(self):
        if self.publishing:
            self.pub.publish(self.target)
            self.n_published += 1

    def _cb_gait(self, msg):
        self.gait = msg

    def _cb_hb(self, msg):
        self.hb = msg
        if self.measuring:
            self.n_hb += 1
            if self.hb_first is None:
                self.hb_first = msg
            self.hb_last = msg

    def _cb_state(self, msg):
        if not self.measuring:
            return
        p = msg.pose.pose.position
        v = msg.twist.twist.linear
        self.n_meas += 1
        self.sum_vx += v.x
        self.z_all.append(p.z)
        r, pi = roll_pitch(msg.pose.pose.orientation)
        tilt = max(abs(r), abs(pi))
        self.tilt_max = max(self.tilt_max, tilt)
        if tilt > TILT_MAX:
            self.n_tilt_over += 1
        if msg.belly_contact:
            self.belly_hits += 1
        if self.x_first is None:
            self.x_first = p.x
        self.x_last = p.x
        self._sub += 1
        if self._sub % 20 == 0 and self.sim is not None:
            self.trace.append((self.sim, p.x))

    def stop(self):
        """Command a standstill before letting go -- the controller keeps the
        last target forever, so simply ceasing to publish leaves it walking."""
        self.target.body_x_dot = 0.0
        self.target.body_y_dot = 0.0
        self.target.hybrid_theta_dot = 0.0
        self.target.world_z = TARGET_Z
        for _ in range(10):
            self.pub.publish(self.target)
            rclpy.spin_once(self, timeout_sec=0.05)


def phase_walk():
    node = Walk()
    if not spin_until(node, lambda: node.sim is not None, CLOCK_WAIT):
        for n, o in (("6 gait-active", "/gait_state"), ("7 solver-health", "/controller_heartbeat counters"),
                     ("8 walking", "/quad_state pose and twist"), ("9 no-fall", "/quad_state")):
            record("FAIL", n, o, "no sim clock, phase abandoned", "a live sim clock")
        return 1

    node.publishing = True
    sim0 = node.sim
    budget = (SETTLE_SIM + TROT_SIM) * 4 + 40
    say("commanding %s at body_x_dot=%.2f world_z=%.2f, %.0f sim-s settle ..."
        % (GAIT, TARGET_VX, TARGET_Z, SETTLE_SIM))
    spin_until(node, lambda: (node.sim - sim0) >= SETTLE_SIM, budget)

    node.measuring = True
    sim_m0 = node.sim
    say("measuring %.0f sim-s of commanded trot ..." % TROT_SIM)
    spin_until(node, lambda: (node.sim - sim_m0) >= TROT_SIM, budget)
    node.measuring = False
    node.publishing = False
    sim_win = node.sim - sim_m0
    say("done: %.2f sim-s, %d /quad_state samples, %d targets published"
        % (sim_win, node.n_meas, node.n_published))

    ok = 0

    # ---- check 6: the gait sequencer actually rebuilt into the asked-for gait.
    # The parameter read-back in check 5 does NOT prove this: an unknown gait
    # name still sets the parameter, and the node then logs "Unknown gait type"
    # and keeps the sequencer it had. /gait_state carries the gait's period,
    # duty factor and phase offsets, which is what a gait is.
    want = GAIT_TABLE.get(GAIT)
    g = node.gait
    if g is None:
        ok = 1
        record("FAIL", "6 gait-active", "/gait_state", "no message received",
               "the %s period/duty/offset signature" % GAIT)
    else:
        got = (g.period, list(g.duty_factor), list(g.phase_offset))
        detail = ("period=%.3f duty_factor=%s phase_offset=%s sequencer=%d"
                  % (g.period, ["%.3f" % d for d in g.duty_factor],
                     ["%.3f" % o for o in g.phase_offset], g.gait_sequencer))
        if want is None:
            record("INFO", "6 gait-active", "/gait_state", detail,
                   "gait '%s' not in the checker's table, reported only" % GAIT)
        else:
            wp, wd, wo = want
            good = (abs(g.period - wp) < 1e-3
                    and all(abs(d - wd) < 1e-3 for d in g.duty_factor)
                    and all(abs(o - t) < 1e-3 for o, t in zip(g.phase_offset, wo)))
            if good:
                record("PASS", "6 gait-active", "/gait_state", detail,
                       "%s signature period=%.3f duty=%.3f offsets=%s" % (GAIT, wp, wd, list(wo)))
            else:
                ok = 1
                record("FAIL", "6 gait-active", "/gait_state", detail,
                       "%s signature period=%.3f duty=%.3f offsets=%s" % (GAIT, wp, wd, list(wo)))

    # ---- check 7: solver health, as DELTAS over the measured window. The
    # ControllerInfo counters are cumulative since controller start, so absolute
    # values only say how old the session is.
    if node.hb_first is None or node.hb_last is None or node.n_hb < 2:
        ok = 1
        record("FAIL", "7 solver-health", "/controller_heartbeat counters",
               "%d heartbeats during the window" % node.n_hb,
               "at least 2 heartbeats, and zero solver failures")
    else:
        a, b = node.hb_first, node.hb_last
        d_mpc_fail = b.num_mpc_solver_fail - a.num_mpc_solver_fail
        d_wbc_fail = b.num_wbc_solver_fail - a.num_wbc_solver_fail
        d_over = ((b.num_mpc_solver_overtime - a.num_mpc_solver_overtime)
                  + (b.num_wbc_overtime - a.num_wbc_overtime))
        d_early = b.num_early_contacts - a.num_early_contacts
        detail = ("d_mpc_fail=%d d_wbc_fail=%d d_overtime=%d (d_early_contacts=%d, %d heartbeats)"
                  % (d_mpc_fail, d_wbc_fail, d_over, d_early, node.n_hb))
        if d_mpc_fail == 0 and d_wbc_fail == 0 and d_over <= OVERTIME_BUDGET:
            record("PASS", "7 solver-health", "/controller_heartbeat counters", detail,
                   "d_mpc_fail=0, d_wbc_fail=0, d_overtime <= %d" % OVERTIME_BUDGET)
        else:
            ok = 1
            record("FAIL", "7 solver-health", "/controller_heartbeat counters", detail,
                   "d_mpc_fail=0, d_wbc_fail=0, d_overtime <= %d" % OVERTIME_BUDGET)

    # ---- check 8: walking. Commanded velocity is tracked, and the body
    # advances through every fifth of the window -- feet cycling in place, or a
    # single lurch, are not walking.
    if node.n_meas == 0 or sim_win <= 0:
        ok = 1
        record("FAIL", "8 walking", "/quad_state pose and twist",
               "%d samples over %.2f sim-s" % (node.n_meas, sim_win),
               "sustained commanded trot for %.0f sim-s" % TROT_SIM)
        record("FAIL", "9 no-fall", "/quad_state belly_contact, z, attitude",
               "no samples", "belly_contact false, z in [%.2f, %.2f] m, tilt <= %.2f rad"
               % (Z_MIN, Z_MAX, TILT_MAX))
        return 1

    vx_mean = node.sum_vx / node.n_meas
    dx = node.x_last - node.x_first
    dx_min = X_ADV * sim_win
    buckets_ok, nbucket = True, 5
    if len(node.trace) >= nbucket * 2:
        t0 = node.trace[0][0]
        span = node.trace[-1][0] - t0
        if span > 0:
            edges = [t0 + span * i / nbucket for i in range(nbucket + 1)]
            for i in range(nbucket):
                seg = [x for (t, x) in node.trace if edges[i] <= t <= edges[i + 1]]
                if len(seg) < 2 or seg[-1] - seg[0] <= 0:
                    buckets_ok = False
    detail = ("vx_mean=%.3f m/s, dx=%.3f m over %.2f sim-s, advanced in all %d sub-windows: %s"
              % (vx_mean, dx, sim_win, nbucket, "yes" if buckets_ok else "no"))
    req = ("vx_mean in [%.2f, %.2f] m/s for a %.2f m/s command, dx >= %.2f m, "
           "advance in every sub-window" % (VX_MIN, VX_MAX, TARGET_VX, dx_min))
    if VX_MIN <= vx_mean <= VX_MAX and dx >= dx_min and buckets_ok:
        record("PASS", "8 walking", "/quad_control_target vs /quad_state twist", detail, req)
    else:
        ok = 1
        record("FAIL", "8 walking", "/quad_control_target vs /quad_state twist", detail, req)

    # ---- check 9: the fall condition, from three signals with three different
    # statistics. Each choice was forced by an observed failure (verify.md §4):
    #
    #   belly_contact -- instantaneous, but NOT sufficient on its own. It stayed
    #     false through a damping collapse (body on the floor at z = 0.075 m) and
    #     through a full tip-over (roll = 166 deg). It never false-positives, so
    #     any hit is a fall; its absence proves nothing.
    #   z -- as the MEDIAN, not per-sample bounds. Body height oscillates with
    #     the gait, and how much depends on the config: stock HPIPM holds
    #     0.310-0.317 m (7 mm peak-to-peak), the composed OSQP config bobs
    #     0.232-0.329 m (97 mm) around a 0.287 m median while walking perfectly
    #     well, and dips below 0.16 m once the session has been running a while.
    #     A per-sample floor tuned to one solver rejects the other. The median
    #     separates the cases by 4x: 0.075 / 0.13 m fallen against
    #     0.287-0.314 m walking.
    #   tilt -- as a sustained fraction. A tipped robot holds its attitude; a
    #     walking one never exceeded 0.13 rad in any capture.
    zs = sorted(node.z_all)
    z_p01 = zs[max(0, int(0.01 * len(zs)) - 1)]
    z_med = zs[len(zs) // 2]
    f_tilt = node.n_tilt_over / node.n_meas
    detail = ("belly_contact=%d/%d samples, z median=%.4f m (p01=%.4f min=%.4f max=%.4f), "
              "max tilt=%.3f rad, tilt over %.2f in %.2f%% of samples"
              % (node.belly_hits, node.n_meas, z_med, z_p01, zs[0], zs[-1],
                 node.tilt_max, TILT_MAX, 100 * f_tilt))
    req = ("belly_contact false in every sample, median z in [%.2f, %.2f] m, tilt over "
           "%.2f rad in <= %.1f%% of samples" % (Z_MIN, Z_MAX, TILT_MAX, 100 * FALL_TOL))
    if (node.belly_hits == 0 and Z_MIN <= z_med <= Z_MAX and f_tilt <= FALL_TOL):
        record("PASS", "9 no-fall", "/quad_state belly_contact, z, attitude", detail, req)
    else:
        ok = 1
        record("FAIL", "9 no-fall", "/quad_state belly_contact, z, attitude", detail, req)
    record("INFO", "  height-tracking", "/quad_state z against commanded world_z",
           "median %.4f m, peak-to-peak %.4f m, commanded %.2f m" % (z_med, zs[-1] - zs[0], TARGET_Z),
           "informative, gait bob is config-dependent")

    node.stop()
    return ok


def main():
    phase = sys.argv[1] if len(sys.argv) > 1 else "observe"
    rclpy.init()
    try:
        rc = phase_observe() if phase == "observe" else phase_walk()
    finally:
        rclpy.try_shutdown()
    return rc


if __name__ == "__main__":
    sys.exit(main())
KENNEL_PY

python3 "$WORK/check.py" observe
GATE=$?
if [ "$GATE" = 2 ]; then
  echo "kennel-verify: checker could not run" >&2
  exit 2
fi

# --------------------------------------------------------------- check 5
# Gait command. `ros2 param set` reports success even for a gait name the node
# rejects -- the parameter is set, the sequencer is not rebuilt -- so this check
# only claims the parameter took. Check 6 is the one that proves the sequencer
# followed, from /gait_state.
if [ "$GATE" != 0 ]; then
  echo
  echo "       liveness gate failed -- not commanding a gait at a stack that is not answering"
  for spec in "5 gait-command|ros2 param set ${NODE} simple_gait_sequencer.gait" \
              "6 gait-active|/gait_state" \
              "7 solver-health|/controller_heartbeat counters" \
              "8 walking|/quad_control_target vs /quad_state twist" \
              "9 no-fall|/quad_state belly_contact, z, attitude"; do
    record FAIL "${spec%%|*}" "${spec##*|}" "skipped, liveness gate (checks 2-4) failed" \
      "a live stack to observe"
  done
else
  GAIT_COMMANDED=1
  set_out="$(timeout 25 ros2 param set "$NODE" simple_gait_sequencer.gait "$GAIT" 2>&1 | tr '\n' ' ')"
  got_gait="$(timeout 25 ros2 param get "$NODE" simple_gait_sequencer.gait 2>/dev/null \
              | sed -n 's/^String value is: //p')"
  if printf '%s' "$set_out" | grep -q 'Set parameter successful' && [ "$got_gait" = "$GAIT" ]; then
    record PASS "5 gait-command" "ros2 param set/get ${NODE} simple_gait_sequencer.gait" \
      "set said '$(printf '%s' "$set_out" | sed 's/[[:space:]]*$//')', read back '$got_gait'" \
      "'Set parameter successful' and read-back '$GAIT'"
  else
    record FAIL "5 gait-command" "ros2 param set/get ${NODE} simple_gait_sequencer.gait" \
      "set said '$(printf '%s' "$set_out" | sed 's/[[:space:]]*$//')', read back '${got_gait:-<nothing>}'" \
      "'Set parameter successful' and read-back '$GAIT'"
  fi

  # ----------------------------------------------------------- checks 6-9
  python3 "$WORK/check.py" walk
fi

# -------------------------------------------------------------- check 10
# Composed-config read-back -- the mechanism #21 needs to prove a non-stock
# solver took effect.
#
# Live: mpc_solver is a declared parameter (default PARTIAL_CONDENSING_HPIPM)
# read ONCE at construction to build the MPC. It is not in the dynamic-parameter
# handler, so the reported value is the constructed value.
# Construction-time corroboration: the controller prints exactly one
# solver-family line on stdout -- "Set hpipm mode to <MODE>" for the two HPIPM
# solvers, "Set osqp linear system solver to <X>" for OSQP. An unknown name is
# fatal: "Unknown mpc solver: <name>" and the node exits.
# /solve_time (MPCDiagnostics) does NOT carry solver identity -- do not look
# there.
active_solver="$(timeout 25 ros2 param get "$NODE" mpc_solver 2>/dev/null \
                 | sed -n 's/^String value is: //p')"
log_line=""
if [ -n "$CTRL_LOG" ] && [ -f "$CTRL_LOG" ]; then
  log_line="$(grep -m1 -E 'Set hpipm mode to|Set osqp linear system solver to' "$CTRL_LOG" \
              | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
fi
corroboration="no controller log supplied"
if [ -n "$CTRL_LOG" ] && [ -z "$log_line" ]; then
  corroboration="no solver line in $CTRL_LOG (DAQP/QPOASES/QPDUNES print none)"
elif [ -n "$log_line" ] && [ -z "$active_solver" ]; then
  # Nothing to corroborate against -- the node is not answering.
  corroboration="launch log said '$log_line'"
elif [ -n "$log_line" ]; then
  case "$log_line" in
    *"hpipm mode"*) fam=HPIPM ;;
    *"osqp linear"*) fam=OSQP ;;
    *) fam="" ;;
  esac
  case "$active_solver" in
    *"$fam"*) corroboration="launch log agrees with the running value ($log_line)" ;;
    *) corroboration="launch log DISAGREES with the running value ($log_line)" ;;
  esac
fi

if [ -z "$active_solver" ]; then
  record FAIL "10 composed-config" "ros2 param get ${NODE} mpc_solver" \
    "no value, ${corroboration}" "${EXPECT_SOLVER:-a readable mpc_solver}"
elif [ -n "$EXPECT_SOLVER" ]; then
  if [ "$active_solver" = "$EXPECT_SOLVER" ] && [ "${corroboration#launch log DISAGREES}" = "$corroboration" ]; then
    record PASS "10 composed-config" "ros2 param get ${NODE} mpc_solver" \
      "$active_solver, ${corroboration}" "$EXPECT_SOLVER"
  else
    record FAIL "10 composed-config" "ros2 param get ${NODE} mpc_solver" \
      "$active_solver, ${corroboration}" "$EXPECT_SOLVER"
  fi
else
  record INFO "10 composed-config" "ros2 param get ${NODE} mpc_solver" \
    "$active_solver, ${corroboration}" "informative, pass --expect-solver to assert"
fi

# ---------------------------------------------------------------- verdict
npass=$(grep -c '^PASS|' "$RESULTS")
nfail=$(grep -c '^FAIL|' "$RESULTS")
{
  echo
  echo "=== verdict ==="
  awk -F'|' '{printf "[%-4s] %-22s -- %s: measured %s, required %s\n", $1, $2, $3, $4, $5}' "$RESULTS"
  echo
  echo "pass=$npass fail=$nfail"
} | tee "$WORK/report.txt"

if [ "$nfail" -gt 0 ]; then
  echo "VERDICT: FAIL" | tee -a "$WORK/report.txt"
  exit 1
fi
echo "VERDICT: PASS -- healthy and walking" | tee -a "$WORK/report.txt"
exit 0
