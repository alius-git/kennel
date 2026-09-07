#!/bin/bash
# Version: 2026.09.06
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
# PRECONDITIONS, all five checked rather than assumed (#45). The issue asked for
# the same review as p21-trot-hold.sh; this tool turned out NOT to share that
# tool's defect -- it runs on the host and never touches /tmp/p21-env.sh -- but
# it had undeclared preconditions of its own:
#
#   1. google-chrome on the host                     -- checked, exit 2
#   2. Meshcat reachable from the host               -- checked, exit 2
#   3. RUN FROM A REPO CHECKOUT: it imports the console's CDP client from
#      kennel_console/cdp.py. Copied to /tmp and run there it used to die as
#      "the capture failed (rc=1)", naming nothing -- checked, exit 2
#   4. the Drake scene tree has ARRIVED over the websocket -- waited for by
#      polling for base_link, never by sleeping (was `sleep 6`)
#   5. the scene is LIVE. base_link's displacement is measured over 2 s and
#      always reported, and a frozen scene (under 1 cm) is warned about -- a
#      paused or dead simulator otherwise renders a perfectly valid-looking
#      PNG. Never fatal: an unlabelled still is the problem, not a still.
#
#      This is deliberately NOT a "is it walking?" test, which is what it was
#      first written as. Measured on this stack, a robot standing at STAND
#      still shuffles 5-22 cm/s laterally under the MPC, so no threshold
#      separates standing from trotting without also depending on the composed
#      simulator_realtime_rate. Telling those apart needs the gait from ROS,
#      which is the guest's to read, not this host-side tool's. See
#      stack/composed-run.md 9.2.
#
# Usage:
#   p21-meshcat-shot.sh <output.png> [distance-m] [height-m]
#
# Knobs (environment variables):
#   KENNEL_CDP_PORT     9281   the headless Chrome debugging port
#   KENNEL_SCENE_WAIT   30     seconds to wait for the scene tree to arrive
#
# Exit codes:
#   0  a screenshot was written and it is not a blank frame
#   2  could not even look: no google-chrome, Meshcat unreachable, not run from
#      a repo checkout, or the scene never carried a robot
#   3  the capture came out blank (see the SwiftShader note above)

set -uo pipefail

OUT="${1:-meshcat-walking.png}"
DIST="${2:-2.0}"
HEIGHT="${3:-0.9}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
CDP_PORT="${KENNEL_CDP_PORT:-9281}"
SCENE_WAIT="${KENNEL_SCENE_WAIT:-30}"

say()  { echo "[p21-shot] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

command -v google-chrome >/dev/null || { fail "google-chrome is required to capture the view."; exit 2; }

# Precondition 3. The python below imports the console's CDP client out of the
# repo, so this script cannot be staged to /tmp and run from there the way the
# GUEST-side tools can. Without this check that mistake surfaced as an opaque
# "the capture failed (rc=1)".
[ -f "$REPO_ROOT/kennel_console/cdp.py" ] || {
    fail "run this from a kennel checkout -- it imports the console's CDP client." \
         "Expected: $REPO_ROOT/kennel_console/cdp.py" \
         "This script cannot be copied to /tmp and run there (the guest-side p21 tools can)."
    exit 2
}

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

OUT="$OUT" DIST="$DIST" HEIGHT="$HEIGHT" CDP_PORT="$CDP_PORT" REPO_ROOT="$REPO_ROOT" \
SCENE_WAIT="$SCENE_WAIT" python3 - <<'PY'
import base64, json, math, os, sys, time
sys.path.insert(0, os.path.join(os.environ["REPO_ROOT"], "kennel_console"))
from cdp import attach   # the console's tiny CDP client; same repo, no new dependency

ws = attach(int(os.environ["CDP_PORT"]))
dist, height = float(os.environ["DIST"]), float(os.environ["HEIGHT"])

# Precondition 4: the SCENE, waited for rather than slept through. Chrome serves
# the page immediately, but the Drake scene tree arrives afterwards over the
# websocket -- and the camera cannot be aimed at a robot that is not there yet.
# This replaced a `sleep 6`; dry-run.md F8's rule is not only for guest tools.
POS_JS = """
(() => {
  const v = window.viewer; if (!v) return '';
  const ill = v.scene.getObjectByName('illustration'); if (!ill) return '';
  let base = null;
  ill.traverse(o => { if (!base && /^base_link$/.test(o.name)) base = o; });
  if (!base) return '';
  const at = new MeshCat.THREE.Vector3();
  base.getWorldPosition(at);
  return JSON.stringify({x: at.x, y: at.y, z: at.z});
})()"""

def base_link_pos():
    r = ws.js(POS_JS)
    return json.loads(r) if isinstance(r, str) and r.startswith("{") else None

deadline, p0 = time.time() + float(os.environ["SCENE_WAIT"]), None
while time.time() < deadline:
    p0 = base_link_pos()
    if p0:
        break
    time.sleep(0.5)
if not p0:
    sys.exit("the Meshcat scene never carried a base_link within "
             f"{os.environ['SCENE_WAIT']}s -- the viewer is up but the robot is not in it. "
             "Is the simulator running?  demo/tools/kennel-demo.sh status")
print("[p21-shot] scene ready     base_link is in the scene")

# Precondition 5: is the scene LIVE? Measured, reported, and warned about only
# when it is unambiguous -- see the header for why this is not a walking test.
time.sleep(2.0)
p1 = base_link_pos() or p0
moved = math.dist((p0["x"], p0["y"], p0["z"]), (p1["x"], p1["y"], p1["z"]))
print(f"[p21-shot] scene motion    {moved * 100:.1f} cm in 2 s")
if moved < 0.01:
    print("[p21-shot] WARNING: base_link has not moved -- the scene looks FROZEN.")
    print("[p21-shot]          A paused or dead simulator still renders a valid-looking PNG.")
    print("[p21-shot]          Check the stack:  demo/tools/kennel-demo.sh status")

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
print(f"[p21-shot] base_link at    {res}")
# The one wait here that is NOT an observation, and it is deliberate: there is
# no signal for "the re-aimed frame has been rendered". Meshcat renders on its
# own rAF loop and exposes no completion event, so this is a settle, recorded as
# a bypass in stack/composed-run.md 9.2 rather than dressed up as a check. The
# blank-frame guard below is what actually catches a bad capture.
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
