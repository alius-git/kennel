#!/usr/bin/env python3
"""Record a fixture of the running stack from the real rosbridge. 2026-09-07.

WHERE IT RUNS: HOST (the machine with the browser), against a guest whose stack
is up and whose bridge is running -- `demo/tools/kennel-demo.sh teleop` starts
one and prints the ws:// URL.

    kennel_console/record-fixture.py --url ws://GUEST:9090/ --seconds 30 \
        --out kennel_console/fixtures/healthy.jsonl.gz [--run ~/kennel-runs/run-<stamp>]

Stdlib only, like everything else in kennel_console/ (serve.md section 1). It
reuses the WebSocket client in cdp.py -- the same one the suites drive Chrome
with -- so there is no second implementation of the protocol to keep in step.

WHY IT EXISTS. The Dashboard's panels have to be verifiable with no VM, and the
only honest way to do that is to replay what the real stack actually said. The
file this writes is fed back by `fake-rosbridge.py --replay`, so every panel
check in verify-dashboard.sh is made against bytes a real controller produced.

NEVER HAND-EDIT A FIXTURE. Regenerating goes through this script, and the run
that produced it travels beside it as <name>.run.json, so a reader can tell
which composition the recording is of. A fixture whose provenance is a text
editor is evidence of nothing.

FORMAT: gzipped JSON Lines. Line 1 is the metadata:

    {"kennel_fixture": 1, "recorded_at": "<UTC ISO>", "bridge": "<url>",
     "run": "run-<stamp>"|null, "pin": "<sha>"|null, "seconds": 30,
     "topics": [...], "throttle_ms": {...}}

then one line per message, in arrival order, exactly as it arrived:

    {"t": <wall seconds since the first subscribe>, "op": "publish",
     "topic": "/quad_state", "msg": {...}}

Knobs are arguments; there is nothing environmental about a recording.

EXIT CODES
    0  a fixture was written
    1  the bridge answered but nothing arrived (is the stack launched?)
    2  could not even look: no such URL, the socket would not open, unwritable out
"""
import argparse
import gzip
import json
import os
import socket
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from cdp import WS                                          # noqa: E402  (same repo, no dependency)

# The eight topics every Dashboard panel needs, with the throttle each one is
# subscribed at. These are the SAME numbers the page uses (RosbridgeDataSource's
# LIVE_TOPICS in Kennel Console.dc.html) -- a fixture recorded at a different
# rate than the page asks for would make the replay a different experiment.
#
#   throttle_rate is a MINIMUM GAP in ms, not a metronome: 20 ms measured
#   49.5 Hz on the live stack, with inter-arrivals of 13.8-26.1 ms.
#   0 means "every message" -- used only for the two topics that are already
#   slow (2 Hz heartbeat, 10-20 Hz target).
TOPICS = [
    ("/clock",                "rosgraph_msgs/msg/Clock",         100),
    ("/quad_state",           "interfaces/msg/QuadState",         20),
    ("/solve_time",           "interfaces/msg/MPCDiagnostics",    20),
    ("/wbc_solve_time",       "interfaces/msg/WBCReturn",         20),
    ("/gait_state",           "interfaces/msg/GaitState",         20),
    ("/contact_state",        "interfaces/msg/ContactState",      20),
    ("/controller_heartbeat", "interfaces/msg/ControllerInfo",     0),
    ("/quad_control_target",  "interfaces/msg/QuadControlTarget",  0),
]


def host_pin():
    """The stack pin, read from stack/pin.lock the way serve.py does."""
    try:
        with open(os.path.join(REPO_ROOT, "stack", "pin.lock"), encoding="utf-8") as f:
            for line in f:
                if line.startswith("commit:"):
                    return line.split(":", 1)[1].strip() or None
    except OSError:
        return None
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", required=True, help="rosbridge WebSocket URL (kennel-demo.sh teleop prints it)")
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--out", required=True, help="destination .jsonl or .jsonl.gz")
    ap.add_argument("--run", default=None, help="the run folder this recording is of")
    args = ap.parse_args(argv)

    out = os.path.abspath(os.path.expanduser(args.out))
    try:
        os.makedirs(os.path.dirname(out), exist_ok=True)
    except OSError as exc:
        print("NONZERO SCRIPT EXIT: cannot write %s: %s" % (out, exc), file=sys.stderr)
        return 2
    try:
        ws = WS(args.url)
    except (OSError, AssertionError, ValueError) as exc:
        print("NONZERO SCRIPT EXIT: cannot open %s (%s)" % (args.url, exc), file=sys.stderr)
        print("  Start one with:  demo/tools/kennel-demo.sh teleop", file=sys.stderr)
        return 2
    ws.s.settimeout(5)

    run_name = os.path.basename(args.run.rstrip("/")) if args.run else None
    meta = {"kennel_fixture": 1,
            "recorded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "bridge": args.url, "run": run_name, "pin": host_pin(),
            "seconds": args.seconds,
            "topics": [t for t, _, _ in TOPICS],
            "throttle_ms": {t: thr for t, _, thr in TOPICS}}

    opener = gzip.open if out.endswith(".gz") else open
    counts, n = {}, 0
    t0 = time.monotonic()
    for i, (topic, typ, thr) in enumerate(TOPICS):
        ws.send({"op": "subscribe", "id": "kennel-fixture-%d" % i, "topic": topic,
                 "type": typ, "throttle_rate": thr, "queue_length": 1})
    with opener(out, "wt", encoding="utf-8") as f:
        f.write(json.dumps(meta) + "\n")
        while time.monotonic() - t0 < args.seconds:
            try:
                m = ws.recv()
            except socket.timeout:
                continue
            except (OSError, ValueError) as exc:
                print("[record-fixture] the bridge went away: %s" % exc, file=sys.stderr)
                break
            if m.get("op") != "publish":
                continue
            f.write(json.dumps({"t": round(time.monotonic() - t0, 4), "op": "publish",
                                "topic": m["topic"], "msg": m["msg"]}) + "\n")
            counts[m["topic"]] = counts.get(m["topic"], 0) + 1
            n += 1
    for i, (topic, _, _) in enumerate(TOPICS):
        ws.send({"op": "unsubscribe", "id": "kennel-fixture-%d" % i, "topic": topic})
    try:
        ws.s.close()
    except OSError:
        pass

    elapsed = time.monotonic() - t0
    if n == 0:
        print("NONZERO SCRIPT EXIT: the bridge answered but published nothing in %.0f s."
              % elapsed, file=sys.stderr)
        print("  Is the stack launched?  demo/tools/kennel-demo.sh status", file=sys.stderr)
        os.remove(out)
        return 1

    if args.run:
        src = os.path.join(os.path.expanduser(args.run), "run.json")
        if os.path.isfile(src):
            dst = out[:-3] if out.endswith(".gz") else out
            dst = os.path.splitext(dst)[0] + ".run.json"
            with open(src, "rb") as a, open(dst, "wb") as b:
                b.write(a.read())
            print("[record-fixture] provenance  %s" % dst)
        else:
            print("[record-fixture] WARNING: no run.json in %s -- the fixture has no provenance"
                  % args.run, file=sys.stderr)

    print("[record-fixture] %s  %d messages in %.1f s, %d bytes"
          % (out, n, elapsed, os.path.getsize(out)))
    print("%-24s %8s %8s" % ("topic", "msgs", "Hz"))
    for topic, _, thr in TOPICS:
        print("%-24s %8d %8.1f" % (topic, counts.get(topic, 0), counts.get(topic, 0) / elapsed))
    missing = [t for t, _, _ in TOPICS if not counts.get(t)]
    if missing:
        print("[record-fixture] WARNING: nothing arrived on %s" % ", ".join(missing),
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
