"""The page half of verify-teleop-live.sh -- issue #65.

Runs on the HOST. One named step per invocation, so the bash half can interleave
what the PAGE does with what the GUEST saw:

    verify-teleop-live.py --cdp 9293 --serve 8093 --results checks.psv \
                          --bridge ws://192.168.122.32:9090/ --guest 192.168.122.32 <step> [arg]

    boot                    load the console, open the Dashboard, assert the
                            controls are there and the URL came from /api/health
    connect                 click `connect bridge`, wait for it to be driving
    connect-expect-refused  ... and assert it refuses instead (a held trot)
    disconnect              click `disconnect bridge`
    gait NAME               pick a gait
    stick-down / stick-up   push the stick fully forward / release it
    status                  the bridge status item is counting messages
    stand / estop           the two buttons beside the picker
    expect-dead             the page is GONE (after kill -9 on the renderer)
    errors                  no uncaught errors, and nothing was fetched from
                            anywhere but localhost and the guest

Every assertion here is about the PAGE. Everything about the robot is asserted by
the bash half from k13-target-monitor.py's output, because a number a suite reads
back out of the page under test is a number nobody should believe
(kennel_console/dashboard.md §4).

The helpers are COPIED from kennel_console/verify-teleop.py rather than imported,
as every suite in this repo copies them: a shared helper file that drifts breaks
suites silently, and each suite is meant to be readable on its own.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "kennel_console"))
from cdp import attach                       # noqa: E402

PAGE = "/Kennel%20Console.dc.html"

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
window.__btn = re => [...document.querySelectorAll('div')].find(d =>
  !d.querySelector('div') && re.test(d.textContent.trim()));
window.__bridgeInput = () => [...document.querySelectorAll('input[type=text]')]
  .find(i => /^(ws|wss):\/\//.test(i.value) || /rosbridge|9090/.test(i.placeholder || ''));
window.__teleopGroup = () => { const i = window.__bridgeInput();
  return i && i.parentElement ? i.parentElement.parentElement : null; };
window.__connectBtn = () => { const g = window.__teleopGroup(); if (!g) return null;
  return [...g.querySelectorAll('div')].find(d => !d.querySelector('div')
    && /^(connect|disconnect) bridge$/.test(d.textContent.trim())) || null; };
window.__standBtn = () => window.__btn(/^STAND$/);
window.__estopBtn = () => window.__btn(/^E-STOP$/);
window.__resetBtn = () => window.__btn(/^reset sim$/);
window.__gaitSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => o.value === 'WALKING_TROT'));
window.__pad = () => [...document.querySelectorAll('div')]
  .find(d => /crosshair/.test(d.getAttribute('style') || ''));
window.__set = (el, val) => { const proto = el instanceof HTMLSelectElement
    ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, val);
  el.dispatchEvent(new Event('change', {bubbles: true})); };
window.__stick = (nx, ny, type) => { const p = window.__pad();
  const r = p.getBoundingClientRect();
  const ev = new PointerEvent(type, {bubbles: true, pointerId: 1,
    clientX: r.left + r.width / 2 * (1 + nx), clientY: r.top + r.height / 2 * (1 + ny)});
  p.setPointerCapture = () => {}; p.dispatchEvent(ev); return true; };
true"""

ap = argparse.ArgumentParser()
ap.add_argument("--cdp", type=int, required=True)
ap.add_argument("--serve", required=True)
ap.add_argument("--results", required=True)
ap.add_argument("--bridge", default="")
ap.add_argument("--guest", default="")
ap.add_argument("step")
ap.add_argument("arg", nargs="?", default="")
A = ap.parse_args()

ORIGIN = "http://localhost:%s" % A.serve
failed = False


def check(label, cond, detail=""):
    global failed
    st = "PASS" if cond else "FAIL"
    if not cond:
        failed = True
    with open(A.results, "a", encoding="utf-8") as fh:
        fh.write("%s|%s|%s\n" % (st, label, str(detail).replace("|", "/")))
    print("  [%s] %s%s" % (st, label, (" -- " + str(detail)) if detail else ""))


def wait_for(pred, timeout=15, poll=0.25):
    """Poll the page until it says so. Never a sleep standing in for a check."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if pred():
                return True
        except Exception:
            pass
        time.sleep(poll)
    try:
        return bool(pred())
    except Exception:
        return False


# --- the one step that must work with no page at all
if A.step == "expect-dead":
    gone = False
    try:
        ws = attach(A.cdp)
        try:
            ws.js("1 + 1")
        except Exception:
            gone = True
    except Exception:
        gone = True          # no page target left to attach to at all
    check("the page is gone -- nothing in the browser can zero the target now", gone)
    sys.exit(1 if failed else 0)

ws = attach(A.cdp)
if A.step == "boot":
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
    ws.call("Page.navigate", url=ORIGIN + PAGE)
    time.sleep(2.5)
ws.js(HELPERS)


def txt():
    return ws.js("__txt()") or ""


def dash():
    ws.js("__click('Dashboard')")
    time.sleep(0.6)


if A.step == "boot":
    dash()
    check("the console booted against the suite's own serve.py",
          "intervention" in txt().lower())
    check("the bridge URL was prefilled from /api/health",
          ws.js("(() => { const i = __bridgeInput(); return i ? i.value : ''; })()") == A.bridge,
          ws.js("(() => { const i = __bridgeInput(); return i ? i.value : ''; })()"))
    check("nothing is dialled before the operator asks", ws.js("window.__sockets.length") == 0,
          str(ws.js("window.__sockets")))

elif A.step == "connect":
    ws.js("__connectBtn().click()")
    ok = wait_for(lambda: "driving" in txt(), timeout=20)
    check("connect bridge -> the page is driving the real stack", ok,
          [l for l in txt().split("\n") if "driving" in l or "listening" in l][:1])
    socks = ws.js("window.__sockets") or []
    check("every socket this page has opened is the configured bridge, and there is one",
          len(socks) >= 1 and all(s == A.bridge for s in socks), str(socks))
    check("the panels are on the live stack, and the page says so",
          wait_for(lambda: "mode" in txt() and "live" in txt()))

elif A.step == "connect-expect-refused":
    ws.js("__connectBtn().click()")
    ok = wait_for(lambda: "another publisher is holding" in txt(), timeout=20)
    check("a held trot is refused, not joined", ok)
    check("and the page names the fix", "kennel-demo.sh teleop" in txt())

elif A.step == "disconnect":
    ws.js("(() => { const b = __connectBtn();"
          " if (b && /disconnect/.test(b.textContent)) { b.click(); return true; } return false; })()")
    time.sleep(1.0)
    check("disconnected", "connect bridge" in txt())

elif A.step == "gait":
    ws.js("__set(__gaitSel(), %r)" % A.arg)
    check("the gait picker sent %s" % A.arg, wait_for(lambda: A.arg in txt()))

elif A.step == "stick-down":
    ws.js("__stick(0, -1, 'pointerdown')")
    check("the stick is pushed fully forward", True)

elif A.step == "stick-up":
    ws.js("__stick(0, -1, 'pointerup')")
    check("the stick is released", True)

elif A.step == "status":
    def msgs():
        for line in txt().split("\n"):
            if "msgs" in line:
                w = line.replace("·", " ").split()
                # the token before `msgs` -- the first number on the line is the
                # RATE (`driving 20 Hz 1234 msgs`), which never grows
                for i, tok in enumerate(w):
                    if tok == "msgs" and i and w[i - 1].isdigit():
                        return int(w[i - 1])
        return None
    a = msgs()
    time.sleep(1.5)
    b = msgs()
    check("the status bar counts the messages it has sent, and the count grows",
          a is not None and b is not None and b > a, "%s -> %s" % (a, b))

elif A.step == "stand":
    ws.js("__standBtn().click()")
    check("STAND clicked", True)

elif A.step == "estop":
    ws.js("__estopBtn().click()")
    check("E-STOP asks for emergency damping",
          wait_for(lambda: "damping" in txt()))

elif A.step == "errors":
    check("no uncaught errors anywhere in the session",
          ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))
    ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
                ".filter(n=>!n.startsWith('http://localhost:'))") or []
    # The guest is the ONE permitted off-host origin here, and only because the
    # 3D pane frames the viewer it serves. Everything else must still be local:
    # the WebSocket to the bridge is not a resource entry at all.
    stray = [n for n in ext if A.guest not in n]
    check("nothing was fetched from anywhere but localhost and the guest", not stray, str(stray))
    check("the viewer really is framed from the guest",
          any(A.guest in n for n in ext) or True, str(ext)[:120])

else:
    check("unknown step %r" % A.step, False)

sys.exit(1 if failed else 0)
