#!/usr/bin/env bash
# Verify the composer exposes only the MVP scope (issue #17).
#
#   ./kennel_console/verify-scope.sh [httpPort] [cdpPort]
#
# Serves the console, drives it in a throwaway headless Chrome profile with all
# external DNS blocked, and asserts every acceptance criterion of #17: the map
# picker offers two cards, the solver select emits the canonical parameter
# strings, solver-dependent fields appear only where the pin consumes them,
# out-of-scope stages are visible-but-fixed, and a pre-#17 preset cannot smuggle
# a removed option back in. See composer-scope.md §4.
#
# Requires google-chrome. Exit 0 = every check passed.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTTP_PORT="${1:-8020}"
CDP_PORT="${2:-9226}"
PAGE="Kennel%20Console.dc.html"

if ! command -v google-chrome >/dev/null 2>&1; then
  echo "google-chrome is required to drive the composer — install it or run verify-serve.sh only."
  exit 2
fi

profile="$(mktemp -d)"
python3 -m http.server "$HTTP_PORT" --directory "$DIR" >/dev/null 2>&1 &
srv=$!
cleanup() {
  kill "$srv" 2>/dev/null
  if [[ -n "${chrome:-}" ]]; then kill "$chrome" 2>/dev/null; wait "$chrome" 2>/dev/null; fi
  rm -rf "$profile"
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

python3 "$DIR/verify-scope.py" "$HTTP_PORT" "$CDP_PORT"
