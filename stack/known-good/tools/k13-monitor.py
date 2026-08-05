#!/usr/bin/env python3
"""Kennel #13 -- sample the healthy-session contracts and print a time series.

Usage: k13-monitor.py <seconds> [label]
Prints one CSV row per second plus a summary, using sim time from /clock.
"""
import sys
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from interfaces.msg import QuadState, GaitState, ControllerInfo

DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
LABEL = sys.argv[2] if len(sys.argv) > 2 else "run"

RELIABLE = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                      history=HistoryPolicy.KEEP_LAST)
BEST = QoSProfile(depth=10, reliability=ReliabilityPolicy.BEST_EFFORT,
                  history=HistoryPolicy.KEEP_LAST)


class Mon(Node):
    def __init__(self):
        super().__init__("k13_monitor")
        self.n_state = self.n_gait = self.n_hb = 0
        self.state = None
        self.gait = None
        self.hb = None
        self.create_subscription(QuadState, "/quad_state", self.cb_state, RELIABLE)
        self.create_subscription(GaitState, "/gait_state", self.cb_gait, BEST)
        self.create_subscription(ControllerInfo, "/controller_heartbeat", self.cb_hb, BEST)
        self.rows = []
        self.t0 = None
        self.sim_first = None
        self.sim_last = None
        self.create_timer(1.0, self.tick)

    def cb_state(self, m):
        self.n_state += 1
        self.state = m
        st = m.header.stamp.sec + m.header.stamp.nanosec / 1e9
        if self.sim_first is None:
            self.sim_first = st
        self.sim_last = st

    def cb_gait(self, m):
        self.n_gait += 1
        self.gait = m

    def cb_hb(self, m):
        self.n_hb += 1
        self.hb = m

    def tick(self):
        if self.state is None:
            print("waiting for /quad_state ...", flush=True)
            return
        t = self.get_clock().now().nanoseconds / 1e9
        if self.t0 is None:
            self.t0 = t
            print("t_sim,x,y,z,vx,vy,vz,quat_w,foot_contact,belly,n_state,n_gait,n_hb", flush=True)
        p = self.state.pose.pose.position
        v = self.state.twist.twist.linear
        contacts = "".join("1" if c else "0" for c in self.state.foot_contact)
        belly = 1 if self.state.belly_contact else 0
        row = (round(t - self.t0, 2), round(p.x, 4), round(p.y, 4), round(p.z, 4),
               round(v.x, 4), round(v.y, 4), round(v.z, 4),
               round(self.state.pose.pose.orientation.w, 5), contacts, belly,
               self.n_state, self.n_gait, self.n_hb)
        self.rows.append(row)
        print(",".join(str(c) for c in row), flush=True)
        if t - self.t0 >= DUR:
            raise SystemExit(0)


def main():
    rclpy.init()
    n = Mon()
    try:
        rclpy.spin(n)
    except SystemExit:
        pass
    finally:
        rows = n.rows
        print("--- summary [%s] ---" % LABEL, flush=True)
        if len(rows) > 3:
            mid = rows[2:]
            vx = [r[4] for r in mid]
            z = [r[3] for r in mid]
            belly_hits = sum(1 for r in mid if r[9])
            print("samples=%d  x_travel=%.3f m  vx_mean=%.3f m/s  vx_min=%.3f  vx_max=%.3f"
                  % (len(mid), rows[-1][1] - rows[0][1], sum(vx) / len(vx), min(vx), max(vx)), flush=True)
            print("z_mean=%.4f m  z_min=%.4f  z_max=%.4f" % (sum(z) / len(z), min(z), max(z)), flush=True)
            print("quad_state msgs=%d  gait_state msgs=%d  controller_heartbeat msgs=%d"
                  % (n.n_state, n.n_gait, n.n_hb), flush=True)
            print("belly_contact samples=%d (0 = never fell)" % belly_hits, flush=True)
            if n.sim_first is not None and rows[-1][0] > 0:
                # header stamps are SIM time; row timestamps are WALL time.
                print("achieved_realtime_rate=%.3f  (sim %.1f s advanced over %.1f s wall; "
                      "simulator_realtime_rate target 1.0)"
                      % ((n.sim_last - n.sim_first) / rows[-1][0],
                         n.sim_last - n.sim_first, rows[-1][0]), flush=True)
        rclpy.try_shutdown()


if __name__ == "__main__":
    main()
