"""Acceptance checks for issue #19 — the generated artifacts leave as files.

Driven by verify-export.sh. Usage: verify-export.py <httpPort> <cdpPort> <downloadDir>

Downloads are real: the browser is told to write into a throwaway directory and
the bytes that land there are what is asserted on. Nothing is read back out of a
JavaScript variable, because the property under test is precisely that the file
on disk equals what the generator produced.
"""
import hashlib
import json
import os
import re
import sys
import time
import zipfile

from cdp import attach

HTTP_PORT = sys.argv[1] if len(sys.argv) > 1 else "8050"
CDP_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9250
DL = os.path.abspath(sys.argv[3])
ws = attach(CDP_PORT)
ok = True
PIN = "dcf53c596339afd45b82f12c54b1e93e8273c2f4"
NAMES = ["simulator_params_go2.yaml", "mit_controller_sim_go2.yaml",
         "commands.txt", "run.json"]


def check(label, cond, detail=""):
    global ok
    ok = ok and bool(cond)
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))


# Downloads are off by default in headless Chrome. Browser.setDownloadBehavior is
# the current command; older builds only carry the deprecated Page. variant, so
# fall back rather than fail the whole suite on a protocol rename.
try:
    ws.call("Browser.setDownloadBehavior", behavior="allow", downloadPath=DL)
    DL_API = "Browser.setDownloadBehavior"
except RuntimeError:
    ws.call("Page.setDownloadBehavior", behavior="allow", downloadPath=DL)
    DL_API = "Page.setDownloadBehavior"

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
window.__pane = () => { const p = [...document.querySelectorAll('pre')]
  .filter(p => /ros__parameters/.test(p.textContent)); return p.length ? p[0].textContent : ''; };
window.__cmds = () => [...document.querySelectorAll('div')]
  .filter(d => /^source \/opt\/ros/.test(d.textContent.trim()))
  .map(d => d.textContent);
// An export button is <name><download>; matched structurally so it can never be
// confused with the YAML tab that carries the same filename as its label.
window.__exportRow = name => [...document.querySelectorAll('div')].find(d =>
  d.children.length === 2 && d.children[0].textContent.trim() === name &&
  /^(download|saved)$/.test(d.children[1].textContent.trim()));
window.__export = name => { const e = window.__exportRow(name);
  if (e) { e.click(); return true; } return false; };
true""")


def pane(tab):
    ws.js(f"__click({tab!r})")
    time.sleep(0.45)
    return ws.js("__pane()")


def settled(timeout=8):
    """Wait until no partial download is in flight, then list what landed."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        names = os.listdir(DL)
        if names and not any(n.endswith(".crdownload") for n in names):
            time.sleep(0.25)
            return sorted(os.listdir(DL))
        time.sleep(0.2)
    return sorted(os.listdir(DL))


def wipe():
    for n in os.listdir(DL):
        os.remove(os.path.join(DL, n))


def read(name):
    with open(os.path.join(DL, name), "rb") as f:
        return f.read()


SIM_TAB, CTRL_TAB = "simulator_params_go2.yaml", "mit_controller_sim_go2.yaml"

print(f"\n0. the export surface exists ({DL_API})")
for n in NAMES:
    check(f"download button for {n}", ws.js(f"!!__exportRow({n!r})"))
check("generate run button present", "generate run" in ws.js("__txt()"))

print("\n1. every artifact downloads, and the YAML bytes are the generator's")
# Read the panes FIRST: what the user sees is the reference the file must match.
sim_pane, ctrl_pane = pane(SIM_TAB), pane(CTRL_TAB)
wipe()
for n in NAMES:
    ws.js(f"__export({n!r})")
    time.sleep(0.5)
landed = settled()
check("all four files landed", landed == sorted(NAMES), str(landed))

sim_bytes, ctrl_bytes = read(NAMES[0]), read(NAMES[1])
check("simulator_params_go2.yaml is byte-identical to the generated pane",
      sim_bytes.decode() == sim_pane,
      f"{len(sim_bytes)} B vs {len(sim_pane.encode())} B")
check("mit_controller_sim_go2.yaml is byte-identical to the generated pane",
      ctrl_bytes.decode() == ctrl_pane,
      f"{len(ctrl_bytes)} B vs {len(ctrl_pane.encode())} B")
check("the controller file is correct even though the simulator tab was last shown",
      b"mpc_solver:" in ctrl_bytes)
for n in NAMES:
    raw = read(n)
    check(f"{n}: no browser mangling",
          b"\r\n" not in raw and not raw.startswith(b"\xef\xbb\xbf") and raw.endswith(b"\n"),
          "CRLF" if b"\r\n" in raw else "BOM" if raw.startswith(b"\xef\xbb\xbf")
          else "" if raw.endswith(b"\n") else "no trailing newline")
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError:
        check(f"{n}: valid UTF-8", False)

solo = {n: read(n) for n in NAMES}

print("\n2. one Generate-run click yields the run folder as a store-only archive")
wipe()
ws.js("__click('generate run ↓')")
time.sleep(0.6)
landed = settled()
check("exactly one file downloaded by Generate", len(landed) == 1, str(landed))
zname = landed[0] if landed else ""
check("named run-<timestamp>.zip", re.fullmatch(r"run-\d{8}T\d{6}Z\.zip", zname), zname)

zf = zipfile.ZipFile(os.path.join(DL, zname))
check("archive is not corrupt (every CRC-32 checks out)", zf.testzip() is None)
infos = zf.infolist()
stem = zname[:-4]
check("four entries", len(infos) == 4, str([i.filename for i in infos]))
check("every entry sits under the run-<timestamp>/ folder",
      all(i.filename.startswith(stem + "/") for i in infos),
      str([i.filename for i in infos]))
check("the folder holds exactly the four artifacts",
      sorted(i.filename.split("/", 1)[1] for i in infos) == sorted(NAMES))
check("every entry is STORED, so the YAML bytes sit in the archive literally",
      all(i.compress_type == zipfile.ZIP_STORED for i in infos))

zipped = {i.filename.split("/", 1)[1]: zf.read(i.filename) for i in infos}
for n in ["simulator_params_go2.yaml", "mit_controller_sim_go2.yaml", "commands.txt"]:
    check(f"archived {n} == the separately downloaded file", zipped[n] == solo[n],
          hashlib.sha256(zipped[n]).hexdigest()[:12] + " vs "
          + hashlib.sha256(solo[n]).hexdigest()[:12])
check("archived simulator YAML == the generated pane", zipped[NAMES[0]].decode() == sim_pane)
check("archived controller YAML == the generated pane", zipped[NAMES[1]].decode() == ctrl_pane)

print("\n3. run.json — minimal provenance, and it agrees with the YAMLs")
rj = json.loads(zipped["run.json"])
check("keys are exactly run_id, run, generated_at, pin, choices",
      list(rj.keys()) == ["run_id", "run", "generated_at", "pin", "choices"], str(list(rj.keys())))
check("pin SHA recorded", rj.get("pin") == PIN, str(rj.get("pin")))
check("generated_at is ISO-8601 UTC to the second",
      bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", rj.get("generated_at", ""))),
      str(rj.get("generated_at")))
check("run matches the folder the archive actually used", rj.get("run") == stem,
      f"{rj.get('run')} vs {stem}")
check("run is derived from generated_at",
      "run-" + re.sub(r"[-:]", "", rj.get("generated_at", "")) == rj.get("run"))
check("run_id is the manifest id shown in the UI",
      bool(re.fullmatch(r"RUN-\d{4}-\d{4}-\d{4}", rj.get("run_id", ""))), str(rj.get("run_id")))
check("choices carries exactly the seven composer-owned fields",
      sorted(rj.get("choices", {})) == sorted([
          "world_urdf", "world_fix_link", "simulator_realtime_rate", "publish_quad_state",
          "mpc_solver", "mpc_hpipm_mode", "mpc_condensed_size"]),
      str(sorted(rj.get("choices", {}))))

print("\n4. commands.txt is the launch block, with #18's constraints intact")
ui_cmds = ws.js("__cmds()")
txt = zipped["commands.txt"].decode()
check("all three UI command blocks appear verbatim",
      all(c in txt for c in ui_cmds), f"{sum(c in txt for c in ui_cmds)}/3")
check("three ros2 launch invocations", txt.count("ros2 launch ") == 3, str(txt.count("ros2 launch ")))
check("simulator, leg driver and controller launched by package, not path",
      "ros2 launch simulator simulator.launch.py sim:=go2" in txt
      and "ros2 launch drivers leg_driver_launch.py sim:=go2" in txt
      and "ros2 launch controllers mit_controller.launch.py sim:=go2" in txt)
check("every block carries the source chain and lands in /root/ros2_ws",
      txt.count("source /root/setup_ulab_workspace.bash") == 3
      and txt.count("cd /root/ros2_ws") == 3)
check("NO mpc_*:= launch args (mapping.md §2.1)", "mpc_" not in txt)
check("no safe_start:= and no config:=", "safe_start" not in txt and "config:=" not in txt)
check("no absolute-path launch invocation", "ros2 launch /" not in txt)
check("pin SHA in the header", PIN in txt)
check("the config precondition is stated, not assumed",
      "src/simulator/config/simulator_params_go2.yaml" in txt
      and "src/controllers/config/mit_controller_sim_go2.yaml" in txt)
check("it does not pretend to be a runnable script",
      not txt.startswith("#!") and "not a script" in txt)

print("\n5. a non-stock choice reaches the exported files")
ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_OSQP')")
time.sleep(0.4)
ws.js("__click('Obstacle terrain')")
time.sleep(0.4)
wipe()
ws.js("__click('generate run ↓')")
time.sleep(0.6)
landed = settled()
zf2 = zipfile.ZipFile(os.path.join(DL, landed[0]))
stem2 = landed[0][:-4]
z2 = {i.filename.split("/", 1)[1]: zf2.read(i.filename) for i in zf2.infolist()}
rj2 = json.loads(z2["run.json"])
check("run.json records the composed solver",
      rj2["choices"]["mpc_solver"] == "PARTIAL_CONDENSING_OSQP", rj2["choices"]["mpc_solver"])
check("run.json records the composed world",
      rj2["choices"]["world_urdf"].endswith("terrain.urdf"), rj2["choices"]["world_urdf"])
check("the exported controller YAML carries that solver",
      b'mpc_solver: "PARTIAL_CONDENSING_OSQP"' in z2[NAMES[1]])
check("the exported simulator YAML carries that world",
      b'world_urdf: "src/common/model/urdf/terrain.urdf"' in z2[NAMES[0]])

try:
    import yaml
    ds = yaml.safe_load(z2[NAMES[0]].decode())["drake_simulator"]["ros__parameters"]
    dc = yaml.safe_load(z2[NAMES[1]].decode())["mit_controller_node"]["ros__parameters"]
    ch = rj2["choices"]
    check("run.json choices == what a YAML parser recovers from the exported files",
          ds["world_urdf"] == ch["world_urdf"]
          and ds["world_fix_link"] == ch["world_fix_link"]
          and ds["simulator_realtime_rate"] == ch["simulator_realtime_rate"]
          and ds["publish_quad_state"] == ch["publish_quad_state"]
          and dc["mpc_solver"] == ch["mpc_solver"]
          and dc["mpc_hpipm_mode"] == ch["mpc_hpipm_mode"]
          and dc["mpc_condensed_size"] == ch["mpc_condensed_size"])
    check("the exported files are still valid YAML after the round trip through disk",
          isinstance(ds["simulator_realtime_rate"], float)
          and isinstance(dc["mpc_condensed_size"], int)
          and isinstance(ds["publish_quad_state"], bool))
except ImportError:
    print("  [SKIP] pyyaml not installed — the textual checks above still apply")

print("\n6. determinism survives export: only the stamp moves")
time.sleep(1.4)   # a second stamp, so the two runs are distinguishable
wipe()
ws.js("__click('generate run ↓')")
time.sleep(0.6)
landed = settled()
zf3 = zipfile.ZipFile(os.path.join(DL, landed[0]))
stem3 = landed[0][:-4]
z3 = {i.filename.split("/", 1)[1]: zf3.read(i.filename) for i in zf3.infolist()}
check("a second export of the same state gets its own folder", stem3 != stem2, stem3)
for n in ["simulator_params_go2.yaml", "mit_controller_sim_go2.yaml", "commands.txt"]:
    check(f"{n} is byte-identical across the two exports", z3[n] == z2[n])
rj3 = json.loads(z3["run.json"])
moved = [k for k in rj3 if rj3[k] != rj2[k]]
check("run.json differs only in the stamp and the manifest id",
      sorted(moved) == sorted(["run", "generated_at", "run_id"]), str(moved))
check("the composed choices are unchanged", rj3["choices"] == rj2["choices"])

print("\n7. no network escaped")
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            f".filter(n=>!n.startsWith('http://localhost:{HTTP_PORT}'))")
check("zero non-localhost requests", not ext, str(ext))

print("\n" + ("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED"))
sys.exit(0 if ok else 1)
