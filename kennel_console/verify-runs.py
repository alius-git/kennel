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
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request

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

print()
for g in groups:
    n, p = groups[g][0], groups[g][1]
    print("  %-72s %d/%d" % (g, p, n))
print()
print("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)
