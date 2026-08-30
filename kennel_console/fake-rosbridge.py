#!/usr/bin/env python3
"""A rosbridge stand-in for verify-teleop: records every op, answers services.

Runs on the HOST, driven by verify-teleop.sh. Stdlib only, like everything else
in kennel_console/ (serve.md §1) -- it is the SERVER half of the WebSocket
client in cdp.py, and exists so the console's teleop path can be verified with
no VM, no ROS and no stack.

    fake-rosbridge.py --port 9391 --log ops.jsonl [--foreign] [--refuse-service]

Every op the page sends is appended to --log as one JSON object per line, with a
`t` wall-clock stamp, so the suite asserts on BYTES THE PAGE ACTUALLY SENT
rather than on a JavaScript variable it could have read back from the page it is
testing.

    --foreign          answer a subscribe to /quad_control_target with one
                       publish, imitating a held trot or a verify walk. The
                       console must then refuse to publish at all.
    --refuse-service   answer call_service with result:false, so the suite can
                       see the page report a refusal rather than swallow it.

It is deliberately NOT a rosbridge: it does not validate types, and it answers
every call_service the same way. The real protocol shapes are proven against the
real bridge in stack/bridge.md §5 -- this fixture proves the CONSOLE's half.

EXIT CODES
    0  clean shutdown (SIGTERM/SIGINT)
    2  could not bind the port
"""
import argparse
import base64
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


class Conn(threading.Thread):
    daemon = True

    def __init__(self, sock, opts, log_lock):
        super().__init__()
        self.sock = sock
        self.opts = opts
        self.log_lock = log_lock
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
            try:
                self.sock.close()
            except OSError:
                pass

    def dispatch(self, msg):
        op = msg.get("op")
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
    opts = ap.parse_args(argv)

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
    print("[fake-rosbridge] ws://localhost:%d/ -> %s%s" % (
        opts.port, opts.log,
        "  (foreign publisher)" if opts.foreign else ""), flush=True)
    lock = threading.Lock()
    try:
        while True:
            sock, _ = srv.accept()
            Conn(sock, opts, lock).start()
    except KeyboardInterrupt:
        return 0
    finally:
        srv.close()


if __name__ == "__main__":
    sys.exit(main())
