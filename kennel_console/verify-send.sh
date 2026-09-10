#!/usr/bin/env bash
# Version: 2026.09.10
# Verify that the console writes its run folder where the driver reads (#56),
# and -- group 7, since #74/#75 -- that the guest's version manifest and drift
# report reach the page and run.json references the manifest.
#
#   ./kennel_console/verify-send.sh [servePort] [plainPort] [cdpPort]
#
# Runs on the HOST. Starts BOTH servers -- serve.py and a plain
# `python3 -m http.server` -- and drives one throwaway headless Chrome across
# both origins with all external DNS blocked. serve.py's --out is a temp
# directory, so nothing here touches the operator's ~/kennel-runs, and the
# downloads land in a second temp directory: what is asserted is bytes on disk,
# never a JavaScript variable. See kennel_console/send.md §4.
#
# Two servers because the property under test is feature detection: with
# serve.py the send button exists and works, with http.server it must not exist
# and must break nothing.
#
# Requires google-chrome.
#
# Exit codes:
#   0  every check passed
#   1  a check failed
#   2  could not run the checks (no google-chrome, a port in use)

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVE_PORT="${1:-8071}"
PLAIN_PORT="${2:-8072}"
CDP_PORT="${3:-9271}"
PAGE="Kennel%20Console.dc.html"

if ! command -v google-chrome >/dev/null 2>&1; then
  echo "google-chrome is required to drive the console -- install it, or run verify-serve.sh only."
  exit 2
fi

tmp="$(mktemp -d)"
profile="$tmp/profile"
downloads="$tmp/downloads"
# Named kennel-runs on purpose: the button's label is built from the last
# segment of --out, and the suite asserts the label an operator would read.
out="$tmp/kennel-runs"
mkdir -p "$profile" "$downloads" "$out"

serve=""; plain=""; chrome=""
cleanup() {
  for p in "$chrome" "$serve" "$plain"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  [[ -n "$chrome" ]] && wait "$chrome" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

python3 "$DIR/serve.py" --port "$SERVE_PORT" --out "$out" >"$tmp/serve.log" 2>&1 &
serve=$!
python3 -m http.server "$PLAIN_PORT" --directory "$DIR" >/dev/null 2>&1 &
plain=$!

# Wait for both to answer rather than sleeping at them (demo/dry-run.md F8).
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

python3 "$DIR/verify-send.py" "$SERVE_PORT" "$PLAIN_PORT" "$CDP_PORT" "$out" "$downloads"
rc=$?

echo
echo "serve.py said:"
sed 's/^/  /' "$tmp/serve.log"
exit $rc
