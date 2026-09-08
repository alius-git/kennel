#!/usr/bin/env bash
# Operator stand-in for demo-script steps 2-3 (issue #22) — deviation D1.
#
#   p22-console-demo.sh <outdir>
#
# Composes the run in the Kennel Console and clicks Generate run, then unpacks
# the downloaded archive into <outdir>/run-<timestamp>/.
#
# WHAT THIS IS AND IS NOT
#
# It is a pair of hands, not a step. #22 asks for the demo to be performed from
# the written instructions; kennel_console/serve.md 1's serve command is run by
# the operator, in their own terminal, and this script only attaches to the URL
# that command publishes. It makes the same choices in the same controls, and
# lets the browser download for real. It does not generate, compute or inject
# any config — export.md 2.1 requires the bytes to come from the console's own
# emitters, and the only way to keep that true is to touch nothing but the UI.
#
# Knobs (all optional):
#   KENNEL_CONSOLE_URL   http://localhost:8000/Kennel%20Console.dc.html
#   KENNEL_SOLVER        PARTIAL_CONDENSING_OSQP
#   KENNEL_RATE          0.75
#   KENNEL_CDP_PORT      9252
#   KENNEL_MAP           (stock)  flat_plane | obstacle_terrain -- the stress
#                        preset's map (#70). Obstacle terrain is known not to
#                        walk (transfer.md 6.3), which is the point of it.
#   KENNEL_HPIPM_MODE    (stock)  SPEED_ABS | SPEED | BALANCE | ROBUST
#   KENNEL_CONDENSED     (stock)  1..10
#   KENNEL_DISTURBANCES  0        1 composes the fourth block (#68), which is
#                        what scenario s004 needs
#
# Exit 0 = the run folder is on disk and every choice was observed to take.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-}"
[[ -z "$OUT" ]] && { echo "usage: p22-console-demo.sh <outdir>" >&2; exit 2; }

URL="${KENNEL_CONSOLE_URL:-http://localhost:8000/Kennel%20Console.dc.html}"
SOLVER="${KENNEL_SOLVER:-PARTIAL_CONDENSING_OSQP}"
RATE="${KENNEL_RATE:-0.75}"
CDP_PORT="${KENNEL_CDP_PORT:-9252}"
# Empty means "leave it at stock and do not touch the control", which is not the
# same as setting it to the stock value: an untouched control is what every
# composition before these knobs existed produced.
MAP="${KENNEL_MAP:-}"
HPIPM_MODE="${KENNEL_HPIPM_MODE:-}"
CONDENSED="${KENNEL_CONDENSED:-}"
DISTURBANCES="${KENNEL_DISTURBANCES:-0}"

command -v google-chrome >/dev/null 2>&1 || {
  echo "google-chrome is required — it is this script's hands." >&2; exit 2; }

# The serve step belongs to the operator (serve.md 1). Refuse to paper over it:
# starting our own server here would mean the demo never tested that command.
if ! curl -sf -o /dev/null "$URL"; then
  echo "The console is not being served at $URL" >&2
  echo "Run the written step first, in its own terminal:" >&2
  echo "    python3 -m http.server 8000 --directory kennel_console" >&2
  exit 2
fi

mkdir -p "$OUT"
profile="$(mktemp -d)"
downloads="$(mktemp -d)"
chrome=""
cleanup() {
  [[ -n "$chrome" ]] && { kill "$chrome" 2>/dev/null; wait "$chrome" 2>/dev/null; }
  rm -rf "$profile" "$downloads"
}
trap cleanup EXIT

# Same flags as kennel_console/verify-export.sh, including the DNS blackhole:
# serve.md 2 makes offline operation a property of the console, and a demo that
# quietly depended on the network would not be the demo the docs describe.
google-chrome --headless --disable-gpu --no-sandbox \
  --user-data-dir="$profile" \
  --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost" \
  --remote-debugging-port="$CDP_PORT" --window-size=1600,1100 \
  "$URL" >/dev/null 2>&1 &
chrome=$!

for _ in $(seq 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25
done
sleep 3   # let the console boot and the mock DataSource settle (verify-export.sh)

shot="$OUT/02-console-compose.png"
out="$(KENNEL_MAP="$MAP" KENNEL_HPIPM_MODE="$HPIPM_MODE" KENNEL_CONDENSED="$CONDENSED" \
       KENNEL_DISTURBANCES="$DISTURBANCES" \
       python3 "$DIR/p22-console-demo.py" "$CDP_PORT" "$downloads" "$SOLVER" "$RATE" "$shot")"
rc=$?
echo "$out"
[[ $rc -ne 0 ]] && { echo "[p22-console] the console did not accept the composition" >&2; exit 1; }

archive="$(sed -n 's/^ARCHIVE=//p' <<< "$out")"
[[ -f "$archive" ]] || { echo "[p22-console] no archive downloaded" >&2; exit 1; }

# Unzip where the operator would: the archive carries the run-<timestamp>/
# prefix on every entry (export.md 2.2), so this recreates the folder by name.
unzip -q -o "$archive" -d "$OUT" || exit 1
run="$OUT/$(basename "$archive" .zip)"
[[ -d "$run" ]] || { echo "[p22-console] archive did not contain $(basename "$archive" .zip)/" >&2; exit 1; }

echo
echo "[p22-console] run folder: $run"
( cd "$run" && sha256sum ./* )
echo "RUNDIR=$run"
