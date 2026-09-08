"""Acceptance checks for issue #58 — the console drives the stack over rosbridge.

Driven by verify-teleop.sh.
Usage: verify-teleop.py <servePort> <plainPort> <cdpPort> <bridgePort> <opsLog>
                        <foreignPort> <foreignOpsLog>
                        <gaitPort> <gaitOpsLog> <fallPort> <fallOpsLog>
                        <healthyPort> <healthyOpsLog>

Groups 1-12 are #58's and are unchanged. Groups 13-17 are #66: `reset sim` as a
real /reset_sim call in the sequence the live stack forced, and a gait picker
that says `active` or `refused` because it read /gait_state -- never just `sent`.
Groups 18-21 are #68: `inject` as a real /disturb_simulation call, gated on what
the newest run composed, and never awaited.

No VM, no ROS, no stack: the far end is fake-rosbridge.py, and every assertion
is made against THE BYTES THE PAGE SENT (the ops log on disk), never against a
JavaScript variable read back out of the page under test.

Three properties pull against each other and all three are checked here:

  1. Connecting is a CLICK, never a page load. A console that dialled the guest
     on mount would open an off-host socket on every open, and the suites'
     zero-non-localhost rule exists precisely to keep that from happening
     quietly. So: zero WebSockets until the button is pressed, exactly one after.
  2. What goes on the wire is what the stack accepts: all six QuadControlTarget
     fields on every message, world_z never absent (the silent trap of
     launch.md §4.2), 20 Hz, ramped at joy_to_target's own acceleration limit,
     and zeros after a release rather than silence.
  3. Served by plain http.server the page is exactly what it was before this
     issue: no controls, no socket, no unresolved placeholders.
"""
import json
import os
import re
import sys
import time

from cdp import attach

SERVE_PORT = sys.argv[1]
PLAIN_PORT = sys.argv[2]
CDP_PORT = int(sys.argv[3])
BRIDGE_PORT = sys.argv[4]
OPS = os.path.abspath(sys.argv[5])
FOREIGN_PORT = sys.argv[6]
FOREIGN_OPS = os.path.abspath(sys.argv[7])
GAIT_PORT = sys.argv[8]
GAIT_OPS = os.path.abspath(sys.argv[9])
FALL_PORT = sys.argv[10]
FALL_OPS = os.path.abspath(sys.argv[11])
HEALTHY_PORT = sys.argv[12]
HEALTHY_OPS = os.path.abspath(sys.argv[13])
FOREIGN_URL = "ws://localhost:%s/" % FOREIGN_PORT
GAIT_URL = "ws://localhost:%s/" % GAIT_PORT
FALL_URL = "ws://localhost:%s/" % FALL_PORT
HEALTHY_URL = "ws://localhost:%s/" % HEALTHY_PORT
RESET_SRV = "/reset_sim"
RESET_TYPE = "interfaces/srv/ResetSimulation"
UNDAMP_SRV = "/set_damping_mode"
DISTURB_SRV = "/disturb_simulation"
DISTURB_TYPE = "interfaces/srv/DisturbSim"
PARAM_SRV = "/mit_controller_node/set_parameters"
ORIGIN = "http://localhost:%s" % SERVE_PORT
PAGE = "/Kennel%20Console.dc.html"
BRIDGE_URL = "ws://localhost:%s/" % BRIDGE_PORT
TOPIC = "/quad_control_target"
FIELDS = {"body_x_dot", "body_y_dot", "world_z", "hybrid_theta_dot", "pitch", "roll"}
HZ = 20
MAX_ACC = 0.5

ws = attach(CDP_PORT)
ok = True


def check(label, cond, detail=""):
    global ok
    ok = ok and bool(cond)
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))


def ops(op=None, path=None):
    """Everything the page has sent so far, newest last."""
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


def wait_for(pred, timeout=12, poll=0.2):
    """Watch the ops log until it says what we are waiting for (never a sleep)."""
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
    # Count sockets from inside the page as well as from CDP: two independent
    # witnesses to the same claim, and the one that survives a CDP event drop.
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
window.__teleopGroup = () => { const i = window.__bridgeInput();
  return i && i.parentElement ? i.parentElement.parentElement : null; };
window.__connectBtn = () => { const g = window.__teleopGroup(); if (!g) return null;
  return [...g.querySelectorAll('div')].find(d => !d.querySelector('div')
    && /^(connect|disconnect) bridge$/.test(d.textContent.trim())) || null; };
window.__standBtn = () => window.__btn(/^STAND$/);
window.__estopBtn = () => window.__btn(/^E-STOP$/);
window.__bridgeInput = () => [...document.querySelectorAll('input[type=text]')]
  .find(i => /^(ws|wss):\/\//.test(i.value) || /rosbridge|9090/.test(i.placeholder || ''));
window.__gaitSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => o.value === 'WALKING_TROT'));
// One Interventions number input, by the label above it: the field column is
// <div><div>LABEL</div><input></div>, the same shape the velocity fields use.
window.__numInput = label => { const col = [...document.querySelectorAll('div')]
  .find(d => d.children.length === 2 && d.children[0].textContent.trim() === label
             && d.querySelector('input[type=number]'));
  return col ? col.querySelector('input[type=number]') : null; };
window.__injectBtn = () => window.__btn(/^inject$/);
window.__pad = () => [...document.querySelectorAll('div')]
  .find(d => /crosshair/.test(d.getAttribute('style') || ''));
window.__set = (el, val) => { const proto = el instanceof HTMLSelectElement
    ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, val);
  el.dispatchEvent(new Event('change', {bubbles: true})); };
// Pointer events on the pad, in the pad's own coordinates: -1..1 in each axis.
window.__stick = (nx, ny, type) => { const p = window.__pad();
  const r = p.getBoundingClientRect();
  const ev = new PointerEvent(type, {bubbles: true, pointerId: 1,
    clientX: r.left + r.width / 2 * (1 + nx), clientY: r.top + r.height / 2 * (1 + ny)});
  p.setPointerCapture = () => {}; p.dispatchEvent(ev); return true; };
true"""


def goto(origin):
    ws.call("Page.navigate", url=origin + PAGE)
    time.sleep(2.2)
    ws.js(HELPERS)


def dash():
    """The teleop controls live on the Dashboard."""
    ws.js("__click('Dashboard')")
    time.sleep(0.6)


print("1. the controls appear only when a kennel server is answering")
goto(ORIGIN)
dash()
check("the console booted against serve.py",
      "intervention" in (ws.js("__txt()") or "").lower())
check("a connect button is present", ws.js("!!__connectBtn()"))
check("a gait picker carrying the node's gaits", ws.js(
    "(() => { const s = __gaitSel(); return !!s && "
    "['STAND','WALKING_TROT','TROT','FLYING_TROT','PRONK'].every("
    "v => [...s.options].some(o => o.value === v)); })()"),
      "including TROT/FLYING_TROT, which the upstream gamepad cannot reach")
check("the bridge URL was prefilled from /api/health", ws.js(
    "(() => { const i = __bridgeInput(); return i ? i.value : ''; })()") == BRIDGE_URL,
      ws.js("(() => { const i = __bridgeInput(); return i ? i.value : ''; })()"))
check("zero unresolved placeholders", "{{" not in (ws.js("document.body.innerHTML") or ""))

print("2. nothing is dialled until the operator asks")
check("no WebSocket opened on load", ws.js("window.__sockets.length") == 0,
      str(ws.js("window.__sockets")))
check("the ops log is empty", len(ops()) == 0)

print("3. connect: it listens before it speaks")
ws.js("__connectBtn().click()")
check("exactly one WebSocket, to the configured URL",
      wait_for(lambda: ws.js("window.__sockets.length") == 1)
      and ws.js("window.__sockets[0]") == BRIDGE_URL,
      str(ws.js("window.__sockets")))
check("it subscribes before advertising", wait_for(lambda: bool(ops("subscribe"))))
sub = ops("subscribe")[0] if ops("subscribe") else {}
check("the probe subscribes to the target topic", sub.get("topic") == TOPIC, sub.get("topic", ""))
check("no publish during the probe window",
      not [o for o in ops("publish") if o["t"] < (ops("advertise")[0]["t"] if ops("advertise") else 1e18)],
      "the page must not publish into a topic it has not finished listening to")
check("then it advertises, with the stack's own type",
      wait_for(lambda: bool(ops("advertise")))
      and ops("advertise")[0].get("type") == "interfaces/msg/QuadControlTarget",
      ops("advertise")[0].get("type", "") if ops("advertise") else "never advertised")
check("and unsubscribes the probe", bool(ops("unsubscribe")))

print("4. what goes on the wire")
check("publishing starts", wait_for(lambda: len(ops("publish")) >= 10))
pubs = ops("publish")
check("every message carries all six fields, and world_z is never absent",
      all(set(o["msg"].keys()) == FIELDS for o in pubs),
      "a message without world_z commands the body to the ground (launch.md §4.2)")
check("world_z is the composed height, not a default",
      all(abs(o["msg"]["world_z"] - 0.30) < 1e-9 for o in pubs), "0.30")
check("zeros are published, not silence",
      all(o["msg"]["body_x_dot"] == 0.0 for o in pubs[:8]),
      "the controller consumes the latest target every cycle; silence is not a stop")
span = pubs[-1]["t"] - pubs[0]["t"]
rate = (len(pubs) - 1) / span if span > 0 else 0
check("published at 20 Hz ± 2", 18 <= rate <= 22, "%.1f Hz over %.1f s" % (rate, span))

print("5. the stick drives it, and the ramp is joy_to_target's")
base = len(ops("publish"))
ws.js("__stick(0, -1, 'pointerdown')")
check("pushing the stick forward raises the target",
      wait_for(lambda: any(o["msg"]["body_x_dot"] > 0.05 for o in ops("publish")[base:])))
ramp = [o["msg"]["body_x_dot"] for o in ops("publish")[base:]]
check("it ramps rather than steps", ramp and max(ramp) > 0.05 and ramp[0] < 0.20,
      "first %.3f → max %.3f m/s" % (ramp[0] if ramp else -1, max(ramp) if ramp else -1))
steps = [abs(b - a) for a, b in zip(ramp, ramp[1:])]
check("no step exceeds max_acceleration / rate",
      not steps or max(steps) <= (MAX_ACC / HZ) + 1e-6,
      "largest %.4f m/s per tick, limit %.4f" % (max(steps) if steps else 0, MAX_ACC / HZ))
check("it saturates at the configured max v, not beyond",
      wait_for(lambda: any(abs(o["msg"]["body_x_dot"] - 0.5) < 0.02
                           for o in ops("publish")[base:]), timeout=8),
      "max seen %.3f" % max([o["msg"]["body_x_dot"] for o in ops("publish")[base:]] or [0]))

print("6. releasing the stick returns the target to zero")
rel = len(ops("publish"))
ws.js("__stick(0, -1, 'pointerup')")
check("the target reaches zero after a release",
      wait_for(lambda: any(o["msg"]["body_x_dot"] == 0.0 for o in ops("publish")[rel:]), timeout=8))
check("and keeps publishing zeros afterwards",
      wait_for(lambda: len([o for o in ops("publish")[rel:] if o["msg"]["body_x_dot"] == 0.0]) >= 5))

print("7. gait, STAND and E-STOP are service calls with the stack's payloads")
ws.js("__set(__gaitSel(), 'WALKING_TROT')")
check("the gait picker calls SetParameters", wait_for(lambda: bool(ops("call_service"))))
calls = ops("call_service")
gait = [c for c in calls if c.get("service") == "/mit_controller_node/set_parameters"]
check("on the controller node's own service", bool(gait))
check("with the parameter the node reads", gait and
      gait[-1]["args"]["parameters"][0]["name"] == "simple_gait_sequencer.gait",
      gait[-1]["args"]["parameters"][0]["name"] if gait else "")
check("as a string ParameterValue (type 4)", gait and
      gait[-1]["args"]["parameters"][0]["value"] == {"type": 4, "string_value": "WALKING_TROT"},
      json.dumps(gait[-1]["args"]["parameters"][0]["value"]) if gait else "")
check("the page says 'sent', never 'active'",
      wait_for(lambda: "sent" in (ws.js("__txt()") or "")) and
      "gait WALKING_TROT active" not in (ws.js("__txt()") or ""),
      "SetParameters reports success even for a gait the node rejects (verify.md §4.4)")

nb = len(ops("call_service"))
ws.js("__standBtn().click()")
check("STAND commands the gait and zeroes the target",
      wait_for(lambda: any(c["args"]["parameters"][0]["value"]["string_value"] == "STAND"
                           for c in ops("call_service")[nb:]
                           if c.get("service", "").endswith("set_parameters"))))
zb = len(ops("publish"))
check("the zero goes out immediately, not on the next tick",
      wait_for(lambda: any(o["msg"]["body_x_dot"] == 0.0 for o in ops("publish")[zb:]), timeout=3))

nb = len(ops("call_service"))
ws.js("__estopBtn().click()")
check("E-STOP calls the damping trigger",
      wait_for(lambda: any(c.get("service") == "/set_emergency_damping_mode"
                           for c in ops("call_service")[nb:])))
es = [c for c in ops("call_service")[nb:] if c.get("service") == "/set_emergency_damping_mode"]
check("as a std_srvs/srv/Trigger", es and es[0].get("type") == "std_srvs/srv/Trigger",
      es[0].get("type", "") if es else "")

print("8. the dead man's switch: leaving the page zeroes the target first")
ws.js("__stick(0, -1, 'pointerdown')")
wait_for(lambda: any(o["msg"]["body_x_dot"] > 0.1 for o in ops("publish")[-10:]), timeout=6)
check("the robot is being driven before we leave",
      any(o["msg"]["body_x_dot"] > 0.1 for o in ops("publish")[-10:]),
      "%.3f m/s" % ops("publish")[-1]["msg"]["body_x_dot"])
ws.call("Page.navigate", url=ORIGIN + PAGE)     # a real unload
time.sleep(2.0)
last = ops("publish")[-1]["msg"] if ops("publish") else {}
check("the last message the bridge ever received is a zero",
      last.get("body_x_dot") == 0.0 and last.get("body_y_dot") == 0.0
      and last.get("hybrid_theta_dot") == 0.0,
      json.dumps(last))
check("it unadvertised on the way out", bool(ops("unadvertise")))

print("9. no console errors from any of it")
ws.js(HELPERS)
check("no uncaught errors", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))

print("10. a bridge with somebody already publishing is refused, not joined")
# Two publishers on this topic do not merge: the controller consumes the latest
# message every cycle, so a held trot (p21-trot-hold.sh) or a kennel-verify.sh
# walk phase and a driving browser alternate, and the robot jitters between two
# speeds. `kennel-demo.sh teleop` stops the one it knows about; this probe is
# what catches the rest.
goto(ORIGIN)
dash()
ws.js("__set(__bridgeInput(), %r)" % FOREIGN_URL)
ws.js("__connectBtn().click()")
check("it still subscribes first",
      wait_for(lambda: bool(ops("subscribe", FOREIGN_OPS))))
check("but never advertises", not wait_for(
    lambda: bool(ops("advertise", FOREIGN_OPS)), timeout=4),
      "advertising would put a second publisher on the topic")
check("and never publishes", not ops("publish", FOREIGN_OPS),
      str(len(ops("publish", FOREIGN_OPS))) + " publishes")
txt = (ws.js("__txt()") or "")
check("the page says who is holding the topic", "another publisher is holding" in txt)
check("and names the fix", "kennel-demo.sh teleop" in txt)

print("11. served by plain http.server the page is untouched")
ws.call("Page.navigate", url="http://localhost:%s%s" % (PLAIN_PORT, PAGE))
time.sleep(2.2)
ws.js(HELPERS)
dash()
check("the console booted against a server with no /api/",
      "intervention" in (ws.js("__txt()") or "").lower())
check("no connect button", ws.js("!!__connectBtn()") is False)
check("no gait picker", ws.js("!!__gaitSel()") is False)
check("no E-STOP", ws.js("!!__estopBtn()") is False)
check("the mock joystick still exists", ws.js("!!__pad()"))
check("zero unresolved placeholders", "{{" not in (ws.js("document.body.innerHTML") or ""))
check("no WebSocket was opened", ws.js("window.__sockets.length") == 0)
check("no console errors", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))

print("12. no network escaped")
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            ".filter(n=>!n.startsWith('http://localhost:'))")
check("zero non-localhost requests", not ext, str(ext))

# ---------------------------------------------------------------- #66
# `reset sim` and the gait picker, against three different far ends. Everything
# below is APPENDED: groups 1-12 above are #58's and are not touched.


def connect_to(url, ops_path, want="driving"):
    """Point the page at one of the fake bridges and press connect."""
    goto(ORIGIN)
    dash()
    ws.js("__set(__bridgeInput(), %r)" % url)
    ws.js("__connectBtn().click()")
    return wait_for(lambda: want in (ws.js("__txt()") or ""), timeout=12)


def reset_click():
    ws.js("(() => { const b = __btn(/^reset sim$/); if (b) { b.click(); return true; } return false; })()")


def svc(entries, name):
    return [c for c in entries if c.get("service") == name]


print("13. reset sim, connected: the zero, the STAND and the call, in that order")
connect_to(BRIDGE_URL, OPS)
base_c = len(ops("call_service"))
base_p = len(ops("publish"))
reset_click()
check("reset sim calls /reset_sim on the simulator",
      wait_for(lambda: bool(svc(ops("call_service")[base_c:], RESET_SRV))))
calls = ops("call_service")[base_c:]
rs = svc(calls, RESET_SRV)
check("with the stack's own service type",
      rs and rs[0].get("type") == RESET_TYPE, rs[0].get("type", "") if rs else "")
check("spawning at the simulator's own height, upright",
      rs and rs[0]["args"]["pose"]["position"]["z"] == 0.40
      and rs[0]["args"]["pose"]["orientation"]["w"] == 1,
      json.dumps(rs[0]["args"]["pose"]) if rs else "")
check("and with NO joint positions, so the simulator uses its own",
      rs and rs[0]["args"]["joint_positions"] == [],
      "anything but exactly 12 makes drake_simulator fall back to "
      "initial_joint_positions -- the stock spawn, with no constants copied here")
stand = [c for c in calls if c.get("service") == PARAM_SRV
         and c["args"]["parameters"][0]["value"]["string_value"] == "STAND"]
check("STAND is asked for BEFORE the reset", stand and rs and stand[0]["t"] < rs[0]["t"],
      "a gait change after the reset would fight the fresh spawn")
zeros = [o for o in ops("publish")[base_p:] if o["msg"]["body_x_dot"] == 0.0]
check("a zero was published before either call",
      zeros and stand and zeros[0]["t"] <= stand[0]["t"],
      "the controller keeps the last target forever; a reset under a held "
      "velocity walks the fresh robot off its spawn (launch.md §4.2)")
check("the robot was NOT taken out of damping -- it was never in it",
      not svc(calls, UNDAMP_SRV),
      "/set_damping_mode on a standing robot would drop it")
check("and the page says what happened", "sim reset" in (ws.js("__txt()") or ""))

print("14. reset sim on a FALLEN robot leaves emergency damping first")
# The recorded fall (kennel_console/fixtures/fall.jsonl.gz) is a real stack going
# to the floor under /set_emergency_damping_mode. The page has to notice.
connect_to(FALL_URL, FALL_OPS)
fell = wait_for(lambda: "FALL" in (ws.js("__txt()") or ""), timeout=40)
check("the replayed fall reaches the page", fell)
base_c = len(ops("call_service", FALL_OPS))
reset_click()
check("reset sim still calls /reset_sim",
      wait_for(lambda: bool(svc(ops("call_service", FALL_OPS)[base_c:], RESET_SRV)), timeout=15))
calls = ops("call_service", FALL_OPS)[base_c:]
und, rs2 = svc(calls, UNDAMP_SRV), svc(calls, RESET_SRV)
check("and this time it leaves EMERGENCY_DAMPING on the way",
      bool(und), "the leg driver stays damping through a reset otherwise, and the "
                 "fresh robot lands with no controller under it")
check("as a std_srvs/srv/Trigger", und and und[0].get("type") == "std_srvs/srv/Trigger",
      und[0].get("type", "") if und else "")
check("before the reset, not after", und and rs2 and und[0]["t"] < rs2[0]["t"])

print("15. reset sim is refused while somebody else holds the topic")
connect_to(FOREIGN_URL, FOREIGN_OPS, want="another publisher is holding")
base_c = len(ops("call_service", FOREIGN_OPS))
reset_click()
time.sleep(2.0)
check("no service is called at all", not ops("call_service", FOREIGN_OPS)[base_c:],
      "a reset under a held trot spawns the robot and walks it straight off")
txt = ws.js("__txt()") or ""
check("and the page names the fix", "walk stop" in txt)

print("16. the gait picker reports what /gait_state says, not what it asked for")
connect_to(GAIT_URL, GAIT_OPS)
ws.js("__set(__gaitSel(), 'WALKING_TROT')")
check("a gait the node loads reads back as ACTIVE",
      wait_for(lambda: "gait WALKING_TROT active" in (ws.js("__txt()") or ""), timeout=8),
      "period 0.500 s, duty 0.60, offsets [0,0.5,0.5,0] -- gait.cpp's own signature")
# A name the node does not know: it answers `successful: true` and keeps the
# sequencer it had (verify.md §4.4). The picker only offers the ten it knows, so
# the suite adds the eleventh -- which is what a future gait, or a typo in a
# preset, would look like.
ws.js("(() => { const s = __gaitSel(); const o = document.createElement('option');"
      " o.value = 'GARBAGE'; o.textContent = 'GARBAGE'; s.appendChild(o); return true; })()")
base_c = len(ops("call_service", GAIT_OPS))
ws.js("__set(__gaitSel(), 'GARBAGE')")
sent = wait_for(lambda: any(c["args"]["parameters"][0]["value"]["string_value"] == "GARBAGE"
                            for c in ops("call_service", GAIT_OPS)[base_c:]
                            if c.get("service") == PARAM_SRV))
check("an unknown gait is still SENT -- the node accepts the parameter", sent)
check("but it is reported as REFUSED, because the signature never changed",
      wait_for(lambda: "gait GARBAGE refused" in (ws.js("__txt()") or ""), timeout=10),
      "SetParameters answered successful: true for it (verify.md §4.4)")
check("and never as active", "gait GARBAGE active" not in (ws.js("__txt()") or ""))
ws.js("__set(__gaitSel(), 'STAND')")
check("picking a gait the node does load says active again",
      wait_for(lambda: "gait STAND active" in (ws.js("__txt()") or ""), timeout=8))
check("the page subscribed to /gait_state to know any of that",
      any(o.get("topic") == "/gait_state" for o in ops("subscribe", GAIT_OPS)))
first_sub = ops("subscribe", GAIT_OPS)[0] if ops("subscribe", GAIT_OPS) else {}
check("and the FIRST subscribe on the wire is still the foreign-publisher probe",
      first_sub.get("topic") == TOPIC, first_sub.get("topic", ""),)


def sim_t():
    """The status bar's `sim t`, read from its LABEL rather than by pattern.

    Matching "a line that ends in ` s`" looked fine and was not: once the mock's
    scripted demo falls, the value reads `45.6 s · frozen at fall` and the match
    silently finds nothing at all.
    """
    lines = [l.strip() for l in (ws.js("__txt()") or "").split("\n")]
    for i, line in enumerate(lines):
        if line.lower().replace(" ", "") == "simt" and i + 1 < len(lines):
            m = re.match(r"([0-9]+(?:\.[0-9]+)?)\s*s", lines[i + 1])
            return float(m.group(1)) if m else None
    return None


print("17. served by plain http.server, reset sim still rewinds the mock")
ws.call("Page.navigate", url="http://localhost:%s%s" % (PLAIN_PORT, PAGE))
time.sleep(2.2)
ws.js(HELPERS)
dash()
time.sleep(2.0)
before = sim_t()
reset_click()
time.sleep(0.6)
after = sim_t()
check("the mock's clock went back", before is not None and after is not None and after < before,
      "%s s -> %s s" % (before, after))
check("no socket was opened by any of it", ws.js("window.__sockets.length") == 0)
check("and nothing threw", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))

def set_num(label, value):
    ws.js("__set(__numInput(%r), %r)" % (label, str(value)))


def inject_click():
    ws.js("(() => { const b = __injectBtn(); if (b) { b.click(); return true; } return false; })()")


print("18. inject, connected the real service call — and nothing waits for it")
# Against the HEALTHY recording with the held trot dropped: a page that is
# driving a robot that is really publishing, which is the only state in which the
# Dashboard renders an event feed at all (with no samples the panels correctly
# show their empty states). The fixture answers /disturb_simulation two seconds
# late, because the real one does -- it publishes the force, sleeps for `time`,
# publishes a zero and only then answers (disturbance_node.cpp:39-65). What is
# under test is BOTH the payload and that the page keeps driving meanwhile.
connect_to(HEALTHY_URL, HEALTHY_OPS)
for label, val in [("Fx [N]", 100), ("Fy [N]", 0), ("Fz [N]", 0), ("dur [s]", 0.2)]:
    set_num(label, val)
time.sleep(0.4)
base_c = len(ops("call_service", HEALTHY_OPS))
n_pub_before = len(ops("publish", HEALTHY_OPS))
t_click = time.time()
inject_click()
check("inject calls /disturb_simulation",
      wait_for(lambda: bool(svc(ops("call_service", HEALTHY_OPS)[base_c:], DISTURB_SRV))))
calls = svc(ops("call_service", HEALTHY_OPS)[base_c:], DISTURB_SRV)
check("exactly one call, not one per tick", len(calls) == 1, str(len(calls)))
check("with the stack's own service type",
      calls and calls[0].get("type") == DISTURB_TYPE, calls[0].get("type", "") if calls else "")
args = calls[0].get("args") if calls else {}
check("the force is what the operator typed",
      args.get("force") == [100, 0, 0], json.dumps(args.get("force")))
check("the duration is what the operator typed", args.get("time") == 0.2, str(args.get("time")))
check("and tau is zero — the row has no torque fields, so none is invented",
      args.get("tau") == [0, 0, 0], json.dumps(args.get("tau")))
check("the page says it asked", "disturbance requested" in (ws.js("__txt()") or ""))
check("the feed logs the exact injected parameters",
      wait_for(lambda: "Disturbance: 100 N for 0.20 s at body CoM (100, 0, 0)"
               in (ws.js("__txt()") or ""), timeout=6),
      "the grammar line verify-dashboard.py group 13 already pins")
# THE POINT: 20 Hz through the two seconds the service is thinking about it.
time.sleep(2.6)
pubs = ops("publish", HEALTHY_OPS)[n_pub_before:]
during = [o for o in pubs if t_click <= o["t"] <= t_click + 2.0]
check("the joystick kept publishing while the service was blocked",
      len(during) >= HZ * 2 * 0.7, "%d messages in the 2 s the answer took" % len(during))
gaps = [b["t"] - a["t"] for a, b in zip(during, during[1:])]
check("  at 20 Hz, with no stall anywhere in the window",
      bool(gaps) and max(gaps) < 0.3, "largest gap %.3f s" % (max(gaps) if gaps else -1))
check("and when the answer finally comes, the page says so",
      wait_for(lambda: "disturbance done: 100 N for 0.20 s" in (ws.js("__txt()") or ""), timeout=8))

print("19. inject is off when the applied run composed no disturber")
# The service only exists if the run the guest launched composed block 4. The
# page cannot see the guest, so it reads the newest run of /api/runs -- what the
# status bar already calls "the run". Here the fixture run folder is rewritten
# without the choice, so the page has a run and it is not one with a disturber.
run_dir = os.path.join(os.path.dirname(OPS), "kennel-runs", "run-20260101T000000Z")
meta = os.path.join(run_dir, "run.json")
with open(meta, encoding="utf-8") as fh:
    saved = fh.read()
try:
    j = json.loads(saved)
    j["choices"].pop("disturbances", None)
    with open(meta, "w", encoding="utf-8") as fh:
        json.dump(j, fh)
    connect_to(HEALTHY_URL, HEALTHY_OPS)
    base_c = len(ops("call_service", HEALTHY_OPS))
    inject_click()
    time.sleep(1.5)
    check("no service is called at all",
          not svc(ops("call_service", HEALTHY_OPS)[base_c:], DISTURB_SRV),
          "a call would come back refused: there is no disturber to answer it")
    txt = ws.js("__txt()") or ""
    check("and the feed says which run, and what to do",
          "disturbances off" in txt and "run-20260101T000000Z" in txt,
          [l for l in txt.split("\n") if "inject is off" in l][:1])
finally:
    with open(meta, "w", encoding="utf-8") as fh:
        fh.write(saved)

print("20. a disturbance is sent even when the page refuses to DRIVE")
# A push needs no publisher: the foreign fixture is holding
# /quad_control_target, so the target refuses to drive -- and inject must still
# work, because watching somebody else's run and pushing the robot are different
# privileges. That fixture also refuses every service, which is what a stack
# whose run composed no disturber does.
connect_to(FOREIGN_URL, FOREIGN_OPS, want="another publisher is holding")
base_c = len(ops("call_service", FOREIGN_OPS))
inject_click()
check("the call goes out even from a page that is not driving",
      wait_for(lambda: bool(svc(ops("call_service", FOREIGN_OPS)[base_c:], DISTURB_SRV))))
check("and a refusal is reported, not swallowed",
      wait_for(lambda: "the disturbance service refused" in (ws.js("__txt()") or ""), timeout=8))
check("  naming the toggle that fixes it",
      "disturbances on" in (ws.js("__txt()") or ""))

print("21. served by plain http.server, inject still drives the mock")
ws.call("Page.navigate", url="http://localhost:%s%s" % (PLAIN_PORT, PAGE))
time.sleep(2.2)
ws.js(HELPERS)
dash()
time.sleep(1.5)
# The scripted demo arrives already fallen -- it is seeded past T_FALL -- and a
# fall PINS the feed to the five seconds before it (#63). An event emitted now
# would be filtered out of that window, correctly. So rewind the mock first,
# which is what `reset sim` does with no bridge attached, and inject into a
# running demo.
reset_click()
time.sleep(1.2)
check("the mock rewound, so the feed is no longer pinned to a post-mortem",
      "pinned · last 5 s before fall" not in (ws.js("__txt()") or ""))
inject_click()
time.sleep(0.8)
check("the mock's own disturbance reaches the feed",
      re.search(r"Disturbance: \d+ N for [\d.]+ s at body CoM", ws.js("__txt()") or "") is not None,
      "the same grammar line, from the other side of the seam")
check("no socket was opened by any of it", ws.js("window.__sockets.length") == 0)
check("and nothing threw", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))

print()
print("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)
