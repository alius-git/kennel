#!/usr/bin/env bash
# Verify the exported run folder (issue #19).
#
#   ./kennel_console/verify-export.sh [httpPort] [cdpPort]
#
# Serves the console, drives it in a throwaway headless Chrome profile with all
# external DNS blocked, and lets it download for real into a temp directory.
# What is asserted is the bytes that land on disk: that they equal what the
# generator produced, that one Generate-run click yields a run-<timestamp>/
# folder of four files, and that #18's launch-block constraints survive the trip
# out of the browser. See export.md §4.
#
# Needs no dfki-quad clone — template provenance is verify-generate.sh's job.
#
# Requires google-chrome. Exit 0 = every check passed.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTTP_PORT="${1:-8051}"
CDP_PORT="${2:-9251}"
PAGE="Kennel%20Console.dc.html"

if ! command -v google-chrome >/dev/null 2>&1; then
  echo "google-chrome is required to drive the composer — install it or run verify-serve.sh only."
  exit 2
fi

profile="$(mktemp -d)"
downloads="$(mktemp -d)"
python3 -m http.server "$HTTP_PORT" --directory "$DIR" >/dev/null 2>&1 &
srv=$!
cleanup() {
  kill "$srv" 2>/dev/null
  if [[ -n "${chrome:-}" ]]; then kill "$chrome" 2>/dev/null; wait "$chrome" 2>/dev/null; fi
  rm -rf "$profile" "$downloads"
}
trap cleanup EXIT

for _ in $(seq 20); do
  curl -sf -o /dev/null "http://localhost:$HTTP_PORT/$PAGE" && break || sleep 0.25
done

google-chrome --headless --disable-gpu --no-sandbox \
  --user-data-dir="$profile" \
  --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost" \
  --remote-debugging-port="$CDP_PORT" --window-size=1400,900 \
  "http://localhost:$HTTP_PORT/$PAGE" >/dev/null 2>&1 &
chrome=$!

for _ in $(seq 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25
done
sleep 3   # let the console boot and the mock DataSource settle

python3 "$DIR/verify-export.py" "$HTTP_PORT" "$CDP_PORT" "$downloads"
