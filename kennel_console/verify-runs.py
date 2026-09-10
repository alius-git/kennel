"""Acceptance checks for issue #64 — the Runs view shows real runs.

Driven by verify-runs.sh.
Usage: verify-runs.py <servePort> <plainPort> <cdpPort> <outDir>

The Runs view used to list five invented runs (`RUN-2026-0718-1142 … verdict
fell`) and show a real send only as `staged · not yet run`. Someone reading that
table was reading fiction. This suite is about the two halves of the fix:

  1. With a kennel server, the table IS the host's run folders, and each row's
     verdict and counters come out of the verify report `kennel-demo.sh verify`
     filed beside the run. The reports used here were produced by
     kennel-verify.sh on the live guest and committed under fixtures/, so the
     verdicts on screen are ones a controller actually reached.
  2. With no server -- plain http.server, which is Devon's demo -- the seeded
     history is still there, because s007.bridge's mock half is a console with
     no stack at all. Every seeded row now says `demo`.

Runs are composed by driving the console, never by writing folders behind its
back: what is under test includes the console's own idea of what a run is.
"""
import hashlib
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request

import yaml

from cdp import attach

SERVE_PORT = sys.argv[1]
PLAIN_PORT = sys.argv[2]
CDP_PORT = int(sys.argv[3])
OUT = os.path.abspath(sys.argv[4])

ORIGIN = "http://localhost:%s" % SERVE_PORT
PLAIN_ORIGIN = "http://localhost:%s" % PLAIN_PORT
PAGE = "/Kennel%20Console.dc.html"
HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")

# Three real reports, and the composition each one is of.
CASES = [
    ("PARTIAL_CONDENSING_OSQP",  "Flat plane",       "verify-completed-osqp.json",  "completed"),
    ("PARTIAL_CONDENSING_HPIPM", "Flat plane",       "verify-completed-hpipm.json", "completed"),
    ("PARTIAL_CONDENSING_OSQP",  "Obstacle terrain", "verify-fell.json",            "fell"),
]

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


def api(path, origin=ORIGIN):
    try:
        with urllib.request.urlopen(origin + path, timeout=10) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.load(e)
        except ValueError:
            return e.code, {}


def raw(path, origin=ORIGIN):
    try:
        with urllib.request.urlopen(origin + path, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def wait_for(pred, timeout=15, poll=0.2):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(poll)
    return pred()


ws.call("Page.enable")
ws.call("Page.addScriptToEvaluateOnNewDocument", source=(
    "window.__errs = [];"
    "window.addEventListener('error', e => window.__errs.push(String(e.message)));"
    "window.addEventListener('unhandledrejection',"
    " e => window.__errs.push('unhandled rejection: ' + e.reason));"))

HELPERS = r"""
if (!window.__errs) { window.__errs = [];
  window.addEventListener('error', e => window.__errs.push(String(e.message)));
  window.addEventListener('unhandledrejection', e => window.__errs.push('unhandled rejection: ' + e.reason));
}
window.__txt = () => document.body.innerText;
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
window.__solverSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /CONDENSING/.test(o.value)));
window.__setSel = (s, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set;
  setter.call(s, val); s.dispatchEvent(new Event('change', {bubbles:true})); };
window.__sendBtn = () => [...document.querySelectorAll('div')].find(d =>
  !d.querySelector('div') && /^send to .+ →$/.test(d.textContent.trim()));
// A Runs table row: the grid whose first cell is the checkbox. Read as the
// cells an operator sees, in order.
// The browser normalises a style attribute set through the CSSOM, so these
// match `grid-template-columns: 34px` with the space it puts there -- reading
// the attribute back literally is what a suite would get wrong once and never
// notice, because "no rows" and "no matching rows" look identical.
window.__isRow = d => { const s = d.getAttribute('style') || '';
  return /grid-template-columns:\s*34px/.test(s) && !/text-transform:\s*uppercase/.test(s); };
window.__rowEls = () => [...document.querySelectorAll('div')].filter(window.__isRow);
window.__rows = () => window.__rowEls().map(d => [...d.children].map(c => c.innerText.trim()));
window.__selectRow = i => { const rows = window.__rowEls();
  if (!rows[i]) return false; rows[i].children[0].click(); return true; };
// The three diff tables, by their headers.
window.__section = title => { const h = [...document.querySelectorAll('div')]
  .find(d => d.textContent.trim() === title);
  return h ? h.parentElement.parentElement.innerText : ''; };
true"""


def goto(origin=ORIGIN, settle=2.4):
    ws.call("Page.navigate", url=origin + PAGE)
    time.sleep(settle)
    ws.js(HELPERS)


def view(name):
    ws.js("__click(%r)" % name)
    time.sleep(0.7)


# ---------------------------------------------------------------- 1
group("1. three real runs, composed in the console and filed with real reports")
goto()
sent = []
for solver, mapname, report, verdict in CASES:
    before = {r["run"] for r in api("/api/runs")[1]["runs"]}
    view("Compose")
    ws.js("__click(%r)" % mapname)
    time.sleep(0.3)
    ws.js("__setSel(__solverSel(), %r)" % solver)
    time.sleep(0.5)
    ws.js("__click(__sendBtn().textContent.trim())")
    got = wait_for(lambda: {r["run"] for r in api("/api/runs")[1]["runs"]} - before, timeout=15)
    new = sorted({r["run"] for r in api("/api/runs")[1]["runs"]} - before)
    check("a run folder appeared for %s / %s" % (solver, mapname), bool(new), str(new))
    if not new:
        break
    run = new[-1]
    sent.append((run, solver, mapname, report, verdict))
    # The report `kennel-demo.sh verify` would file, from the live guest.
    shutil.copyfile(os.path.join(FIXTURES, report), os.path.join(OUT, run, "verify.json"))
    shutil.copyfile(os.path.join(FIXTURES, report),
                    os.path.join(OUT, run, "verify.txt"))     # text half; content is not read
    time.sleep(1.1)     # stampNow() has one-second resolution; two sends inside it collide

check("three runs were composed", len(sent) == 3, "%d" % len(sent))

# ---------------------------------------------------------------- 2
group("2. the API serves them, and refuses everything else")
st, doc = api("/api/runs")
by_run = {r["run"]: r for r in doc["runs"]}
for run, solver, mapname, report, verdict in sent:
    r = by_run.get(run) or {}
    check("%s is listed with its composed choices" % run[:20],
          (r.get("choices") or {}).get("mpc_solver") == solver,
          str((r.get("choices") or {}).get("mpc_solver")))
    check("  and with a verify summary carrying the verdict",
          (r.get("verify") or {}).get("verdict") == verdict,
          str((r.get("verify") or {}).get("verdict")))
# kennel-demo.sh status lists runs by sed-ing `"run": "..."` out of this
# document. A nested one would show up there as a run that does not exist.
body = json.dumps(doc)
check("no nested \"run\" key anywhere in the document",
      body.count('"run"') == len(doc["runs"]),
      "%d occurrences for %d runs" % (body.count('"run"'), len(doc["runs"])))
run0 = sent[0][0]
st, b = raw("/api/runs/%s/verify.json" % run0)
check("GET /api/runs/<stamp>/verify.json serves the report", st == 200 and b"verdict" in b, str(st))
st, b = raw("/api/runs/%s/simulator_params_go2.yaml" % run0)
check("and the generated YAML the diff needs", st == 200 and b"drake_simulator" in b, str(st))
for bad in ("/api/runs/%s/serve.py" % run0, "/api/runs/../serve.py",
            "/api/runs/%s/../../serve.py" % run0, "/api/runs/not-a-run/verify.json",
            "/api/runs/%s/../%s/verify.json" % (run0, run0)):
    st, b = raw(bad)
    check("404: %s" % bad, st == 404 and b"error" in b, str(st))

# ---------------------------------------------------------------- 3
group("3. the table shows the runs, the verdicts and the counters")
goto()
view("Runs")
rows = ws.js("__rows()") or []
check("every run on the host is a row", len(rows) >= 3, "%d rows" % len(rows))
txt = ws.js("__txt()") or ""
# In the TABLE. The status bar carries a run id too, and with a host to ask it
# is now the newest run folder rather than the composer's next manifest id.
table = "\n".join(" ".join(r) for r in rows)
check("no invented run is in the table", "RUN-2026-07" not in table,
      next((l for l in table.splitlines() if "RUN-2026-07" in l), ""))
check("and the status bar's run id is the newest real run",
      any(run in txt for run, *_ in sent), "expected one of %s" % [r[0] for r in sent])
check("the sub-header says where the runs came from",
      "verify.json" in txt and "kennel-runs" in txt,
      next((l for l in txt.splitlines() if "runs in" in l), ""))
seen = {}
for r in rows:
    if len(r) >= 7:
        seen[r[1].splitlines()[0]] = r
for run, solver, mapname, report, verdict in sent:
    row = seen.get(run)
    # The badge is uppercased by CSS, and innerText returns what is rendered.
    check("%s shows verdict %s" % (run[:20], verdict),
          row and row[5].lower() == verdict, str(row[5]) if row else "no row")
    with open(os.path.join(FIXTURES, report), encoding="utf-8") as f:
        h = json.load(f)["headline"]
    check("  and its real counters", row and ("early %d" % h["early_contacts"]) in row[6],
          str(row[6]) if row else "")
    check("  and the map it was composed on", row and row[2] == mapname, str(row[2]) if row else "")
    check("  with a link to the report", row and "verify" in row[7], str(row[7]) if row else "")
# A run with no report is honestly `staged`, not a verdict invented for it.
view("Compose")
ws.js("__click(__sendBtn().textContent.trim())")
time.sleep(2.0)
view("Runs")
rows = ws.js("__rows()") or []
check("a run that has not been run says `staged`",
      any(len(r) >= 6 and r[5].lower() == "staged" for r in rows),
      str([r[5] for r in rows if len(r) >= 6]))

# ---------------------------------------------------------------- 4
group("4. selecting two runs isolates exactly what differs")
goto()
view("Runs")
rows = ws.js("__rows()") or []
idx = {}
for i, r in enumerate(rows):
    if len(r) >= 2:
        idx[r[1].splitlines()[0]] = i
a_run, b_run = sent[0][0], sent[1][0]        # OSQP vs HPIPM, same map
ws.js("__selectRow(%d)" % idx[a_run])
time.sleep(0.4)
ws.js("__selectRow(%d)" % idx[b_run])
time.sleep(1.6)
cfg = ws.js("__section('Config diff')") or ""
check("the solver is named as the difference", "mpc.implementation" in cfg, cfg[:90])
check("the map is not", "sim.map" not in cfg)
check("the real-time rate is not", "sim.real_time_rate" not in cfg)
# composer-scope.md §2: condensing follows partial-vs-full, hpipm_mode follows
# the family, and the two cut across each other. Both these solvers are partial,
# so condensed_size is read by both and hpipm_mode by the HPIPM one only.
check("the solver-dependent keys say which side reads them",
      "read by both" in cfg or "read by " + b_run in cfg, cfg.replace("\n", " | ")[:200])
out = ws.js("__section('Outcome')") or ""
check("the two verdicts are compared", "verdict" in out and "completed" in out, out[:80])
check("and the headline counters", "headline.early_contacts" in out, out[:120])
yml = ws.js("__section('Generated YAML')") or ""
check("the generated YAML pair is compared line by line",
      wait_for(lambda: "differing lines" in (ws.js("__section('Generated YAML')") or ""), timeout=15),
      (ws.js("__section('Generated YAML')") or "").splitlines()[1:2])
yml = ws.js("__section('Generated YAML')") or ""
check("and the only lines that differ are the solver's",
      "mpc_solver" in yml and "world_urdf" not in yml, yml.replace("\n", " | ")[:200])

# a different map instead: exactly one key
goto()
view("Runs")
rows = ws.js("__rows()") or []
idx = {r[1].splitlines()[0]: i for i, r in enumerate(rows) if len(r) >= 2}
ws.js("__selectRow(%d)" % idx[sent[0][0]])
time.sleep(0.4)
ws.js("__selectRow(%d)" % idx[sent[2][0]])
time.sleep(1.6)
cfg = ws.js("__section('Config diff')") or ""
check("two runs differing only in the map show only the map",
      "sim.map" in cfg and "mpc.implementation" not in cfg, cfg.replace("\n", " | ")[:160])
out = ws.js("__section('Outcome')") or ""
check("their verdicts differ, and the table says so",
      "completed" in out and "fell" in out, out.replace("\n", " | ")[:120])

# ---------------------------------------------------------------- 5
group("5. with no host to read runs from, the demo history says it is a demo")
goto(PLAIN_ORIGIN)
view("Runs")
txt = ws.js("__txt()") or ""
check("the seeded history is still there for the demo", "RUN-2026-07" in txt)
check("and every seeded row is labelled", txt.count("demo") >= 5,
      "%d occurrences of 'demo'" % txt.count("demo"))
check("the sub-header says there is no host", "seeded demo history" in txt)
check("no refresh control, because there is nothing to refresh", "refresh" not in txt)
check("no console errors", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))

# ---------------------------------------------------------------- 6
group("6. no network escaped")
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            ".filter(n=>!n.startsWith('http://localhost:'))")
check("zero non-localhost requests", not ext, str(ext))

# ---------------------------------------------------------------- 7
group("7. a shipped preset round-trips through a real run folder (#72)")
# The acceptance of #72: load preset -> generate -> load the generated run.json
# back -> byte-identical YAMLs. It lives here rather than in verify-scope
# because only this suite has a real serve.py writing real run folders and a
# real Runs table to load one back from -- everywhere else it would be a
# comparison of a page against itself.
#
# The four compositions are LITERALS. A suite that read them out of the page
# under test would pass whatever that page said; these are the rows
# stack/stress.md §2 measured, written down again on purpose.
W = "src/common/model/urdf/plane.urdf"
FIX = "plane_base_link"
EXPECT = {
    "Stock Go2 walk": {"world_urdf": W, "world_fix_link": FIX,
                       "simulator_realtime_rate": 1, "publish_quad_state": True,
                       "mpc_solver": "PARTIAL_CONDENSING_HPIPM",
                       "mpc_hpipm_mode": "SPEED", "mpc_condensed_size": 5},
    "Solver benchmark A (HPIPM)": {"world_urdf": W, "world_fix_link": FIX,
                                   "simulator_realtime_rate": 0, "publish_quad_state": True,
                                   "mpc_solver": "PARTIAL_CONDENSING_HPIPM",
                                   "mpc_hpipm_mode": "SPEED", "mpc_condensed_size": 5},
    "Solver benchmark B (OSQP)": {"world_urdf": W, "world_fix_link": FIX,
                                  "simulator_realtime_rate": 0, "publish_quad_state": True,
                                  "mpc_solver": "PARTIAL_CONDENSING_OSQP",
                                  "mpc_hpipm_mode": "SPEED", "mpc_condensed_size": 5},
    "Stress": {"world_urdf": W, "world_fix_link": FIX,
               "simulator_realtime_rate": 1, "publish_quad_state": True,
               "mpc_solver": "PARTIAL_CONDENSING_OSQP",
               "mpc_hpipm_mode": "SPEED", "mpc_condensed_size": 1},
}
PRESET_HELPERS = r"""
window.__presetSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /load preset/.test(o.textContent)));
window.__loadPreset = name => { const s = window.__presetSel();
  const o = [...s.options].find(o => o.value && o.textContent.trim() === name);
  if (!o) return false; window.__setSel(s, o.value); return true; };
window.__pane = () => { const p = [...document.querySelectorAll('pre')]
  .filter(p => /ros__parameters/.test(p.textContent)); return p.length ? p[0].textContent : ''; };
// The `load` control of ONE row -- searched inside that row's element, so a
// second `load` anywhere on the page can never be the one clicked.
window.__loadRow = i => { const r = window.__rowEls()[i]; if (!r) return false;
  const b = [...r.querySelectorAll('div')].find(d => !d.querySelector('div')
    && d.textContent.trim() === 'load');
  if (!b) return false; b.click(); return true; };
true"""
SIM_TAB, CTRL_TAB = "simulator_params_go2.yaml", "mit_controller_sim_go2.yaml"


def pane(tab):
    ws.js("__click(%r)" % tab)
    time.sleep(0.45)
    return ws.js("__pane()")


for name in ("Stock Go2 walk", "Solver benchmark A (HPIPM)",
             "Solver benchmark B (OSQP)", "Stress"):
    goto()
    ws.js(PRESET_HELPERS)
    view("Compose")
    loaded = ws.js("__loadPreset(%r)" % name)
    time.sleep(0.5)
    check("%s loads in the composer" % name, loaded is not False)
    sim_a, ctrl_a = pane(SIM_TAB), pane(CTRL_TAB)
    ws.js("__click('Compose')")
    time.sleep(0.3)
    before = {r["run"] for r in api("/api/runs")[1]["runs"]}
    ws.js("__click(__sendBtn().textContent.trim())")
    wait_for(lambda: {r["run"] for r in api("/api/runs")[1]["runs"]} - before, timeout=15)
    new = sorted({r["run"] for r in api("/api/runs")[1]["runs"]} - before)
    check("  a run folder was written for it", bool(new), str(new))
    if not new:
        continue
    run = new[-1]
    on_disk = {n: open(os.path.join(OUT, run, n), "rb").read().decode()
               for n in ("simulator_params_go2.yaml", "mit_controller_sim_go2.yaml", "run.json")}
    check("  the folder's YAMLs are the panes, byte for byte",
          on_disk["simulator_params_go2.yaml"] == sim_a
          and on_disk["mit_controller_sim_go2.yaml"] == ctrl_a)
    choices = json.loads(on_disk["run.json"])["choices"]
    check("  run.json records the preset's composition", choices == EXPECT[name], str(choices))
    # Now the other half: the run folder back into the composer, through the
    # Runs view's own `load` -- cfgFromChoices -> normalizeCfg -> the emitters.
    goto()
    ws.js(PRESET_HELPERS)
    view("Runs")
    check("  the run is the newest row",
          (ws.js("__rows()") or [["", ""]])[0][1].startswith(run), str((ws.js("__rows()") or [[]])[0][:2]))
    check("  its `load` control is there", ws.js("__loadRow(0)") is not False)
    time.sleep(0.7)
    check("  load lands on Compose", "Compose experiment" in (ws.js("__txt()") or ""))
    check("  and the reloaded run regenerates the same bytes",
          pane(SIM_TAB) == sim_a and pane(CTRL_TAB) == ctrl_a,
          "export.md §6's round-trip, from a run folder a server actually wrote")
    time.sleep(1.1)   # stampNow() has one-second resolution: two sends inside it collide
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            ".filter(n=>!n.startsWith('http://localhost:'))")
check("zero non-localhost requests through the whole round trip", not ext, str(ext))

# ---------------------------------------------------------------- 8
group("8. the harness fixture is what the console emits (#24)")
# test/fixtures/run-<stamp>/ is the composition issue #24's Yuruna sequence
# applies: a run folder the console EXPORTED, committed, and never hand-edited.
# Two things have to stay true of it, and neither is visible by reading it.
#
#   a. It is a console export -- the same four files, the same bytes the
#      emitters produce, the pin it claims. Asserted statically here and then
#      by round-tripping it through the real Runs table, which is the only
#      place in this repo where a run folder becomes a composition again.
#   b. The MVP sequence restates its name, the pin, the solver and the sha256
#      of each YAML, so a fixture regenerated without the sequence being
#      updated is a red run at the apply step rather than a quietly different
#      experiment. Those literals are compared against the fixture below.
#
# Regenerate with `demo/tools/kennel-demo.sh compose` (no knobs), never by
# editing a file -- see test/harness.md.
REPO = os.path.dirname(HERE)
FIXROOT = os.path.join(REPO, "test", "fixtures")
RUN_FILES = ("simulator_params_go2.yaml", "mit_controller_sim_go2.yaml",
             "commands.txt", "run.json")

fixdirs = sorted(n for n in os.listdir(FIXROOT)) if os.path.isdir(FIXROOT) else []
check("exactly one fixture run folder", len(fixdirs) == 1, str(fixdirs))
FIXNAME = fixdirs[0] if fixdirs else ""
FIX = os.path.join(FIXROOT, FIXNAME)
check("it is named run-<stamp>", re.fullmatch(r"run-\d{8}T\d{6}Z", FIXNAME) is not None, FIXNAME)
check("it holds the four files an export carries, and nothing else",
      sorted(os.listdir(FIX)) == sorted(RUN_FILES), str(sorted(os.listdir(FIX))))

fix_bytes = {n: open(os.path.join(FIX, n), "rb").read() for n in RUN_FILES}
fix_json = json.loads(fix_bytes["run.json"])
fix_sha = {n: hashlib.sha256(fix_bytes[n]).hexdigest() for n in RUN_FILES}

pin = ""
for line in open(os.path.join(REPO, "stack", "pin.lock")):
    if line.startswith("commit:"):
        pin = line.split(":", 1)[1].strip()
check("run.json's pin is stack/pin.lock's commit", fix_json.get("pin") == pin, fix_json.get("pin", ""))

# The composition, as literals. The suite states what the fixture must be
# rather than reading it out of the thing under test -- the same rule group 7
# follows for the shipped presets.
check("the fixture composes the driver's default: OSQP",
      fix_json["choices"]["mpc_solver"] == "PARTIAL_CONDENSING_OSQP",
      fix_json["choices"]["mpc_solver"])
check("...at realtime rate 0.75",
      fix_json["choices"]["simulator_realtime_rate"] == 0.75,
      str(fix_json["choices"]["simulator_realtime_rate"]))
check("...on the flat plane, ground truth on",
      fix_json["choices"]["world_urdf"].endswith("plane.urdf")
      and fix_json["choices"]["publish_quad_state"] is True)
check("both are non-stock, so the sequence's assert is a real one",
      fix_json["choices"]["mpc_solver"] != "PARTIAL_CONDENSING_HPIPM"
      and fix_json["choices"]["simulator_realtime_rate"] != 1,
      "stock is HPIPM at rate 1")

# commands.txt, split by p21-launch-from-commands.sh's own rule: the payload is
# every non-comment, non-blank line, and a block ends at its `ros2 launch` (or
# `ros2 run`) line. Three blocks, the canonical three, in order, no fourth.
payload = [l for l in fix_bytes["commands.txt"].decode().splitlines()
           if l.strip() and not l.lstrip().startswith("#")]
blocks = [l for l in payload if l.startswith("ros2 launch ") or l.startswith("ros2 run ")]
check("commands.txt splits into exactly three shells", len(blocks) == 3, str(len(blocks)))
check("...the canonical three of stack/launch.md §1.1, in order",
      blocks == ["ros2 launch simulator simulator.launch.py sim:=go2",
                 "ros2 launch drivers leg_driver_launch.py sim:=go2",
                 "ros2 launch controllers mit_controller.launch.py sim:=go2"],
      str(blocks))
check("...and no fourth block: the fixture composes no disturbances",
      not any(l.startswith("ros2 run ") for l in payload)
      and fix_json["choices"].get("disturbances") in (None, False))

# The round trip, through a real server and the real Runs table: the fixture
# loads back into the composer and the emitters reproduce it byte for byte.
# This is what makes "it is a console export" a measurement rather than a
# claim -- a hand-edited YAML would not survive it.
shutil.copytree(FIX, os.path.join(OUT, FIXNAME), dirs_exist_ok=True)
shutil.copyfile(os.path.join(FIXTURES, "verify-completed-osqp.json"),
                os.path.join(OUT, FIXNAME, "verify.json"))
goto()
ws.js(PRESET_HELPERS)
ws.js("window.__rowIndexOf = name => window.__rows().findIndex(r => (r[1]||'').startsWith(name));\ntrue")
view("Runs")
idx = ws.js("__rowIndexOf(%r)" % FIXNAME)
check("the fixture appears in the Runs table", isinstance(idx, int) and idx >= 0, str(idx))
if isinstance(idx, int) and idx >= 0:
    check("its `load` control is there", ws.js("__loadRow(%d)" % idx) is not False)
    time.sleep(0.7)
    check("load lands on Compose", "Compose experiment" in (ws.js("__txt()") or ""))
    sim_f, ctrl_f = pane(SIM_TAB), pane(CTRL_TAB)
    check("the composer regenerates the fixture's simulator YAML byte for byte",
          sim_f == fix_bytes["simulator_params_go2.yaml"].decode())
    check("...and its controller YAML byte for byte",
          ctrl_f == fix_bytes["mit_controller_sim_go2.yaml"].decode())
    # And out again: a send from that state writes the same bytes, so the
    # fixture is a fixed point of the console rather than an old export the
    # emitters have since drifted away from.
    ws.js("__click('Compose')")
    time.sleep(0.3)
    before = {r["run"] for r in api("/api/runs")[1]["runs"]}
    ws.js("__click(__sendBtn().textContent.trim())")
    wait_for(lambda: {r["run"] for r in api("/api/runs")[1]["runs"]} - before, timeout=15)
    new = sorted({r["run"] for r in api("/api/runs")[1]["runs"]} - before)
    check("a fresh send writes a new run folder", bool(new), str(new))
    if new:
        again = {n: open(os.path.join(OUT, new[-1], n), "rb").read() for n in RUN_FILES}
        check("its two YAMLs are the fixture's, byte for byte",
              hashlib.sha256(again["simulator_params_go2.yaml"]).hexdigest()
              == fix_sha["simulator_params_go2.yaml"]
              and hashlib.sha256(again["mit_controller_sim_go2.yaml"]).hexdigest()
              == fix_sha["mit_controller_sim_go2.yaml"],
              "the emitters have not drifted since the fixture was exported")
        check("its commands.txt is the fixture's too",
              hashlib.sha256(again["commands.txt"]).hexdigest() == fix_sha["commands.txt"])
        check("only run.json differs, and only in its stamp",
              json.loads(again["run.json"])["choices"] == fix_json["choices"]
              and json.loads(again["run.json"])["run"] != fix_json["run"],
              "export.md §1: three files are deterministic, run.json carries the stamp")

# The other half of (b): the MVP sequence's four literals. It restates them so
# that a fixture regenerated on its own fails LOUDLY at the apply step -- which
# only works while they agree, and nothing else in the repo compares them.
SEQ = os.path.join(REPO, "test", "workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml")
seq_text = open(SEQ).read() if os.path.exists(SEQ) else ""
check("the MVP sequence is there to compare against", bool(seq_text), SEQ)
check("it stages the fixture this repo ships",
      ("KENNEL_MVP_RUN=%s " % FIXNAME) in seq_text, FIXNAME)
check("it expects the pin run.json carries", ("KENNEL_PIN=%s " % pin) in seq_text, pin)
check("it expects the solver the fixture composes",
      "--expect-solver PARTIAL_CONDENSING_OSQP" in seq_text
      and "KENNEL_EXPECT_SOLVER" not in seq_text)
check("it restates the simulator YAML's sha256",
      ("KENNEL_EXPECT_SIM_SHA=%s " % fix_sha["simulator_params_go2.yaml"]) in seq_text,
      fix_sha["simulator_params_go2.yaml"][:16] + "...")
check("it restates the controller YAML's sha256",
      ("KENNEL_EXPECT_CTRL_SHA=%s " % fix_sha["mit_controller_sim_go2.yaml"]) in seq_text,
      fix_sha["mit_controller_sim_go2.yaml"][:16] + "...")
# And the fixture is what a cycle would actually run: test.runner.yml's
# top-level has to be the sequence that applies it.
runner = yaml.safe_load(open(os.path.join(REPO, "test", "test.runner.yml")))
check("a cycle's top-level is the sequence that applies it",
      runner.get("sequences") == ["workload.guest.ubuntu.server.24.kennel.mvp.ssh"],
      str(runner.get("sequences")))
# Every YAML under test/ has to PARSE, because Yuruna's pre-cycle gate parses
# each one and refuses to start the cycle over a single bad file -- and a plain
# scalar carrying ": " is invalid YAML that reads perfectly well to a human.
# Found the hard way: a testSets description did exactly that and the gate
# refused the MVP run four seconds in.
for name in sorted(n for n in os.listdir(os.path.join(REPO, "test")) if n.endswith(".yml")):
    try:
        yaml.safe_load(open(os.path.join(REPO, "test", name)))
        parsed, why = True, ""
    except Exception as exc:                       # noqa: BLE001 - report any parse failure
        parsed, why = False, str(exc).splitlines()[0]
    check("test/%s parses as YAML" % name, parsed, why)

ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            ".filter(n=>!n.startsWith('http://localhost:'))")
check("zero non-localhost requests while round-tripping the fixture", not ext, str(ext))

print()
for g in groups:
    n, p = groups[g][0], groups[g][1]
    print("  %-72s %d/%d" % (g, p, n))
print()
print("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)
