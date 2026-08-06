#!/bin/bash
# Version: 2026.08.06
# Kennel -- issue #21: photograph the walking robot in Meshcat, from the host.
#
# Runs on the HOST. Issue #21's acceptance evidence includes "Meshcat screenshot
# of the walking robot", and a screenshot is the one acceptance item that cannot
# be asserted -- so it is at least made reproducible rather than hand-aimed.
#
# Three things have to be arranged, and none of them is obvious:
#
#   1. Meshcat's default camera frames the WORLD ORIGIN, and the robot leaves it.
#      At 0.3 m/s it is 10 m away after half a minute of trotting -- a speck near
#      the horizon. The camera is aimed at the robot's CURRENT position instead.
#   2. That position is taken from the SCENE GRAPH (base_link's world transform),
#      not from /quad_state over SSH. Both describe the same robot, but only the
#      scene-graph one is already in the frame the camera lives in -- see 3.
#   3. `viewer.camera` sits under a "rotated" parent: Meshcat is Y-up, the Drake
#      scene is Z-up, and that parent is the bridge. Camera positions must
#      therefore be converted with `camera.parent.worldToLocal()`. Setting
#      camera.position to a Z-up world coordinate directly puts the camera under
#      the ground plane, looking up at the robot's underside.
#
# Headless Chrome has no GPU here, so WebGL comes from SwiftShader
# (--use-gl=swiftshader). Without it the canvas renders empty, and the failure
# looks exactly like "the robot is not in the scene".
#
# Usage:
#   p21-meshcat-shot.sh <output.png> [distance-m] [height-m]
#
# Exit codes:
#   0  a screenshot was written and it is not a blank frame
#   2  Meshcat unreachable, or the robot is not in the scene
#   3  the capture came out blank (see the SwiftShader note above)

set -uo pipefail

OUT="${1:-meshcat-walking.png}"
DIST="${2:-2.0}"
HEIGHT="${3:-0.9}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
CDP_PORT="${KENNEL_CDP_PORT:-9281}"

say()  { echo "[p21-shot] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

command -v google-chrome >/dev/null || { fail "google-chrome is required to capture the view."; exit 2; }

# Reuse #11's discovery rather than restating the two hops.
URL="$("$REPO_ROOT/vm/test/verify-meshcat-host.sh" --quiet 2>/dev/null | tail -1)"
case "$URL" in
    http://*) ;;
    *) fail "Meshcat is not reachable from this host." \
            "Diagnose it with: vm/test/verify-meshcat-host.sh"; exit 2 ;;
esac
say "meshcat          $URL"

profile="$(mktemp -d)"
cleanup() { [ -n "${ch:-}" ] && kill "$ch" 2>/dev/null; rm -rf "$profile" 2>/dev/null; }
trap cleanup EXIT

google-chrome --headless --disable-gpu --no-sandbox --user-data-dir="$profile" \
  --enable-unsafe-swiftshader --use-gl=swiftshader --window-size=1280,800 \
  --remote-debugging-port="$CDP_PORT" "$URL" >/dev/null 2>&1 &
ch=$!
for _ in $(seq 60); do curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25; done
sleep 6   # let the scene tree arrive over the websocket before touching the camera

OUT="$OUT" DIST="$DIST" HEIGHT="$HEIGHT" CDP_PORT="$CDP_PORT" REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import base64, os, sys, time
sys.path.insert(0, os.path.join(os.environ["REPO_ROOT"], "kennel_console"))
from cdp import attach   # the console's tiny CDP client; same repo, no new dependency

ws = attach(int(os.environ["CDP_PORT"]))
dist, height = float(os.environ["DIST"]), float(os.environ["HEIGHT"])

if ws.js("typeof window.viewer") != "object":
    sys.exit("meshcat viewer object absent -- is this a Meshcat page?")

# Aim from behind and to one side so the gait reads as a gait: a head-on shot
# hides the diagonal leg pairing that makes a trot recognisable.
res = ws.js(f"""
(() => {{
  const v = window.viewer, cam = v.camera, THREE = MeshCat.THREE;
  const ill = v.scene.getObjectByName('illustration');
  if (!ill) return 'no illustration group';
  let base = null;
  ill.traverse(o => {{ if (!base && /^base_link$/.test(o.name)) base = o; }});
  if (!base) return 'no base_link';

  const at = new THREE.Vector3();
  base.getWorldPosition(at);

  // Frame-agnostic aiming. Which axis is "up" here is genuinely ambiguous --
  // Meshcat is Y-up, Drake is Z-up, and the scene is bridged by the camera's
  // "rotated" parent -- so instead of hard-coding either convention, KEEP THE
  // DEFAULT CAMERA'S OWN DIRECTION and just re-centre it on the robot at the
  // requested distance. The default view is already a sensible 3/4 elevation,
  // and this cannot put the camera under the ground plane whichever axis is up.
  const eye0 = new THREE.Vector3(), at0 = new THREE.Vector3();
  cam.getWorldPosition(eye0);
  if (v.controls && v.controls.target) at0.copy(v.controls.target); // controls' frame
  const dir = eye0.clone().sub(at0);
  if (dir.length() < 1e-6) dir.set(0, 1, 3);
  dir.normalize().multiplyScalar({dist});
  // Lift slightly along the same up the default view uses.
  const eye = at.clone().add(dir).add(cam.up.clone().normalize().multiplyScalar({height}));

  const eyeLocal = cam.parent ? cam.parent.worldToLocal(eye.clone()) : eye;
  const atLocal  = cam.parent ? cam.parent.worldToLocal(at.clone())  : at;

  cam.position.copy(eyeLocal);
  if (v.controls && v.controls.target) {{ v.controls.target.copy(atLocal); v.controls.update(); }}
  cam.lookAt(atLocal);
  cam.updateProjectionMatrix();
  v.needs_render = true;
  if (v.render) v.render();
  return JSON.stringify({{x: +at.x.toFixed(3), y: +at.y.toFixed(3), z: +at.z.toFixed(3)}});
}})()""")

if not res.startswith("{"):
    sys.exit(f"could not aim the camera: {res}")
print(f"[p21-shot] base_link at     {res}")
time.sleep(2.5)

png = base64.b64decode(ws.call("Page.captureScreenshot", format="png")["data"])
open(os.environ["OUT"], "wb").write(png)
PY
rc=$?
[ "$rc" = 0 ] || { fail "the capture failed (rc=$rc)."; exit 2; }

# A blank SwiftShader frame compresses to almost nothing. Catch it here rather
# than letting a featureless PNG become the acceptance evidence.
size="$(stat -c%s "$OUT" 2>/dev/null || echo 0)"
if [ "$size" -lt 20000 ]; then
    fail "the screenshot is $size bytes -- almost certainly a blank frame." \
         "The WebGL context probably failed; check the --use-gl=swiftshader flag."
    exit 3
fi
say "wrote            $OUT ($size bytes)"
