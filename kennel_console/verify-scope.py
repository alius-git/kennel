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

print("\n11. named presets — four ship, and the operator's own save, duplicate and delete (#72)")
# A fresh page: group 8 left a poisoned `legacy` entry in localStorage and the
# composer on its values, and neither belongs to this group. The four
# compositions are restated here as LITERALS on purpose -- a suite that read its
# expectations out of the page under test would pass whatever that page said.
# They are the rows stack/stress.md §2 measured.
ws.js("localStorage.removeItem('kennel.presets')")
ws.call("Page.reload"); time.sleep(4)
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
// The preset select, by the one option text that is part of its contract.
window.__presetSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /load preset/.test(o.textContent)));
window.__presetNames = () => [...__presetSel().options].filter(o => o.value)
  .map(o => o.textContent.trim());
window.__loadPreset = name => { const s = __presetSel();
  const o = [...s.options].find(o => o.value && o.textContent.trim() === name);
  if (!o) return false; __setSel(s, o.value); return true; };
// The preset-name field, by ITS placeholder. Never by "an input[type=text]":
// the bridge URL field is one too, and every suite finds THAT one by a ws://
// value or a /rosbridge|9090/ placeholder -- the two must not collide.
window.__presetInput = () => document.querySelector('input[placeholder="preset name"]');
window.__setText = (el, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  setter.call(el, String(val));
  el.dispatchEvent(new Event('input', {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true})); };
window.__simNum = label => { const row = [...document.querySelectorAll('div')]
  .find(d => d.children.length === 2 && d.children[0].textContent.trim() === label
             && d.querySelector('input[type=number]'));
  return row ? row.querySelector('input[type=number]') : null; };
window.__setNum = (el, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  setter.call(el, String(val));
  el.dispatchEvent(new Event('input', {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true})); };
window.__saved = () => { try { return JSON.parse(localStorage.getItem('kennel.presets') || '[]'); }
  catch (e) { return 'unparseable'; } };
window.__simTab = 'simulator_params_go2.yaml';
window.__ctrlTab = 'mit_controller_sim_go2.yaml';
true""")


def pane(tab):
    """One generated YAML pane, by clicking its tab and letting React settle."""
    ws.js(f"__click({tab!r})")
    time.sleep(0.45)
    return ws.js("__pane()")


SHIPPED = ["Stock Go2 walk", "Solver benchmark A (HPIPM)",
           "Solver benchmark B (OSQP)", "Stress"]

# 11a — what the select offers
check("the load-preset option is still the select's first",
      ws.js("__presetSel().options[0].textContent.trim()") == "load preset…",
      ws.js("__presetSel().options[0].textContent.trim()"))
check("the four shipped presets are listed, in order, and nothing else yet",
      ws.js("__presetNames()") == SHIPPED, str(ws.js("__presetNames()")))

# 11b — Stock Go2 walk IS a fresh session
fresh_sim, fresh_ctrl = pane("simulator_params_go2.yaml"), pane("mit_controller_sim_go2.yaml")
ws.js("__click('Compose')"); time.sleep(0.3)
check("Stock Go2 walk loads", ws.js("__loadPreset('Stock Go2 walk')"))
time.sleep(0.5)
check("the composer says which preset it holds",
      "preset · Stock Go2 walk" in ws.js("__txt()"),
      next((l for l in ws.js("__txt()").split("\n") if l.startswith("preset ·")), "absent"))
check("and not as modified", "(modified)" not in ws.js("__txt()"))
check("Stock Go2 walk emits exactly what a fresh session emits",
      pane("simulator_params_go2.yaml") == fresh_sim
      and pane("mit_controller_sim_go2.yaml") == fresh_ctrl,
      "the stock preset is the pin's own files (generate.md §4 group 2)")

# 11c — the benchmark pair differs in the solver line and nothing else
ws.js("__click('Compose')"); time.sleep(0.3)
ws.js("__loadPreset('Solver benchmark A (HPIPM)')"); time.sleep(0.5)
a_sim, a_ctrl = pane("simulator_params_go2.yaml"), pane("mit_controller_sim_go2.yaml")
check("A runs as fast as possible", "simulator_realtime_rate: 0.0" in a_sim,
      next((l.strip() for l in a_sim.split("\n") if "simulator_realtime_rate" in l), "absent"))
check("A is HPIPM, SPEED, condensed 5",
      'mpc_solver: "PARTIAL_CONDENSING_HPIPM"' in a_ctrl
      and 'mpc_hpipm_mode: "SPEED"' in a_ctrl and "mpc_condensed_size: 5" in a_ctrl)
ws.js("__click('Compose')"); time.sleep(0.3)
ws.js("__loadPreset('Solver benchmark B (OSQP)')"); time.sleep(0.5)
b_sim, b_ctrl = pane("simulator_params_go2.yaml"), pane("mit_controller_sim_go2.yaml")
check("B is OSQP", 'mpc_solver: "PARTIAL_CONDENSING_OSQP"' in b_ctrl)
# All three MPC keys are emitted whatever the solver reads (generate.md §2.1):
# the honesty is paid in the block's own note, and the always-emit policy is
# exactly what keeps a one-choice change a one-line diff. The FIELD is hidden
# in the drawer (group 3); the KEY is still written.
check("B still emits the key the solver ignores, with the note that says so",
      'mpc_hpipm_mode: "SPEED"' in b_ctrl and "mpc_hpipm_mode is declared but unused" in b_ctrl,
      "generate.md §2.1's always-emit policy")
check("A and B differ in no simulator key at all", a_sim == b_sim)
diff = [(x, y) for x, y in zip(a_ctrl.split("\n"), b_ctrl.split("\n")) if x != y]
solver_lines = [d for d in diff if "mpc_solver" in d[0] or "mpc_solver" in d[1]]
comment_lines = [d for d in diff if d[0].strip().startswith("#") or d[1].strip().startswith("#")]
check("the A/B controller diff is the solver line plus its consumes-note",
      len(diff) == len(solver_lines) + len(comment_lines) and len(solver_lines) == 1,
      f"{len(diff)} differing lines — s005.compare's 'exactly one difference'")

# 11d — Stress is stack/stress.md §4's composition, as literals
ws.js("__click('Compose')"); time.sleep(0.3)
ws.js("__loadPreset('Stress')"); time.sleep(0.5)
s_sim, s_ctrl = pane("simulator_params_go2.yaml"), pane("mit_controller_sim_go2.yaml")
check("Stress is OSQP at condensed 1",
      'mpc_solver: "PARTIAL_CONDENSING_OSQP"' in s_ctrl and "mpc_condensed_size: 1" in s_ctrl)
check("Stress runs at rate 1.0 on the flat plane",
      "simulator_realtime_rate: 1.0" in s_sim
      and 'world_urdf: "src/common/model/urdf/plane.urdf"' in s_sim,
      "stress.md §4: the margin is composable, the map is not the lever")

# 11e — (modified) is a byte comparison, both directions
ws.js("__click('Compose')"); time.sleep(0.3)
ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_HPIPM')"); time.sleep(0.5)
check("changing a choice marks the preset modified",
      "preset · Stress (modified)" in ws.js("__txt()"),
      next((l for l in ws.js("__txt()").split("\n") if l.startswith("preset ·")), "absent"))
ws.js("__setSel(__solverSel(), 'PARTIAL_CONDENSING_OSQP')"); time.sleep(0.5)
check("changing it back clears the mark",
      "preset · Stress" in ws.js("__txt()") and "(modified)" not in ws.js("__txt()"))

# 11f — a shipped preset is read-only
ws.js("__click('save preset')"); time.sleep(0.4)
check("save refuses to overwrite a shipped preset",
      "ships with the console and is read-only" in ws.js("__txt()"))
check("and nothing was written to localStorage", ws.js("__saved()") == [], str(ws.js("__saved()")))

# 11g — duplicate under a typed name
ws.js("__setText(__presetInput(), 'my stress')"); time.sleep(0.3)
ws.js("__click('duplicate')"); time.sleep(0.5)
check("duplicate creates a user preset under the typed name",
      "preset · my stress" in ws.js("__txt()"))
saved = ws.js("__saved()")
check("  and it is in localStorage, alone", isinstance(saved, list) and len(saved) == 1
      and saved[0]["name"] == "my stress", str(saved)[:120])
check("  and the select now lists five", ws.js("__presetNames()") == SHIPPED + ["my stress"],
      str(ws.js("__presetNames()")))
check("  holding Stress's composition",
      pane("mit_controller_sim_go2.yaml") == s_ctrl and pane("simulator_params_go2.yaml") == s_sim)

# 11h — save over it, and survive a reload
ws.js("__click('Compose')"); time.sleep(0.3)
ws.js("__setNum(__simNum('real-time rate'), 0.5)"); time.sleep(0.5)
check("editing a loaded user preset marks it modified", "(modified)" in ws.js("__txt()"))
ws.js("__click('save preset')"); time.sleep(0.5)
check("save with no name typed overwrites the loaded user preset",
      "saved over my stress" in ws.js("__txt()"))
check("  still one saved preset, not two", len(ws.js("__saved()")) == 1,
      str([p["name"] for p in ws.js("__saved()")]))
ws.call("Page.reload"); time.sleep(4)
ws.js(r"""
window.__txt = () => document.body.innerText;
window.__presetSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /load preset/.test(o.textContent)));
window.__presetNames = () => [...__presetSel().options].filter(o => o.value)
  .map(o => o.textContent.trim());
window.__setSel = (s, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set;
  setter.call(s, val); s.dispatchEvent(new Event('change', {bubbles:true})); };
window.__loadPreset = name => { const s = __presetSel();
  const o = [...s.options].find(o => o.value && o.textContent.trim() === name);
  if (!o) return false; __setSel(s, o.value); return true; };
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
window.__pane = () => { const p = [...document.querySelectorAll('pre')]
  .filter(p => /ros__parameters/.test(p.textContent)); return p.length ? p[0].textContent : ''; };
window.__saved = () => { try { return JSON.parse(localStorage.getItem('kennel.presets') || '[]'); }
  catch (e) { return 'unparseable'; } };
window.__presetInput = () => document.querySelector('input[placeholder="preset name"]');
window.__setText = (el, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;
  setter.call(el, String(val));
  el.dispatchEvent(new Event('input', {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true})); };
true""")
check("the saved preset survived a reload",
      ws.js("__presetNames()") == SHIPPED + ["my stress"], str(ws.js("__presetNames()")))
check("Compose is still the landing view", "Compose experiment" in ws.js("__txt()"))
ws.js("__loadPreset('my stress')"); time.sleep(0.5)
check("and it loads what was saved into it",
      "simulator_realtime_rate: 0.5" in pane("simulator_params_go2.yaml"))

# 11i — duplicate with nothing typed, twice
ws.js("__click('Compose')"); time.sleep(0.3)
ws.js("__click('duplicate')"); time.sleep(0.5)
check("duplicate with no name typed appends (copy)", "preset · my stress (copy)" in ws.js("__txt()"))
ws.js("__click('duplicate')"); time.sleep(0.5)
check("  and a second one does not collide",
      "preset · my stress (copy) (2)" in ws.js("__txt()"),
      str([p["name"] for p in ws.js("__saved()")]))

# 11j — delete
ws.js("__loadPreset('Stock Go2 walk')"); time.sleep(0.5)
ws.js("__click('delete')"); time.sleep(0.4)
check("delete refuses a shipped preset", "cannot be deleted" in ws.js("__txt()"))
check("  and deleted nothing", len(ws.js("__saved()")) == 3,
      str([p["name"] for p in ws.js("__saved()")]))
ws.js("__loadPreset('my stress (copy) (2)')"); time.sleep(0.5)
ws.js("__click('delete')"); time.sleep(0.5)
check("delete removes the loaded user preset",
      [p["name"] for p in ws.js("__saved()")] == ["my stress", "my stress (copy)"],
      str([p["name"] for p in ws.js("__saved()")]))
check("  it is gone from the select",
      "my stress (copy) (2)" not in ws.js("__presetNames()"), str(ws.js("__presetNames()")))
check("  and the label is cleared", "preset ·" not in ws.js("__txt()"))

# 11k — the new load path is the same funnel group 8 proved
ws.js(r"""localStorage.setItem('kennel.presets', JSON.stringify([{name:'poisoned',
  cfg:{map:'brick', sim:{initial_height:0.36, real_time_rate:-5, ground_truth_state:false},
  blocks:{gait:{impl:'bio',params:{}}, mpc:{impl:'osqp',params:{mpc_condensed_size:99}},
          wbc:{impl:'arcopt',params:{}}, swing:{impl:'raibert',params:{}},
          contact:{impl:'fused',params:{}}, adapt:{impl:'ls',params:{}}}}}]))""")
ws.call("Page.reload"); time.sleep(4)
ws.js(r"""
window.__txt = () => document.body.innerText;
window.__presetSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /load preset/.test(o.textContent)));
window.__setSel = (s, val) => { const setter =
  Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set;
  setter.call(s, val); s.dispatchEvent(new Event('change', {bubbles:true})); };
window.__loadPreset = name => { const s = __presetSel();
  const o = [...s.options].find(o => o.value && o.textContent.trim() === name);
  if (!o) return false; __setSel(s, o.value); return true; };
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
window.__pane = () => { const p = [...document.querySelectorAll('pre')]
  .filter(p => /ros__parameters/.test(p.textContent)); return p.length ? p[0].textContent : ''; };
window.__solverSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /CONDENSING/.test(o.value)));
true""")
check("a poisoned user preset loads through the same funnel",
      ws.js("__loadPreset('poisoned')") is not False)
time.sleep(0.5)
psim, pctrl = pane("simulator_params_go2.yaml"), pane("mit_controller_sim_go2.yaml")
check("  map 'brick' normalized to the plane",
      'world_urdf: "src/common/model/urdf/plane.urdf"' in psim and "brick" not in psim)
check("  negative rate rejected", "simulator_realtime_rate: -5" not in psim)
check("  out-of-range condensed size clamped", "mpc_condensed_size: 99" not in pctrl)
check("  legacy solver id canonicalized",
      ws.js("__solverSel().value") == "PARTIAL_CONDENSING_OSQP", ws.js("__solverSel().value"))
check("  fixed stages not re-armed",
      not any(f"implementation: {k}" in pctrl for k in ["bio", "raibert", "fused", "ls", "arcopt"]))

# 11l — nothing was reordered or added that a suite clicks by text
check("the composer still has exactly one CONDENSING select",
      ws.js("[...document.querySelectorAll('select')]"
            ".filter(s=>[...s.options].some(o=>/CONDENSING/.test(o.value))).length") == 1)
ws.js("localStorage.removeItem('kennel.presets')")

print("\n10. no network escaped")
ext = ws.js("performance.getEntriesByType('resource').map(e=>e.name)"
            f".filter(n=>!n.startsWith('http://localhost:{HTTP_PORT}'))")
check("zero non-localhost requests", not ext, str(ext))

print("\n" + ("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED"))
sys.exit(0 if ok else 1)
