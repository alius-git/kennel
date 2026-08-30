#!/usr/bin/env bash
# Version: 2026.08.30
# Verify that the console drives the stack over rosbridge (#58).
#
#   ./kennel_console/verify-teleop.sh [servePort] [plainPort] [cdpPort] [bridgePort]
#
# Runs on the HOST. NO VM, NO ROS, NO STACK: the far end is fake-rosbridge.py,
# which records every op the page sends to a JSONL file, so every assertion is
# made against bytes the page actually put on the wire. The real protocol shapes
# are proven separately against the real bridge (stack/bridge.md §5).
#
# Like verify-send.sh it starts BOTH servers -- serve.py and a plain
# `python3 -m http.server` -- and drives one throwaway headless Chrome across
# both origins with external DNS blocked, because the property under test is
# feature detection: with serve.py the controls exist and work, with
# http.server they must not exist and must break nothing.
#
# The bridge URL reaches the page the way it does in real use: serve.py reads it
# from <out>/.kennel-bridge, which `kennel-demo.sh teleop` writes. The suite
# writes that file itself, so the hand-off is exercised rather than bypassed.
#
# Requires google-chrome.
#
# Exit codes:
#   0  every check passed
#   1  a check failed
#   2  could not run the checks (no google-chrome, a port in use)

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVE_PORT="${1:-8081}"
PLAIN_PORT="${2:-8082}"
CDP_PORT="${3:-9281}"
BRIDGE_PORT="${4:-9391}"
# A second fixture, identical but with a publisher already on the topic. The
# console must refuse to drive against it rather than join the fight.
FOREIGN_PORT="$((BRIDGE_PORT + 1))"
PAGE="Kennel%20Console.dc.html"

if ! command -v google-chrome >/dev/null 2>&1; then
  echo "google-chrome is required to drive the console -- install it, or run verify-serve.sh only."
  exit 2
fi

tmp="$(mktemp -d)"
profile="$tmp/profile"
out="$tmp/kennel-runs"
ops="$tmp/ops.jsonl"
foreign_ops="$tmp/ops-foreign.jsonl"
mkdir -p "$profile" "$out"

# What `kennel-demo.sh teleop` writes after it has discovered the guest. serve.py
# reads it per request and reports it in /api/health; the console prefills its
# field from there. Writing it here is the point: the hand-off is under test.
echo "ws://localhost:$BRIDGE_PORT/" > "$out/.kennel-bridge"

serve=""; plain=""; chrome=""; bridge=""; foreign=""
cleanup() {
  for p in "$chrome" "$serve" "$plain" "$bridge" "$foreign"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  [[ -n "$chrome" ]] && wait "$chrome" 2>/dev/null
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

python3 "$DIR/fake-rosbridge.py" --port "$BRIDGE_PORT" --log "$ops" >"$tmp/bridge.log" 2>&1 &
bridge=$!
python3 "$DIR/fake-rosbridge.py" --port "$FOREIGN_PORT" --log "$foreign_ops" --foreign \
  >"$tmp/bridge-foreign.log" 2>&1 &
foreign=$!
python3 "$DIR/serve.py" --port "$SERVE_PORT" --out "$out" >"$tmp/serve.log" 2>&1 &
serve=$!
python3 -m http.server "$PLAIN_PORT" --directory "$DIR" >/dev/null 2>&1 &
plain=$!

# Wait for each to answer rather than sleeping at them (demo/dry-run.md F8).
for port in "$SERVE_PORT" "$PLAIN_PORT"; do
  up=0
  for _ in $(seq 40); do
    curl -sf -o /dev/null "http://localhost:$port/$PAGE" && { up=1; break; }
    sleep 0.25
  done
  [[ "$up" == 1 ]] || {
    echo "NONZERO SCRIPT EXIT: nothing answered on port $port within 10s." >&2
    [[ "$port" == "$SERVE_PORT" ]] && sed 's/^/  serve.py: /' "$tmp/serve.log" >&2
    exit 2
  }
done
for port in "$BRIDGE_PORT" "$FOREIGN_PORT"; do
  up=0
  for _ in $(seq 40); do
    # A TCP connect is enough: the fixture only speaks WebSocket, and the suite's
    # first real check is that the page can upgrade against it.
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { up=1; exec 3<&-; break; }
    sleep 0.25
  done
  [[ "$up" == 1 ]] || {
    echo "NONZERO SCRIPT EXIT: a fake bridge never came up on port $port." >&2
    sed 's/^/  fake-rosbridge: /' "$tmp/bridge.log" "$tmp/bridge-foreign.log" >&2
    exit 2
  }
done

# localhost is excluded from the DNS blackhole, and the fake bridge is on
# localhost -- so a page that dialled anything else would still be caught by the
# zero-non-localhost check in group 11.
google-chrome --headless --disable-gpu --no-sandbox \
  --user-data-dir="$profile" \
  --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost" \
  --remote-debugging-port="$CDP_PORT" --window-size=1400,900 \
  "http://localhost:$SERVE_PORT/$PAGE" >/dev/null 2>&1 &
chrome=$!

for _ in $(seq 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25
done
sleep 3   # let the console boot and the mock DataSource settle

python3 "$DIR/verify-teleop.py" "$SERVE_PORT" "$PLAIN_PORT" "$CDP_PORT" "$BRIDGE_PORT" "$ops" \
  "$FOREIGN_PORT" "$foreign_ops"
rc=$?

echo
echo "the fake bridges recorded $(wc -l < "$ops") and $(wc -l < "$foreign_ops") ops."
exit $rc
