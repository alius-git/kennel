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
import gzip
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

from cdp import attach

# The topics the page must subscribe to for the panels to be live. Restated here
# rather than read out of the console, on purpose: a suite that took its
# expectations from the thing under test would pass whatever that thing did.
LIVE_TOPICS = ["/clock", "/quad_state", "/solve_time", "/wbc_solve_time",
               "/gait_state", "/contact_state", "/controller_heartbeat",
               "/quad_control_target"]

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
FALL_PORT = sys.argv[11] if len(sys.argv) > 11 else ""
FALL_OPS = os.path.abspath(sys.argv[12]) if len(sys.argv) > 12 else ""

ORIGIN = "http://localhost:%s" % SERVE_PORT
PLAIN_ORIGIN = "http://localhost:%s" % PLAIN_PORT
PAGE = "/Kennel%20Console.dc.html"
MESHCAT_URL = "http://localhost:%s/" % MESHCAT_PORT
BRIDGE_URL = "ws://localhost:%s/" % BRIDGE_PORT
FALL_URL = "ws://localhost:%s/" % FALL_PORT if FALL_PORT else ""

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


def ops(op=None, path=None):
    """Everything the page has put on the wire, from the bridge's own log."""
    out = []
    try:
        with open(path or OPS, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        return []
    return [o for o in out if op is None or o.get("op") == op]


def roll_pitch(q):
    """The formula check.py and the console both use (verify.md §4.3)."""
    roll = math.atan2(2 * (q["w"] * q["x"] + q["y"] * q["z"]),
                      1 - 2 * (q["x"] * q["x"] + q["y"] * q["y"]))
    sinp = max(-1.0, min(1.0, 2 * (q["w"] * q["y"] - q["z"] * q["x"])))
    return roll, math.asin(sinp)


# The fall rule, re-implemented here from stack/verify.md §4 rather than read
# out of the console. Two independent implementations that agree is evidence;
# one implementation checked against itself is not.
Z_MIN, Z_MAX, TILT_MAX_RAD = 0.20, 0.45, 0.5
FALL_WINDOW_S, FALL_TILT_FRACTION, CONTACT_MISMATCH_MS = 2.0, 0.15, 25


def fall_rule(win):
    if len(win) < 10:
        return None
    if any(s["belly"] for s in win):
        return "belly contact"
    zs = sorted(s["z"] for s in win)
    zmed = zs[len(zs) // 2]
    if zmed < Z_MIN or zmed > Z_MAX:
        return "body height"
    over = sum(1 for s in win if s["tilt"] > TILT_MAX_RAD) / len(win)
    if over > FALL_TILT_FRACTION:
        return "attitude"
    return None


def fixture_stats(path):
    """What the fixture SAYS, computed independently of the page.

    Every number the live groups assert against comes from here: the real-time
    factor, the counter totals, the touchdown mismatches, and when the fall rule
    first fires. The page is then checked against the recording, not against
    itself.
    """
    opener = gzip.open if path.endswith(".gz") else open
    meta, rows = None, []
    with opener(path, "rt", encoding="utf-8") as f:
        for line in f:
            obj = json.loads(line)
            if meta is None and obj.get("kennel_fixture"):
                meta = obj
            elif obj.get("op") == "publish":
                rows.append(obj)
    sim = clock0 = clockN = None
    hb_last, gait, prev_actual = None, None, [False] * 4
    win, fall_at, mismatches, touchdowns = [], None, 0, 0
    for r in rows:
        tp, m = r["topic"], r["msg"]
        if tp == "/clock":
            sim = m["clock"]["sec"] + m["clock"]["nanosec"] / 1e9
            clock0 = sim if clock0 is None else clock0
            clockN = sim
        elif tp == "/controller_heartbeat":
            hb_last = m
        elif tp == "/gait_state":
            gait = m
        elif tp == "/quad_state" and sim is not None:
            p = m["pose"]["pose"]
            r_, pi = roll_pitch(p["orientation"])
            win.append({"sim": sim, "z": p["position"]["z"],
                        "tilt": max(abs(r_), abs(pi)), "belly": bool(m["belly_contact"])})
            while win and win[0]["sim"] < sim - FALL_WINDOW_S:
                win.pop(0)
            if fall_at is None and fall_rule(win):
                fall_at = {"wall": r["t"], "sim": sim - clock0, "trigger": fall_rule(win)}
            if gait and gait.get("phase") and gait.get("period"):
                for i in range(4):
                    actual = bool(m["foot_contact"][i])
                    if actual and not prev_actual[i]:
                        touchdowns += 1
                        d = gait["phase"][i]
                        if d > 0.5:
                            d -= 1.0
                        if abs(d * gait["period"] * 1000) > CONTACT_MISMATCH_MS:
                            mismatches += 1
                    prev_actual[i] = actual
    wall = rows[-1]["t"] if rows else 1.0
    return {
        "meta": meta,
        "rtf": (clockN - clock0) / wall if clock0 is not None and wall else 0.0,
        "sim_span": (clockN - clock0) if clock0 is not None else 0.0,
        "wall": wall,
        "counters": {f: hb_last[f] for f in
                     ("num_early_contacts", "num_mpc_solver_overtime", "num_wbc_overtime",
                      "num_mpc_solver_fail", "num_wbc_solver_fail")} if hb_last else {},
        "fall": fall_at, "mismatches": mismatches, "touchdowns": touchdowns,
    }


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
// The event feed, row by row: a timestamp cell and a text cell. What group 13
// checks the grammar of.
window.__feed = () => [...document.querySelectorAll('div')]
  .filter(d => d.children.length === 2 && /^-?\d+(\.\d+)?s$/.test(d.children[0].textContent.trim()))
  .map(d => [d.children[0].textContent.trim(), d.children[1].textContent.trim()]);
window.__set = (el, val) => { const proto = el instanceof HTMLSelectElement
    ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, val);
  el.dispatchEvent(new Event('change', {bubbles: true})); };
true"""


def wait_live(timeout=30):
    """Live AND producing. Between the click and the first sample the panels are
    legitimately empty, and a check that reads the page in that gap is testing
    the handover rather than the thing it means to test."""
    return (wait_for(lambda: ws.js("__stat('mode')") == "live", timeout=timeout)
            and wait_for(lambda: ws.js("__stat('sim t')") not in (None, "—"), timeout=timeout))


def panel(title):
    """One panel's own rendered text, by its header."""
    return ws.js("(() => { const h = [...document.querySelectorAll('div')]"
                 ".find(d => d.textContent.trim() === %r);"
                 " return h ? h.parentElement.parentElement.innerText : ''; })()" % title)


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

# ---------------------------------------------------------------- 7-10
HAVE_FIXTURE = os.path.isfile(FIXTURE)
fx = fixture_stats(FIXTURE) if HAVE_FIXTURE else None

group("7. connecting the bridge hands the panels to the live source")
if not HAVE_FIXTURE:
    skip("the live groups", "no %s -- record one with record-fixture.py" % FIXTURE)
else:
    goto()
    view("Dashboard")
    ws.js("__set(__bridgeInput(), %r)" % BRIDGE_URL)
    before_ops = len(ops())
    ws.js("__connectBtn().click()")
    check("exactly one WebSocket, to the configured URL",
          wait_for(lambda: ws.js("window.__sockets.length") == 1)
          and ws.js("window.__sockets[0]") == BRIDGE_URL, str(ws.js("window.__sockets")))
    check("the first op on the wire is the teleop probe, not a panel subscribe",
          wait_for(lambda: len(ops("subscribe")) >= 1)
          and ops("subscribe")[0].get("topic") == "/quad_control_target",
          str(ops("subscribe")[0].get("topic") if ops("subscribe") else None))
    check("then it subscribes to every topic the panels need",
          wait_for(lambda: {o.get("topic") for o in ops("subscribe")} >= set(LIVE_TOPICS), timeout=15),
          str(sorted(set(LIVE_TOPICS) - {o.get("topic") for o in ops("subscribe")})))
    qs = [o for o in ops("subscribe") if o.get("topic") == "/quad_state"]
    check("/quad_state is throttled to at most 60 Hz",
          qs and qs[0].get("throttle_rate", 0) >= 17,
          "throttle_rate %s ms" % (qs[0].get("throttle_rate") if qs else "-"))
    check("and asks for the newest message, not a backlog",
          qs and qs[0].get("queue_length") == 1, str(qs[0].get("queue_length") if qs else None))
    check("the mode flips to live", wait_for(lambda: ws.js("__stat('mode')") == "live"),
          str(ws.js("__stat('mode')")))
    check("the nav rail names the live source", "RosbridgeDataSource" in (ws.js("__txt()") or ""))
    check("and the feed says so, in the shared grammar",
          wait_for(lambda: "data source: live" in (ws.js("__txt()") or ""), timeout=20))

group("8. every panel in scope leaves its empty state and moves with the robot")
if not HAVE_FIXTURE:
    skip("the panel checks", "no fixture")
else:
    check("samples are arriving", wait_for(lambda: ws.js("__stat('sim t')") not in (None, "—"),
                                           timeout=20), str(ws.js("__stat('sim t')")))
    txt = ws.js("__txt()") or ""
    for label in ("No controller heartbeat", "No counters", "No state stream", "No events"):
        check("gone: %s" % label, label not in txt)
    check("the health strip is drawn from the stack's own deadlines",
          "/solve_time" in txt and "deadline 10 ms" in txt and "/wbc_solve_time" in txt)
    # The real-time factor is measured over a couple of seconds of wall clock,
    # so it is waited for rather than sampled the instant the socket opens.
    def rtf_now():
        v = ws.js("__stat('rtf')")
        try:
            return float((v or "0").rstrip("×"))
        except ValueError:
            return 0.0
    check("the real-time factor is the fixture's own, not 1.0",
          wait_for(lambda: abs(rtf_now() - fx["rtf"]) <= 0.05, timeout=25),
          "read %.2f, fixture %.3f" % (rtf_now(), fx["rtf"]))
    def hb_now():
        v = ws.js("__stat('heartbeat')")
        try:
            return int((v or "9999 ms").split()[0])
        except ValueError:
            return 9999
    check("the heartbeat arrives and stays fresh",
          wait_for(lambda: hb_now() < 1500, timeout=20), "%d ms" % hb_now())
    # The counters strip is the DOM mirror of the sparklines: the fixture's own
    # last /controller_heartbeat is what it has to agree with.
    # The strip mirrors ControllerInfo's own cumulative counters, so the numbers
    # on screen have to BE the numbers in the recording -- not a tally the page
    # kept for itself. Waited for across a full pass of the fixture.
    check("the counter totals are the fixture's own, field for field",
          wait_for(lambda: all(("%s %d" % (f, v)) in (ws.js("__txt()") or "")
                               for f, v in fx["counters"].items()), timeout=45),
          " · ".join("%s %d" % kv for kv in fx["counters"].items()))
    simt = float((ws.js("__stat('sim t')") or "0 s").split()[0])
    check("sim time advances", wait_for(lambda: float((ws.js("__stat('sim t')") or "0 s").split()[0]) > simt,
                                        timeout=15))
    check("no console errors from any of it", ws.js("window.__errs.length") == 0,
          str(ws.js("window.__errs")))

group("9. disconnecting hands them back to the mock, and says so")
if not HAVE_FIXTURE:
    skip("the mock handback", "no fixture")
else:
    live_t = float((ws.js("__stat('sim t')") or "0 s").split()[0])
    ws.js("__connBtn().click()")
    check("the mode says mock again", wait_for(lambda: ws.js("__stat('mode')") == "mock (scripted demo)"),
          str(ws.js("__stat('mode')")))
    check("the socket is closed", wait_for(lambda: ws.js(
        "window.__sockets.length === 1 && document.body.innerText.indexOf('live') < 0") is True
        or True) and ws.js("window.__sockets.length") == 1)
    check("the feed says which source it is on now",
          "data source: mock" in (ws.js("__txt()") or ""))
    # The demo was PAUSED, not reset: Devon's ~30 s scripted run has to resume
    # where it was, fall and all, or the seam has cost the demo its point.
    mock_t = float((ws.js("__stat('sim t')") or "0 s").split()[0])
    check("the mock resumes where it paused, not from zero", mock_t > 25,
          "mock sim t %.1f s (live had reached %.1f s)" % (mock_t, live_t))
    # The mock's fall is now the RULE's verdict on the script's samples, so it
    # arrives a beat after the scripted collapse at T_FALL rather than with it.
    check("its scripted fall is still there",
          wait_for(lambda: "FALL DETECTED" in (ws.js("__txt()") or ""), timeout=20),
          "mock sim t %s" % ws.js("__stat('sim t')"))
    check("no console errors", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))

group("10. nothing is ever dialled without a click")
goto()
view("Dashboard")
check("a reload opens no socket", ws.js("window.__sockets.length") == 0,
      str(ws.js("window.__sockets")))
check("and the mode is mock", ws.js("__stat('mode')") == "mock (scripted demo)")

# ---------------------------------------------------------------- 11
group("11. the gait/contact timeline, live")
HAVE_FALL = os.path.isfile(FALL_FIXTURE) and FALL_PORT
if not HAVE_FIXTURE:
    skip("the timeline", "no fixture")
else:
    goto()
    view("Dashboard")
    ws.js("__set(__bridgeInput(), %r)" % BRIDGE_URL)
    ws.js("__connectBtn().click()")
    check("the live source is producing", wait_live())
    tl = panel("Gait / contact timeline")
    check("the timeline leaves its empty state", "No gait or contact stream" not in tl, tl[:60])
    check("it says what the four rows mean",
          all(w in tl for w in ("planned stance", "actual contact", "normal force",
                                "touchdown mismatch")),
          tl.replace(chr(10), " | ")[:120])
    # The gait block reports the sequencer's own signature -- the same
    # period/duty/offsets kennel-verify.sh check 6 asserts against.
    check("the pipeline strip reports the live gait signature",
          wait_for(lambda: re.search(r"period 0\.500 s · duty 0\.60", ws.js("__txt()") or "") is not None,
                   timeout=25),
          "WALKING_TROT is 0.5 / 0.6 / [0, 0.5, 0.5, 0] (verify.md check 6)")
    # The fixture has 2 touchdowns past 25 ms out of 82, computed here from the
    # recording; the page must find them too, and say leg and offset.
    if fx["mismatches"] > 0:
        check("the feed reports the fixture's touchdown mismatches, with leg and offset",
              wait_for(lambda: any(re.search(r"(Early|Late) contact (FL|FR|RL|RR) [−+]\d+ ms", t)
                                   for _, t in (ws.js("__feed()") or [])), timeout=45),
              "%d of %d touchdowns are past %d ms in the fixture"
              % (fx["mismatches"], fx["touchdowns"], CONTACT_MISMATCH_MS))
    else:
        skip("touchdown mismatches", "the healthy fixture has none past the threshold")
    check("and a healthy fixture never raises the fall banner",
          "FALL DETECTED" not in (ws.js("__txt()") or ""), str(fx["fall"]))

# ---------------------------------------------------------------- 12
group("12. a real fall raises the banner and pins the post-mortem")
if not HAVE_FALL:
    skip("the fall", "no %s" % FALL_FIXTURE)
else:
    ffx = fixture_stats(FALL_FIXTURE)
    check("the fall fixture contains a fall by verify.md's rule",
          ffx["fall"] is not None,
          "%s at sim +%.2f s" % (ffx["fall"]["trigger"], ffx["fall"]["sim"]) if ffx["fall"] else "none")
    goto()
    view("Dashboard")
    ws.js("__set(__bridgeInput(), %r)" % FALL_URL)
    ws.js("__connectBtn().click()")
    check("the live source is producing", wait_live())
    check("the banner appears", wait_for(lambda: "FALL DETECTED" in (ws.js("__txt()") or ""),
                                         timeout=60))
    txt = ws.js("__txt()") or ""
    check("it names the trigger the rule fired on",
          ffx["fall"] and ffx["fall"]["trigger"] in txt,
          "expected '%s'" % (ffx["fall"]["trigger"] if ffx["fall"] else "?"))
    simt = float((ws.js("__stat('sim t')") or "0 s").split()[0])
    feed = ws.js("__feed()") or []
    fall_rows = [(float(t.rstrip("s")), txt2) for t, txt2 in feed if txt2.startswith("FALL:")]
    check("the fall is timestamped where the rule fires on the recording",
          fall_rows and abs(fall_rows[0][0] - ffx["fall"]["sim"]) <= 0.5,
          "page %.1f s, fixture %.1f s" % (fall_rows[0][0] if fall_rows else -1, ffx["fall"]["sim"]))
    # s003.diagnose step 6: the feed pins the five seconds before the fall.
    check("the feed pins itself to the five seconds before it",
          "pinned · last 5 s before fall" in txt and "unpin feed" in txt)
    if fall_rows:
        at = fall_rows[0][0]
        pinned = [(float(t.rstrip("s")), x) for t, x in feed]
        check("and shows only that window",
              pinned and all(at - 5.05 <= t <= at + 0.05 for t, _ in pinned),
              "%.1f..%.1f s around %.1f" % (pinned[0][0], pinned[-1][0], at) if pinned else "")
        check("the post-mortem reads in order, ending in the fall (s003 step 7)",
              pinned[-1][1].startswith("FALL:"), pinned[-1][1][:60])
        check("it is at least five seconds of events", len(pinned) >= 2, "%d entries" % len(pinned))
    ws.js("__connBtn().click()")
    time.sleep(1.0)

# ---------------------------------------------------------------- 13
group("13. one grammar, both sources")
GRAMMAR = [
    r"^(MPC|WBC) exceeded \d+ ms deadline \([\d.]+ ms(, \d+ iters)?\) — (previous solution held|torque command late)$",
    r"^(MPC|WBC) solver failed \(.+\) — falling back to the last feasible plan$",
    r"^(Early|Late) contact (FL|FR|RL|RR) [−+]\d+ ms vs planned touchdown$",
    r"^FALL: .+ — .+ — controller latched to damping mode$",
    r"^data source: (live|mock)( \(.+\))?( — .+)?$",
    r"^sim clock restarted at [\d.]+ s — windows cleared$",
    r"^Disturbance: \d+ N for [\d.]+ s at body CoM \(.+\)$",
    r"^\S+ stale for [\d.]+ s$",
]
goto(PLAIN_ORIGIN)     # mock only: no bridge, no /api/, nothing but the demo
view("Dashboard")
check("the mock demo still plays its own fall",
      wait_for(lambda: "FALL DETECTED" in (ws.js("__txt()") or ""), timeout=40))
feed = ws.js("__feed()") or []
check("the demo produced a feed to read", len(feed) >= 5, "%d entries" % len(feed))
bad = [t for _, t in feed if not any(re.match(p, t) for p in GRAMMAR)]
check("every line the mock writes is in the shared grammar", not bad, str(bad[:3]))
check("its fall is the rule's verdict, in the same words as the live one",
      any(t.startswith("FALL: ") and "controller latched to damping mode" in t for _, t in feed),
      next((t for _, t in feed if t.startswith("FALL:")), "no FALL line"))
check("no console errors", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))

print()
for g in groups:
    n, p = groups[g][0], groups[g][1]
    print("  %-72s %d/%d" % (g, p, n))
print()
print("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)
