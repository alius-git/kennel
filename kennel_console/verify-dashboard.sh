#!/usr/bin/env bash
# Version: 2026.09.07
# Verify the Dashboard: the real viewer in the 3D pane, honest empty states, the
# mock/live label, and every panel driven by the live DataSource (#61, #62, #63).
#
#   ./kennel_console/verify-dashboard.sh [servePort] [plainPort] [cdpPort] [bridgePort] [meshcatPort]
#
# Runs on the HOST. NO VM, NO ROS, NO STACK. Three fixtures stand in for the
# guest, and every one of them is a real server on localhost so that what is
# asserted is bytes on a wire rather than a JavaScript variable read back out of
# the page under test:
#
#   fake meshcat      a python3 -m http.server on a temp dir. Its ACCESS LOG is
#                     the witness that the iframe actually loaded the URL --
#                     an src= attribute nobody fetched proves the string, not
#                     the pane. Serving it ourselves is also why the suite needs
#                     no VM and no WebGL: the pane under test is the frame, and
#                     Drake's own viewer is proven separately (vm/meshcat-exposure.md).
#   fake rosbridge    fake-rosbridge.py --replay, feeding recorded fixtures of
#                     the real stack (kennel_console/fixtures/, see dashboard.md)
#   two servers       serve.py and a plain `python3 -m http.server`, because the
#                     property under test is feature detection: with serve.py
#                     the pane and the live source exist, with http.server the
#                     page must be byte-for-byte what it always was.
#
# The bridge URL and the Meshcat URL reach the page the way they do in real use:
# the suite writes <out>/.kennel-bridge and <out>/.kennel-meshcat, which is what
# `kennel-demo.sh teleop` writes, and serve.py reads them per request. The
# hand-off is exercised rather than bypassed.
#
# Requires google-chrome. The fixtures are optional: without them the live
# groups SKIP and groups 1-6 still run.
#
# Exit codes:
#   0  every check passed
#   1  a check failed
#   2  could not run the checks (no google-chrome, a port in use)

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVE_PORT="${1:-8091}"
PLAIN_PORT="${2:-8092}"
CDP_PORT="${3:-9291}"
BRIDGE_PORT="${4:-9491}"
MESHCAT_PORT="${5:-8093}"
PAGE="Kennel%20Console.dc.html"

if ! command -v google-chrome >/dev/null 2>&1; then
  echo "google-chrome is required to drive the console -- install it, or run verify-serve.sh only."
  exit 2
fi

tmp="$(mktemp -d)"
profile="$tmp/profile"
out="$tmp/kennel-runs"
meshroot="$tmp/meshcat"
ops="$tmp/ops.jsonl"
mkdir -p "$profile" "$out" "$meshroot"

# The stand-in viewer. Deliberately not a copy of Drake's page: what the pane has
# to prove is that it frames the URL /api/health handed it, and a one-line
# document makes the access log unambiguous.
cat > "$meshroot/index.html" <<'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>fake meshcat</title></head>
<body style="margin:0;background:#101820;color:#8fc9ea;font:12px monospace">
<div id="marker">fake meshcat — the 3D pane framed this document</div></body></html>
HTML

echo "http://localhost:$MESHCAT_PORT/" > "$out/.kennel-meshcat"
echo "ws://localhost:$BRIDGE_PORT/"    > "$out/.kennel-bridge"

serve=""; plain=""; chrome=""; bridge=""; meshcat=""
cleanup() {
  for p in "$chrome" "$serve" "$plain" "$bridge" "$meshcat"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  [[ -n "$chrome" ]] && wait "$chrome" 2>/dev/null
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

# stderr is http.server's access log: one line per request, which is how group 1
# proves the iframe fetched the document rather than merely naming it.
python3 -m http.server "$MESHCAT_PORT" --directory "$meshroot" \
  >/dev/null 2>"$tmp/meshcat-access.log" &
meshcat=$!

FIXTURE="$DIR/fixtures/healthy.jsonl.gz"
FALL_FIXTURE="$DIR/fixtures/fall.jsonl.gz"
if [[ -f "$FIXTURE" ]]; then
  python3 "$DIR/fake-rosbridge.py" --port "$BRIDGE_PORT" --log "$ops" \
    --replay "$FIXTURE" --loop >"$tmp/bridge.log" 2>&1 &
  bridge=$!
else
  echo "  [SKIP] $FIXTURE is absent -- the live groups will skip."
  python3 "$DIR/fake-rosbridge.py" --port "$BRIDGE_PORT" --log "$ops" >"$tmp/bridge.log" 2>&1 &
  bridge=$!
fi

python3 "$DIR/serve.py" --port "$SERVE_PORT" --out "$out" >"$tmp/serve.log" 2>&1 &
serve=$!
python3 -m http.server "$PLAIN_PORT" --directory "$DIR" >/dev/null 2>&1 &
plain=$!

# Wait for each to answer rather than sleeping at them (demo/dry-run.md F8).
for port in "$SERVE_PORT" "$PLAIN_PORT" "$MESHCAT_PORT"; do
  up=0
  for _ in $(seq 40); do
    curl -sf -o /dev/null "http://localhost:$port/" && { up=1; break; }
    sleep 0.25
  done
  [[ "$up" == 1 ]] || {
    echo "NONZERO SCRIPT EXIT: nothing answered on port $port within 10s." >&2
    [[ "$port" == "$SERVE_PORT" ]] && sed 's/^/  serve.py: /' "$tmp/serve.log" >&2
    exit 2
  }
done
up=0
for _ in $(seq 40); do
  (exec 3<>"/dev/tcp/127.0.0.1/$BRIDGE_PORT") 2>/dev/null && { up=1; exec 3<&-; break; }
  sleep 0.25
done
[[ "$up" == 1 ]] || {
  echo "NONZERO SCRIPT EXIT: the fake bridge never came up on port $BRIDGE_PORT." >&2
  sed 's/^/  fake-rosbridge: /' "$tmp/bridge.log" >&2
  exit 2
}

# The iframe's document is same-origin-ish only in the sense that it is on
# localhost too: the DNS blackhole excludes localhost, so a page that dialled
# anything else is still caught by the zero-non-localhost check.
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

python3 "$DIR/verify-dashboard.py" "$SERVE_PORT" "$PLAIN_PORT" "$CDP_PORT" \
  "$MESHCAT_PORT" "$tmp/meshcat-access.log" "$out" "$BRIDGE_PORT" "$ops" \
  "$FIXTURE" "$FALL_FIXTURE"
rc=$?

echo
echo "the fake meshcat logged $(grep -c 'GET /' "$tmp/meshcat-access.log" 2>/dev/null || echo 0) requests;" \
     "the fake bridge recorded $(wc -l < "$ops") ops."
exit $rc
