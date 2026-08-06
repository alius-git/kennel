"""Acceptance checks for issue #18 — generated configs the pinned stack accepts.

Driven by verify-generate.sh. Usage: verify-generate.py <httpPort> <cdpPort>

The console is driven for real: choices are made in the UI and the generated
panes are read back out of the DOM, so what is asserted is what a user would
copy.
"""
import re
import subprocess
import sys
import time

from cdp import attach

HTTP_PORT = sys.argv[1] if len(sys.argv) > 1 else "8050"
ws = attach(int(sys.argv[2]) if len(sys.argv) > 2 else 9250)
ok = True
PIN = "dcf53c596339afd45b82f12c54b1e93e8273c2f4"


def check(label, cond, detail=""):
    global ok
    ok = ok and bool(cond)
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))


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
true""")


def pane(tab):
    """Read a generated YAML pane by clicking its tab and letting React settle."""
    ws.js(f"__click({tab!r})")
    time.sleep(0.45)
    return ws.js("__pane()")


SIM_TAB, CTRL_TAB = "simulator_params_go2.yaml", "mit_controller_sim_go2.yaml"

print("\n0. template provenance — the embedded stock files are the pin's, byte for byte")
# This runs without the gitignored dfki-quad clone: the templates are extracted
# straight out of the page source and hashed against the recorded sha256 of the
# files at the pin. If someone edits a template by hand, this is what catches it.
import hashlib, os
STOCK_SHA = {
    "STOCK_SIM_YAML": "eb31c744941a68b27e7452f4c8724cf740eb1df88041ee0530bc959eef0b1942",
    "STOCK_CTRL_YAML": "406830007e94597697855ab6d10b4961ef3b52b8cc69536bbe4df1610eef2923",
}
_src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "Kennel Console.dc.html"), encoding="utf-8").read()
for _name, _want in STOCK_SHA.items():
    _m = re.search(r"const " + _name + r" = `(.*?)`;\n", _src, re.S)
    if not _m:
        check(f"{_name} embedded", False, "template literal not found")
        continue
    _raw = _m.group(1).replace("\\`", "`").replace("\\${", "${").replace("\\\\", "\\")
    _got = hashlib.sha256(_raw.encode()).hexdigest()
    check(f"{_name} matches the pin's file", _got == _want, _got[:16] if _got != _want else "")

print("\n1. determinism — the same state generates the same bytes")
a_sim, a_ctrl = pane(SIM_TAB), pane(CTRL_TAB)
b_sim, b_ctrl = pane(SIM_TAB), pane(CTRL_TAB)
check("simulator YAML stable across regenerations", a_sim == b_sim)
check("controller YAML stable across regenerations", a_ctrl == b_ctrl)
check("no timestamp or run id in either header",
      not re.search(r"RUN-|\d{4}-\d{2}-\d{2}T", a_sim + a_ctrl))
check("pin SHA present in both headers", PIN in a_sim and PIN in a_ctrl)

print("\n2. stock choices reproduce the stock file")
try:
    stock_sim = subprocess.run(["git", "-C", "dfki-quad", "show",
                                f"{PIN}:ws/src/simulator/config/simulator_params_go2.yaml"],
                               capture_output=True, text=True, check=True).stdout
    stock_ctrl = subprocess.run(["git", "-C", "dfki-quad", "show",
                                 f"{PIN}:ws/src/controllers/config/mit_controller_sim_go2.yaml"],
                                capture_output=True, text=True, check=True).stdout
    have_pin = True
except Exception as e:
    have_pin = False
    print(f"  [SKIP] nested dfki-quad clone absent ({type(e).__name__}) — "
          "template provenance is recorded by sha256 in generate.md")

if have_pin:
    def body(y):
        return "\n".join(l for l in y.split("\n") if not l.startswith("#"))
    # Defaults are flat_plane + rate 1.0 + ground truth on, which IS stock.
    check("generated simulator body is byte-identical to stock",
          body(a_sim).strip() == stock_sim.strip(),
          "differs" if body(a_sim).strip() != stock_sim.strip() else "")
    extra = [l for l in body(a_ctrl).split("\n") if l.strip() and l not in stock_ctrl.split("\n")]
    check("controller body is stock plus only the composed block",
          all(("mpc_solver" in l or "mpc_hpipm_mode" in l or "mpc_condensed_size" in l
               or l.strip().startswith("#")) for l in extra),
          f"{len(extra)} added lines")
    check("the three MPC keys are absent from stock (so insertion is correct)",
          not any(k in stock_ctrl for k in ["mpc_solver:", "mpc_hpipm_mode:", "mpc_condensed_size:"]))

print("\n3. types the ROS parameter layer requires")
check("simulator_realtime_rate written as a double",
      re.search(r"simulator_realtime_rate:\s*1\.0(\s|$)", a_sim) is not None,
      (re.search(r"simulator_realtime_rate:.*", a_sim) or [""])[0].strip())
check("mpc_condensed_size written as a bare int",
      re.search(r"mpc_condensed_size:\s*5(\s|$)", a_ctrl) is not None)
check("mpc_solver written as a quoted string",
      '"PARTIAL_CONDENSING_HPIPM"' in a_ctrl)

print("\n4. the map sets BOTH keys (mapping.md §1.1)")
check("world_urdf is the plane at default", 'world_urdf: "src/common/model/urdf/plane.urdf"' in a_sim)
check("world_fix_link emitted explicitly", 'world_fix_link: "plane_base_link"' in a_sim)

print("\n5. one non-stock choice → a one-line diff")
ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_OSQP')")
time.sleep(0.4)
osqp_ctrl = pane(CTRL_TAB)
diff = [(x, y) for x, y in zip(a_ctrl.split("\n"), osqp_ctrl.split("\n")) if x != y]
solver_lines = [d for d in diff if "mpc_solver" in d[0] or "mpc_solver" in d[1]]
comment_lines = [d for d in diff if d[0].strip().startswith("#") or d[1].strip().startswith("#")]
check("controller diff is the mpc_solver line (plus its consumes-note)",
      len(diff) == len(solver_lines) + len(comment_lines) and len(solver_lines) == 1,
      f"{len(diff)} differing lines")
check("line counts match — nothing added or removed",
      len(a_ctrl.split("\n")) == len(osqp_ctrl.split("\n")),
      "the always-emit policy holds the shape constant")
check("simulator YAML unchanged by a controller-only choice", pane(SIM_TAB) == a_sim)

ws.js("__click('Obstacle terrain')")
time.sleep(0.4)
terr_sim = pane(SIM_TAB)
sdiff = [(x, y) for x, y in zip(a_sim.split("\n"), terr_sim.split("\n")) if x != y]
check("map change touches exactly the world_urdf line",
      len(sdiff) == 1 and "world_urdf" in sdiff[0][0], f"{len(sdiff)} differing lines")
check("terrain URDF is the composed value", "terrain.urdf" in terr_sim)
ws.js("__click('Flat plane')")
time.sleep(0.4)
ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_HPIPM')")
time.sleep(0.4)

print("\n6. the command block")
cmds = ws.js("__cmds()")
check("three shells emitted", len(cmds) == 3, f"{len(cmds)}")
joined = "\n".join(cmds)
check("simulator launched by package, not path",
      "ros2 launch simulator simulator.launch.py sim:=go2" in joined)
check("leg driver present (launch.md §1.1)",
      "ros2 launch drivers leg_driver_launch.py sim:=go2" in joined)
check("controller launched by package, not path",
      "ros2 launch controllers mit_controller.launch.py sim:=go2" in joined)
check("every shell carries the source chain",
      all("source /root/setup_ulab_workspace.bash" in c for c in cmds))
check("every shell ends up in /root/ros2_ws (mapping.md §2.3)",
      all("cd /root/ros2_ws" in c for c in cmds))
check("NO mpc_*:= launch args anywhere (mapping.md §2.1)", "mpc_" not in joined)
check("no safe_start:= (launch.md §1.2 — the settle is the intended path)",
      "safe_start" not in joined)
check("no config:= argument (no such arg exists at the pin)", "config:=" not in joined)
check("no absolute-path launch invocation", "ros2 launch /" not in joined)
check("no fictional package names survive",
      not any(p in joined for p in ["kennel_sim", "kennel_control", "kennel_estimation"]))
check("settle warning surfaced to the operator",
      "settle" in ws.js("__txt()").lower())

print("\n7. round-trip through the load modal")
ws.js("__setSel(__solverSel(), 'FULL_CONDENSING_QPOASES')")
time.sleep(0.4)
src_sim, src_ctrl = pane(SIM_TAB), pane(CTRL_TAB)
ws.js("__click('load YAML')")
time.sleep(0.6)
loaded = ws.js(r"""(() => {
  const tas=[...document.querySelectorAll('textarea')];
  if(tas.length<2) return 'no textareas';
  return tas.map(t=>t.value.length).join(',');
})()""")
check("modal pre-filled with the generated pair", "," in str(loaded), str(loaded))
ws.js("__click('load into composer')")
time.sleep(0.6)
verdict = ws.js("__txt()")
check("round-trip reported identical", "round-trip identical" in verdict,
      "reported lossy" if "lossy" in verdict else "")
ws.js("__click('close')")
time.sleep(0.5)
check("composer still on the pasted solver after load",
      ws.js("__solverSel().value") == "FULL_CONDENSING_QPOASES", ws.js("__solverSel().value"))
check("regenerated bytes match the pasted bytes", pane(CTRL_TAB) == src_ctrl)

print("\n8. the generated files are valid YAML with the nesting ROS expects")
try:
    import yaml
    ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_OSQP')")
    time.sleep(0.4)
    ws.js("__click('Obstacle terrain')")
    time.sleep(0.4)
    gs, gc = pane(SIM_TAB), pane(CTRL_TAB)
    ds = yaml.safe_load(gs)
    dc = yaml.safe_load(gc)
    sp = ds["drake_simulator"]["ros__parameters"]
    cp = dc["mit_controller_node"]["ros__parameters"]
    check("simulator YAML parses under drake_simulator/ros__parameters", bool(sp))
    check("controller YAML parses under mit_controller_node/ros__parameters", bool(cp))
    check("composed keys land in the parameter map, not beside it",
          all(k in cp for k in ["mpc_solver", "mpc_hpipm_mode", "mpc_condensed_size"]))
    check("mpc_condensed_size parses as int", isinstance(cp["mpc_condensed_size"], int))
    check("simulator_realtime_rate parses as float",
          isinstance(sp["simulator_realtime_rate"], float), repr(sp["simulator_realtime_rate"]))
    check("publish_quad_state parses as bool", isinstance(sp["publish_quad_state"], bool))
    check("composed world reached the parsed value",
          sp["world_urdf"].endswith("terrain.urdf") and sp["world_fix_link"] == "plane_base_link")
    check("composed solver reached the parsed value",
          cp["mpc_solver"] == "PARTIAL_CONDENSING_OSQP")
    check("the duplicated manually_step_sim still collapses to stock's value",
          sp["manually_step_sim"] is False)
    ws.js("__click('Flat plane')")
    time.sleep(0.3)
    ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_HPIPM')")
    time.sleep(0.3)
except ImportError:
    print("  [SKIP] pyyaml not installed — textual checks above still apply")

print("\n9. no network escaped")
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            f".filter(n=>!n.startsWith('http://localhost:{HTTP_PORT}'))")
check("zero non-localhost requests", not ext, str(ext))

print("\n" + ("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED"))
sys.exit(0 if ok else 1)
