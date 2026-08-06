#!/usr/bin/env bash
# Verify the generated configs and launch block (issue #18).
#
#   ./kennel_console/verify-scope.sh [httpPort] [cdpPort]
#
# Serves the console, drives it in a throwaway headless Chrome profile with all
# external DNS blocked, and asserts that Generate run emits configs the pinned
# stack would accept: the pin's stock files with only composed fields changed,
# ROS-correct types, both map keys, a one-line diff per non-stock choice, and a
# three-shell launch block carrying no mpc_*:= arguments. See generate.md §4.
#
# The stock-file comparison needs the gitignored dfki-quad clone; without it
# that group SKIPs and the rest still runs.
#
# Requires google-chrome. Exit 0 = every check passed.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTTP_PORT="${1:-8050}"
CDP_PORT="${2:-9250}"
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

python3 "$DIR/verify-generate.py" "$HTTP_PORT" "$CDP_PORT"
