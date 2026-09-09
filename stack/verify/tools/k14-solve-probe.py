#!/usr/bin/env python3
"""Measure the MPC solve margin from inside the stack, and print one JSON line. 2026-09-08.

WHERE IT RUNS: in the dfki_quad CONTAINER (rclpy, the ROS graph). It is copied in
and run by `kennel-bridge.sh observe`, which takes the tool to run from
KENNEL_MONITOR -- so the sweep on the host reads the stack through exactly the
path every other live measurement here takes, and there is no second copy of the
container source chain:

    KENNEL_MONITOR=/tmp/k14-solve-probe.py kennel-bridge.sh observe 20 --label <point>

    k14-solve-probe.py --sim-seconds 20 [--label L] [--rows]

WHY IT EXISTS. Issue #70 asks for a composition that predictably degrades the MPC
solve margin, and nobody had ever looked at the margin. The margin is
/solve_time against MPC_CONTROL_DT: the controller runs its MPC on a SIM-time
timer every 10 ms (mit_controller_params.hpp:8) and measures the solve with a
WALL clock (mit_controller_node.cpp:885), incrementing num_mpc_solver_overtime
when the solver takes longer than the period (:910). So the "10 ms deadline" is a
wall-clock budget per sim-time cycle -- which is why simulator_realtime_rate 0
("as fast as possible") is the knob that looks like it should matter.

WINDOWS ARE SIM SECONDS, never wall seconds, for the same reason every window in
this repo is (stack/verify.md §1.1): the sweep composes rates from 1.0 to 0, and
a wall-clock window measures a different amount of robot at each one.

OUTPUT: `KENNEL_MEASURING <wall> sim=<sim>` the moment the window opens, optional
CSV rows (--rows), then exactly one line

    KENNEL_JSON {...}

The marker is load-bearing: FastRTPS writes RTPS_TRANSPORT_SHM warnings into
captured output (stack/launch.md §7 trap 7), so "the last line" is not a safe way
to find the result -- the reader greps for this prefix instead.

EXIT CODES
    0  a window was measured and the JSON line was printed
    2  could not even look: no /clock or no /quad_state within CLOCK_WAIT
"""
import argparse
import json
import math
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy

from rosgraph_msgs.msg import Clock
from interfaces.msg import QuadState, ControllerInfo, MPCDiagnostics, WBCReturn

CLOCK_WAIT = 20.0          # wall seconds to wait for the first /clock and /quad_state
RTF_FLOOR = 0.2            # the slowest sim this will wait for before giving up
TILT_MAX = 0.5             # rad -- check.py's TILT_MAX_RAD, so tilt means one thing
# The two deadlines the controller itself uses, in ms. MPC_CONTROL_DT = 0.01 s
# and WBC_CYCLE_DT = CONTROL_DT = 0.002 s (mit_controller_params.hpp:8-11), and
# the heartbeat counters increment at exactly these bounds.
MPC_DEADLINE_MS = 10.0
WBC_DEADLINE_MS = 2.0

RELIABLE = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                      history=HistoryPolicy.KEEP_LAST)
# The controller publishes its diagnostics QOS_BEST_EFFORT_NO_DEPTH
# (mit_controller_node.cpp:218-245 at the pin), and /solve_time arrives at
# 100 Hz sim -- a reliable subscription would be asking for retransmissions of
# samples that are worthless by the time they arrive.
BEST = QoSProfile(depth=50, reliability=ReliabilityPolicy.BEST_EFFORT,
                  history=HistoryPolicy.KEEP_LAST)

HB_FIELDS = ("num_mpc_solver_overtime", "num_mpc_solver_fail", "num_wbc_overtime",
             "num_wbc_solver_fail", "num_early_contacts")


def q(vals, frac):
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, max(0, int(frac * len(s))))]


def roll_pitch(o):
    """check.py's formula, so tilt means one thing across this repo."""
    roll = math.atan2(2.0 * (o.w * o.x + o.y * o.z), 1.0 - 2.0 * (o.x * o.x + o.y * o.y))
    sinp = max(-1.0, min(1.0, 2.0 * (o.w * o.y - o.z * o.x)))
    return roll, math.asin(sinp)


class Probe(Node):
    def __init__(self):
        super().__init__("k14_solve_probe")
        self.sim = None
        self.sim0 = None
        self.wall0 = None
        self.measuring = False
        self.state = None

        self.mpc = []            # ms
        self.iters = []
        self.acados_return = 0
        self.wbc = []            # ms
        self.wbc_fail = 0
        self.hb_first = None
        self.hb_last = None
        self.n_hb = 0
        self.n_state = 0
        self.z = []
        self.n_tilt_over = 0
        self.tilt_max = 0.0
        self.vx = []
        self.vy = []
        self.x_first = self.x_last = None
        self.y_first = self.y_last = None

        self.create_subscription(Clock, "/clock", self.cb_clock, BEST)
        self.create_subscription(QuadState, "/quad_state", self.cb_state, RELIABLE)
        self.create_subscription(MPCDiagnostics, "/solve_time", self.cb_mpc, BEST)
        self.create_subscription(WBCReturn, "/wbc_solve_time", self.cb_wbc, BEST)
        self.create_subscription(ControllerInfo, "/controller_heartbeat", self.cb_hb, BEST)

    def cb_clock(self, m):
        self.sim = m.clock.sec + m.clock.nanosec / 1e9

    def cb_state(self, m):
        self.state = m
        if not self.measuring:
            return
        self.n_state += 1
        p = m.pose.pose.position
        v = m.twist.twist.linear
        self.z.append(p.z)
        self.vx.append(v.x)
        self.vy.append(v.y)
        self.x_last, self.y_last = p.x, p.y
        if self.x_first is None:
            self.x_first, self.y_first = p.x, p.y
        r, pi = roll_pitch(m.pose.pose.orientation)
        t = max(abs(r), abs(pi))
        self.tilt_max = max(self.tilt_max, t)
        if t > TILT_MAX:
            self.n_tilt_over += 1

    def cb_mpc(self, m):
        if not self.measuring:
            return
        self.mpc.append(m.solve_time * 1000.0)
        self.iters.append(int(m.acados_num_iter))
        if m.acados_return:
            self.acados_return += 1

    def cb_wbc(self, m):
        if not self.measuring:
            return
        self.wbc.append(m.total_time * 1000.0)
        if not m.success:
            self.wbc_fail += 1

    def cb_hb(self, m):
        if not self.measuring:
            return
        if self.hb_first is None:
            self.hb_first = m
        self.hb_last = m
        self.n_hb += 1


def summarise(n, label, sim_window, wall_window):
    deltas = {}
    if n.hb_first is not None and n.hb_last is not None:
        for f in HB_FIELDS:
            deltas[f] = int(getattr(n.hb_last, f) - getattr(n.hb_first, f))
    out = {
        "label": label,
        "sim_window": round(sim_window, 3),
        "wall_window": round(wall_window, 3),
        "rtf": round(sim_window / wall_window, 4) if wall_window > 0 else None,
        # The margin, in the units the controller measures it in: WALL
        # milliseconds per solve, against a 10 ms budget.
        "mpc": {
            "n": len(n.mpc),
            "mean_ms": round(sum(n.mpc) / len(n.mpc), 3) if n.mpc else None,
            "p50_ms": round(q(n.mpc, 0.5), 3) if n.mpc else None,
            "p95_ms": round(q(n.mpc, 0.95), 3) if n.mpc else None,
            "max_ms": round(max(n.mpc), 3) if n.mpc else None,
            "over_deadline": sum(1 for v in n.mpc if v >= MPC_DEADLINE_MS),
            "iters_mean": round(sum(n.iters) / len(n.iters), 2) if n.iters else None,
            "acados_return_nonzero": n.acados_return,
        },
        "wbc": {
            "n": len(n.wbc),
            "mean_ms": round(sum(n.wbc) / len(n.wbc), 3) if n.wbc else None,
            "p95_ms": round(q(n.wbc, 0.95), 3) if n.wbc else None,
            "max_ms": round(max(n.wbc), 3) if n.wbc else None,
            "over_deadline": sum(1 for v in n.wbc if v >= WBC_DEADLINE_MS),
            "fail": n.wbc_fail,
        },
        # The controller's OWN counters over the same window -- the second
        # witness, and the one kennel-verify.sh check 7 asserts against.
        "hb_deltas": deltas,
        "n_hb": n.n_hb,
        "n_state": n.n_state,
        "hb_hz": round(n.n_hb / sim_window, 3) if sim_window > 0 else None,
    }
    if n.z:
        speeds = [math.hypot(a, b) for a, b in zip(n.vx, n.vy)]
        out.update(
            z_median=round(q(n.z, 0.5), 5), z_min=round(min(n.z), 5), z_max=round(max(n.z), 5),
            tilt_max=round(n.tilt_max, 4),
            tilt_over_frac=round(n.n_tilt_over / len(n.z), 5),
            speed_mean=round(sum(speeds) / len(speeds), 4) if speeds else None,
            # Yaw-invariant, for the same reason k13-target-monitor.py reports
            # it: /quad_state twist is world-frame, and a robot that has turned
            # is not walking backwards (bridge.md §10.7).
            dist_xy=round(math.hypot((n.x_last or 0) - (n.x_first or 0),
                                     (n.y_last or 0) - (n.y_first or 0)), 4))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sim-seconds", type=float, required=True,
                    help="length of the measurement window, in SIM seconds")
    ap.add_argument("--label", default="probe")
    ap.add_argument("--rows", action="store_true", help="print a CSV row every 0.5 s")
    a = ap.parse_args()

    rclpy.init()
    n = Probe()

    # Wait for the stack to be saying anything at all, bounded, and say which of
    # the two is missing rather than timing out silently.
    t0 = time.monotonic()
    while time.monotonic() - t0 < CLOCK_WAIT and (n.sim is None or n.state is None):
        rclpy.spin_once(n, timeout_sec=0.2)
    if n.sim is None or n.state is None:
        missing = " ".join(t for t, v in (("/clock", n.sim), ("/quad_state", n.state)) if v is None)
        print("NONZERO SCRIPT EXIT: no %s within %.0f s -- is the stack launched?"
              % (missing, CLOCK_WAIT), file=sys.stderr)
        rclpy.try_shutdown()
        return 2

    n.sim0 = n.sim
    n.wall0 = time.monotonic()
    n.measuring = True
    print("KENNEL_MEASURING %.3f sim=%.3f" % (time.time(), n.sim0), flush=True)
    if a.rows:
        print("wall,sim,mpc_ms,iters,wbc_ms,z,speed", flush=True)

    # Bounded in WALL time as well, so a stalled sim cannot hang a sweep that is
    # going to run eighteen of these unattended.
    bound = a.sim_seconds / RTF_FLOOR + 30
    last_row = 0.0
    while True:
        rclpy.spin_once(n, timeout_sec=0.05)
        wall = time.monotonic() - n.wall0
        if n.sim - n.sim0 >= a.sim_seconds or wall > bound:
            break
        if a.rows and wall - last_row >= 0.5:
            last_row = wall
            v = n.state.twist.twist.linear if n.state else None
            print("%.1f,%.3f,%s,%s,%s,%s,%s" % (
                wall, n.sim,
                ("%.3f" % n.mpc[-1]) if n.mpc else "-",
                (n.iters[-1] if n.iters else "-"),
                ("%.3f" % n.wbc[-1]) if n.wbc else "-",
                ("%.4f" % n.state.pose.pose.position.z) if n.state else "-",
                ("%.3f" % math.hypot(v.x, v.y)) if v else "-"), flush=True)

    sim_window = n.sim - n.sim0
    wall_window = time.monotonic() - n.wall0
    print("KENNEL_JSON " + json.dumps(summarise(n, a.label, sim_window, wall_window),
                                      sort_keys=True), flush=True)
    rclpy.try_shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
