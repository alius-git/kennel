"""Acceptance checks for the Dashboard: #61 (truth pass), #62/#63 (the live seam).

Driven by verify-dashboard.sh.
Usage: verify-dashboard.py <servePort> <plainPort> <cdpPort> <meshcatPort>
                           <meshcatAccessLog> <outDir> <bridgePort> <opsLog>
                           <healthyFixture> <fallFixture>

No VM, no ROS, no stack. Everything the page talks to is a real server on
localhost that this suite started, and every claim about what the page DID is
made against bytes those servers recorded -- the fake meshcat's access log, the
fake bridge's op log -- never against a JavaScript variable read back out of the
page under test.

Three properties pull against each other and all three are checked here:

  1. The 3D pane frames the viewer the driver discovered, and ONLY when
     /api/health carried one. A src= attribute nobody fetched would prove the
     string and not the pane, so the witness is the viewer's access log.
  2. Every command any panel names is one that exists -- a kennel-demo.sh verb
     or one of the console's own generated launch blocks. This is the check that
     would have caught `ros2 launch kennel_viz meshcat.launch.py`, a package
     that never existed anywhere.
  3. Served by plain http.server the page is exactly what it was: no iframe, no
     bridge controls, no socket, no errors.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

from cdp import attach

SERVE_PORT = sys.argv[1]
PLAIN_PORT = sys.argv[2]
CDP_PORT = int(sys.argv[3])
MESHCAT_PORT = sys.argv[4]
MESHCAT_LOG = os.path.abspath(sys.argv[5])
OUT = os.path.abspath(sys.argv[6])
BRIDGE_PORT = sys.argv[7]
OPS = os.path.abspath(sys.argv[8])
FIXTURE = os.path.abspath(sys.argv[9])
FALL_FIXTURE = os.path.abspath(sys.argv[10])

ORIGIN = "http://localhost:%s" % SERVE_PORT
PLAIN_ORIGIN = "http://localhost:%s" % PLAIN_PORT
PAGE = "/Kennel%20Console.dc.html"
MESHCAT_URL = "http://localhost:%s/" % MESHCAT_PORT
BRIDGE_URL = "ws://localhost:%s/" % BRIDGE_PORT

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
CONSOLE = os.path.join(HERE, "Kennel Console.dc.html")

ws = attach(CDP_PORT)
ok = True
groups = {}
_group = ""


def group(title):
    global _group
    _group = title
    print("\n" + title)


def check(label, cond, detail=""):
    global ok
    ok = ok and bool(cond)
    groups[_group] = groups.get(_group, [0, 0])
    groups[_group][0] += 1
    groups[_group][1] += 1 if cond else 0
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))


def skip(label, why):
    print(f"  [SKIP] {label} — {why}")


def api(path, origin=ORIGIN):
    with urllib.request.urlopen(origin + path, timeout=10) as r:
        return json.load(r)


def meshcat_hits():
    """GET lines the stand-in viewer has served. The iframe's only footprint."""
    try:
        with open(MESHCAT_LOG, encoding="utf-8", errors="replace") as f:
            return [l for l in f if "GET /" in l]
    except OSError:
        return []


def wait_for(pred, timeout=12, poll=0.2):
    """Watch until it is true (never a bare sleep standing in for a wait)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(poll)
    return pred()


ws.call("Page.enable")
ws.call("Network.enable")
ws.call("Page.addScriptToEvaluateOnNewDocument", source=(
    "window.__errs = [];"
    "window.__sockets = [];"
    "window.addEventListener('error', e => window.__errs.push(String(e.message)));"
    "window.addEventListener('unhandledrejection',"
    " e => window.__errs.push('unhandled rejection: ' + e.reason));"
    "(() => { const N = window.WebSocket;"
    "  window.WebSocket = function (u, p) { window.__sockets.push(String(u));"
    "    return p === undefined ? new N(u) : new N(u, p); };"
    "  window.WebSocket.prototype = N.prototype; })();"))

HELPERS = r"""
if (!window.__sockets) {
  window.__sockets = [];
  const N = window.WebSocket;
  window.WebSocket = function (u, p) { window.__sockets.push(String(u));
    return p === undefined ? new N(u) : new N(u, p); };
  window.WebSocket.prototype = N.prototype;
}
if (!window.__errs) { window.__errs = [];
  window.addEventListener('error', e => window.__errs.push(String(e.message)));
  window.addEventListener('unhandledrejection', e => window.__errs.push('unhandled rejection: ' + e.reason));
}
window.__txt = () => document.body.innerText;
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
// The innermost div carrying exactly this label. Not a no-children matcher:
// every {{ mustache }} is wrapped in a <span>, so that silently matches nothing
// (the trap verify-send.py records for the send button).
window.__btn = re => [...document.querySelectorAll('div')].find(d =>
  !d.querySelector('div') && re.test(d.textContent.trim()));
window.__frames = () => [...document.querySelectorAll('iframe')].map(f => f.getAttribute('src'));
window.__bridgeInput = () => [...document.querySelectorAll('input[type=text]')]
  .find(i => /^(ws|wss):\/\//.test(i.value) || /rosbridge|9090/.test(i.placeholder || ''));
window.__teleopGroup = () => { const i = window.__bridgeInput();
  return i && i.parentElement ? i.parentElement.parentElement : null; };
window.__connectBtn = () => { const g = window.__teleopGroup(); if (!g) return null;
  return [...g.querySelectorAll('div')].find(d => !d.querySelector('div')
    && /^(connect|disconnect) bridge$/.test(d.textContent.trim())) || null; };
// The status bar's own toggle, which owns the DataSource.
window.__connBtn = () => { const all = [...document.querySelectorAll('div')].filter(d =>
    !d.querySelector('div') && /^(connect|disconnect)( bridge)?$/.test(d.textContent.trim()));
  return all.length ? all[all.length - 1] : null; };
// One status-bar item by its uppercase label, as text: "mode", "rtf", "sim t"...
window.__stat = name => { const lab = [...document.querySelectorAll('div')].find(d =>
    !d.querySelector('div') && d.textContent.trim() === name);
  return lab && lab.nextElementSibling ? lab.nextElementSibling.textContent.trim() : null; };
window.__pad = () => [...document.querySelectorAll('div')]
  .find(d => /crosshair/.test(d.getAttribute('style') || ''));
true"""


def goto(origin=ORIGIN, settle=2.2):
    ws.call("Page.navigate", url=origin + PAGE)
    time.sleep(settle)
    ws.js(HELPERS)


def view(name):
    ws.js("__click(%r)" % name)
    time.sleep(0.6)


ws.js(HELPERS)          # the shell navigated Chrome itself; this is that page

# ---------------------------------------------------------------- 1
group("1. the 3D pane frames the viewer /api/health handed it")
health = api("/api/health")
check("/api/health carries the meshcat URL the driver wrote",
      health.get("meshcat") == MESHCAT_URL, str(health.get("meshcat")))
# The shell's own readiness curl is in this log too, so the claim is not "zero
# requests" but "the console added none": the console opens on Compose, and a
# page that framed the viewer on mount would hold a WebGL context on every view.
before = len(meshcat_hits())
time.sleep(1.0)
check("the console framed nothing before the Dashboard was opened",
      len(meshcat_hits()) == before, "%d new requests" % (len(meshcat_hits()) - before))
check("no iframe on Compose", ws.js("__frames().length") == 0)
view("Dashboard")
frames = ws.js("__frames()")
check("exactly one iframe on the Dashboard", frames is not None and len(frames) == 1,
      str(frames))
check("its src is the URL from /api/health, verbatim",
      frames and frames[0] == MESHCAT_URL, str(frames))
check("the viewer was actually loaded, not merely named",
      wait_for(lambda: len(meshcat_hits()) > before),
      "%d requests in the stand-in viewer's access log" % len(meshcat_hits()))
txt = ws.js("__txt()") or ""
check("the pane reports the URL and the pose beneath the frame",
      MESHCAT_URL in txt and "pose" in txt)
check("the old placeholder is gone", "meshcat iframe slot" not in txt)
view("Runs")
check("no iframe on Runs", ws.js("__frames().length") == 0)

# ---------------------------------------------------------------- 2
group("2. no URL, no pane -- and the empty state names a verb that exists")
os.remove(os.path.join(OUT, ".kennel-meshcat"))
check("/api/health now reports no viewer", api("/api/health").get("meshcat") is None)
goto()
view("Dashboard")
check("no iframe", ws.js("__frames().length") == 0)
txt = ws.js("__txt()") or ""
check("the pane says no viewer is attached", "No viewer attached" in txt)
check("and names the verb", "kennel-demo.sh run" in txt)
check("it does not name a package that does not exist",
      "kennel_viz" not in txt and "meshcat.launch.py" not in txt)
# Put it back: the later groups want the pane.
with open(os.path.join(OUT, ".kennel-meshcat"), "w", encoding="utf-8") as f:
    f.write(MESHCAT_URL + "\n")

# ---------------------------------------------------------------- 3
group("3. every command the Dashboard names is one that exists")
with open(CONSOLE, encoding="utf-8") as f:
    src = f.read()
dash = src[src.index('value="{{ isDash }}"'):src.index('value="{{ isRuns }}"')]
named_verbs = set(re.findall(r"kennel-demo\.sh ([a-z]+)", dash))
named_launches = set(l.strip() for l in re.findall(r"ros2 launch [^<\"']+", dash))
# The console's own generated block is the only launch vocabulary it may use:
# read it out of COMMAND_BLOCKS rather than restating it here.
own_launches = set(l.strip() for l in re.findall(
    r"ros2 launch [a-z_]+ [a-z_.]+ sim:=go2", src[src.index("const COMMAND_BLOCKS"):]))
help_verbs = set()
driver = os.path.join(REPO_ROOT, "demo", "tools", "kennel-demo.sh")
if os.path.isfile(driver):
    out = subprocess.run([driver, "help"], capture_output=True, text=True, timeout=60).stdout
    help_verbs = set(re.findall(r"kennel-demo\.sh ([a-z]+)", out))
if help_verbs:
    check("every verb a panel names is a driver verb",
          named_verbs and named_verbs <= help_verbs,
          "named %s; unknown %s" % (sorted(named_verbs), sorted(named_verbs - help_verbs)))
else:
    skip("driver verbs", "demo/tools/kennel-demo.sh not found")
check("every launch a panel names is one the console itself generates",
      named_launches <= own_launches,
      "named %s; not generated %s" % (sorted(named_launches), sorted(named_launches - own_launches)))
check("no panel names a package that does not exist at the pin",
      not re.search(r"kennel_(viz|control|estimation|sim)\b", src),
      "kennel_viz / kennel_control / kennel_estimation / kennel_sim")
check("no panel labels a plot with a topic the pin does not publish",
      not re.search(r"/odom|/imu/data|/cmd_vel|/rosout|/gait/plan|/mpc/solution"
                    r"|/pipeline/diagnostics|/wbc/torque_cmd|/swing/foot_target|/model/estimate", src))

# ---------------------------------------------------------------- 4
group("4. the mode is labelled, and it reads the DataSource in use")
goto()
view("Dashboard")
check("the status bar carries a mode item", ws.js("__stat('mode')") is not None)
check("and it says mock, in the operator's words",
      ws.js("__stat('mode')") == "mock (scripted demo)", str(ws.js("__stat('mode')")))
check("the nav rail agrees about the source", "MockDataSource" in (ws.js("__txt()") or ""))

# ---------------------------------------------------------------- 5
group("5. served by plain http.server the page is what it always was")
goto(PLAIN_ORIGIN)
view("Dashboard")
check("the console booted against a server with no /api/",
      "intervention" in (ws.js("__txt()") or "").lower())
check("no iframe", ws.js("__frames().length") == 0)
check("no bridge controls", ws.js("!!__connectBtn()") is False)
check("the mock joystick still exists", ws.js("!!__pad()"))
check("the mode still says mock", ws.js("__stat('mode')") == "mock (scripted demo)")
check("zero unresolved placeholders", "{{" not in (ws.js("document.body.innerHTML") or ""))
# The empty states are what a paused source shows: the status bar's toggle is
# what pauses it, so this is also the only way to read them at all.
ws.js("__connBtn().click()")
time.sleep(0.8)
txt = ws.js("__txt()") or ""
for label in ("No viewer attached", "No controller heartbeat", "No gait or contact stream",
              "No counters", "No state stream", "No events"):
    check("empty state: %s" % label, label in txt)
check("every empty state names the driver verb", txt.count("kennel-demo.sh run") >= 6,
      "%d occurrences" % txt.count("kennel-demo.sh run"))
check("and the mock ones say the demo is paused",
      txt.count("the scripted demo is paused") >= 5,
      "%d occurrences" % txt.count("the scripted demo is paused"))
check("no console errors", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))
ws.js("__connBtn().click()")

# ---------------------------------------------------------------- 6
group("6. nothing reached off-host, and nothing was dialled")
check("no WebSocket was opened", ws.js("window.__sockets.length") == 0,
      str(ws.js("window.__sockets")))
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            ".filter(n=>!n.startsWith('http://localhost:'))")
check("zero non-localhost requests", not ext, str(ext))

print()
for g in groups:
    n, p = groups[g][0], groups[g][1]
    print("  %-72s %d/%d" % (g, p, n))
print()
print("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)
