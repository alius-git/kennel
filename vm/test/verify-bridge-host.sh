#!/bin/bash
# Version: 2026.08.30
# Kennel -- issue #58: prove the rosbridge WebSocket (served inside the guest's
# container) is reachable from the HOST browser, and print the URL to connect to.
#
# Runs on the HOST, not in the guest -- the sibling of verify-meshcat-host.sh,
# and for the same reason: Yuruna has no host-exec action, so the guest->host hop
# cannot be asserted from inside a sequence. Same two-hop model
# (vm/meshcat-exposure.md), same discovery by DHCP lease hostname, same --quiet
# contract: the last stdout line is the URL.
#
# Read-only. It discovers, handshakes and reports; it never starts or stops
# anything. `kennel-demo.sh teleop` is what starts the bridge.
#
# Usage:
#   vm/test/verify-bridge-host.sh              # discover everything, verify
#   vm/test/verify-bridge-host.sh --quiet      # print only the final ws:// URL
#
# Exit codes mirror verify-meshcat-host.sh -- each failure has a different fix:
#   0  bridge reachable from the host; last stdout line is the ws:// URL
#   2  guest IP could not be discovered      (guest down? wrong network?)
#   3  guest unreachable over SSH            (key? boot not finished?)
#   4  no listener on the bridge port        (not started -- kennel-demo.sh teleop)
#   5  listener is loopback-only             (the documented contingency)
#   6  port answers but it is not rosbridge  (something else took the port)
#   7  listener present but NOT reachable from the host (routing/firewall)

set -uo pipefail

# --- REGION: knobs (same names and defaults as the Meshcat sibling)
GUEST_HOSTNAME="${KENNEL_GUEST_HOSTNAME:-kennel-vm}"   # as it appears in the DHCP lease
LIBVIRT_NET="${KENNEL_LIBVIRT_NET:-default}"
GUEST_USER="${KENNEL_GUEST_USER:-yuuser24}"
SSH_KEY="${KENNEL_SSH_KEY:-$HOME/git/yuruna/test/status/ssh/yuruna_ed25519}"
GUEST_DOMAIN="${KENNEL_VM_DOMAIN:-}"
GUEST_IP="${KENNEL_GUEST_IP:-}"
PORT="${KENNEL_BRIDGE_PORT:-9090}"
WS_TIMEOUT="${KENNEL_WS_TIMEOUT:-10}"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" = 1 ] || echo "$@"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

# --- REGION: hop 2, part 1 -- find the guest on the libvirt NAT network
# Lease-by-hostname is the primary path: `kennel-vm` is the guest's HOSTNAME and
# never the libvirt domain name (meshcat-exposure.md §3.1).
if [ -z "$GUEST_IP" ]; then
    GUEST_IP="$(virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null \
                | awk -v h="$GUEST_HOSTNAME" '$0 ~ h {print $5}' \
                | cut -d/ -f1 | tail -1)"
fi
if [ -z "$GUEST_IP" ] && [ -n "$GUEST_DOMAIN" ]; then
    GUEST_IP="$(virsh domifaddr "$GUEST_DOMAIN" --source lease 2>/dev/null \
                | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)"
fi
if [ -z "$GUEST_IP" ]; then
    fail "could not discover the guest IP on libvirt network '$LIBVIRT_NET'." \
         "Is the guest running?   virsh list --all" \
         "Leases:                 virsh net-dhcp-leases $LIBVIRT_NET" \
         "Override directly with: KENNEL_GUEST_IP=192.168.122.x $0"
    exit 2
fi
say "guest            $GUEST_HOSTNAME at $GUEST_IP (libvirt '$LIBVIRT_NET')"

# --- REGION: hop 1 -- what did rosbridge actually bind, inside the guest?
# --network host means a listener opened in the container is a listener in the
# GUEST's namespace, so `ss` on the guest sees it. Unlike Meshcat's 7000-7099
# scan the port is known -- rosbridge binds exactly what it was told.
listener="$(ssh "${SSH_OPTS[@]}" "$GUEST_USER@$GUEST_IP" \
            "ss -tlnH 2>/dev/null | awk '{print \$4}' | grep -E ':$PORT\$' | sort -u || true" 2>/dev/null)"
ssh_rc=$?
if [ "$ssh_rc" -ne 0 ] && [ -z "$listener" ]; then
    fail "cannot reach the guest over SSH at $GUEST_USER@$GUEST_IP (rc=$ssh_rc)." \
         "Key: $SSH_KEY" \
         "Try: ssh -i $SSH_KEY $GUEST_USER@$GUEST_IP hostname"
    exit 3
fi

if [ -z "$listener" ]; then
    fail "no listener on port $PORT in the guest -- the bridge is not running." \
         "It exists only while something starts it, and nothing does by default:" \
         "  demo/tools/kennel-demo.sh teleop      # launches it beside a running stack" \
         "The stack must be up first (the bridge resolves message types out of the" \
         "sourced workspace). See stack/bridge.md."
    exit 4
fi

# Loopback-only is the documented contingency: with --network host the
# container's loopback IS the guest's loopback, so nothing outside can reach it.
if ! grep -qvE '^(127\.|\[::1\])' <<< "$listener"; then
    fail "the bridge is bound LOOPBACK-ONLY in the guest -- unreachable from the host." \
         "Listeners seen: $(tr '\n' ' ' <<< "$listener")" \
         "The launch file's 'address' argument defaults to every interface, so this" \
         "means it was started some other way. Workaround (SSH tunnel from the host):" \
         "  ssh -i $SSH_KEY -N -L $PORT:127.0.0.1:$PORT $GUEST_USER@$GUEST_IP" \
         "NB 127.0.0.1, NOT localhost -- see vm/meshcat-exposure.md §6.1." \
         "And file it: the binding changed."
    exit 5
fi
say "listener         $(tr '\n' ' ' <<< "$listener") -- non-loopback, port $PORT"

# --- REGION: hop 2, part 2 -- a real WebSocket handshake from the host
# A TCP connect proves nothing here: the question is whether a BROWSER can speak
# rosbridge to it. So this does what the console does -- upgrade, then exchange
# one rosbridge op -- and separates "unreachable" (7) from "not rosbridge" (6).
URL="ws://$GUEST_IP:$PORT/"
probe="$(python3 - "$GUEST_IP" "$PORT" "$WS_TIMEOUT" <<'PY' 2>&1
import base64, json, os, socket, struct, sys

host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])

def frame(payload):
    n = len(payload)
    hdr = b"\x81"
    if n < 126:                 hdr += struct.pack("!B", n | 0x80)
    elif n < 1 << 16:           hdr += struct.pack("!BH", 126 | 0x80, n)
    else:                       hdr += struct.pack("!BQ", 127 | 0x80, n)
    mask = os.urandom(4)
    return hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

try:
    s = socket.create_connection((host, port), timeout=timeout)
except OSError as e:
    print("UNREACHABLE %s" % e); raise SystemExit(0)

try:
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (host, port, key)).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            print("NOTWS handshake closed with no response"); raise SystemExit(0)
        buf += chunk
    status = buf.split(b"\r\n")[0].decode("latin-1", "replace")
    if b"101" not in buf.split(b"\r\n")[0]:
        print("NOTWS handshake refused: %s" % status); raise SystemExit(0)

    # Speak rosbridge, not merely WebSocket. /rosapi/topics is served by the
    # rosapi node the same launch spawns, so a well-formed service_response is
    # proof this is a rosbridge and that the ROS side of it is alive.
    s.sendall(frame(json.dumps({"op": "call_service", "service": "/rosapi/topics",
                                "id": "kennel-probe"}).encode()))
    rest = buf.split(b"\r\n\r\n", 1)[1]
    def recv(n):
        global rest
        while len(rest) < n:
            chunk = s.recv(65536)
            if not chunk: raise ConnectionError("closed mid-frame")
            rest += chunk
        out, rest = rest[:n], rest[n:]
        return out
    b0, b1 = recv(2)
    ln = b1 & 0x7F
    if   ln == 126: ln = struct.unpack("!H", recv(2))[0]
    elif ln == 127: ln = struct.unpack("!Q", recv(8))[0]
    msg = json.loads(recv(ln))
    if msg.get("op") != "service_response":
        print("NOTWS spoke WebSocket but not rosbridge (op=%r)" % msg.get("op")); raise SystemExit(0)
    topics = (msg.get("values") or {}).get("topics") or []
    print("OK %s %d topics visible%s" % (status, len(topics),
          "" if "/quad_control_target" in topics else " (no /quad_control_target -- stack down?)"))
except Exception as e:
    print("NOTWS %s: %s" % (type(e).__name__, e))
finally:
    try: s.close()
    except Exception: pass
PY
)"

case "$probe" in
    OK*)
        say "handshake        ${probe#OK }" ;;
    UNREACHABLE*)
        fail "the listener exists in the guest but the host cannot reach $URL." \
             "  ${probe#UNREACHABLE }" \
             "The host routes to the guest over virbr0; check it is up and unfiltered:" \
             "  ip -br addr show virbr0" \
             "  sudo iptables -L LIBVIRT_FWI -n"
        exit 7 ;;
    *)
        fail "$URL answered, but it is not a rosbridge WebSocket." \
             "  ${probe#NOTWS }" \
             "Something else may hold port $PORT:" \
             "  ssh -i $SSH_KEY $GUEST_USER@$GUEST_IP \"ss -ltnp | grep $PORT\""
        exit 6 ;;
esac

say ""
say "The rosbridge is reachable from this host. Connect the console to:"
echo "$URL"
