"""Acceptance checks for issue #56 — the console writes where the driver reads.

Group 7 (#74, #75): the guest's version manifest and drift report reach the page
through /api/health, and run.json references the manifest when one is known.

Driven by verify-send.sh.
Usage: verify-send.py <servePort> <plainPort> <cdpPort> <outDir> <downloadDir>

Two properties are under test and they pull in opposite directions:

  1. Served by serve.py, one click puts a run folder on the host's disk, and the
     bytes in it are the same bytes `generate run` downloads — asserted by
     exporting BOTH ways in one session and comparing them, not by trusting that
     two code paths call the same emitter.
  2. Served by plain `python3 -m http.server`, the console is exactly what it
     was before this issue: no button, no error, no unresolved placeholders.
     The feature detection is the whole mechanism, so it is verified from the
     far side — a second origin in the same browser.

Nothing is read back out of a JavaScript variable where a file is the claim.
"""
import hashlib
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
import zipfile

from cdp import attach

SERVE_PORT = sys.argv[1]
PLAIN_PORT = sys.argv[2]
CDP_PORT = int(sys.argv[3])
OUT = os.path.abspath(sys.argv[4])
DL = os.path.abspath(sys.argv[5])
ORIGIN = "http://localhost:%s" % SERVE_PORT
PAGE = "/Kennel%20Console.dc.html"

PIN = "dcf53c596339afd45b82f12c54b1e93e8273c2f4"
NAMES = ["simulator_params_go2.yaml", "mit_controller_sim_go2.yaml",
         "commands.txt", "run.json"]
SIM_TAB, CTRL_TAB = NAMES[0], NAMES[1]
SEND_LABEL = "send to %s →" % os.path.basename(OUT)

ws = attach(CDP_PORT)
ok = True


def check(label, cond, detail=""):
    global ok
    ok = ok and bool(cond)
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))


try:
    ws.call("Browser.setDownloadBehavior", behavior="allow", downloadPath=DL)
except RuntimeError:
    ws.call("Page.setDownloadBehavior", behavior="allow", downloadPath=DL)

# Installed before the second navigation, so group 5 can assert that a 404 on
# /api/health raises nothing: an uncaught rejection there would be invisible to
# a DOM check and is exactly the failure mode feature detection invites.
ws.call("Page.addScriptToEvaluateOnNewDocument", source=(
    "window.__errs = [];"
    "window.addEventListener('error', e => window.__errs.push(String(e.message)));"
    "window.addEventListener('unhandledrejection',"
    " e => window.__errs.push('unhandled rejection: ' + e.reason));"))

HELPERS = r"""
window.__txt = () => document.body.innerText;
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
window.__solverSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /CONDENSING/.test(o.value)));
window.__setSel = (s, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set;
  setter.call(s, val); s.dispatchEvent(new Event('change', {bubbles:true})); };
window.__pane = () => { const p = [...document.querySelectorAll('pre')]
  .filter(p => /ros__parameters/.test(p.textContent)); return p.length ? p[0].textContent : ''; };
// Structural, like verify-export.py's: an export row is <name><download>, and
// the send button must never be mistaken for one.
window.__exportRow = name => [...document.querySelectorAll('div')].find(d =>
  d.children.length === 2 && d.children[0].textContent.trim() === name &&
  /^(download|saved)$/.test(d.children[1].textContent.trim()));
// The innermost div carrying exactly the label. NOT `!d.querySelector('*')`:
// the template engine wraps every {{ mustache }} in a <span class="sc-interp">,
// so a no-children matcher silently matches nothing and turns the "no send
// button under http.server" check in group 5 into a check of nothing at all.
window.__sendBtn = () => [...document.querySelectorAll('div')].find(d =>
  !d.querySelector('div') && /^send to .+ →$/.test(d.textContent.trim()));
true"""
ws.js(HELPERS)


def pane(tab):
    ws.js(f"__click({tab!r})")
    time.sleep(0.45)
    return ws.js("__pane()")


def api(path):
    with urllib.request.urlopen(ORIGIN + path, timeout=10) as r:
        return json.load(r)


def post(raw):
    """POST an archive. Returns (status, body) — a refusal is data, not an error."""
    req = urllib.request.Request(ORIGIN + "/api/runs", data=raw, method="POST",
                                 headers={"Content-Type": "application/zip"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.load(e)


def wait_for_new_run(before, timeout=15):
    """Watch the server's own view of OUT until a run appears (never a sleep)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        now = {r["run"] for r in api("/api/runs")["runs"]}
        new = now - before
        if new:
            return sorted(new)[-1]
        time.sleep(0.2)
    return None


def settled_zip(timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        names = [n for n in os.listdir(DL) if n.endswith(".zip")]
        if names and not any(n.endswith(".crdownload") for n in os.listdir(DL)):
            time.sleep(0.25)
            return sorted(names)[-1]
        time.sleep(0.2)
    return None


def read(path):
    with open(path, "rb") as f:
        return f.read()


def make_zip(run, names=NAMES, pin=PIN, method=zipfile.ZIP_STORED, source=None):
    """Craft an archive the way the console would, then bend one thing about it."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for n in names:
            data = source[n] if source and n in source else b"placeholder\n"
            if n == "run.json":
                data = (json.dumps({"run_id": "RUN-2026-0724-1400", "run": run,
                                    "generated_at": "2026-08-30T12:00:00Z", "pin": pin,
                                    "choices": {}}, indent=2) + "\n").encode()
            z.writestr(zipfile.ZipInfo(f"{run}/{n}"), data, compress_type=method)
    return buf.getvalue()


print("\n0. the send surface exists, and only because the server offers it")
health = api("/api/health")
check("GET /api/health reports a kennel server", health.get("kennel") is True, str(health))
check("health names the run directory", health.get("out") == OUT, str(health.get("out")))
check("health names the stack pin", health.get("pin") == PIN, str(health.get("pin")))
check("the send button rendered", bool(ws.js("!!__sendBtn()")))
check("it says where the bytes go", SEND_LABEL in ws.js("__txt()"), SEND_LABEL)
check("generate run ↓ is still there", "generate run" in ws.js("__txt()"))
for n in NAMES:
    check(f"the export strip still carries {n}", ws.js(f"!!__exportRow({n!r})"))

print("\n1. one click puts a run folder on the host's disk")
# A non-stock solver, so what lands is provably a composition and not a default.
ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_HPIPM')")
time.sleep(0.5)
sim_pane, ctrl_pane = pane(SIM_TAB), pane(CTRL_TAB)
before = {r["run"] for r in api("/api/runs")["runs"]}
ws.js(f"__click({SEND_LABEL!r})")
run = wait_for_new_run(before)
check("a new run folder appeared in OUT", run is not None, str(run))
if run is None:
    print("\n" + "SOME CHECKS FAILED")
    print("  strip said: " + " | ".join(l for l in ws.js("__txt()").splitlines() if "send" in l.lower()))
    sys.exit(1)
folder = os.path.join(OUT, run)
check("it holds exactly the four artifacts", sorted(os.listdir(folder)) == sorted(NAMES),
      str(sorted(os.listdir(folder))))
sent = {n: read(os.path.join(folder, n)) for n in NAMES}
check("simulator_params_go2.yaml is byte-identical to the rendered pane",
      sent[SIM_TAB].decode() == sim_pane, f"{len(sent[SIM_TAB])} B vs {len(sim_pane.encode())} B")
check("mit_controller_sim_go2.yaml is byte-identical to the rendered pane",
      sent[CTRL_TAB].decode() == ctrl_pane, f"{len(sent[CTRL_TAB])} B vs {len(ctrl_pane.encode())} B")
meta = json.loads(sent["run.json"])
check("run.json carries the composed solver",
      meta["choices"]["mpc_solver"] == "PARTIAL_CONDENSING_HPIPM", meta["choices"]["mpc_solver"])
check("run.json carries the stack pin", meta["pin"] == PIN)
check("run.json's run equals the folder it landed in", meta["run"] == run)
check("the strip reports the path the server wrote", folder in ws.js("__txt()"))

print("\n2. sent bytes == downloaded bytes, in one session")
dl_name = None
ws.js("__click('generate run ↓')")
dl_name = settled_zip()
check("generate run ↓ still downloads an archive", dl_name is not None, str(dl_name))
if dl_name:
    with zipfile.ZipFile(os.path.join(DL, dl_name)) as z:
        prefix = z.namelist()[0].split("/")[0]
        downloaded = {n: z.read(f"{prefix}/{n}") for n in NAMES}
    for n in NAMES[:3]:
        check(f"{n} is identical whether sent or downloaded", sent[n] == downloaded[n],
              f"{hashlib.sha256(sent[n]).hexdigest()[:12]} vs "
              f"{hashlib.sha256(downloaded[n]).hexdigest()[:12]}")
    # run.json is the one file that moves, and only where export.md §6 says --
    # a SUBSET of those three keys, not all of them: a send and a download one
    # second apart share a stamp, and then only run_id moves. (That collision is
    # also why the server refuses an existing folder: same stamp, same name.)
    a, b = json.loads(sent["run.json"]), json.loads(downloaded["run.json"])
    moved = sorted(k for k in a if a[k] != b[k])
    check("run.json differs only in the stamp and the manifest id",
          moved and set(moved) <= {"run", "generated_at", "run_id"}, str(moved))
    check("the two exports agree on every composed choice", a["choices"] == b["choices"])

print("\n3. the archive kept beside the folder is the artifact the console produced")
kept = os.path.join(OUT, run + ".zip")
check("run-<stamp>.zip was kept beside the folder", os.path.isfile(kept))
if os.path.isfile(kept):
    with zipfile.ZipFile(kept) as z:
        check("every CRC-32 checks out", z.testzip() is None)
        infos = z.infolist()
        check("four entries, all under the run folder",
              len(infos) == 4 and all(i.filename.startswith(run + "/") for i in infos),
              str([i.filename for i in infos]))
        check("every entry is STORED (export.md §2.2)",
              all(i.compress_type == zipfile.ZIP_STORED for i in infos))
        check("its entries are byte-identical to the folder on disk",
              all(z.read(f"{run}/{n}") == sent[n] for n in NAMES))

print("\n4. the server refuses what is not a console export, and writes nothing")
snapshot = sorted(os.listdir(OUT))
cases = [
    ("wrong pin → 409", make_zip("run-20260830T010101Z", pin="0" * 40), 409, "pin"),
    ("three entries → 400", make_zip("run-20260830T020202Z", names=NAMES[:3]), 400, "export"),
    ("a deflated entry → 400", make_zip("run-20260830T030303Z", method=zipfile.ZIP_DEFLATED),
     400, "compressed"),
    ("an existing folder → 409", make_zip(run), 409, "exists"),
    ("not a zip at all → 400", b"this is not a zip file", 400, "zip"),
    ("a traversing folder name → 400", make_zip("../../etc"), 400, "run-<stamp>"),
]
for label, raw, want, word in cases:
    status, body = post(raw)
    check(label, status == want and word in json.dumps(body), f"{status} {body.get('error', '')[:70]}")
check("nothing was written for any refused POST", sorted(os.listdir(OUT)) == snapshot,
      str(sorted(set(os.listdir(OUT)) ^ set(snapshot))))

print("\n5. served by plain http.server the console is what it always was")
ws.call("Page.navigate", url="http://localhost:%s%s" % (PLAIN_PORT, PAGE))
booted = False
deadline = time.time() + 30
while time.time() < deadline:
    try:
        body = ws.js("document.body ? document.body.innerText : ''")
        if body and "Compose experiment" in body:
            booted = True
            break
    except RuntimeError:
        pass
    time.sleep(0.3)
check("the console booted against a server with no /api/", booted)
ws.js(HELPERS)
check("no send button", not ws.js("!!__sendBtn()"))
check("generate run ↓ is unaffected", "generate run" in ws.js("__txt()"))
check("zero unresolved placeholders",
      "{{" not in ws.js("document.documentElement.outerHTML"))
check("the export strip is intact", all(ws.js(f"!!__exportRow({n!r})") for n in NAMES))
errors = ws.js("(window.__errs || []).length")
check("no console errors raised by the absent endpoint", not errors, str(errors))

print("\n6. no network escaped")
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            f".filter(n=>!n.startsWith('http://localhost:'))")
check("zero non-localhost requests", not ext, str(ext))

print("\n7. the guest's version manifest reaches the page, and run.json references it (#74, #75)")
# Appended after group 6, and it leaves groups 0-6 exactly as they were. What the
# driver would leave under --out is written here by hand -- the manifest and the
# drift report are FILES in a contract (serve.py reads them per request), so the
# claim is tested at that seam, and the bytes that land are read back off disk.
import re  # noqa: E402 -- group 7's alone

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(OUT, ".kennel-manifest.json")
DRIFT = os.path.join(OUT, ".kennel-drift")
FIVE = ["run_id", "run", "generated_at", "pin", "choices"]


def literal(path, pattern):
    with open(path, encoding="utf-8") as f:
        found = re.search(pattern, f.read(), re.M)
    return found.group(1) if found else None


def write_manifest(pin):
    """A manifest in the prep script's shape, written its canonical way. Returns its ref."""
    doc = {"schema": "kennel-manifest/1", "pin": pin, "created": "2026-09-10T12:00:00Z",
           "os": {"id": "ubuntu", "version_id": "24.04", "pretty_name": "Ubuntu 24.04.5 LTS"},
           "kernel": "6.8.0-139-generic", "docker": "29.8.0", "image_id": "sha256:" + "3f" * 32,
           "container_os": "Ubuntu 22.04.5 LTS", "ros_distro": "humble",
           "ros_base": "ros-humble-ros-base 0.10.0-1jammy.20260804.204550",
           "drake": "20231218181452 9ba8f5d8d4ee6919ec41542d47509549cfa8d919",
           "drake_source": "a suite fixture",
           "packages": {"file": "kennel-manifest.packages.txt", "count": 1, "sha256": "0" * 64},
           "project_commit": None, "console_version": server_v, "guides_version": None,
           "provenance": "knobs", "image_sha256": None}
    raw = (json.dumps(doc, indent=2, sort_keys=True) + "\n").encode()
    with open(MANIFEST, "wb") as f:
        f.write(raw)
    return hashlib.sha256(raw).hexdigest()


def reopen():
    """Back to serve.py's origin. The page asks /api/health once, on mount."""
    ws.call("Page.navigate", url=ORIGIN + PAGE)
    deadline = time.time() + 30
    while time.time() < deadline:
        try:
            if "Compose experiment" in (ws.js("document.body ? document.body.innerText : ''") or ""):
                break
        except RuntimeError:
            pass
        time.sleep(0.3)
    ws.js(HELPERS)


def page_text_when(pred, timeout=10):
    """The page text once pred holds -- the health probe is asynchronous -- or at the deadline."""
    deadline = time.time() + timeout
    text = ""
    while time.time() < deadline:
        text = ws.js("__txt()") or ""
        if pred(text):
            break
        time.sleep(0.2)
    return text


def next_second(after_run):
    """Two sends in one UTC second share a stamp and the second is refused: wait it out."""
    while after_run and time.strftime("run-%Y%m%dT%H%M%SZ", time.gmtime()) <= after_run:
        time.sleep(0.05)


def send_run():
    """Click send; the run.json that landed on disk, in file order. None if nothing did."""
    before = {r["run"] for r in api("/api/runs")["runs"]}
    ws.js(f"__click({SEND_LABEL!r})")
    landed = wait_for_new_run(before)
    return json.loads(read(os.path.join(OUT, landed, "run.json"))) if landed else None


server_v = literal(os.path.join(HERE, "serve.py"), r'^KENNEL_CONSOLE_VERSION = "([^"]+)"')
page_v = literal(os.path.join(HERE, "Kennel Console.dc.html"), r"^const KENNEL_CONSOLE_VERSION = '([^']+)';")
check("serve.py and the page carry one KENNEL_CONSOLE_VERSION", bool(server_v) and server_v == page_v,
      f"{server_v} vs {page_v}")
for leftover in (MANIFEST, DRIFT):
    if os.path.exists(leftover):
        os.remove(leftover)
health = api("/api/health")
check("/api/health reports the console version", health.get("console_version") == server_v,
      str(health.get("console_version")))
check("with nothing under --out, its manifest, manifest_ref and drift are null",
      health.get("manifest") is None and health.get("manifest_ref") is None and health.get("drift") is None,
      str({k: health.get(k) for k in ("manifest", "manifest_ref", "drift")})[:120])

ref = write_manifest(PIN)
health = api("/api/health")
check("once the driver has left one, health carries the guest's manifest",
      (health.get("manifest") or {}).get("pin") == PIN, str((health.get("manifest") or {}).get("pin")))
check("and manifest_ref is the sha256 of the file's bytes", health.get("manifest_ref") == ref,
      str(health.get("manifest_ref"))[:16])
reopen()
text = page_text_when(lambda t: ("guest " + PIN[:7]) in t and SEND_LABEL in t)
check("the export strip names the guest: its pin, its manifest, the console version",
      all(w in text for w in ("guest " + PIN[:7], "manifest " + ref[:7], "console " + str(server_v))),
      " | ".join(l for l in text.splitlines() if "guest " in l)[:160])
check("and warns about nothing: one pin, one console version, no drift report",
      not any(w in text for w in ("guest pin differs", "console version differs", "environment drifted")))
meta = send_run()
check("send still writes a run folder", meta is not None)
last_run = meta["run"] if meta else None
check("its run.json carries six keys, manifest_ref last",
      bool(meta) and list(meta.keys()) == FIVE + ["manifest_ref"], str(list(meta.keys()) if meta else None))
check("and that manifest_ref is the guest's", bool(meta) and meta.get("manifest_ref") == ref)

ref0 = write_manifest("0" * 40)
reopen()
text = page_text_when(lambda t: "guest pin differs" in t)
check("a guest at another pin is named in the strip", "guest pin differs" in text and "0" * 12 in text,
      " | ".join(l for l in text.splitlines() if "differs" in l)[:160])
next_second(last_run)
meta = send_run()
check("and a send still lands: the server's own pin is pin.lock's, not the guest's",
      bool(meta) and meta.get("manifest_ref") == ref0, str(meta.get("manifest_ref") if meta else None)[:16])
last_run = meta["run"] if meta else last_run

# The server's half: a run composed against a manifest the guest no longer
# carries. Stamped an hour back so it cannot collide with a send above.
stale = time.strftime("run-%Y%m%dT%H%M%SZ", time.gmtime(time.time() - 3600))
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w") as z:
    for n in NAMES:
        data = b"placeholder\n"
        if n == "run.json":
            data = (json.dumps({"run_id": "RUN-2026-0724-1499", "run": stale,
                                "generated_at": "2026-09-10T11:00:00Z", "pin": PIN, "choices": {},
                                "manifest_ref": "f" * 64}, indent=2) + "\n").encode()
        z.writestr(zipfile.ZipInfo(f"{stale}/{n}"), data, compress_type=zipfile.ZIP_STORED)
status, body = post(buf.getvalue())
check("a POST composed against another manifest is written, with a warning naming both refs",
      status == 201 and "f" * 12 in body.get("warning", "") and ref0[:12] in body.get("warning", ""),
      f"{status} {(body.get('warning') or body.get('error') or '')[:100]}")

with open(DRIFT, "w", encoding="utf-8") as f:
    json.dump({"schema": "kennel-drift/1", "checked": "2026-09-10T12:00:00Z", "manifest_ref": ref0,
               "findings": [{"class": "tracked-file", "detail": " M ws/src/common/launch/simulation.launch.py"},
                            {"class": "package", "detail": "sl 5.02-1 (added)"}],
               "notes": []}, f)
health = api("/api/health")
check("/api/health carries the drift report the driver left",
      len((health.get("drift") or {}).get("findings") or []) == 2, str(health.get("drift"))[:120])
reopen()
text = page_text_when(lambda t: "environment drifted" in t)
check("the strip warns: environment drifted, with the count", "environment drifted: 2 findings" in text,
      " | ".join(l for l in text.splitlines() if "drift" in l)[:160])
os.remove(DRIFT)
reopen()
text = page_text_when(lambda t: SEND_LABEL in t and ("guest " + "0" * 7) in t)
check("and stops warning once the report is gone", "environment drifted" not in text)

os.remove(MANIFEST)
health = api("/api/health")
check("with the manifest gone, health says so", health.get("manifest") is None and health.get("manifest_ref") is None)
reopen()
text = page_text_when(lambda t: SEND_LABEL in t)
check("and the strip names no guest", ("guest " + "0" * 7) not in text and ("guest " + PIN[:7]) not in text)
next_second(last_run)
meta = send_run()
check("a send with no manifest known writes the five keys export.md specifies",
      bool(meta) and list(meta.keys()) == FIVE, str(list(meta.keys()) if meta else None))
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            ".filter(n=>!n.startsWith('http://localhost:'))")
check("zero non-localhost requests in this group", not ext, str(ext))

print("\n" + ("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED"))
sys.exit(0 if ok else 1)
