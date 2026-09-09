#!/usr/bin/env bash
# Version: 2026.09.09
# Verify the guides: served, rendered, linked from the console shell (#73).
#
#   ./kennel_console/verify-guides.sh [servePort] [plainPort] [cdpPort]
#
# Runs on the HOST. NO VM, NO ROS, NO STACK. Two servers and one throwaway
# headless Chrome with all external DNS blocked, exactly as verify-runs.sh does,
# because the property under test is again FEATURE DETECTION: guides/ sits
# outside the docroot, so serve.py can serve a guide and `python3 -m http.server
# --directory kennel_console` cannot, however it is asked. With serve.py the
# shell has a fourth nav item; with http.server it must have exactly three and
# must behave as it always did.
#
# serve.py's stdout is captured and IS the witness for group 4: an iframe whose
# src attribute nobody fetched proves the string, not the pane. The assertions
# are that the SERVER logged the request.
#
# Group 5 is the one that matters most and reads nothing rendered at all: it
# asserts that guides/first-run.md is EXECUTABLE -- every bash fence is a driver
# verb that exists in `kennel-demo.sh help`, and every click fence names a step
# demo/tools/scenario-page.py actually implements. That is what keeps the page a
# newcomer follows and the page `kennel-demo.sh scenario firstwalk` performs one
# file.
#
# 62 checks. Requires google-chrome; the crops need python3-pil (group 6 SKIPs
# without it).
#
# Exit codes:
#   0  every check passed
#   1  a check failed
#   2  could not run the checks (no google-chrome, a port in use, no guides/)

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
SERVE_PORT="${1:-8111}"
PLAIN_PORT="${2:-8112}"
CDP_PORT="${3:-9311}"
PAGE="Kennel%20Console.dc.html"

if ! command -v google-chrome >/dev/null 2>&1; then
  echo "google-chrome is required to drive the console -- install it, or run verify-serve.sh only."
  exit 2
fi
[[ -d "$REPO_ROOT/guides" ]] || {
  echo "NONZERO SCRIPT EXIT: no guides/ directory at $REPO_ROOT/guides." >&2
  echo "  This suite verifies the guides; without them there is nothing to verify." >&2
  exit 2; }

tmp="$(mktemp -d)"
profile="$tmp/profile"
out="$tmp/kennel-runs"
# A guides directory of the suite's own, for the escaping fixture and for the
# "no guides at all" half of group 3. The repo's own guides/ is what the rest of
# the suite reads.
fixture="$tmp/fixture-guides"
mkdir -p "$profile" "$out" "$fixture"

serve=""; plain=""; chrome=""
cleanup() {
  for p in "$chrome" "$serve" "$plain"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  [[ -n "$chrome" ]] && wait "$chrome" 2>/dev/null
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

python3 "$DIR/serve.py" --port "$SERVE_PORT" --out "$out" --guides "$REPO_ROOT/guides" \
  >"$tmp/serve.log" 2>&1 &
serve=$!
python3 -m http.server "$PLAIN_PORT" --directory "$DIR" >/dev/null 2>&1 &
plain=$!

for port in "$SERVE_PORT" "$PLAIN_PORT"; do
  up=0
  for _ in $(seq 40); do
    curl -sf -o /dev/null "http://localhost:$port/$PAGE" && { up=1; break; }
    sleep 0.25
  done
  [[ "$up" == 1 ]] || {
    echo "NONZERO SCRIPT EXIT: nothing answered on port $port within 10s." >&2
    [[ "$port" == "$SERVE_PORT" ]] && sed 's/^/  serve.py: /' "$tmp/serve.log" >&2
    exit 2; }
done

google-chrome --headless --disable-gpu --no-sandbox \
  --user-data-dir="$profile" \
  --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost" \
  --remote-debugging-port="$CDP_PORT" --window-size=1500,950 \
  "http://localhost:$SERVE_PORT/$PAGE" >/dev/null 2>&1 &
chrome=$!

for _ in $(seq 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25
done
sleep 3   # let the console boot and the mock DataSource settle

python3 "$DIR/verify-guides.py" "$SERVE_PORT" "$PLAIN_PORT" "$CDP_PORT" \
        "$tmp/serve.log" "$fixture"
rc=$?

exit $rc
