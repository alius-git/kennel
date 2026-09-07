#!/usr/bin/env python3
"""A rosbridge stand-in for verify-teleop: records every op, answers services.

Runs on the HOST, driven by verify-teleop.sh. Stdlib only, like everything else
in kennel_console/ (serve.md §1) -- it is the SERVER half of the WebSocket
client in cdp.py, and exists so the console's teleop path can be verified with
no VM, no ROS and no stack.

    fake-rosbridge.py --port 9391 --log ops.jsonl [--foreign] [--refuse-service]
                      [--replay FIXTURE.jsonl.gz [--loop]]

Every op the page sends is appended to --log as one JSON object per line, with a
`t` wall-clock stamp, so the suite asserts on BYTES THE PAGE ACTUALLY SENT
rather than on a JavaScript variable it could have read back from the page it is
testing.

    --foreign          answer a subscribe to /quad_control_target with one
                       publish, imitating a held trot or a verify walk. The
                       console must then refuse to publish at all.
    --refuse-service   answer call_service with result:false, so the suite can
                       see the page report a refusal rather than swallow it.
    --replay FIXTURE   answer every subscribe by replaying what the REAL stack
                       said, at the timing it said it -- a fixture recorded by
                       record-fixture.py against a live guest (#62). This is
                       what makes the Dashboard's live panels testable with no
                       VM: the numbers on screen came out of a real controller.
    --loop             restart the fixture when it ends, REBASING SIM TIME so
                       /clock and every header.stamp keep advancing. Without the
                       rebase a looping replay looks to the page like a sim that
                       jumped backwards, which is a real event (a relaunch, or
                       #66's /reset_sim) and would clear its windows every loop.

It is deliberately NOT a rosbridge: it does not validate types, and it answers
every call_service the same way. What it does honour is the one thing the panels
depend on -- `throttle_rate` as a MINIMUM GAP between messages on a topic, taken
as the minimum over that connection's subscriptions, which is rosbridge 2.0.7's
own rule (rosbridge_library/capabilities/subscribe.py). The real protocol shapes
are proven against the real bridge in stack/bridge.md §5 -- this fixture proves
the CONSOLE's half.

EXIT CODES
    0  clean shutdown (SIGTERM/SIGINT)
    2  could not bind the port
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TOPIC = "/quad_control_target"


def load_fixture(path):
    """(metadata, [(t, topic, msg)…], sim_span) from a record-fixture.py file.

    Never repaired, never reordered: what the stack said, in the order it said
    it. A fixture that does not parse is a fixture to record again, not to fix.
    """
    opener = gzip.open if path.endswith(".gz") else open
    meta, rows = None, []
    with opener(path, "rt", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if meta is None and obj.get("kennel_fixture"):
                meta = obj
                continue
            if obj.get("op") == "publish":
                rows.append((float(obj["t"]), obj["topic"], obj["msg"]))
    if meta is None:
        raise ValueError("%s has no kennel_fixture metadata line" % path)
    clocks = [sim_of(m) for t, tp, m in rows if tp == "/clock"]
    clocks = [c for c in clocks if c is not None]
    span = (max(clocks) - min(clocks)) if len(clocks) > 1 else 0.0
    return meta, rows, span


def sim_of(msg):
    """The sim seconds a /clock message carries."""
    c = msg.get("clock")
    if not isinstance(c, dict):
        return None
    return c.get("sec", 0) + c.get("nanosec", 0) / 1e9


def shift(msg, seconds):
    """A copy of `msg` with every sim stamp in it moved forward (--loop)."""
    if seconds <= 0:
        return msg
    out = dict(msg)
    if isinstance(out.get("clock"), dict):
        c = dict(out["clock"])
        total = c.get("sec", 0) + c.get("nanosec", 0) / 1e9 + seconds
        c["sec"], c["nanosec"] = int(total), int(round((total - int(total)) * 1e9))
        out["clock"] = c
    h = out.get("header")
    if isinstance(h, dict) and isinstance(h.get("stamp"), dict):
        h = dict(h)
        st = dict(h["stamp"])
        total = st.get("sec", 0) + st.get("nanosec", 0) / 1e9 + seconds
        st["sec"], st["nanosec"] = int(total), int(round((total - int(total)) * 1e9))
        h["stamp"] = st
        out["header"] = h
    return out


class Conn(threading.Thread):
    daemon = True

    def __init__(self, sock, opts, log_lock, fixture=None):
        super().__init__()
        self.sock = sock
        self.opts = opts
        self.log_lock = log_lock
        self.fixture = fixture              # (meta, rows, sim_span) or None
        self.subs = {}                      # topic -> throttle ms, per subscription id
        self.sub_lock = threading.Lock()
        self.send_lock = threading.Lock()   # two threads write frames on this socket
        self.replayer = None
        self.alive = True
        self.buf = b""

    # --- framing ------------------------------------------------------------
    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv_frame(self):
        b0, b1 = self._read(2)
        opcode = b0 & 0x0F
        masked = b1 & 0x80
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack("!H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", self._read(8))[0]
        mask = self._read(4) if masked else b""
        payload = self._read(n)
        if masked:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return opcode, payload

    def send_text(self, obj):
        payload = json.dumps(obj).encode("utf-8")
        n = len(payload)
        hdr = b"\x81"                      # server frames are NOT masked
        if n < 126:
            hdr += struct.pack("!B", n)
        elif n < 1 << 16:
            hdr += struct.pack("!BH", 126, n)
        else:
            hdr += struct.pack("!BQ", 127, n)
        try:
            # The replay thread and the request thread both write here; a frame
            # interleaved with another frame is not a frame.
            with self.send_lock:
                self.sock.sendall(hdr + payload)
        except OSError:
            pass

    # --- protocol -----------------------------------------------------------
    def handshake(self):
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                return False
            head += chunk
        key = ""
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"sec-websocket-key:"):
                key = line.split(b":", 1)[1].strip().decode()
        if not key:
            return False
        accept = base64.b64encode(
            hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.sock.sendall(
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
             "Connection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        self.buf = head.split(b"\r\n\r\n", 1)[1]
        return True

    def record(self, obj):
        with self.log_lock:
            with open(self.opts.log, "a", encoding="utf-8") as f:
                f.write(json.dumps(dict(obj, t=time.time())) + "\n")

    def run(self):
        try:
            if not self.handshake():
                return
            while True:
                opcode, payload = self.recv_frame()
                if opcode == 0x8:                      # close
                    return
                if opcode in (0x9,):                   # ping -> pong
                    continue
                if opcode not in (0x1, 0x2):
                    continue
                try:
                    msg = json.loads(payload)
                except ValueError:
                    continue
                self.record(msg)
                self.dispatch(msg)
        except (ConnectionError, OSError):
            pass
        finally:
            self.alive = False
            try:
                self.sock.close()
            except OSError:
                pass

    # --- replay ---------------------------------------------------------
    def throttle_for(self, topic):
        """Milliseconds, the minimum over this connection's subscriptions to the
        topic -- rosbridge 2.0.7's own rule (capabilities/subscribe.py:225)."""
        with self.sub_lock:
            vals = [v for (tp, v) in self.subs.values() if tp == topic]
        return min(vals) if vals else None

    def start_replay(self):
        if self.replayer is None and self.fixture is not None:
            self.replayer = threading.Thread(target=self.replay, daemon=True)
            self.replayer.start()

    def replay(self):
        """Feed back what the real stack said, at the timing it said it.

        Time is honoured, not synthesised: each row is held until its own
        recorded offset has elapsed. A row whose topic nobody is subscribed to
        is dropped rather than queued -- the page subscribes a moment after it
        connects, and delivering the backlog would put the first second of the
        fixture on the wire all at once.
        """
        meta, rows, span = self.fixture
        loop = 0
        while self.alive:
            base = time.monotonic()
            offset = loop * span
            last = {}
            for (t, topic, msg) in rows:
                # Hold this row until its own recorded offset. Bounded sleeps so
                # a client that goes away is noticed inside a quarter of a second.
                while self.alive:
                    wait = base + t - time.monotonic()
                    if wait <= 0:
                        break
                    time.sleep(min(wait, 0.25))
                if not self.alive:
                    return
                thr = self.throttle_for(topic)
                if thr is None:
                    continue
                now = time.monotonic()
                if thr > 0 and (now - last.get(topic, -1e9)) * 1000.0 < thr:
                    continue
                last[topic] = now
                self.send_text({"op": "publish", "topic": topic, "msg": shift(msg, offset)})
            if not self.opts.loop:
                return
            loop += 1

    def dispatch(self, msg):
        op = msg.get("op")
        if op == "subscribe" and self.fixture is not None:
            with self.sub_lock:
                self.subs[msg.get("id") or msg.get("topic")] = (
                    msg.get("topic"), int(msg.get("throttle_rate") or 0))
            self.start_replay()
            return
        if op == "unsubscribe" and self.fixture is not None:
            with self.sub_lock:
                key = msg.get("id") or msg.get("topic")
                self.subs.pop(key, None)
                if key is None or msg.get("id") is None:
                    for k in [k for k, v in self.subs.items() if v[0] == msg.get("topic")]:
                        self.subs.pop(k, None)
            return
        if op == "call_service":
            self.send_text({
                "op": "service_response",
                "service": msg.get("service"),
                "id": msg.get("id"),
                "result": not self.opts.refuse_service,
                "values": ({"results": [{"successful": True, "reason": ""}]}
                           if not self.opts.refuse_service
                           else "service unavailable"),
            })
        elif op == "subscribe" and self.opts.foreign and msg.get("topic") == TOPIC:
            # Somebody else is already publishing: a held trot (p21-trot-hold.sh)
            # or kennel-verify.sh's walk phase. The console's probe must see this
            # and refuse to advertise.
            self.send_text({"op": "publish", "topic": TOPIC, "msg": {
                "body_x_dot": 0.3, "body_y_dot": 0.0, "world_z": 0.3,
                "hybrid_theta_dot": 0.0, "pitch": 0.0, "roll": 0.0}})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--foreign", action="store_true")
    ap.add_argument("--refuse-service", action="store_true")
    ap.add_argument("--replay", default=None,
                    help="a fixture from record-fixture.py: answer subscribes with it")
    ap.add_argument("--loop", action="store_true",
                    help="restart the fixture when it ends, rebasing sim time")
    opts = ap.parse_args(argv)

    fixture = None
    if opts.replay:
        try:
            fixture = load_fixture(opts.replay)
        except (OSError, ValueError) as exc:
            print("NONZERO SCRIPT EXIT: cannot replay %s: %s" % (opts.replay, exc),
                  file=sys.stderr)
            return 2
        meta, rows, span = fixture
        print("[fake-rosbridge] replaying %s: %d messages, %.1f s wall, %.1f s sim, run %s"
              % (opts.replay, len(rows), rows[-1][0] if rows else 0, span, meta.get("run")),
              flush=True)

    open(opts.log, "w", encoding="utf-8").close()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        # localhost only: this speaks for a robot, and nothing here should be
        # reachable off the host even in a test.
        srv.bind(("127.0.0.1", opts.port))
    except OSError as exc:
        print("NONZERO SCRIPT EXIT: cannot bind port %d: %s" % (opts.port, exc),
              file=sys.stderr)
        return 2
    srv.listen(8)
    print("[fake-rosbridge] ws://localhost:%d/ -> %s%s%s" % (
        opts.port, opts.log,
        "  (foreign publisher)" if opts.foreign else "",
        "  (replay%s)" % (", looping" if opts.loop else "") if opts.replay else ""), flush=True)
    lock = threading.Lock()
    try:
        while True:
            sock, _ = srv.accept()
            Conn(sock, opts, lock, fixture).start()
    except KeyboardInterrupt:
        return 0
    finally:
        srv.close()


if __name__ == "__main__":
    sys.exit(main())
