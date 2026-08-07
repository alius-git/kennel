"""Operator stand-in for demo-script steps 2-3 — deviation D1 of demo/dry-run.md.

Usage: p22-console-demo.py <cdpPort> <downloadDir> <solver> <rate> <shotPath>

An agent has no hands, so the clicks a human performs in the Compose view are
scripted here. What is NOT scripted is the work: every value travels through the
console's own controls and its own download path, exactly as a person clicking
would send it. Nothing is injected into the config, nothing is read back out of
a JavaScript variable and written to disk, and the bytes asserted on are the
bytes the browser wrote.

The click helpers are lifted verbatim from kennel_console/verify-export.py so
that this file cannot drive the console through a different surface than the
one #19 already proved.
"""
import base64
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "..", "kennel_console"))
from cdp import attach  # noqa: E402

CDP_PORT = int(sys.argv[1])
DL = os.path.abspath(sys.argv[2])
SOLVER = sys.argv[3]
RATE = float(sys.argv[4])
SHOT = os.path.abspath(sys.argv[5])

ws = attach(CDP_PORT)
fail = []


def step(label, cond, detail=""):
    if not cond:
        fail.append(label)
    print(f"  [{'ok ' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))


try:
    ws.call("Browser.setDownloadBehavior", behavior="allow", downloadPath=DL)
except RuntimeError:
    ws.call("Page.setDownloadBehavior", behavior="allow", downloadPath=DL)

ws.js(r"""
window.__txt = () => document.body.innerText;
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
window.__solverSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /CONDENSING/.test(o.value)));
window.__setSel = (s, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set;
  setter.call(s, val); s.dispatchEvent(new Event('change', {bubbles:true})); };
// The Sim options rows are <label><control>; find the row by its label text and
// take the number input inside it. Matching on the label is what a person does.
window.__simNum = label => { const row = [...document.querySelectorAll('div')]
  .find(d => d.children.length === 2 && d.children[0].textContent.trim() === label
             && d.querySelector('input[type=number]'));
  return row ? row.querySelector('input[type=number]') : null; };
window.__setNum = (el, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  setter.call(el, String(val));
  el.dispatchEvent(new Event('input', {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true})); };
window.__pane = () => { const p = [...document.querySelectorAll('pre')]
  .filter(p => /ros__parameters/.test(p.textContent)); return p.length ? p[0].textContent : ''; };
true""")


def pane(tab):
    ws.js(f"__click({tab!r})")
    time.sleep(0.45)
    return ws.js("__pane()")


def settled(timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        names = os.listdir(DL)
        if names and not any(n.endswith(".crdownload") for n in names):
            time.sleep(0.3)
            return sorted(os.listdir(DL))
        time.sleep(0.2)
    return sorted(os.listdir(DL))


SIM_TAB, CTRL_TAB = "simulator_params_go2.yaml", "mit_controller_sim_go2.yaml"

print("\n[compose] the console is up and on Compose")
# innerText reflects text-transform, and the panel headings are uppercased in
# CSS — match case-insensitively or this asserts on the stylesheet.
step("Compose view is the landing view", "sim options" in ws.js("__txt()").lower())
step("solver dropdown present", ws.js("!!__solverSel()"))
step("real-time rate input present", ws.js("!!__simNum('real-time rate')"))
step("starts at stock solver", ws.js("__solverSel().value") == "PARTIAL_CONDENSING_HPIPM",
     ws.js("__solverSel().value"))
step("starts at stock rate", float(ws.js("__simNum('real-time rate').value")) == 1.0,
     ws.js("__simNum('real-time rate').value"))

print(f"\n[compose] choice 1 — MPC solver -> {SOLVER}")
ws.js(f"__setSel(__solverSel(), {SOLVER!r})")
time.sleep(0.5)
step("dropdown holds the choice", ws.js("__solverSel().value") == SOLVER, ws.js("__solverSel().value"))
ctrl = pane(CTRL_TAB)
step("controller YAML shows it", f'mpc_solver: "{SOLVER}"' in ctrl,
     next((l.strip() for l in ctrl.split("\n") if "mpc_solver" in l), "absent"))

print(f"\n[compose] choice 2 — real-time rate -> {RATE}")
ws.js(f"__setNum(__simNum('real-time rate'), {RATE})")
time.sleep(0.5)
step("input holds the choice", float(ws.js("__simNum('real-time rate').value")) == RATE,
     ws.js("__simNum('real-time rate').value"))
sim = pane(SIM_TAB)
step("simulator YAML shows it", f"simulator_realtime_rate: {RATE}" in sim,
     next((l.strip() for l in sim.split("\n") if "simulator_realtime_rate" in l), "absent"))

print("\n[compose] map left at stock — transfer.md 6.3: obstacle terrain does not walk")
step("world_urdf is still the plane", 'world_urdf: "src/common/model/urdf/plane.urdf"' in sim)

# Back to the composition itself for the photograph: the YAML tabs are a detail
# pane, and the screenshot is meant to show the choices as an operator made them.
ws.js("__click('Compose')")
time.sleep(0.8)
shot = ws.call("Page.captureScreenshot", format="png")["data"]
with open(SHOT, "wb") as f:
    f.write(base64.b64decode(shot))
step("Compose view photographed", os.path.getsize(SHOT) > 20000, f"{os.path.getsize(SHOT)} B")

print("\n[generate] generate run")
for n in os.listdir(DL):
    os.remove(os.path.join(DL, n))
ws.js("__click('generate run ↓')")
landed = settled()
step("exactly one archive downloaded", len(landed) == 1, str(landed))
if landed:
    print(f"\nARCHIVE={os.path.join(DL, landed[0])}")

sys.exit(1 if fail else 0)
