"""Acceptance checks for issue #58 — the console drives the stack over rosbridge.

Driven by verify-teleop.sh.
Usage: verify-teleop.py <servePort> <plainPort> <cdpPort> <bridgePort> <opsLog>
                        <foreignPort> <foreignOpsLog>

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
FOREIGN_URL = "ws://localhost:%s/" % FOREIGN_PORT
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

print()
print("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)
