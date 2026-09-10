#!/usr/bin/env bash
# Version: 2026.09.09
# Verify the Runs view: real verdicts, real counters, a one-key config diff (#64),
# and a shipped preset's round trip through a run folder the server wrote (#72).
#
#   ./kennel_console/verify-runs.sh [servePort] [plainPort] [cdpPort]
#
# Runs on the HOST. NO VM, NO ROS, NO STACK. The runs are composed by driving
# the console for real -- three sends through serve.py, each with a different
# choice -- and the verify reports beside them are REAL ONES, captured from
# kennel-verify.sh on the live guest and committed under fixtures/. So what the
# table renders is a verdict a controller actually produced, not a literal
# invented for a test.
#
# Both servers, one throwaway headless Chrome, all external DNS blocked, and a
# temp --out so the operator's ~/kennel-runs is never touched. The plain
# http.server half is the point of the pairing: with no host to read runs from,
# the view falls back to the seeded demo history and every row says so.
#
# Group 7 is #72's acceptance and needs this suite's real server: each shipped
# preset is loaded, sent, and then loaded BACK out of the written run folder
# through the Runs view's own `load` -- the round trip is a byte comparison of
# what the emitters produce at both ends.
#
# 84 checks.
#
# Requires google-chrome.
#
# Exit codes:
#   0  every check passed
#   1  a check failed
#   2  could not run the checks (no google-chrome, a port in use, no report fixtures)

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVE_PORT="${1:-8101}"
PLAIN_PORT="${2:-8102}"
CDP_PORT="${3:-9301}"
PAGE="Kennel%20Console.dc.html"

if ! command -v google-chrome >/dev/null 2>&1; then
  echo "google-chrome is required to drive the console -- install it, or run verify-serve.sh only."
  exit 2
fi

for f in verify-completed-osqp.json verify-completed-hpipm.json verify-fell.json; do
  [[ -f "$DIR/fixtures/$f" ]] || {
    echo "NONZERO SCRIPT EXIT: missing report fixture fixtures/$f." >&2
    echo "  These are real kennel-verify.sh reports; see kennel_console/runs.md." >&2
    exit 2
  }
done

tmp="$(mktemp -d)"
profile="$tmp/profile"
out="$tmp/kennel-runs"
mkdir -p "$profile" "$out"

serve=""; plain=""; chrome=""
cleanup() {
  for p in "$chrome" "$serve" "$plain"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  [[ -n "$chrome" ]] && wait "$chrome" 2>/dev/null
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

python3 "$DIR/serve.py" --port "$SERVE_PORT" --out "$out" >"$tmp/serve.log" 2>&1 &
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
    exit 2
  }
done

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

python3 "$DIR/verify-runs.py" "$SERVE_PORT" "$PLAIN_PORT" "$CDP_PORT" "$out"
rc=$?

echo
echo "the run directory ended with: $(ls "$out" | tr '\n' ' ')"
exit $rc
