#!/usr/bin/env python3
"""The dead man's switch the browser cannot provide -- issue #67. 2026-09-07.

WHERE IT RUNS: in the dfki_quad CONTAINER (rclpy), started and stopped beside the
rosbridge by `kennel-bridge.sh start|stop`, which is `kennel-demo.sh teleop`.

WHY. The controller keeps the last /quad_control_target it received FOREVER
(mit_controller_node.cpp:793-798 at the pin), so a page that goes away mid-stride
has to put a zero on the wire before it does. kennel_console/teleop.md §5 lists
the events the console fires for that -- pointerup, visibilitychange, pagehide,
beforeunload -- and then says the honest thing: a KILLED RENDERER FIRES NONE OF
THEM. Kill the tab and the robot keeps walking until someone runs `teleop stop`.
Measured before this node existed, on the real stack: it kept going for the whole
30-second window it was watched in (stack/bridge.md §11). No amount of JavaScript
fixes that, because the JavaScript is what died. This is the guest-side node that
was named as the retirement path.

WHAT IT DOES, and the four things it deliberately does NOT do:

  1. NEVER BEFORE THE FIRST MESSAGE. Until it has seen one target it does
     nothing, forever if need be. A freshly launched stack -- where joy_to_target
     is up and idle and nobody has commanded anything -- is never touched.
  2. STALE AND ARMED -> ONE ZERO. When no message has arrived for STALE seconds
     and the last one was commanding motion, it publishes a zero with world_z
     COPIED FROM THAT MESSAGE (launch.md §4.2: a target that omits world_z
     commands the body into the floor, so all six fields are always filled).
  3. A BOUNDED BURST, not "until a fresh message arrives". The intervention is
     repeated REPEAT-1 times at one second, and then it is quiet. A watchdog that
     published forever after a kill would BE a publisher on the topic, and the
     console's one-second probe would then count it and refuse to drive on the
     next connect (teleop.md §3) -- the reconciliation #67 itself asks for. Two
     seconds of repeats and silence keeps both. The controller's subscription is
     RELIABLE, so the repeats are belt and braces, not delivery.
  4. ITS OWN ECHOES NEED NO FILTER. rclpy at this image's version has no
     `ignore_local_publications`, so this node hears the zeros it publishes. That
     is harmless by construction: an echoed zero sets `last` to a zero, and a
     zero never arms rule 2. Do not add a filter -- there is nothing to filter.
  5. IT NEVER TOUCHES THE GAIT. No parameter call, no service call, ever. It
     stops the robot walking; it does not decide what the robot is.

STALENESS IS WALL TIME. Publishers run on wall clocks whatever the composed
simulator_realtime_rate is, so "nobody has published for a second" is a wall-clock
fact. How long the robot then takes to come to rest is a SIM-time fact, and that
is what k13-target-monitor.py measures. Both numbers are in stack/bridge.md §11.

    k13-target-watchdog.py            # knobs are environment variables

Knobs:
    KENNEL_WATCHDOG_STALE   1.0   seconds without a target before intervening
    KENNEL_WATCHDOG_REPEAT  3     zeros per intervention, one second apart

Files:
    /tmp/k13-watchdog.log     one line per event (this script's stdout)
    /tmp/k13-watchdog.state   `armed|idle <wall> <vx> <wz> <z> interventions=<n>`,
                              rewritten on every change. `kennel-bridge.sh stop`
                              reads it: the bridge goes down FIRST and the
                              watchdog is only stopped once this says idle,
                              because the seconds right after the bridge dies are
                              the whole point of the node.

EXIT CODES
    0  stopped by SIGINT/SIGTERM (it prints its intervention count on the way out)
    2  could not start: no rclpy, or the message type would not resolve
"""
import os
import signal
import sys
import time

try:
    import rclpy
    from rclpy.node import Node
    from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
    from interfaces.msg import QuadControlTarget
except Exception as exc:                                   # noqa: BLE001
    print("NONZERO SCRIPT EXIT: cannot import rclpy/interfaces: %s" % exc, file=sys.stderr)
    print("  Is this shell inside the container, with the workspace sourced?", file=sys.stderr)
    sys.exit(2)

TOPIC = "/quad_control_target"
STATE_FILE = "/tmp/k13-watchdog.state"
STALE = float(os.environ.get("KENNEL_WATCHDOG_STALE") or 1.0)
REPEAT = int(float(os.environ.get("KENNEL_WATCHDOG_REPEAT") or 3))
TICK = 0.1

# The controller subscribes QOS_RELIABLE_NO_DEPTH (mit_controller_node.cpp:649-651)
# and every publisher of this topic is reliable -- joy_to_target, `ros2 topic pub`
# and rosbridge's advertise. Depth 1 on the way out: the newest target is the only
# one that matters, and a queue of stale zeros helps nobody.
SUB_QOS = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE,
                     history=HistoryPolicy.KEEP_LAST)
PUB_QOS = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                     history=HistoryPolicy.KEEP_LAST)


def commanding_motion(m):
    """Is this target asking the robot to move? world_z is a POSE, not motion:
    a zero target still holds the body at its commanded height."""
    return (abs(m.body_x_dot) > 1e-9 or abs(m.body_y_dot) > 1e-9
            or abs(m.hybrid_theta_dot) > 1e-9)


def say(msg):
    print("[watchdog] %s" % msg, flush=True)


class Watchdog(Node):
    def __init__(self):
        super().__init__("k13_target_watchdog")
        self.last = None            # the last target seen, or None: rule 1
        self.last_wall = 0.0
        self.interventions = 0
        self.burst_left = 0
        self.next_burst = 0.0
        self.armed_logged = False
        self.pub = self.create_publisher(QuadControlTarget, TOPIC, PUB_QOS)
        self.create_subscription(QuadControlTarget, TOPIC, self.on_target, SUB_QOS)
        self.create_timer(TICK, self.tick)
        self.write_state("idle")
        say("ready -- stale after %.2f s, %d zero(s) per intervention, waiting for the "
            "first target on %s" % (STALE, REPEAT, TOPIC))

    # --- state, for kennel-bridge.sh stop
    def write_state(self, what):
        m = self.last
        try:
            with open(STATE_FILE, "w") as fh:
                fh.write("%s %.3f %.4f %.4f %.4f interventions=%d\n" % (
                    what, time.time(),
                    m.body_x_dot if m else 0.0, m.hybrid_theta_dot if m else 0.0,
                    m.world_z if m else 0.0, self.interventions))
        except OSError:
            pass

    def armed(self):
        return self.last is not None and commanding_motion(self.last)

    def on_target(self, m):
        was_armed = self.armed()
        self.last = m
        self.last_wall = time.time()
        if commanding_motion(m):
            # Somebody is driving again: whatever burst was in flight is over.
            if self.burst_left:
                say("quiet: a fresh non-zero target arrived, burst cancelled")
                self.burst_left = 0
            if not was_armed:
                self.armed_logged = True
                say("armed: vx=%.3f vy=%.3f wz=%.3f z=%.3f" % (
                    m.body_x_dot, m.body_y_dot, m.hybrid_theta_dot, m.world_z))
                self.write_state("armed")
        elif was_armed:
            self.write_state("idle")

    def zero_like(self, m):
        """A stop that keeps everything that is not motion. ALL SIX FIELDS, and
        world_z copied from what was last commanded -- an omitted or defaulted
        world_z is 0.0, which commands the body to the ground (launch.md §4.2)."""
        out = QuadControlTarget()
        out.body_x_dot = 0.0
        out.body_y_dot = 0.0
        out.hybrid_theta_dot = 0.0
        out.world_z = m.world_z
        out.pitch = 0.0
        out.roll = 0.0
        return out

    def tick(self):
        now = time.time()
        if self.burst_left and now >= self.next_burst:
            self.pub.publish(self.zero_like(self.last))
            self.burst_left -= 1
            self.next_burst = now + 1.0
            say("  repeat zero (%d left)" % self.burst_left)
            return
        if not self.armed():
            return
        age = now - self.last_wall
        if age < STALE:
            return
        m = self.last
        self.interventions += 1
        zero = self.zero_like(m)
        self.pub.publish(zero)
        say("INTERVENTION #%d: no target for %.2f s (stale after %.2f s); last was "
            "vx=%.3f vy=%.3f wz=%.3f -- published a zero, world_z %.3f kept; "
            "repeating %d more at 1 s" % (
                self.interventions, age, STALE, m.body_x_dot, m.body_y_dot,
                m.hybrid_theta_dot, m.world_z, max(0, REPEAT - 1)))
        # What the controller now holds is known, so the clock restarts here
        # rather than waiting for our own echo to come back.
        self.last = zero
        self.last_wall = now
        self.burst_left = max(0, REPEAT - 1)
        self.next_burst = now + 1.0
        self.write_state("idle")


def main():
    rclpy.init()
    n = Watchdog()
    stop = {"now": False}

    def bye(_sig, _frm):
        stop["now"] = True
    signal.signal(signal.SIGINT, bye)
    signal.signal(signal.SIGTERM, bye)

    while not stop["now"]:
        rclpy.spin_once(n, timeout_sec=TICK)
    say("stopping -- interventions=%d" % n.interventions)
    try:
        os.unlink(STATE_FILE)
    except OSError:
        pass
    rclpy.try_shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
