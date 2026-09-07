#!/usr/bin/env python3
"""Measure the teleop path from inside the stack, and print one JSON line. 2026-09-07.

WHERE IT RUNS: in the dfki_quad CONTAINER (rclpy, the ROS graph). It is copied in
and run by `kennel-bridge.sh observe`, which is how stack/bridge/verify-teleop-live.sh
(HOST) reads the guest -- so every live assertion is made against what a node in
the graph saw, never against a variable read back out of the page under test
(kennel_console/dashboard.md section 4).

    k13-target-monitor.py --sim-seconds 20 [--label drive] [--rows]

WINDOWS ARE SIM SECONDS, never wall seconds. The guest runs the sim at a composed
simulator_realtime_rate (0.5 and 1.0 are both used), so a wall-clock window
measures a different amount of robot at every rate -- the rule stack/verify.md
section 1.1 established for the CLI recipe. Wall time appears in exactly one
place: the staleness of /quad_control_target, because PUBLISHERS run on wall
clocks whatever the sim is doing, and that is what #67's watchdog measures.

OUTPUT: `KENNEL_MEASURING <wall> sim=<sim>` the moment the window opens (rclpy
takes seconds to start, and a caller that wants to act INSIDE the window must
wait for this rather than sleep at it), optional CSV rows (--rows), then exactly
one line

    KENNEL_JSON {...}

The marker is load-bearing. FastRTPS writes RTPS_TRANSPORT_SHM warnings into
captured output (stack/launch.md section 7 trap 7), so "the last line" is not a
safe way to find the result -- the reader greps for this prefix instead.

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
from interfaces.msg import QuadState, GaitState, ControllerInfo, QuadControlTarget

TOPIC = "/quad_control_target"
CLOCK_WAIT = 20.0          # wall seconds to wait for the first /clock and /quad_state
RTF_FLOOR = 0.2            # the slowest sim this will wait for before giving up
TILT_MAX = 0.5             # rad -- check.py's TILT_MAX_RAD, so the two agree
STOPPED_VX = 0.05          # mean |vx| under this is "at rest" (#65's release criterion)
STOPPED_HOLD_SIM = 0.5     # ... and it has to hold this long, in sim seconds
SMOOTH_SIM = 0.5           # ... measured as a MEAN over this many sim seconds.
# A PER-SAMPLE threshold cannot express "at rest" here and it is worth saying why.
# A robot commanded to zero in WALKING_TROT does not stand still: it trots in
# place, and vx crosses +/- 0.05 m/s several times a second at 1 kHz. The same
# shape composed-run.md §9.2 records for the standing robot that shuffles 5-22
# cm/s under the MPC -- no instantaneous bound separates walking from stopped.
SERIES_MIN_DT = 0.02       # decimate the series to ~50 Hz: 1 kHz is not needed

RELIABLE = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                      history=HistoryPolicy.KEEP_LAST)
BEST = QoSProfile(depth=10, reliability=ReliabilityPolicy.BEST_EFFORT,
                  history=HistoryPolicy.KEEP_LAST)

# GaitDatabase::getGait at the pin (controllers/src/mit_controller/gait.cpp:748-783).
# The same table check.py carries (stack/verify/kennel-verify.sh) -- /gait_state
# carries no gait NAME, only what a gait IS, so a name is a lookup or nothing.
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


def gait_name(period, duty, offsets, tol=1e-3):
    """The gait whose signature this is, or None -- which is itself a finding."""
    for name, (T, d, off) in GAIT_TABLE.items():
        if abs(period - T) > tol:
            continue
        if len(duty) != 4 or any(abs(x - d) > tol for x in duty):
            continue
        if len(offsets) != 4 or any(abs(a - b) > tol for a, b in zip(offsets, off)):
            continue
        return name
    return None


def roll_pitch(q):
    """Body roll and pitch in radians -- check.py's formula, so tilt means one thing."""
    roll = math.atan2(2.0 * (q.w * q.x + q.y * q.z),
                      1.0 - 2.0 * (q.x * q.x + q.y * q.y))
    sinp = max(-1.0, min(1.0, 2.0 * (q.w * q.y - q.z * q.x)))
    return roll, math.asin(sinp)


def nonzero(msg):
    """Is this target commanding motion? world_z is a POSE, not motion, and is
    never part of this test: a zero target still holds the body at world_z."""
    return (abs(msg.body_x_dot) > 1e-9 or abs(msg.body_y_dot) > 1e-9
            or abs(msg.hybrid_theta_dot) > 1e-9)


class Monitor(Node):
    def __init__(self):
        super().__init__("k13_target_monitor")
        self.sim = None
        self.state = None
        self.gait = None
        self.measuring = False

        # Counters and series, all filled only while `measuring`.
        self.n_state = self.n_hb = self.n_target = 0
        self.vx = []
        self.z = []
        self.x_first = self.x_last = None
        self.n_tilt_over = 0
        self.tilt_max = 0.0
        self.belly_hits = 0
        self.contacts = ""
        self.wz = 0.0

        # /quad_control_target: arrivals, staleness, what was commanded.
        self.gaps = []                       # ms between consecutive arrivals
        self.prev_target_wall = None
        self.target_vals = {}                # rounded body_x_dot -> count
        self.last_target = None              # (msg, wall, sim)
        self.last_nonzero = None             # (wall, sim)
        self.first_zero_after_nonzero = None  # (wall, sim)
        self.seen_nonzero = False

        # (sim, vx) at ~50 Hz, so "when did it come to rest" can be answered by a
        # SMOOTHED reading afterwards rather than by an instantaneous one.
        self.series = []
        self.series_last = None
        self.gait_changes = []
        self.sig = None

        self.create_subscription(Clock, "/clock", self.cb_clock, BEST)
        self.create_subscription(QuadState, "/quad_state", self.cb_state, RELIABLE)
        self.create_subscription(GaitState, "/gait_state", self.cb_gait, BEST)
        self.create_subscription(ControllerInfo, "/controller_heartbeat", self.cb_hb, BEST)
        # RELIABLE: both publishers of this topic are (joy_to_target and
        # `ros2 topic pub`; rosbridge's advertise is too -- the controller's own
        # subscription is QOS_RELIABLE_NO_DEPTH, mit_controller_node.cpp:649-651,
        # and it receives what the browser sends).
        self.create_subscription(QuadControlTarget, TOPIC, self.cb_target, RELIABLE)

    def cb_clock(self, m):
        self.sim = m.clock.sec + m.clock.nanosec / 1e9

    def cb_state(self, m):
        self.state = m
        if not self.measuring:
            return
        self.n_state += 1
        p = m.pose.pose.position
        v = m.twist.twist.linear
        self.wz = m.twist.twist.angular.z
        self.vx.append(v.x)
        self.z.append(p.z)
        self.x_last = p.x
        if self.x_first is None:
            self.x_first = p.x
        r, pi = roll_pitch(m.pose.pose.orientation)
        tilt = max(abs(r), abs(pi))
        self.tilt_max = max(self.tilt_max, tilt)
        if tilt > TILT_MAX:
            self.n_tilt_over += 1
        if m.belly_contact:
            self.belly_hits += 1
        self.contacts = "".join("1" if c else "0" for c in m.foot_contact)
        if self.sim is not None and (self.series_last is None
                                     or self.sim - self.series_last >= SERIES_MIN_DT):
            self.series_last = self.sim
            self.series.append((self.sim, v.x))

    def cb_gait(self, m):
        self.gait = m
        if not self.measuring:
            return
        sig = (round(m.period, 4), tuple(round(d, 4) for d in m.duty_factor),
               tuple(round(o, 4) for o in m.phase_offset))
        if sig != self.sig:
            self.sig = sig
            self.gait_changes.append({
                "sim": round(self.sim, 3) if self.sim is not None else None,
                "name": gait_name(m.period, list(m.duty_factor), list(m.phase_offset)),
                "period": round(m.period, 4),
                "duty": round(m.duty_factor[0], 4) if len(m.duty_factor) else None})

    def cb_hb(self, m):
        if self.measuring:
            self.n_hb += 1

    def cb_target(self, m):
        if not self.measuring:
            return
        now = time.time()
        self.n_target += 1
        if self.prev_target_wall is not None:
            self.gaps.append((now - self.prev_target_wall) * 1000.0)
        self.prev_target_wall = now
        key = round(m.body_x_dot, 3)
        self.target_vals[key] = self.target_vals.get(key, 0) + 1
        self.last_target = (m, now, self.sim)
        if nonzero(m):
            self.seen_nonzero = True
            self.last_nonzero = (now, self.sim)
        elif self.seen_nonzero and self.first_zero_after_nonzero is None:
            # The moment somebody put the robot back to a stop: a stick release,
            # a STAND, or #67's watchdog noticing that nobody is at the controls.
            self.first_zero_after_nonzero = (now, self.sim)


def row_header():
    return "wall,sim,z,x,vx,wz,contacts,tgt_vx,tgt_wz,tgt_z,n_tgt,gait"


def row(n, t0):
    tm = n.last_target[0] if n.last_target else None
    p = n.state.pose.pose.position if n.state else None
    v = n.state.twist.twist.linear if n.state else None
    g = n.gait
    return "%.1f,%s,%s,%s,%s,%.3f,%s,%s,%s,%s,%d,%s" % (
        time.monotonic() - t0,
        ("%.3f" % n.sim) if n.sim is not None else "-",
        ("%.4f" % p.z) if p else "-", ("%.3f" % p.x) if p else "-",
        ("%.3f" % v.x) if v else "-", n.wz, n.contacts or "-",
        ("%.3f" % tm.body_x_dot) if tm else "-",
        ("%.3f" % tm.hybrid_theta_dot) if tm else "-",
        ("%.3f" % tm.world_z) if tm else "-",
        n.n_target,
        gait_name(g.period, list(g.duty_factor), list(g.phase_offset)) if g else "-")


def rest_since(series, sim_now, first=True):
    """When the robot came to rest, or None if it never did in this window.

    `first` picks WHICH rest: the first sustained one (did it stop after the
    stick was released?) or the one the window ends in (is it stopped NOW?).
    Both are needed and they are not the same question. Measured on this guest:
    a robot released in WALKING_TROT stops within about 1.5 s and holds station
    for roughly ten seconds -- and then, still trotting in place against a zero
    target, it starts creeping forward again while its body sags from 0.30 m to
    0.15 m. So "is it at rest at the end of the window" answers `no` about a
    robot that plainly did stop when it was asked to.

    "At rest" is |NET velocity| over SMOOTH_SIM seconds, which is displacement
    per second -- not mean speed, and certainly not a per-sample bound. A robot
    released in WALKING_TROT trots in place: it goes nowhere while its body
    velocity swings about +/- 0.09 m/s several times a second, so mean SPEED
    reads 0.057 m/s and a per-sample test never settles at all. Going nowhere is
    what "it stopped" means to the operator who let go of the stick, and it is
    what PR #59 recorded as "holds station".

    What comes back is the start of the run of rest the window ENDS in -- a robot
    that stopped and was then driven off again has not come to rest.
    """
    if not series or sim_now is None:
        return None
    smooth, i = [], 0
    for j, (t, _) in enumerate(series):
        while series[i][0] < t - SMOOTH_SIM:
            i += 1
        vals = [v for _, v in series[i:j + 1]]
        smooth.append((t, abs(sum(vals) / len(vals))))
    start, done = None, None
    for t, mean_vx in smooth:
        if mean_vx < STOPPED_VX:
            if start is None:
                start = t
            elif first and done is None and t - start >= STOPPED_HOLD_SIM:
                done = start
        else:
            start = None
    if first:
        return round(done, 3) if done is not None else None
    if start is None or sim_now - start < STOPPED_HOLD_SIM:
        return None
    return round(start, 3)


def summarise(n, label, sim_window, wall_window):
    def q(vals, frac):
        s = sorted(vals)
        return s[min(len(s) - 1, max(0, int(frac * len(s))))]

    gaps = n.gaps
    gap_mean = sum(gaps) / len(gaps) if gaps else None
    gap_std = None
    if len(gaps) > 1:
        var = sum((g - gap_mean) ** 2 for g in gaps) / (len(gaps) - 1)
        gap_std = math.sqrt(var)
    tm = n.last_target[0] if n.last_target else None
    distinct = sorted(n.target_vals)
    g = n.gait

    rest = rest_since(n.series, n.sim, first=True)
    rest_now = rest_since(n.series, n.sim, first=False)

    out = {
        "label": label,
        "sim_window": round(sim_window, 3),
        "wall_window": round(wall_window, 3),
        "rtf": round(sim_window / wall_window, 4) if wall_window > 0 else None,
        "target": {
            "n": n.n_target,
            "hz": round(n.n_target / sim_window, 3) if sim_window > 0 else None,
            "hz_wall": round(n.n_target / wall_window, 3) if wall_window > 0 else None,
            "gap_mean_ms": round(gap_mean, 2) if gap_mean is not None else None,
            "gap_std_ms": round(gap_std, 2) if gap_std is not None else None,
            "gap_max_ms": round(max(gaps), 2) if gaps else None,
            "distinct_vx": [round(v, 3) for v in distinct[:12]],
            "distinct_vx_n": len(distinct),
            "n_publishers": n.count_publishers(TOPIC),
            "last_wall": round(n.last_target[1], 3) if n.last_target else None,
            "last_sim": round(n.last_target[2], 3) if n.last_target and n.last_target[2] else None,
            "last_msg": ({"body_x_dot": round(tm.body_x_dot, 4),
                          "body_y_dot": round(tm.body_y_dot, 4),
                          "world_z": round(tm.world_z, 4),
                          "hybrid_theta_dot": round(tm.hybrid_theta_dot, 4),
                          "pitch": round(tm.pitch, 4), "roll": round(tm.roll, 4)}
                         if tm else None),
            "last_nonzero_wall": round(n.last_nonzero[0], 3) if n.last_nonzero else None,
            "last_nonzero_sim": (round(n.last_nonzero[1], 3)
                                 if n.last_nonzero and n.last_nonzero[1] else None),
            "first_zero_after_nonzero_wall": (round(n.first_zero_after_nonzero[0], 3)
                                              if n.first_zero_after_nonzero else None),
            "first_zero_after_nonzero_sim": (round(n.first_zero_after_nonzero[1], 3)
                                             if n.first_zero_after_nonzero
                                             and n.first_zero_after_nonzero[1] else None),
        },
        # The first sustained rest in the window (did it stop when it was told
        # to?) and whether it is STILL stopped at the end (which a robot trotting
        # in place against a zero target stops being, after about ten seconds).
        "vx_below_%s_since_sim" % str(STOPPED_VX).replace(".", "_"): rest,
        "at_rest_at_end_since_sim": rest_now,
        "n_state": n.n_state,
        "n_hb": n.n_hb,
        "hb_hz": round(n.n_hb / sim_window, 3) if sim_window > 0 else None,
        "gait_changes": n.gait_changes,
        "gait": ({"period": round(g.period, 4),
                  "duty": [round(d, 4) for d in g.duty_factor],
                  "offsets": [round(o, 4) for o in g.phase_offset],
                  "sequencer": int(g.gait_sequencer),
                  "name": gait_name(g.period, list(g.duty_factor), list(g.phase_offset))}
                 if g else None),
    }
    if n.vx:
        out.update(vx_mean=round(sum(n.vx) / len(n.vx), 4),
                   vx_min=round(min(n.vx), 4), vx_max=round(max(n.vx), 4),
                   x_travel=round((n.x_last or 0) - (n.x_first or 0), 4),
                   z_median=round(q(n.z, 0.5), 5), z_min=round(min(n.z), 5),
                   z_max=round(max(n.z), 5), z_p01=round(q(n.z, 0.01), 5),
                   tilt_max=round(n.tilt_max, 4),
                   tilt_over_frac=round(n.n_tilt_over / len(n.vx), 5),
                   belly_hits=n.belly_hits)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sim-seconds", type=float, required=True,
                    help="length of the measurement window, in SIM seconds")
    ap.add_argument("--label", default="observe")
    ap.add_argument("--rows", action="store_true", help="print a CSV row every 0.5 s")
    a = ap.parse_args()

    rclpy.init()
    n = Monitor()
    t0 = time.monotonic()

    # Wait for the stack to say anything at all. Bounded, and it names which of
    # the two never came -- "could not even look" is exit 2, not a failed assert.
    deadline = t0 + CLOCK_WAIT
    while time.monotonic() < deadline and (n.sim is None or n.state is None):
        rclpy.spin_once(n, timeout_sec=0.05)
    if n.sim is None or n.state is None:
        missing = " and ".join(x for x, ok in (("/clock", n.sim is not None),
                                               ("/quad_state", n.state is not None)) if not ok)
        print("NONZERO SCRIPT EXIT: no %s within %.0f s -- is the stack launched?"
              % (missing, CLOCK_WAIT), file=sys.stderr)
        rclpy.try_shutdown()
        return 2

    sim0, wall0 = n.sim, time.monotonic()
    n.measuring = True
    # The window is OPEN. A caller that wants to do something (release the stick,
    # kill the renderer) inside the window has to know when it started, and
    # rclpy's own start-up is seconds long -- so it is announced rather than
    # slept at (demo/dry-run.md F8, applied to this tool's own callers).
    print("KENNEL_MEASURING %.3f sim=%.3f" % (time.time(), sim0), flush=True)
    # Bounded by the SLOWEST sim worth waiting for, so a stalled simulator ends
    # the window instead of hanging the suite that called this.
    budget = a.sim_seconds / RTF_FLOOR + 30.0
    if a.rows:
        print(row_header(), flush=True)
    nxt = wall0
    while (n.sim - sim0) < a.sim_seconds and (time.monotonic() - wall0) < budget:
        rclpy.spin_once(n, timeout_sec=0.02)
        if a.rows and time.monotonic() >= nxt:
            nxt += 0.5
            print(row(n, wall0), flush=True)
    n.measuring = False

    sim_window = n.sim - sim0
    wall_window = time.monotonic() - wall0
    print("KENNEL_JSON " + json.dumps(summarise(n, a.label, sim_window, wall_window),
                                      sort_keys=True), flush=True)
    rclpy.try_shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
