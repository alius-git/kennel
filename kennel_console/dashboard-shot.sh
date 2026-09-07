#!/usr/bin/env bash
# Version: 2026.09.07
# Photograph the console: the Dashboard with the real viewer in its 3D pane and
# the live source behind its panels, or the Runs view (#61, #62, #63, #64).
#
# Runs on the HOST, against a console `kennel-demo.sh console` is already
# serving. The render in an implementation record is the one acceptance item
# that cannot be asserted, so -- like p21-meshcat-shot.sh, whose shape this
# follows -- it is at least made reproducible rather than hand-aimed.
#
#   kennel_console/dashboard-shot.sh <output.png> [--view dashboard|runs] [--connect]
#
# --connect clicks `connect bridge` and waits for the page to say `mode · live`
# AND for its sim clock to advance twice, so what is photographed is a page with
# data in it rather than one that has merely opened a socket. `kennel-demo.sh
# teleop` has to have run: that is what puts the ws:// URL in /api/health.
#
# WebGL comes from SwiftShader, as it does in p21-meshcat-shot.sh -- headless
# Chrome has no GPU here, and without those flags the Meshcat iframe renders an
# empty canvas, which looks exactly like "the robot is not in the scene".
#
# PRECONDITIONS, checked rather than assumed:
#   1. google-chrome on the host                              -- exit 2
#   2. a console answering on KENNEL_CONSOLE_URL              -- exit 2
#   3. run from a repo checkout: it imports kennel_console/cdp.py  -- exit 2
#
# Knobs (environment variables):
#   KENNEL_CONSOLE_URL  http://localhost:8000/Kennel%20Console.dc.html
#   KENNEL_CDP_PORT     9331
#   KENNEL_SHOT_WAIT    45     seconds to wait for the page to become live
#
# Exit codes:
#   0  a screenshot was written
#   2  could not even look (a precondition above)
#   3  the page never reached the state asked for (it names what never happened)

set -uo pipefail

OUT="${1:-dashboard-render.png}"
VIEW="dashboard"
CONNECT=0
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --view)    VIEW="$2"; shift 2 ;;
    --connect) CONNECT=1; shift ;;
    *) echo "NONZERO SCRIPT EXIT: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL="${KENNEL_CONSOLE_URL:-http://localhost:8000/Kennel%20Console.dc.html}"
CDP_PORT="${KENNEL_CDP_PORT:-9331}"
WAIT="${KENNEL_SHOT_WAIT:-45}"

say()  { echo "[dashboard-shot] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

command -v google-chrome >/dev/null || { fail "google-chrome is required."; exit 2; }
[ -f "$HERE/cdp.py" ] || {
  fail "run this from a kennel checkout -- it imports the console's CDP client." \
       "Expected: $HERE/cdp.py"; exit 2; }
curl -sf -o /dev/null "$URL" || {
  fail "nothing is serving $URL." "Start one with:  demo/tools/kennel-demo.sh console"; exit 2; }

profile="$(mktemp -d)"
ch=""
cleanup() { [ -n "$ch" ] && kill "$ch" 2>/dev/null; rm -rf "$profile" 2>/dev/null; }
trap cleanup EXIT

google-chrome --headless --disable-gpu --no-sandbox --user-data-dir="$profile" \
  --enable-unsafe-swiftshader --use-gl=swiftshader --window-size=1600,1000 \
  --remote-debugging-port="$CDP_PORT" "$URL" >/dev/null 2>&1 &
ch=$!
for _ in $(seq 60); do curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25; done

OUT="$OUT" VIEW="$VIEW" CONNECT="$CONNECT" CDP_PORT="$CDP_PORT" HERE="$HERE" WAIT="$WAIT" \
python3 - <<'PY'
import base64, os, sys, time
sys.path.insert(0, os.environ["HERE"])
from cdp import attach

ws = attach(int(os.environ["CDP_PORT"]))
wait = float(os.environ["WAIT"])
time.sleep(4)          # the console boots and the mock DataSource settles

ws.js("""
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
window.__stat = name => { const lab = [...document.querySelectorAll('div')].find(d =>
    !d.querySelector('div') && d.textContent.trim() === name);
  return lab && lab.nextElementSibling ? lab.nextElementSibling.textContent.trim() : null; };
window.__bridgeInput = () => [...document.querySelectorAll('input[type=text]')]
  .find(i => /^(ws|wss):\\/\\//.test(i.value) || /rosbridge|9090/.test(i.placeholder || ''));
window.__connectBtn = () => { const i = window.__bridgeInput(); if (!i) return null;
  const g = i.parentElement.parentElement;
  return [...g.querySelectorAll('div')].find(d => !d.querySelector('div')
    && /^connect bridge$/.test(d.textContent.trim())) || null; };
true""")


def hold(pred, why, budget=None):
    """Wait for a state of the PAGE, bounded, and name it if it never comes."""
    deadline = time.time() + (budget or wait)
    while time.time() < deadline:
        if pred():
            return
        time.sleep(0.3)
    print("NONZERO SCRIPT EXIT: %s" % why, file=sys.stderr)
    sys.exit(3)


view = os.environ["VIEW"]
ws.js("__click(%r)" % ("Runs" if view == "runs" else "Dashboard"))
time.sleep(1.0)

if os.environ["CONNECT"] == "1":
    hold(lambda: ws.js("!!__connectBtn()"),
         "the console has no bridge controls -- is it served by serve.py, and has "
         "`kennel-demo.sh teleop` run?")
    ws.js("__connectBtn().click()")
    hold(lambda: ws.js("__stat('mode')") == "live",
         "the page never reached `mode - live` -- is the bridge reachable?")
    # Two distinct sim-clock readings: a page that has opened a socket but is
    # receiving nothing would satisfy the mode check and photograph as empty.
    first = ws.js("__stat('sim t')")
    hold(lambda: ws.js("__stat('sim t')") not in (None, "—", first),
         "the sim clock never advanced -- the bridge is up but nothing is publishing")
    print("[dashboard-shot] mode %s, rtf %s, sim t %s"
          % (ws.js("__stat('mode')"), ws.js("__stat('rtf')"), ws.js("__stat('sim t')")))
    time.sleep(6)      # let the plots fill the window before the shutter

png = base64.b64decode(ws.call("Page.captureScreenshot", format="png")["data"])
with open(os.environ["OUT"], "wb") as f:
    f.write(png)
print("[dashboard-shot] wrote %s (%d bytes)" % (os.environ["OUT"], len(png)))
PY
rc=$?
[ "$rc" = 0 ] && say "done: $OUT"
exit $rc
