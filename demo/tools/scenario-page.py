"""The page half of the scenario verbs -- issues #69 and #71. 2026-09-08.

Runs on the HOST. One named step per invocation, so the bash half can interleave
what the PAGE does with what the GUEST saw:

    scenario-page.py --cdp 9294 --serve 8094 --results checks.psv \
                     --guest 192.168.122.32 --out demo/evidence/s004-disturb <step> [arg]

    boot                    load the console, open the Dashboard, assert the
                            controls are there and the bridge URL came from
                            /api/health
    connect / disconnect    the bridge button, and what the page says it is doing
    gait NAME               pick a gait, and wait for it to read back `active`
    vx V                    type a forward velocity into the Interventions field
    stick NY                push the pad (NY = -1 is fully forward)
    release                 let it go
    inject FX FY FZ DUR     type the four disturbance fields and press inject
    reset                   press `reset sim`
    banner / nobanner       the fall banner is / is not raised
    feed FILE               dump the event feed as JSON (t, text) pairs
    health FILE             dump the six pipeline blocks with their tint levels
    runs FILE               open the Runs view, dump its rows, come back
    shot FILE               photograph the page
    errors                  no uncaught errors, and nothing fetched from anywhere
                            but localhost and the guest

Every assertion here is about the PAGE. Everything about the robot is asserted
by the bash half from k13-target-monitor.py's output, because a number a suite
reads back out of the page under test is a number nobody should believe
(kennel_console/dashboard.md §4).

The helpers are COPIED from stack/bridge/verify-teleop-live.py and
kennel_console/verify-dashboard.py rather than imported, as every suite in this
repo copies them: a shared helper file that drifts breaks suites silently, and
each suite is meant to be readable on its own.

EXIT CODES
    0  every check this step made passed
    1  a check failed (the check itself is also appended to --results, so the
       bash half's totals see it)
"""
import argparse
import json
import os
import re
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
window.__injectBtn = () => window.__btn(/^inject$/);
window.__unpinBtn = () => window.__btn(/^unpin feed$/);
window.__gaitSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => o.value === 'WALKING_TROT'));
window.__pad = () => [...document.querySelectorAll('div')]
  .find(d => /crosshair/.test(d.getAttribute('style') || ''));
// One Interventions number input, by the label above it.
window.__numInput = label => { const col = [...document.querySelectorAll('div')]
  .find(d => d.children.length === 2 && d.children[0].textContent.trim() === label
             && d.querySelector('input[type=number]'));
  return col ? col.querySelector('input[type=number]') : null; };
// One status-bar item by its uppercase label, as text: "mode", "rtf", "sim t"...
window.__stat = name => { const lab = [...document.querySelectorAll('div')].find(d =>
    !d.querySelector('div') && d.textContent.trim() === name);
  return lab && lab.nextElementSibling ? lab.nextElementSibling.textContent.trim() : null; };
// The event feed, row by row: a timestamp cell and a text cell.
window.__feed = () => [...document.querySelectorAll('div')]
  .filter(d => d.children.length === 2 && /^-?\d+(\.\d+)?s$/.test(d.children[0].textContent.trim()))
  .map(d => [d.children[0].textContent.trim(), d.children[1].textContent.trim()]);
// The six pipeline-health blocks and their TINT, as a string rather than a
// colour: `data-lvl` is on the card for exactly this reason (#71). A canvas
// cannot be read by a suite, and neither can a background colour.
// The card's first LEAF div with text is its name: `div > div` finds the status
// DOT first, which has no text at all, and a nameless reading makes every later
// aggregation quietly empty rather than wrong.
window.__health = () => [...document.querySelectorAll('[data-lvl]')].map(d => {
  const name = [...d.querySelectorAll('div')]
    .find(x => !x.querySelector('div') && x.textContent.trim());
  return [name ? name.textContent.trim() : '?', d.getAttribute('data-lvl')]; });
// A Runs table row: the grid whose first cell is the checkbox, minus the header.
// Copied from verify-runs.py, which is where this was got right: the browser
// normalises a style attribute set through the CSSOM, so the match has to allow
// the space it inserts -- and "no rows" and "no matching rows" look identical
// from the outside, which is how a selector like this goes wrong unnoticed.
window.__isRow = d => { const s = d.getAttribute('style') || '';
  return /grid-template-columns:\s*34px/.test(s) && !/text-transform:\s*uppercase/.test(s); };
window.__rows = () => [...document.querySelectorAll('div')].filter(window.__isRow)
  .map(d => [...d.children].map(c => c.innerText.trim()));
window.__set = (el, val) => { const proto = el instanceof HTMLSelectElement
    ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, val);
  el.dispatchEvent(new Event('input', {bubbles: true}));
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
ap.add_argument("--guest", default="")
ap.add_argument("--out", default=".")
ap.add_argument("step")
ap.add_argument("args", nargs="*")
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


def note(label, detail=""):
    """Something measured and reported, not asserted."""
    with open(A.results, "a", encoding="utf-8") as fh:
        fh.write("NOTE|%s|%s\n" % (label, str(detail).replace("|", "/")))
    print("  [NOTE] %s%s" % (label, (" -- " + str(detail)) if detail else ""))


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


def num(label, value):
    ws.js("__set(__numInput(%r), %r)" % (label, str(value)))


def dump(name, obj, compact=False):
    """`compact` writes one line, for the files the bash half appends into a
    .jsonl -- a pretty-printed record in a line-oriented file is a file nothing
    can read back."""
    path = os.path.join(A.out, name)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        if compact:
            json.dump(obj, fh)
        else:
            json.dump(obj, fh, indent=1)
    return path


step, rest = A.step, A.args

if step == "boot":
    dash()
    check("the console booted against the scenario's own serve.py",
          "intervention" in txt().lower())
    url = ws.js("(() => { const i = __bridgeInput(); return i ? i.value : ''; })()")
    check("the bridge URL was prefilled from /api/health, so teleop's hand-off works",
          bool(url) and A.guest in url, url)
    check("nothing is dialled before the operator asks",
          ws.js("window.__sockets.length") == 0, str(ws.js("window.__sockets")))

elif step == "connect":
    ws.js("__connectBtn().click()")
    ok = wait_for(lambda: "driving" in txt(), timeout=25)
    check("connect bridge -> the page is driving the real stack", ok,
          [l for l in txt().split("\n") if "driving" in l or "listening" in l
           or "holding" in l][:1])
    check("the panels are on the live stack, and the page says so",
          wait_for(lambda: ws.js("__stat('mode')") == "live"), ws.js("__stat('mode')"))

elif step == "disconnect":
    ws.js("(() => { const b = __connectBtn();"
          " if (b && /disconnect/.test(b.textContent)) { b.click(); return true; } return false; })()")
    time.sleep(1.0)
    check("disconnected, so nothing of ours is publishing", "connect bridge" in txt())

elif step == "gait":
    want = rest[0]
    ws.js("__set(__gaitSel(), %r)" % want)
    check("the gait picker reports %s ACTIVE from /gait_state" % want,
          wait_for(lambda: ("gait %s active" % want) in txt(), timeout=10),
          [l for l in txt().split("\n") if l.startswith("gait ")][:1])

elif step == "vx":
    v = rest[0]
    num("vx [m/s]", v)
    check("the velocity field holds %s m/s" % v,
          ws.js("(() => { const i = __numInput('vx [m/s]'); return i ? i.value : ''; })()") == str(v))

elif step == "stick":
    ny = float(rest[0]) if rest else -1.0
    ws.js("__stick(0, %r, 'pointerdown')" % ny)
    check("the stick is pushed (ny=%s)" % ny, True)

elif step == "release":
    ws.js("__stick(0, -1, 'pointerup')")
    check("the stick is released", True)

elif step == "inject":
    fx, fy, fz, dur = (float(x) for x in rest[:4])
    for label, v in (("Fx [N]", fx), ("Fy [N]", fy), ("Fz [N]", fz), ("dur [s]", dur)):
        num(label, v)
    time.sleep(0.4)
    ws.js("(() => { const b = __injectBtn(); if (b) { b.click(); return true; } return false; })()")
    check("inject asked for %.0f N for %.2f s" % ((fx ** 2 + fy ** 2 + fz ** 2) ** 0.5, dur),
          wait_for(lambda: "disturbance requested" in txt(), timeout=8),
          [l for l in txt().split("\n") if "disturbance" in l][:1])
    # The feed line is the record of what was injected -- the grammar
    # verify-dashboard.py group 13 pins, so this is the same sentence the mock
    # writes (s007.bridge step 6).
    want = "Disturbance: %.0f N for %.2f s at body CoM" % (
        (fx ** 2 + fy ** 2 + fz ** 2) ** 0.5, dur)
    check("and the feed logs the exact injected parameters",
          wait_for(lambda: want in txt(), timeout=8), want)

elif step == "reset":
    ws.js("(() => { const b = __resetBtn(); if (b) { b.click(); return true; } return false; })()")
    check("reset sim was pressed", True)
    check("the page says it called /reset_sim",
          wait_for(lambda: "/reset_sim called" in txt(), timeout=10),
          [l for l in txt().split("\n") if "reset" in l.lower()][:2])

elif step == "banner":
    ok = wait_for(lambda: "FALL DETECTED" in txt(), timeout=float(rest[0]) if rest else 20)
    check("the fall banner is raised", ok,
          next((l for l in txt().split("\n") if "FALL DETECTED" in l), ""))
    check("and the feed is pinned to the five seconds before it",
          "pinned · last 5 s before fall" in txt() and "unpin feed" in txt())

elif step == "nobanner":
    check("no fall banner", "FALL DETECTED" not in txt())

elif step == "feed":
    feed = ws.js("__feed()") or []
    dump(rest[0], feed)
    check("the feed has something to read", len(feed) >= 1, "%d entries" % len(feed))

elif step == "health":
    h = ws.js("__health()") or []
    dump(rest[0], {"t": round(time.time(), 2), "sim": ws.js("__stat('sim t')"),
                   "blocks": h}, compact=True)
    check("the six pipeline blocks report a tint a suite can read",
          len(h) == 6, str(h))

elif step == "runs":
    ws.js("__click('Runs')")
    time.sleep(2.0)
    rows = ws.js("__rows()") or []
    dump(rest[0], rows)
    check("the Runs view lists the host's runs", len(rows) >= 1, "%d rows" % len(rows))
    if len(rest) > 1:
        run, verdict = rest[1], rest[2]
        row = next((r for r in rows if any(run in c for c in r)), None)
        check("%s is listed, with the verdict its record carries" % run[:22],
              row is not None and verdict in " ".join(row).lower(),
              (" | ".join(c for c in row if c)[:130] if row else "no row for that run")
              + " (want %s)" % verdict)
    ws.js("__click('Dashboard')")
    time.sleep(0.8)

elif step == "shot":
    path = os.path.join(A.out, rest[0])
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    import base64
    data = ws.call("Page.captureScreenshot", format="png")["data"]
    with open(path, "wb") as fh:
        fh.write(base64.b64decode(data))
    check("photographed %s" % rest[0], os.path.getsize(path) > 20000,
          "%d B" % os.path.getsize(path))

elif step == "simt":
    v = ws.js("__stat('sim t')")
    note("the page's sim clock reads", v)
    m = re.match(r"([0-9.]+)", v or "")
    if len(rest) and m:
        check("the sim clock restarted (under %s s)" % rest[0],
              float(m.group(1)) < float(rest[0]), v)

elif step == "errors":
    check("no uncaught errors anywhere in the session",
          ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))
    ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
                ".filter(n=>!n.startsWith('http://localhost:'))") or []
    stray = [n for n in ext if A.guest not in n]
    check("nothing was fetched from anywhere but localhost and the guest",
          not stray, str(stray))

else:
    check("unknown step %r" % step, False)

sys.exit(1 if failed else 0)
