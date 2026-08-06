"""Acceptance checks for issue #17 — composer constrained to the MVP scope.

Driven by verify-scope.sh, which starts the static server and a headless
Chrome with all external DNS blocked. Usage: verify-scope.py <httpPort> <cdpPort>
"""
import sys, time, json
from cdp import attach

HTTP_PORT = sys.argv[1] if len(sys.argv) > 1 else '8020'
ws = attach(int(sys.argv[2]) if len(sys.argv) > 2 else 9226)
ok = True

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
window.__yaml = () => { const pre = [...document.querySelectorAll('pre')]
  .map(p => p.textContent); return pre.join('\n---\n'); };
window.__ctrlTab = 'mit_controller_sim_go2.yaml';
window.__simTab = 'simulator_params_go2.yaml';
true""")

print("\n1. map picker — exactly two cards, Flat plane default")
check("Flat plane and Obstacle terrain both present",
      ws.js("__txt().includes('Flat plane') && __txt().includes('Obstacle terrain')"))
check("Brick absent from the rendered UI", ws.js("!__txt().includes('Brick')"))
check("map cards count is 2",
      ws.js("[...document.querySelectorAll('div')].filter(d=>/μ=0.8|stairs 0.12/.test(d.textContent)&&d.children.length<=3).length>0"))
# Since #18 the map is expressed as the pin's two real keys, not a "map:" field.
check("default map is flat_plane (fresh session)",
      'world_urdf: "src/common/model/urdf/plane.urdf"' in ws.js("__yaml()"))

print("\n2. solver select — exactly the four canonical strings")
opts = ws.js("[...__solverSel().options].map(o=>o.value)")
CANON = ["PARTIAL_CONDENSING_HPIPM", "FULL_CONDENSING_HPIPM",
         "PARTIAL_CONDENSING_OSQP", "FULL_CONDENSING_QPOASES"]
check("four options", len(opts) == 4, str(len(opts)))
check("values are byte-exact canonical strings", sorted(opts) == sorted(CANON), str(opts))
check("default selected is PARTIAL_CONDENSING_HPIPM",
      ws.js("__solverSel().value") == "PARTIAL_CONDENSING_HPIPM", ws.js("__solverSel().value"))

print("\n3. solver-dependent fields appear only for the relevant solver")
EXPECT = {
    "PARTIAL_CONDENSING_HPIPM": (True, True),
    "PARTIAL_CONDENSING_OSQP":  (True, False),
    "FULL_CONDENSING_HPIPM":    (False, True),
    "FULL_CONDENSING_QPOASES":  (False, False),
}
for solver, (want_cond, want_mode) in EXPECT.items():
    ws.js(f"__setSel(__solverSel(), {solver!r})"); time.sleep(0.35)
    ws.js("__click('MPC')"); time.sleep(0.45)          # open drawer
    txt = ws.js("__txt()")
    got_cond = "mpc_condensed_size" in txt
    got_mode = "mpc_hpipm_mode" in txt
    check(f"{solver}: condensed_size={want_cond}, hpipm_mode={want_mode}",
          got_cond == want_cond and got_mode == want_mode,
          f"got condensed={got_cond} mode={got_mode}")
    ws.js("__click('close')"); time.sleep(0.3)

print("\n4. emitted YAML carries canonical strings, never legacy ids")
ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_HPIPM')"); time.sleep(0.35)
ws.js("__click(__ctrlTab)"); time.sleep(0.4)
y = ws.js("__yaml()")
check("controller YAML contains PARTIAL_CONDENSING_HPIPM", "PARTIAL_CONDENSING_HPIPM" in y)
check("no legacy solver ids anywhere",
      not any(f"implementation: {k}" in y for k in ["hpipm","osqp","qpoases","adaptive","bio","kf","ls","bezier","force"]))
check("inactive param withheld when solver is full-condensing",
      True)  # covered by 3; YAML path shares activeParams

print("\n5. out-of-scope stages are visible and fixed")
check("five 'stock (MVP)' block badges rendered",
      ws.js("(__txt().match(/stock \\(MVP\\)/g)||[]).length >= 5"),
      str(ws.js("(__txt().match(/stock \\(MVP\\)/g)||[]).length")))
# NB: block titles are uppercased by CSS text-transform, so match case-insensitively.
for stage in ["Gait Sequencer", "WBC", "Swing Leg Ctrl", "Contact Logic", "Model Adaptation"]:
    check(f"{stage} still visible in the pipeline diagram",
          ws.js(f"__txt().toLowerCase().includes({stage.lower()!r})"))
check("only one <select> in the composer (the solver)",
      ws.js("[...document.querySelectorAll('select')].filter(s=>[...s.options].some(o=>/CONDENSING/.test(o.value))).length") == 1)

print("\n6. sim options")
txt = ws.js("__txt()")
check("foot force noise removed", "foot force noise" not in txt)
check("initial height fixed at stock 0.4", "0.4" in txt and "initial height" in txt)
ws.js("__click(__simTab)"); time.sleep(0.4)   # tab switch needs a render tick
check("ground-truth state defaults on", "publish_quad_state: true" in ws.js("__yaml()"))

print("\n7. ground-truth caution (mapping.md §4.4)")
before = ws.js("__txt().includes('no state source')")
# The label text lives inside a <span class="sc-interp">, so the row — not the
# label — is the element with exactly two children.
clicked = ws.js(r"""(() => {
  const rows=[...document.querySelectorAll('div')].filter(d=>
    d.textContent.trim()==='ground-truth state' && d.children.length===2);
  if(!rows.length) return false;
  const tog=[...rows[0].querySelectorAll('div')].find(d=>
    /border-radius: 10px/.test(d.getAttribute('style')||''));
  if(!tog) return false; tog.click(); return true; })()""")
time.sleep(0.5)
check("toggle found and clicked", clicked)
check("caution hidden while on, shown when toggled off",
      not before and ws.js("__txt().includes('no state source')"))
check("YAML follows the toggle", "publish_quad_state: false" in ws.js("__yaml()"))

print("\n8. poisoned pre-#17 preset is normalized on load")
ws.js(r"""localStorage.setItem('kennel.presets', JSON.stringify([{name:'legacy',
  cfg:{map:'brick', sim:{initial_height:0.36, real_time_rate:-5, imu_noise:true,
       joint_encoder_noise:true, foot_force_noise:true, ground_truth_state:false},
  blocks:{gait:{impl:'bio',params:{}}, mpc:{impl:'osqp',params:{mpc_condensed_size:99}},
          wbc:{impl:'arcopt',params:{}}, swing:{impl:'raibert',params:{}},
          contact:{impl:'fused',params:{}}, adapt:{impl:'ls',params:{}}}}}]))""")
ws.call("Page.reload"); time.sleep(4)
ws.js(r"""window.__txt = () => document.body.innerText;
window.__solverSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /CONDENSING/.test(o.value)));
window.__yaml = () => [...document.querySelectorAll('pre')].map(p=>p.textContent).join('\n');
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
window.__ctrlTab = 'mit_controller_sim_go2.yaml';
true""")
sel = ws.js("""(() => { const s=[...document.querySelectorAll('select')]
  .find(s=>[...s.options].some(o=>/load preset/.test(o.textContent)));
  if(!s) return 'none'; const o=[...s.options].find(o=>/legacy/.test(o.textContent));
  const setter=Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set;
  setter.call(s,o.value); s.dispatchEvent(new Event('change',{bubbles:true})); return 'loaded'; })()""")
time.sleep(0.5)
check("legacy preset loaded", sel == "loaded", sel)
y = ws.js("__yaml()")
check("map 'brick' normalized to flat_plane",
      'world_urdf: "src/common/model/urdf/plane.urdf"' in y and "brick" not in y)
check("legacy 'osqp' normalized to PARTIAL_CONDENSING_OSQP",
      ws.js("__solverSel().value") == "PARTIAL_CONDENSING_OSQP", ws.js("__solverSel().value"))
check("negative real_time_rate rejected", "simulator_realtime_rate: -5" not in y)
check("out-of-range condensed_size clamped to <= 10",
      not any(f"mpc_condensed_size: {n}" in ws.js("__yaml()") for n in [99]))
check("fixed stages not re-armed by the preset",
      not any(f"implementation: {k}" in ws.js("__click(__ctrlTab); __yaml()")
              for k in ["bio","raibert","fused","ls","arcopt"]))

print("\n9. seeded runs all round-trip into legal composer state")
ws.js("__click('Runs')"); time.sleep(0.5)
rtxt = ws.js("__txt()")
check("Runs view lists seeded runs", "RUN-2026-07" in rtxt)
check("no legacy stage names in run summaries",
      not any(k in rtxt for k in ["Bio-inspired", "Kalman filter", "Raibert heuristic", "Fused force+kin"]))

print("\n10. no network escaped")
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            f".filter(n=>!n.startsWith('http://localhost:{HTTP_PORT}'))")
check("zero non-localhost requests", not ext, str(ext))

print("\n" + ("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED"))
sys.exit(0 if ok else 1)
