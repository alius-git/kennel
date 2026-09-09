# Kennel — Plan I: the user surface (#72 · #73), one PR

Steps 15–16 of milestone [*Finish the system*](https://github.com/alius-git/kennel/milestone/2),
written like plans A–H (`next-goals.md`, `teleop-joystick.md`, `reliability.md`,
`console-live.md`, `teleop-hardened.md`, `two-scenarios.md`) so an agent can
implement them on one branch without re-deriving the repo. Everything in §0 was
checked on **2026-09-09** with the commands shown.

| Step | Issue | One line |
|---|---|---|
| 15 | [#72](https://github.com/alius-git/kennel/issues/72) | four **shipped presets as page data** — *Stock Go2 walk*, *Solver benchmark A (HPIPM)*, *Solver benchmark B (OSQP)*, *Stress* — read-only and duplicable; user presets save / load / duplicate / delete, every load through `normalizeCfg()`; the round trip preset → generate → `run.json` → composer asserted byte for byte; `KENNEL_PRESET=<name>` picked **in the UI by text**, the driver's own table retired; *Stairs + Adaptive gait* recorded as a bypass |
| 16 | [#73](https://github.com/alius-git/kennel/issues/73) | `guides/first-run.md` (the checklist — one command or one click per step, success texts **quoted** from `runbook.md` §3), `guides/walkthrough.md`, `guides/diagnosis.md` (one real screenshot per panel); `serve.py --guides` serves and renders them, the console shell gains a `Guides` item that is **absent under plain `http.server`**; `kennel-demo.sh scenario firstwalk` performs the checklist as written under a RAW-clock timer and asserts every command came from it |

**One branch, one PR, closing both.** The maintainer's call for this step, as
for E–H; the milestone's default is one issue per PR and the PR body says so
(§6.1). The four deliverables the user asked for — the presets, the checklist,
the walkthrough, the primer — land together because the checklist's second step
*is* a shipped preset: `first-run.md` cannot be written, let alone audited,
until *Stock Go2 walk* exists in the page. The order is fixed: #72 first (the
page's data, the toolbar, the driver, the two appended suite groups), then the
guides route and view (the shell has to link something before the something is
written against it), then the three guides, then the s001 verb that audits the
first of them. Budget: about **one and a half hours of live-guest time** (§4)
— two `all`s, one `scenario diagnose`, one `reset`, two audits — and the rest
is editing.

---

## 0. Ground truth the implementer must know

**Repo.** `origin/main` is `1c9a2ab` (*Merge pull request #82 from
alius-git/stack/68-two-scenarios*, 2026-09-09 13:40 −03). Local `main` is at
it. **The working tree carries uncommitted deck work** — `M slides/slides.md`
and five untracked files under `slides/` — that is the maintainer's and is not
this PR's: branch from `main`, never `git add -A`, stage files by name. No
`console/72-*` or `guides/*` branch exists. There is **no `guides/`
directory** anywhere in the repo; `plan/design/05-guides.md` and
`plan/applications.md` §Kennel/guides describe what it should hold, and that
is all that exists of it.

**Host.** `google-chrome` 151.0.7922.71, `python3` 3.12.3 with **PIL 10.2.0**
and **pyyaml**, ImageMagick `convert`, `virsh`, `ssh`. `serve.py` is running on
`:8000` (`/api/health`: `kennel: true`, out `~/kennel-runs`, pin `dcf53c59…`,
`bridge: null`, `meshcat: null`). `~/kennel-runs` holds the maintainer's run
folders, newest **`run-20260908T232641Z`** — and that folder is **the all-stock
composition** (`plane.urdf`, rate `1`, `publish_quad_state` true,
`PARTIAL_CONDENSING_HPIPM` / `SPEED` / condensed `5`), with a `verify.json`
beside it. In other words `kennel-demo.sh run` today would launch exactly what
*Stock Go2 walk* composes. Two of the suites this plan extends are green on
this host today: `verify-scope.sh` **36/36**, `verify-export.sh` **72/72**
(transcripts in the scratchpad; the numbers are the ones §2.3 and §6.2 count
from).

**Guest.** `kennel-vm` at `192.168.122.32` (user `yuuser24`, key
`~/git/yuruna/test/status/ssh/yuruna_ed25519`), container `dfki_quad` running,
clone at the pin, applied run `run-20260908T232641Z`, three runs staged
(`run-20260907T202843Z`, `run-20260908T202817Z`, `run-20260908T232641Z`),
**the stack is down** (`status`: *Meshcat not reachable*), bridge down. Left
exactly as found: this plan's only probe was `kennel-demo.sh status`, which is
read-only. §4's last row puts it back the same way.

### 0.1 The numbers the s001 budget is measured against

The dry run's `run` phases (`demo/dry-run.md` §2, 2026-08-07: transfer 1m02,
launch 2m09, verify 55 s, walk 1m22 — **5m28**) predate #52's graph wait and
#54's zip-free transfer. The number that stands today is PR #82's cold cycle
(`demo/evidence/s004-disturb/01-run.txt`, 2026-09-08, immediately after a
`reset` whose 12 steps took ~70 s):

| phase | measured |
|---|---|
| guest | 0 s |
| transfer | 2 s |
| launch | **35 s** (leg driver up 5 s; the six-node graph 1 s after *Starting controller*) |
| verify | 33 s |
| walk | 7 s |
| **`run`, total** | **77 s** |

`teleop` is ~15 s (`runbook.md` §3), a page boot ~3 s, the composed click
steps a few seconds each, the walk itself 10 sim-s at rate 1.0. So the
checklist, from a provisioned guest with the stack down, should come in around
**2–3 minutes** against s001's *≈ 5 min target, 10 min ceiling* — and the verb
measures it rather than this paragraph asserting it. Measured on
`CLOCK_MONOTONIC_RAW` through `p22-clock.sh`, because this host's adjusted
clocks run ~10 % slow (`demo/dry-run.md` §2, `vm/provisioning.md` §6a) and a
budget number is exactly the kind of number that must not be quietly wrong.

### 0.2 Presets, as they are (`kennel_console/Kennel Console.dc.html`)

- The toolbar (`~68–73`): a `<select>` whose first option reads **`load
  preset…`**, then `save preset`, then `load YAML`. Option values are
  `String(i)` into `st.presets`.
- State (`~2567`): `presets: []`, `presetSel: ''`; `componentDidMount`
  (`~2602`) reads `localStorage['kennel.presets']` (an array of
  `{name, cfg}`).
- `onPresetSave` (`~3371`) auto-names the entry `<map> / <friendly solver> ·
  <MM-DD HH:MM>` and appends; `onPresetLoad` (`~3379`) does
  `normalizeCfg(st.presets[i].cfg)` and puts `presetSel` back to `''`. There
  is **no delete, no duplicate, no shipped data, and no indication of which
  preset is loaded**.
- `normalizeCfg` (`~981`) is the funnel every load already goes through
  (`composer-scope.md` §3); `defaultCfg()` (`~946`) is stock and
  `verify-generate.py` group 2 proves stock reproduces the pin's files byte for
  byte. `emitSimYaml`/`emitCtrlYaml` are deterministic (group 1) — which is
  what makes *"is this composition still the preset's"* a byte comparison.
- The Runs view's `onLoad` (`~3219`) is `normalizeCfg(cfgFromChoices(r.choices))`
  → `view: 'compose'` — the `run.json` → composer path. **No suite clicks it
  today** (`grep -n load kennel_console/verify-runs.py` finds nothing); §2.4
  is where that changes.

**The driver.** `KENNEL_PRESET` is read at `kennel-demo.sh:148`; `preset_field`
(`:1183–1197`) knows one name, `stress` → `flat_plane / 1.0 /
PARTIAL_CONDENSING_OSQP / condensed 1`, and exits 2 naming #72 for anything
else; `do_compose` (`:1199–1226`) fills in only the knobs the operator did not
set (`RATE_IS_DEFAULT`, `SOLVER_IS_DEFAULT`, `:141–143`) and hands
`p22-console-demo.sh` a full set of knobs. `p22-console-demo.py` **always** sets
the solver and the rate (positional, defaults OSQP / 0.75) and touches map /
HPIPM mode / condensed size / disturbances only when their knob is non-empty —
*"an untouched control is not the same as a control set to stock"* — and it
runs Chrome in a **throwaway profile** (`mktemp -d`), so it can never see a
preset an operator saved in their own browser.

**Who else reads `KENNEL_PRESET`.** `scenario-diagnose.sh:72` exports
`KENNEL_PRESET="${KENNEL_PRESET:-stress}"`, runs `kennel-demo.sh compose`, and
asserts only that it exited 0 and printed a run folder (`:141–145`); its
verdict is the fall count, read from the stack. `k14-sweep.sh` composes through
the knobs and never through the preset. So retiring the driver's table breaks
nothing **provided `stress` still resolves to the same composition** — and §4
row 2 proves that with a `diff`, not a promise.

**The four compositions #72 names are already measured.** Every one is a row
of `stack/stress.md` §2's table, walked or fell on the reference guest:

| Preset | Composition | stress.md §2 row | Measured |
|---|---|---|---|
| Stock Go2 walk | everything stock: flat plane · rate 1.0 · ground truth on · `PARTIAL_CONDENSING_HPIPM` · `SPEED` · condensed 5 · disturbances off | `hpipm-speed-5-r1` | 0.685 ms mean, walked; and a real `completed` report of this composition is `fixtures/verify-completed-hpipm.json` |
| Solver benchmark A (HPIPM) | as stock, **rate 0** | `hpipm-speed-5-r0` | 0.67 ms, rtf 2.15, walked |
| Solver benchmark B (OSQP) | as A, solver `PARTIAL_CONDENSING_OSQP` | `osqp-5-r0` | 1.151 ms, rtf 2.06, walked |
| Stress | flat plane · rate 1.0 · `PARTIAL_CONDENSING_OSQP` · condensed **1** | `osqp-1-r1`; §4 three runs | 3.75 ms mean, **fell 3 of 3**, the composition `KENNEL_PRESET=stress` composes today |

Why A and B sit at rate 0 is §7.2. *Stairs + Adaptive gait* cannot ship:
`Adaptive` is the fixed value of a stage the composer cannot select
(`composer-scope.md` §1.2; `mapping.md` §4.3 — `gait_sequencer` is out of the
MVP config path) and obstacle terrain falls 2 of 3 with **no** solver
degradation (`stress.md` §4.1). Neither half is honest, so it is the bypass
row #72 asks for (§2.5).

### 0.3 The guides — what exists to build them from

- The success texts the checklist may quote **verbatim** exist, one per verb,
  in `demo/runbook.md` §3's *Success looks like* column (quoted in §3.1). The
  click steps have no runbook row; their success texts are DOM strings the
  suites already pin: the send strip says **`saved <absolute path>`**
  (`~2942`, `send.md` §3); `connect bridge` ends in **`driving`** (`~1809`,
  `verify-teleop.py`); the gait picker says **`gait WALKING_TROT active —
  /gait_state period …`** (`~1939`, `verify-teleop.py:452`); the status bar
  says **`mode · live`** (`__stat('mode') == 'live'`, `dashboard-shot.sh`).
- `serve.py` serves `--dir` (default `kennel_console/`) plus `/api/health`,
  `/api/runs`, `/api/runs/<stamp>/<file>` — every file served is inside the
  docroot or allow-listed by name, and `guides/` is **outside** the docroot.
  Plain `http.server --directory kennel_console` can therefore never serve a
  guide, which is the feature-detection rule holding by construction rather
  than by a flag.
- The page already frames a server-side document in a pane: the 3D scene is an
  `<iframe src="{{ meshcatUrl }}">` (`~394`) shown only when `/api/health`
  carries a URL (`hasScene`/`noScene`, `~3290`). The Guides view copies that
  idiom (§3.4). The `.dc.html` runtime (`support.js`) compiles the template's
  `sc-if`/`sc-for`/`{{ }}`; it exposes no raw-HTML binding to the template,
  and the page paints only canvases through refs — one more reason to render
  the markdown in `serve.py`, where `html.escape` lives, and not in the page.
- Renders that exist and are the walkthrough's and primer's images (all
  committed, all real): `kennel_console/composer-scope-render.png` 1400×900,
  `generate-render.png`, `export-render.png`, `send-render.png` 1400×757,
  `teleop-render.png` 1500×797, `dashboard-render.png` 1600×857,
  `runs-render.png`, `kennel_console/dashboard/evidence/04-live.png`,
  `05-timeline.png` 1600×857, `06-fall-live.png`, `07-runs.png`,
  `demo/evidence/07-meshcat-walking.png` 1280×657 (HUD at 76 rtr%),
  `demo/evidence/s003-diagnose/05-renders/{01-green,02-amber,03-red,04-reset}-attempt{1,2,3}.png`
  1500×807 (a live degradation, fall and reset under the stress preset),
  `demo/evidence/s004-disturb/05-renders/{02-moderate,03-fall,04-reset}.png`.
  The Dashboard's panel headers, as rendered (uppercased by CSS): **3D scene ·
  Pipeline health · Gait / contact timeline · Health counters · State plots ·
  Event feed · Interventions**.
- Tools the s001 verb reuses without a copy: `demo/tools/p22-clock.sh` (marks
  on `CLOCK_MONOTONIC_RAW`, log path `KENNEL_TIMINGS`, a `ratio` verb that
  proves the clock first); `demo/tools/scenario-lib.sh` (**sourced** by the
  scenario family: `scenario_preflight` `:61`, `check`/`bypass`/`note`
  `:114–131`, `observe` `:171`, `page` `:235`, `start_chrome` `:248`
  (window 1500×950, the DNS blackhole with the guest excluded), `totals`
  `:284`); `demo/tools/scenario-page.py` (steps `boot`, `connect`,
  `disconnect`, `gait`, `vx`, `stick`, `release`, `inject`, `reset`,
  `banner`/`nobanner`, `feed`, `health`, `runs`, `shot`, `simt`, `errors`,
  `:229–356`; helpers `__stat`, `__health`, `__gaitSel`, `__pad`,
  `__connectBtn` at `:60–120`). `kennel-demo.sh scenario <name>` (`:1499`)
  dispatches to `scenario-<name>.sh` and lists the files that exist.

### 0.4 What the existing suites pin down — constraints, all of which stay green

- `verify-scope.py` group 5 (`:88–90`): *"only one `<select>` in the composer"*
  counts only selects with a `CONDENSING` option — the preset select is not
  counted, and nothing new may offer such an option. Group 8 (`:116–150`)
  writes a poisoned `kennel.presets` entry named `legacy`, reloads, finds the
  preset select by an option matching `/load preset/`, the option by
  `/legacy/`, and **sets `.value` directly** — so the option-value scheme is
  free, the `load preset…` text is not, and a user preset must still be listed
  by its name. It then expects the load to land on legal values.
- `verify-generate.py`: `__cmds()` finds three blocks by default; group 7
  (`:167–187`) is the `load YAML` → `load into composer` round trip, clicked by
  text; group 1 asserts determinism. **Unmodified** by this plan.
- `verify-export.py:170–171`: `list(rj.keys()) == ["run_id", "run",
  "generated_at", "pin", "choices"]`; `:184–188` exactly the seven `choices`
  (eight only with disturbances on). **Unmodified.**
- `verify-send.py` / `verify-runs.py`: `__sendBtn` matches `^send to .+ →$`;
  a Runs row is the grid with `grid-template-columns: 34px`; `goto()` reloads
  and re-installs `HELPERS`; the send loop sleeps 1.1 s between sends because
  `stampNow()` has one-second resolution (`verify-runs.py:174`). `verify-runs`
  groups 1–6; §2.4 appends group 7.
- `verify-dashboard.py` group 3 (`:369–400`): slices the template between
  `value="{{ isDash }}"` and `value="{{ isRuns }}"` — a Guides block appended
  **after** the Runs block is outside the slice; every `kennel-demo.sh <verb>`
  the Dashboard names must be in `kennel-demo.sh help`; the whole source is
  grepped for `kennel_(viz|control|estimation|sim)`.
- `verify-serve.sh` step 4: the dumped DOM contains `Compose experiment` and
  no `{{` — Compose stays the landing view; and `p22-console-demo.py`'s first
  check is *"Compose view is the landing view"*.
- `verify-teleop.py`: `gait <NAME> active` / `refused` texts; the
  Interventions buttons found by exact text.
- Every suite's `__click` takes the **first** element whose exact text matches:
  append only; never add an element reading `Compose`, `Dashboard`, `Runs`,
  `load YAML`, `save preset`, `generate run ↓`, `send to … →`, `connect
  bridge`, `inject`, `reset sim`, `STAND`, `close`, `MPC`, `Flat plane`,
  `Obstacle terrain`, or a YAML tab name.
- `p22-console-demo.py` reads the composition **back out of the YAML panes**
  by key line (`keyline`, never the comment above it — PR #82's third
  correction); `p22-console-demo.sh` refuses to start a server of its own.

**Read first.** `CLAUDE.md`; `plan/scenarios.md` s001 (steps 3–8 are the
checklist's spec), s002 steps 3, 6–7 and s005 steps 1–2, 5 (what the presets
serve); `plan/design/05-guides.md`, `seq.s001.firstwalk.md`; `plan/prompts.txt`
lines 34 and 149–151 (the preset specification); `kennel_console/composer-scope.md`
§3 (the normalization funnel) and §4; `export.md` §2.1, §6; `send.md` §2.1,
§3; `runs.md` §4; `teleop.md` §3, §12.2; `dashboard.md` §1.2, §2.1, §3.3, §4;
`stack/stress.md` §1, §2, §4; `demo/runbook.md` §1, §3 (the column the
checklist quotes), §4; `demo/dry-run.md` (the method: obey the prose, log every
friction as an F-number, D1); `demo/scenarios.md` §0 and §3; PR #82's body
(the shape); `demo/tools/scenario-disturb.sh` (the model for the s001 verb).

---

## 1. Shape of the work

- Branch `console/72-user-surface` from `origin/main` (`1c9a2ab`).
- Seven commits, in this order, house form `<type>(<area>): <what> (#N)`:
  1. `feat(console): shipped presets as data — Stock Go2 walk, Solver benchmark A/B, Stress — read-only and duplicable; user presets save, load, duplicate, delete through normalizeCfg (#72)` — includes this plan file and the appended `verify-scope` / `verify-runs` groups.
  2. `feat(demo): KENNEL_PRESET=<name> is picked in the UI by text; the driver's own preset table is retired (#72)`
  3. `feat(console): serve.py --guides serves and renders guides/; the shell's Guides item, absent under plain http.server (#73)` — with `verify-guides.sh` + `.py`.
  4. `docs(guides): first-run.md, walkthrough.md, diagnosis.md — the checklist quotes the runbook, the primer has one real screenshot per panel (#73)` — with `guides/img/` and `guides/tools/make-img.sh`.
  5. `feat(demo): kennel-demo.sh scenario firstwalk — s001 as a verb: the checklist performed as written, timed on the RAW clock, every command traced to it (#73)`
  6. `docs: record the user-surface pass — composer-scope.md §7, guides.md, scenarios.md §s001, the friction log, evidence (#72, #73)`
  7. (only if the audit found prose to fix — it will) `docs(guides): the frictions F10–F<n> fixed in the prose, as found (#73)` — or fold into 6 if the fixes landed before the second audit run.
- New files: `guides/first-run.md`, `guides/walkthrough.md`,
  `guides/diagnosis.md`, `guides/img/*.png`, `guides/tools/make-img.sh`
  (HOST); `kennel_console/verify-guides.sh` + `verify-guides.py` (HOST, no
  VM); `kennel_console/guides.md`; `demo/tools/scenario-firstwalk.sh` (HOST);
  `demo/evidence/s001-firstwalk/`; `kennel_console/composer-scope/evidence/`
  (the two `all` transcripts and the `diff`).
- Modified: `kennel_console/Kennel Console.dc.html`, `serve.py`,
  `verify-scope.py`, `verify-runs.py` (**appended** groups only);
  `demo/tools/kennel-demo.sh`, `p22-console-demo.sh` + `.py`,
  `scenario-lib.sh` (one appended optional argument), `scenario-page.py`
  (appended steps); the records of §5.
- **Six suites unmodified**: serve, generate, export, send, teleop, dashboard —
  proven by `git diff --stat main -- kennel_console/verify-{serve,generate,export,send,teleop,dashboard}.*` printing nothing (§6.2).
- Every touched script keeps its header truthful (`# Version:` date, what,
  **where it runs**, usage, knobs, exit codes); the Python tools carry the same
  block as a docstring.
- **Append, never reorder** in the console: the preset controls after `load
  YAML` in the same toolbar row; the `Guides` nav item after `Runs`; the Guides
  view block after the Runs view block; attributes added to existing elements
  rather than elements inserted before them.

The architecture after step 16:

```
 host                                                                   guest (kennel-vm)
 ───────────────────────────────────────────────────────────────────     ─────────────────────────────
 page: SHIPPED_PRESETS (4, data) ─┐                                       
       localStorage kennel.presets (user) ─┴─ load ─► normalizeCfg ─► cfg ─► emitters ─► send ─► ~/kennel-runs/run-<stamp>/ ─ run ─► the stack
       Runs › load ─► cfgFromChoices(run.json) ─► normalizeCfg ─► cfg   (byte-identical YAMLs: verify-runs group 7)
 kennel-demo.sh compose ─ KENNEL_PRESET=<name> ─► p22-console-demo.py picks the option by text, reads the panes back
 serve.py --guides guides/ ─► /api/health.guides ─► the shell's 4th item `Guides` ─► <iframe src=/guides/<name>.html> ─► rendered by serve.py
                                                    plain http.server: no /api/health ─► no item, byte-for-byte the old shell
 kennel-demo.sh scenario firstwalk ─► parses guides/first-run.md ─► ```bash fences run on the host, ```click fences drive the page
                                      p22-clock.sh marks ─► the s001 budget; observe 10 ─► the walk, from the guest's own monitor
```

---

## 2. Step 15 — #72, named presets

### 2.1 The page: shipped presets as data, and the toolbar's new controls

**Data**, placed right after `normalizeCfg` (`~1010`) so it can use it:

```js
// Presets that ship with the page (#72). Read-only and duplicable, never
// written to localStorage -- kennel.presets stays the operator's own list, so
// a poisoned or pre-#17 entry there (verify-scope.py group 8) is still that
// list's problem and not this one's. Every cfg is a WHOLE composer state built
// from defaultCfg() and passed through normalizeCfg(), so a load has nothing
// to invent; and every one is a measured row of stack/stress.md §2 -- a preset
// nobody has run is a guess with a name.
function shippedCfg(o) {
  const c = defaultCfg();
  if (o.rate !== undefined) c.sim.real_time_rate = o.rate;
  if (o.solver) c.blocks.mpc.impl = o.solver;
  if (o.condensed !== undefined) c.blocks.mpc.params.mpc_condensed_size = o.condensed;
  return normalizeCfg(c);
}
const SHIPPED_PRESETS = [
  {name: 'Stock Go2 walk',
   why: 'every choice at its stock value -- the pin\'s own files, byte for byte (generate.md §4 group 2); stress.md §2 hpipm-speed-5-r1',
   cfg: shippedCfg({})},
  {name: 'Solver benchmark A (HPIPM)',
   why: 'PARTIAL_CONDENSING_HPIPM · SPEED · condensed 5, flat plane, rate 0 (as fast as possible: 2.1x the solves per wall second, stress.md §1); stress.md §2 hpipm-speed-5-r0',
   cfg: shippedCfg({rate: 0})},
  {name: 'Solver benchmark B (OSQP)',
   why: 'A with the solver changed and nothing else -- the pair s005.compare diffs; stress.md §2 osqp-5-r0',
   cfg: shippedCfg({rate: 0, solver: 'PARTIAL_CONDENSING_OSQP'})},
  {name: 'Stress',
   why: 'PARTIAL_CONDENSING_OSQP · condensed 1, flat plane, rate 1.0 -- the red composition: 3 of 3 fell, 3 of 3 crossed the 7 ms amber line (stress.md §4). What kennel-demo.sh scenario diagnose composes',
   cfg: shippedCfg({solver: 'PARTIAL_CONDENSING_OSQP', condensed: 1})}
];
const SHIPPED_NAMES = SHIPPED_PRESETS.map(p => p.name);
// "stock-go2-walk", "solver-benchmark-a-hpipm", ... -- what KENNEL_PRESET may
// say instead of the exact name (p22-console-demo.py matches either).
function presetSlug(name) { return name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); }
```

`shippedCfg` sets `mpc_condensed_size` on OSQP through the same params object
the drawer writes; `activeParams` already withholds `mpc_hpipm_mode` from the
OSQP YAML (`composer-scope.md` §2) and `emitRunJson` still writes all three
keys to `run.json` — exactly as a hand-composed OSQP run does today.

**State** (`~2567`, appended to the literal): `presetName: ''` (the loaded
preset's name, `''` when none), `presetOwn: ''` (`'shipped'` | `'user'` |
`''`), `presetCfg: null` (the loaded preset's normalized cfg, for the
*modified* comparison), `presetInput: ''` (the name field), `presetMsg: ''`,
`presetErr: false`.

**Option values.** `presets` in `renderVals` becomes
`SHIPPED_PRESETS.map((p, i) => ({v: 's' + i, label: p.name}))
.concat(st.presets.map((p, i) => ({v: 'u' + i, label: p.name})))` — shipped
first, user after, the `load preset…` option untouched. `verify-scope.py`
group 8 keeps finding `legacy` by its text and setting its value.

**The handlers**, replacing `onPresetSave`/`onPresetLoad` (`~3371–3382`) in
place and adding three:

```js
const same = (a, b) => !!a && !!b && emitSimYaml(a) === emitSimYaml(b)
  && emitCtrlYaml(a) === emitCtrlYaml(b) && !!a.sim.disturbances === !!b.sim.disturbances;
const autoName = () => {
  const solver = (BY_ID.mpc.impls.find(x => x[0] === cfg.blocks.mpc.impl) || [0, cfg.blocks.mpc.impl])[1];
  return cfg.map + ' / ' + solver + ' · ' + new Date().toISOString().slice(5, 16).replace('T', ' ');
};
const persist = next => { try { localStorage.setItem('kennel.presets', JSON.stringify(next)); } catch (e) {} };
const uniqueName = (base, list) => { let n = base, k = 2; while (list.some(p => p.name === n)) n = base + ' (' + (k++) + ')'; return n; };
const pmsg = (m, err) => ({presetMsg: m, presetErr: !!err});
...
onPresetLoad: e => {
  const v = e.target.value; if (v === '') return;
  const src = v[0] === 's' ? SHIPPED_PRESETS[Number(v.slice(1))] : st.presets[Number(v.slice(1))];
  if (!src) return;
  const next = normalizeCfg(clone(src.cfg));        // shipped or saved: untrusted alike
  this.setState(Object.assign({cfg: next, presetSel: '', presetName: src.name,
    presetOwn: v[0] === 's' ? 'shipped' : 'user', presetCfg: clone(next), presetInput: ''},
    pmsg('loaded ' + src.name + (v[0] === 's' ? ' (ships with the console; duplicate it to edit under your own name)' : ''))));
},
onPresetInput: e => this.setState({presetInput: e.target.value}),
onPresetSave: () => {
  const typed = st.presetInput.trim();
  const name = typed || (st.presetOwn === 'user' ? st.presetName : autoName());
  if (SHIPPED_NAMES.indexOf(name) >= 0) {
    this.setState(pmsg('"' + name + '" ships with the console and is read-only -- duplicate it, or pick another name', true)); return;
  }
  const next = st.presets.slice(); const k = next.findIndex(p => p.name === name);
  if (k >= 0) next[k] = {name, cfg: clone(cfg)}; else next.push({name, cfg: clone(cfg)});
  persist(next);
  this.setState(Object.assign({presets: next, presetName: name, presetOwn: 'user', presetCfg: clone(cfg), presetInput: ''},
    pmsg((k >= 0 ? 'saved over ' : 'saved ') + name)));
},
onPresetDuplicate: () => {
  const typed = st.presetInput.trim();
  const name = uniqueName(typed || ((st.presetName || autoName()) + ' (copy)'), st.presets.concat(SHIPPED_PRESETS));
  const next = st.presets.concat([{name, cfg: clone(cfg)}]);
  persist(next);
  this.setState(Object.assign({presets: next, presetName: name, presetOwn: 'user', presetCfg: clone(cfg), presetInput: ''},
    pmsg('duplicated as ' + name)));
},
onPresetDelete: () => {
  if (st.presetOwn !== 'user') {
    this.setState(pmsg(st.presetOwn === 'shipped' ? '"' + st.presetName + '" ships with the console and cannot be deleted' : 'no saved preset is loaded', true)); return;
  }
  const next = st.presets.filter(p => p.name !== st.presetName);
  persist(next);
  this.setState(Object.assign({presets: next, presetName: '', presetOwn: '', presetCfg: null}, pmsg('deleted ' + st.presetName)));
},
presetInput: st.presetInput,
presetLabel: st.presetName ? 'preset · ' + st.presetName + (same(cfg, st.presetCfg) ? '' : ' (modified)') : '',
presetMsg: st.presetMsg, presetFg: st.presetErr ? '#d98a84' : '#8fc9ea',
deleteFg: st.presetOwn === 'user' ? '#a8b3c0' : '#4b5563',
deleteWhy: st.presetOwn === 'user' ? 'delete ' + st.presetName : (st.presetOwn === 'shipped' ? 'shipped presets cannot be deleted' : 'load a saved preset to delete it'),
```

Semantics, stated so the record can quote them: **load** is always through
`normalizeCfg`; **save** writes the typed name, else the loaded user preset's
name, else the auto-name — over an existing user preset of that name, never
over a shipped one; **duplicate** always creates a new user preset, named the
typed name or `<loaded> (copy)`, made unique with ` (2)`, ` (3)`; **delete**
removes only a loaded user preset. The `preset · <name>` label says which
preset the composer holds, and **`(modified)` is a byte comparison** of the
emitted pair against the preset's — the same comparison the `load YAML`
round-trip makes (`~3394`), so *"still the preset"* means what `export.md` §2.1
means. A duplicate of a shipped preset with the solver changed and saved is
s002 step 3 and s005 step 2 in four clicks.

**Template** (`~73`, appended after `load YAML` inside the same flex row, in
this order):

```html
<input type="text" value="{{ presetInput }}" onChange="{{ onPresetInput }}" placeholder="preset name" style="width:150px;background:#0a0e14;border:1px solid #232b36;color:#dbe2ea;font-size:11px;padding:5px 8px;border-radius:4px">
<div onClick="{{ onPresetDuplicate }}" style="…the save button's style…">duplicate</div>
<div onClick="{{ onPresetDelete }}" title="{{ deleteWhy }}" style="…;color:{{ deleteFg }}">delete</div>
<div style="font:500 11px 'IBM Plex Mono';color:#8fc9ea">{{ presetLabel }}</div>
<div style="font:400 10px 'IBM Plex Mono';color:{{ presetFg }}">{{ presetMsg }}</div>
```

The `placeholder` is `preset name`: `__bridgeInput()` (every suite) finds the
bridge field by a `ws://` value or a `/rosbridge|9090/` placeholder, so this
field is invisible to it. The `delete` button is always present and dimmed
when inert (the `inject` guard's shape, `~348`) — a conditional element would
change document order between renders. Nothing here reads `save preset` or
`load YAML`; `verify-generate` and `verify-export` keep clicking the first.

### 2.2 `KENNEL_PRESET=<name>` — the driver passes, the page decides

**`p22-console-demo.py`** gains a step before *choice 1*, run only when
`KENNEL_PRESET` is non-empty:

```python
PRESET = os.environ.get("KENNEL_PRESET", "")
...
ws.js(r"""
window.__presetSel = () => [...document.querySelectorAll('select')]
  .find(s => [...s.options].some(o => /load preset/.test(o.textContent)));
window.__slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
// The option whose text IS the name, or whose slug is -- so KENNEL_PRESET=stress
// and KENNEL_PRESET='Stress' both land on the same row of the page's data.
window.__presetOpt = want => { const s = __presetSel(); if (!s) return null;
  return [...s.options].find(o => o.value !== '' && (o.textContent.trim() === want || __slug(o.textContent) === __slug(want))) || null; };
true""")
if PRESET:
    print(f"\n[compose] preset -> {PRESET} (picked in the UI by text)")
    opt = ws.js(f"(() => {{ const o = __presetOpt({PRESET!r}); return o ? o.textContent.trim() : null; }})()")
    step("the preset is one the page ships", bool(opt),
         opt or "not offered -- the four are: " + ", ".join(ws.js(
             "[...__presetSel().options].filter(o => o.value).map(o => o.textContent.trim())")))
    if not opt:
        sys.exit(1)
    ws.js(f"__setSel(__presetSel(), __presetOpt({PRESET!r}).value)")
    # The label is the page's own statement of what it loaded, and the panes are
    # the composition -- read both back; a preset that "loaded" but left the
    # panes at stock would pass a check that only looked at the select.
    deadline = time.time() + 3
    while time.time() < deadline and f"preset · {opt}" not in ws.js("__txt()"):
        time.sleep(0.2)
    step("the composer says which preset it holds", f"preset · {opt}" in ws.js("__txt()"))
    sim, ctrl = pane(SIM_TAB), pane(CTRL_TAB)
    for key, text in (("mpc_solver", ctrl), ("mpc_condensed_size", ctrl), ("mpc_hpipm_mode", ctrl),
                      ("simulator_realtime_rate", sim), ("world_urdf", sim)):
        print(f"  PRESET_{key.upper()}={keyline(text, key)}")
```

`keyline` (the drawer block's helper) moves up so the preset step can use it.
`SOLVER = sys.argv[3]` and `RATE = sys.argv[4]` become **optional-empty**:
`if SOLVER:` around *choice 1*, `if RATE:` around *choice 2* — an empty
argument leaves the control alone, which is what a preset needs and what every
other optional knob already does. With no preset the two are what they always
were (OSQP / 0.75 arrive from the shell script's defaults), so **default
behaviour is unchanged** and `verify`'s `runbook.md` §3.3 reasoning stands.

**`p22-console-demo.sh`**: header knob `KENNEL_PRESET (none) — a preset the
page ships, by its name or its slug: stock-go2-walk, solver-benchmark-a-hpipm,
solver-benchmark-b-osqp, stress. Loaded FIRST; the other knobs then override
only what they name.` Then:

```bash
PRESET="${KENNEL_PRESET:-}"
if [[ -n "$PRESET" ]]; then
  SOLVER="${KENNEL_SOLVER:-}"; RATE="${KENNEL_RATE:-}"     # empty = the preset's
else
  SOLVER="${KENNEL_SOLVER:-PARTIAL_CONDENSING_OSQP}"; RATE="${KENNEL_RATE:-0.75}"
fi
```

and `KENNEL_PRESET="$PRESET"` on the python line. A saved preset **cannot** be
named here — the browser is a throwaway profile — and the header says so.

**`kennel-demo.sh`**: `preset_field` (`:1169–1197`) is **deleted**; the
knobs-region comment (`:139–148`) and the header (`:88–96`) say what the knob
now is: *a preset the console ships, picked in the UI by text — the
composition is the page's data (`kennel_console/composer-scope.md` §7), not this
script's*; `do_compose` becomes

```bash
do_compose() {
    OUT="${1:-$OUT}"
    mkdir -p "$OUT"
    ... (the server block, unchanged) ...
    # A preset fills in only what the operator did not choose: an EXPLICIT
    # KENNEL_SOLVER / KENNEL_RATE still wins, a defaulted one yields to the
    # preset. The page owns the table; p22-console-demo.py reads it back.
    local solver="$SOLVER" rate="$RATE"
    if [ -n "$PRESET" ]; then
        [ "$SOLVER_IS_DEFAULT" = 1 ] && solver=""
        [ "$RATE_IS_DEFAULT" = 1 ] && rate=""
        say "preset           $PRESET -- picked in the console by text; the composition is the page's (composer-scope.md §7)"
    fi
    KENNEL_CONSOLE_URL="$CONSOLE_URL" KENNEL_SOLVER="$solver" KENNEL_RATE="$rate" \
        KENNEL_PRESET="$PRESET" \
        KENNEL_MAP="${KENNEL_MAP:-}" \
        KENNEL_HPIPM_MODE="${KENNEL_HPIPM_MODE:-}" KENNEL_CONDENSED="${KENNEL_CONDENSED:-}" \
        KENNEL_DISTURBANCES="${KENNEL_DISTURBANCES:-0}" \
        "$HERE/p22-console-demo.sh" "$OUT"
    ...
}
```

(`PRESET_MAP` and its `KENNEL_MAP="${KENNEL_MAP:-$PRESET_MAP}"` go with the
table.) A wrong name is refused **by the page**, through p22's exit 1 and its
line naming the four — the driver's `fail "compose failed"` follows, exit 1
instead of today's 2; `runbook.md` §5 gets the row. `do_verify` is untouched:
it reads the solver from the applied run's `run.json`, which is why a preset
composed by the page needs no driver-side knowledge at all.

### 2.3 `verify-scope.py` — group 11, appended after group 10

Group 10 (*no network escaped*) stays last in spirit: append **11** before it
only if the implementer prefers the network check to close the file — either
way the numbering is by insertion and the count is what changes. The group,
in a fresh `Page.reload` after group 9 so no prior state leaks:

| # | Asserts (DOM, and `localStorage` through the page) |
|---|---|
| 11a | the preset select lists **exactly** `SHIPPED_NAMES` first (four, in that order, by text), then the user presets; the `load preset…` option is still first |
| 11b | load *Stock Go2 walk* → `preset · Stock Go2 walk` in the DOM; both panes byte-equal to a fresh session's (the values a group-1-style read captured before any click); no `(modified)` |
| 11c | load *Solver benchmark A (HPIPM)* → `simulator_realtime_rate: 0.0` in the sim pane (the double form `generate.md` §1.4 requires), solver `PARTIAL_CONDENSING_HPIPM`, `mpc_hpipm_mode: "SPEED"`, `mpc_condensed_size: 5`; load *B* → the controller pane differs from A's **only** in the `mpc_solver` line plus its consumes-note, and `mpc_hpipm_mode` is absent from B's YAML (composer-scope §2's 2×2); the sim panes are byte-equal |
| 11d | load *Stress* → `PARTIAL_CONDENSING_OSQP`, `mpc_condensed_size: 1`, rate `1.0`, `plane.urdf` — **the composition `stack/stress.md` §4 measured**, restated here as literals on purpose (a suite that reads its expectations from the page passes whatever the page says) |
| 11e | change the solver → the label reads `preset · Stress (modified)`; change it back → `(modified)` gone (the byte comparison, both directions) |
| 11f | click `save preset` with the shipped preset loaded and no name typed → the message says *read-only*, `kennel.presets` unchanged (read through `localStorage.getItem`) |
| 11g | type `my stress` in the `preset name` field, `duplicate` → `preset · my stress`, `kennel.presets` has one entry named `my stress` whose cfg normalizes to Stress's panes; the select now lists five |
| 11h | change the rate to `0.5`, `save preset` (no name typed) → *saved over my stress*; still one user entry; reload the page → the select lists four shipped + `my stress`; load it → rate `0.5` (**presets survive a reload** — the acceptance) |
| 11i | `duplicate` with nothing typed → `my stress (copy)`; again → `my stress (copy) (2)` |
| 11j | `delete` with a shipped preset loaded → refused, count unchanged; load `my stress (copy)`, `delete` → gone from the select and from `localStorage`; label cleared |
| 11k | the group-8 `legacy` poisoning still normalizes when loaded through the new path (write it, reload, load, `brick`→plane, `-5`→stock, `99`→≤10) — group 8 keeps its own copy of this; this row proves the new handler and the old share the funnel |
| 11l | the composer still has exactly one `CONDENSING` select; `Compose experiment` still the landing view after every reload |

`verify-scope.sh`'s header and `composer-scope.md` §4 say the new count
(36 → about 60).

### 2.4 `verify-runs.py` — group 7, appended: the round trip through `run.json`

The acceptance's *"load preset → generate → load the generated `run.json` back
→ byte-identical YAMLs"* has one honest home: the suite that already writes
real run folders through `serve.py` and reads a real Runs table. Group 7,
after group 6, on the `serve.py` origin:

```python
group("7. a shipped preset round-trips through a real run folder (#72)")
for name in ("Stock Go2 walk", "Solver benchmark A (HPIPM)", "Solver benchmark B (OSQP)", "Stress"):
    goto(); view("Compose")
    ws.js("__setSel(__presetSel(), __presetOpt(%r).value)" % name)          # helpers copied from p22-console-demo.py
    time.sleep(0.4)
    before = {r["run"] for r in api("/api/runs")[1]["runs"]}
    sim_a, ctrl_a = pane(SIM_TAB), pane(CTRL_TAB)                            # pane(): copied from verify-generate.py
    ws.js("__click(__sendBtn().textContent.trim())")
    new = wait_for(lambda: {r["run"] for r in api("/api/runs")[1]["runs"]} - before, timeout=15)
    run = sorted({r["run"] for r in api("/api/runs")[1]["runs"]} - before)[-1]
    on_disk = {n: open(os.path.join(OUT, run, n), "rb").read() for n in ("simulator_params_go2.yaml", "mit_controller_sim_go2.yaml", "run.json")}
    check("%s: the folder's YAMLs are the panes, byte for byte" % name,
          on_disk["simulator_params_go2.yaml"].decode() == sim_a and on_disk["mit_controller_sim_go2.yaml"].decode() == ctrl_a)
    choices = json.loads(on_disk["run.json"])["choices"]
    check("  run.json choices are the preset's", choices == EXPECT[name], str(choices))   # EXPECT: the four rows of §0.2, as literals
    goto(); view("Runs")
    ws.js("__loadRow(0)")            # new helper: the newest row's `load` control, by its text, inside __rowEls()[0]
    time.sleep(0.6)
    check("  Runs › load lands on Compose", "Compose experiment" in ws.js("__txt()"))
    check("  and regenerates the same bytes", pane(SIM_TAB) == sim_a and pane(CTRL_TAB) == ctrl_a)
    time.sleep(1.1)                   # stampNow() has one-second resolution
```

`EXPECT` restates the four compositions as `choices` literals (`world_urdf`,
`world_fix_link`, `simulator_realtime_rate` **as a number: `0` for A/B, `1` for
the rest** — `Number(yamlDouble(0))` is `0`, and the suite must expect what
`emitRunJson` writes, not what YAML shows). The `load` control's exact text
comes from the Runs row template (`~600`); the helper finds it *inside* row 0
so a second `load` elsewhere can never be the one clicked. This is also the
first time the Runs view's `load` is asserted at all — say so in `runs.md` §5.
Count 51 → about 71; `verify-runs.sh`'s header says so.

### 2.5 Records for #72

- **`kennel_console/composer-scope.md` §7 "Named presets (#72)"**, appended:
  the four shipped compositions with their `stress.md` rows (§0.2's table),
  the semantics paragraph of §2.1 verbatim, the option-value scheme, where the
  data lives and why not in `localStorage`, `KENNEL_PRESET` by text and the
  throwaway-profile limit, the two suite groups with their counts, and the
  **bypass row**: *"Stairs + Adaptive gait" — `Adaptive` is a fixed stage
  (§1.2) and obstacle terrain does not walk (`stress.md` §4.1); shipped
  instead: Stress. Retirement: the `gait_sequencer` key entering the MVP
  config path (mapping §1.4's two-key pattern) AND a terrain composition that
  walks — both, not either.* §4's table gains the group-11 row; §6 marks #72
  done.
- **`generate.md` §5** one paragraph: a preset is composer state and generates
  through the same emitters — nothing preset-specific reaches a YAML, and the
  `preset ·` label's *(modified)* is the emitters' byte comparison.
- **`runs.md` §5** the group-7 row and the sentence that `load` is now
  asserted; §8 #72 → done.
- **`stack/stress.md` §4** one sentence: the preset now ships in the page as
  *Stress*; `KENNEL_PRESET=stress` picks it by text (slug), the driver holds
  no table.
- **`demo/runbook.md` §4** `KENNEL_PRESET` row rewritten (four names / slugs,
  picked in the UI, a saved preset is not reachable from the scripted
  compose); §3.1 one sentence naming the presets; §5 one row: *compose says
  "the preset is one the page ships … not offered"*.
- **`kennel-demo.sh` header** `:88–96`, `p22-console-demo.sh` header.

---

## 3. Step 16 — #73, the guides

### 3.1 `guides/first-run.md` — the checklist

**Frame.** Top: what it assumes — *a host where `demo/tools/kennel-demo.sh
setup` and `provision` have already run once (a provisioned guest, on or off);
a terminal at the repo root; nothing else.* One sentence that the appliance
import (*"import the OVA, first boot lands here"*, s001 steps 1–2) is
[#76](https://github.com/alius-git/kennel/issues/76) and until then the
provisioned guest is the starting line. Then the steps, **each one command or
one click**, each with *success looks like* — for a verb, the runbook's cell
**verbatim, in quotes**, with a `(runbook.md §3)` tag; for a click, the DOM
string the suites pin. No other links: a newcomer following this file consults
nothing else (s001 step 8), and the console cannot serve the repo anyway
(§7.10). Records are cited as plain paths in backticks.

| # | Step | Kind | Success looks like | Source |
|---|---|---|---|---|
| 1 | `demo/tools/kennel-demo.sh console` | bash | "the URL, and the page in your browser" | runbook §3 |
| 2 | in the page, open **`load preset…`** and pick **Stock Go2 walk** | click `preset Stock Go2 walk` | the header reads `preset · Stock Go2 walk`; the MPC block reads `HPIPM · partial condensing` | §2.1 |
| 3 | click **`send to kennel-runs →`** | click `send` | the strip reads `saved /home/<you>/kennel-runs/run-<stamp>` | `send.md` §3, `~2942` |
| 4 | `demo/tools/kennel-demo.sh run` | bash | "the run it picked and why, then `pass=10 fail=0` and the Meshcat URL" — the guest is started first if it was off | runbook §3 |
| 5 | `demo/tools/kennel-demo.sh teleop` | bash | "the `ws://` and Meshcat URLs, a line about the watchdog, then *Dashboard → Interventions → connect bridge*" | runbook §3 |
| 6 | open **Dashboard**, click **`connect bridge`** | click `dashboard` / `connect` | the target line ends in `driving`; the status bar reads `mode · live`; the empty states clear panel by panel | `teleop.md` §3, `dashboard.md` §1.3 |
| 7 | in the gait picker choose **WALKING_TROT** | click `gait WALKING_TROT` | `gait WALKING_TROT active — /gait_state period 0.500 s …` | `teleop.md` §12.2 |
| 8 | push the stick **straight up** and hold it for ten seconds, then let go | click `stick -1` / `hold 10` / `release` | in Meshcat the robot trots away; the state plots' `vx` settles near `0.5 m/s` (the `max v` field); no block in the health strip is red, no banner | `teleop.md` §11 group 2 (0.47 m/s measured) |

Closing line, verbatim s001 step 7: **the robot has walked 10 s under your
command.** Then *next: `walkthrough.md`*; and, for when it did not: *`demo/tools/kennel-demo.sh reset` returns the guest to the baseline in ~90 s* (runbook §1). Optional aside under step 4: the Meshcat URL opens in a second tab to watch — not a step.

**The fence convention — how the verb reads this file.** A step's action is a
fenced block: ```` ```bash ```` holds the one command, ```` ```click ```` holds
one or more lines naming page steps. The footer of `first-run.md` states the
vocabulary in one table (`preset <name>`, `send`, `dashboard`, `connect`,
`gait <NAME>`, `stick -1`, `hold <sim-s>`, `release`) and that
`kennel-demo.sh scenario firstwalk` performs the file exactly as written. On
GitHub a `click` fence renders as a code block; in the console it renders as a
callout (§3.4). The human reads the prose beside it; the verb reads the fence;
**there is one file**, which is what makes s001 step 8 checkable.

### 3.2 `guides/walkthrough.md` — compose → send → run → watch → drive → reset

User language, no implementation vocabulary, seven short sections each with
*what you do · what you see · what it means* and one render:

| Section | Names | Image (byte-identical copy of) |
|---|---|---|
| Compose | the map cards, sim options, the pipeline (one selectable stage, five held at stock and shown so), the MPC drawer, the YAML tabs, the four shipped presets and save/duplicate | `kennel_console/composer-scope-render.png` → `img/compose.png` |
| Send | `send to kennel-runs →` vs `generate run ↓`; where the folder lands | `send-render.png` → `img/send.png` |
| Run | `kennel-demo.sh run` — the four lines it prints, quoted from runbook §3; `walk stop`, `down` | `demo/evidence/07-meshcat-walking.png` → `img/meshcat-walking.png` |
| Watch | the Dashboard with `mode · live`, the six panels in one sentence each (→ `diagnosis.md`) | `dashboard-render.png` → `img/dashboard.png` |
| Drive | `teleop`, connect, gait, stick, `STAND`, `E-STOP`, what the watchdog does when the tab dies | `teleop-render.png` → `img/teleop.png` |
| Reset | **two resets**: `reset sim` in the page (the robot, the clock) and `kennel-demo.sh reset` (the whole guest) — the runbook's *restore-stock vs reset* paragraph in user words | `demo/evidence/s004-disturb/05-renders/04-reset.png` → `img/reset.png` |
| The record | the Runs view: verdicts, counters, pick two → the diff; `verify.txt` | `runs-render.png` → `img/runs.png` |

Every verb it names is in `kennel-demo.sh help`; every command it shows is a
`kennel-demo.sh` verb or a click — the `dashboard.md` §1.2 rule, applied to
prose, and `verify-guides` group 5 checks it (§3.5).

### 3.3 `guides/diagnosis.md` — how to read the Dashboard

One section per panel, each with **one real screenshot** — a crop of a live
render already in the repo — what it shows, the topic it reads, the threshold
that colours it, and what a person does about it:

| Panel | Says | Threshold(s), with their owner (`stress.md` §1) | Crop of |
|---|---|---|---|
| Pipeline health | six blocks, green/amber/red; the MPC and WBC blocks tint on the worst solve in a 100 ms bin; `off` is a stage the composition disabled | MPC amber 7 ms / red 10 ms (the console's), WBC 2 ms; the controller's own overtime counter fires at 10 ms | `s003-diagnose/05-renders/02-amber-attempt2.png` → `img/panel-health-amber.png`; `03-red-attempt2.png` → `img/panel-health-red.png` |
| Health counters | sparklines of the heartbeat counters' rates: early contacts, MPC/WBC overtime, MPC/WBC fails — an increase flashes the block | `/controller_heartbeat`, Δ per s | `03-red-attempt2.png` → `img/panel-counters.png` |
| Gait / contact timeline | four rows FL/FR/RL/RR; planned stance as bands, actual contact overlaid, early/late touchdown in amber | 25 ms (quantised to ~20 ms by the subscription rate, `dashboard.md` §6) | `kennel_console/dashboard/evidence/05-timeline.png` → `img/panel-timeline.png` |
| State plots | body height and attitude; commanded vs actual velocity | the fall rule: z median outside `[0.20, 0.45]` m or attitude past 0.5 rad over the window (`verify.md` §4 — the recipe's rule, not the spec's) | `kennel_console/dashboard/evidence/04-live.png` → `img/panel-plots.png` |
| Event feed | the narrated lines — the eight grammar shapes of `dashboard.md` §3.3, quoted; a fall pins the last 5 s | — | `03-red-attempt2.png` → `img/panel-feed-pinned.png` |
| The banner | `FALL DETECTED`, what it latched, `unpin feed` | the same rule | `03-red-attempt2.png` → `img/banner.png` |
| The status bar | `mode · mock/live`, `rtf`, `sim t`, the run id (newest of `/api/runs`) | — | `dashboard-render.png` → `img/statusbar.png` |

Then **"Reading a fall"**: the order of things in the pinned feed (contact
lines, deadline lines if any, then `FALL:` last), the verdict `kennel-demo.sh
verify` files (`fell` outranks `solver-failed`, `runs.md` §1), and the Runs
diff as the next question to ask. And one honest paragraph from `stress.md`
§4.2: a composed stress preset is degraded from the first solve — the amber
you see is the composition, not a transition.

**The crops are made by a tool, not by hand.** `guides/tools/make-img.sh`
(HOST; needs PIL — exit 2 without it, naming `python3-pil`) holds one table:
`source → target [x y w h]`; whole-page images are `cp`'d (byte-identical, so
git stores no new blob — the deck did the same), panels are cropped with PIL
from the sources above at the boxes the implementer measures once on the
1500×807 / 1600×857 renders. `guides/img/` is the whole of what the guides
reference, and the record lists every row of the table.

### 3.4 `serve.py --guides` and the shell's `Guides` item

**`serve.py`.** `--guides DIR` (default `os.path.join(REPO_ROOT, "guides")`;
env `KENNEL_GUIDES` for the knob rule), stored as `Handler.guides_dir` —
`None` when the directory does not exist at start (say so on stdout, like the
pin line). Then:

- `/api/health` gains **`"guides"`**: `null` when there is no directory,
  else a list `[{"name": "first-run.md", "title": "First run — …"}, …]`,
  ordered by `GUIDE_ORDER = ("first-run.md", "walkthrough.md", "diagnosis.md")`
  first and any other `*.md` alphabetically after (#77's two land at the end
  without a code change); the title is the file's first `# ` line, read per
  request like the side channels — an edited guide shows without a restart.
- `GET /guides/<name>.md` → the file's bytes, `text/markdown; charset=utf-8`;
  `GET /guides/<name>.html` → the rendered page; `GET /guides/img/<file>.png`
  → `image/png`. Names checked against `GUIDE_RE = ^[a-z0-9][a-z0-9-]*$` and
  the path **built** from the checked segments, never joined from the request
  (`_run_file`'s reasoning, copied in the comment); everything else under
  `/guides/` is a JSON 404. `Cache-Control: no-store` on all three.
- **`render_md(text, name)`**: stdlib only, `html.escape` on every run of text,
  a fixed subset: `#`/`##`/`###` (with `id`s), paragraphs, `-` and `1.` lists,
  `>` quotes, `|` tables (header, `---` row, body), fenced code with the
  language kept as a class — **a ```` ```click ```` fence renders as a
  callout** `<div class="click">in the console: …</div>`, a `bash` one as
  `<pre><code>`; inline `` `code` ``, `**bold**`, `*em*`, `[text](href)`,
  `![alt](img/x.png)`. Links: `name.md` (no slash) → `name.html` (the frame
  navigates within the guides); `http(s)://` → `target="_blank"
  rel="noopener"`; any other relative path → rendered as `<code>` (a repo
  path the console cannot serve, §7.10). Output: a full document with an
  inline dark stylesheet in the console's palette (`#0a0d12` ground,
  `#dbe2ea` text, `#8fc9ea` links, Plex from `../vendor/fonts/plex.css` —
  relative, same origin) and a top line linking back to `first-run.html` ·
  `walkthrough.html` · `diagnosis.html`. Unknown markdown becomes a paragraph;
  nothing is passed through unescaped.
- The docstring's endpoint list gains the three routes and the knob.

**The page.** `probeKennel` already stores the whole health object as
`st.kennel`. In `renderVals`:

```js
const guides = (st.kennel && Array.isArray(st.kennel.guides)) ? st.kennel.guides : null;
const nav = [{id:'compose', label:'Compose'}, {id:'dashboard', label:'Dashboard'}, {id:'runs', label:'Runs'}]
  .concat(guides ? [{id:'guides', label:'Guides'}] : [])        // appended, only when the server has a guides dir (#73)
  .map(n => { ... unchanged ... });
...
isGuides: st.view === 'guides',
guideList: (guides || []).map(g => ({name: g.name, title: g.title || g.name,
  on: (st.guide || (guides[0] && guides[0].name)) === g.name, onClick: () => this.setState({guide: g.name})})),
guideSrc: guides ? '/guides/' + ((st.guide || guides[0].name).replace(/\.md$/, '')) + '.html' : '',
guideRaw: guides ? '/guides/' + (st.guide || guides[0].name) : '',
```

with `guide: ''` in the state literal (appended). The template block, appended
**after** the Runs `sc-if` (so `verify-dashboard`'s slice is untouched):

```html
<sc-if value="{{ isGuides }}" hint-placeholder-val="{{ true }}">
<div style="height:100%;display:grid;grid-template-columns:240px 1fr">
  <div style="border-right:1px solid #1b222c;padding:18px 14px;overflow:auto">
    <div style="font:600 15px 'IBM Plex Sans'">Guides</div>
    <div style="font:400 10px 'IBM Plex Mono';color:#6f7a88;margin:3px 0 14px">served from guides/ by serve.py · <a href="{{ guideRaw }}" target="_blank" rel="noopener">raw ↗</a></div>
    <sc-for list="{{ guideList }}" as="g" hint-placeholder-count="3">
      <div onClick="{{ g.onClick }}" style="padding:8px 10px;border-radius:5px;cursor:pointer;font:500 12px 'IBM Plex Sans';color:{{ g.fg }};background:{{ g.bg }}">{{ g.title }}</div>
    </sc-for>
  </div>
  <iframe src="{{ guideSrc }}" title="Kennel guide" style="width:100%;height:100%;border:0;background:#0a0d12"></iframe>
</div>
</sc-if>
```

Under plain `http.server` there is no `/api/health`, `guides` is null, the nav
has three items and the template block never mounts — the same rule `send`
(`send.md` §2.1) and `teleop` (`teleop.md` §7) follow, and `verify-guides`
asserts both halves. The guide's own links navigate **inside the frame**;
nothing the page does fetches anything but same-origin URLs, so the zero-non-
localhost assertion in every suite still holds and still means what it meant.

### 3.5 `verify-guides.sh` + `verify-guides.py` — the ninth suite, no VM

Shape: `verify-runs.sh`'s (two servers, one throwaway Chrome, all external DNS
blocked, `serve.py`'s stdout captured — **its access log is the witness**).
Ports `8111` / `8112` / `9311`. Exit 0/1/2. Groups:

| # | Asserts |
|---|---|
| 1 | `/api/health.guides` lists the three names in `GUIDE_ORDER`, each with a title equal to the file's first `# ` line; `GET /guides/first-run.md` is **byte-equal** to `guides/first-run.md` on disk, `text/markdown` |
| 2 | `GET /guides/first-run.html`: 200, `text/html`; contains one `<h1>` with the title; every ```` ```bash ```` fence of the file appears as a `<pre>` whose text is the fence's text byte for byte (escaped, then unescaped by the suite with `html.unescape`); every ```` ```click ```` fence as a `.click` callout carrying its lines; every `![…](img/x.png)` as `<img src="img/x.png">` **and** each such image answers 200 with `image/png`; every `[…](name.md)` as `href="name.html"`; no `<script>`; a fixture guide written into a temp `--guides` dir with `<b>&</b>` in a paragraph comes back escaped |
| 3 | refusals: `/guides/../serve.py`, `/guides/first-run.md/..`, `/guides/img/../first-run.md`, `/guides/First-Run.md`, `/guides/x.txt` → 404 JSON; `serve.py --guides /nonexistent` → `guides: null` in health and `/guides/first-run.html` → 404 |
| 4 | the page on `serve.py`: **four** nav items, the fourth reads `Guides`, `Compose experiment` is still the landing view; click `Guides` → the list shows three titles; the iframe's `src` is `/guides/first-run.html` and **`serve.py`'s log shows `GET /guides/first-run.html`** and one `GET /guides/img/…` per image the file references; the frame is same-origin so `document.querySelector('iframe').contentDocument.querySelector('h1').textContent` is the title; click the frame's `walkthrough.html` link → the log shows it; click the second list item → the frame's `h1` changes; `raw ↗` points at `/guides/first-run.md` |
| 5 | **the checklist is executable**: every ```` ```bash ```` fence is exactly one line of the form `demo/tools/kennel-demo.sh <verb>[ args]` with `<verb>` in `kennel-demo.sh help` (the dashboard suite's own technique, `verify-dashboard.py:380–384`); every ```` ```click ```` line's first word is a step `scenario-page.py`'s docstring lists (parse the docstring's step column) and `hold`; the file's last non-empty heading or line contains *walked 10 s under your command*; every verb `walkthrough.md` and `diagnosis.md` name in backticks as `kennel-demo.sh <verb>` is in `help`; no guide names `ros2 launch` at all (the launcher runs those, the newcomer never types them) and none contains `kennel_(viz\|control\|estimation\|sim)` |
| 6 | every image the three guides reference exists in `guides/img/` and has the dimensions `make-img.sh`'s table says (parse the table out of the script) |
| 7 | the page on plain `http.server`: exactly **three** nav items, no `Guides`, no request to `/guides/` or `/api/` in the page's resource timing; no uncaught errors on either origin |
| 8 | zero non-localhost requests on both origins |

Count: about 45. The `.sh` header names the ports and that the suite needs no
VM; `CLAUDE.md`'s console row goes from eight suites to nine.

### 3.6 `kennel-demo.sh scenario firstwalk` — s001 as a verb

**Why a scenario verb and not the issue's `p22-checklist-audit.sh`** is §7.6:
s001.firstwalk *is* one of the ten scenarios, `scenario disturb` and
`scenario diagnose` are the established shape for "a scenario as a test", and
the verb needs exactly the lib and page driver they share. `do_scenario`
(`:1499`) needs no change — it dispatches to whatever `scenario-<name>.sh`
exists — and `scenario` with no name lists three.

**`demo/tools/scenario-firstwalk.sh`** (HOST, `set -uo pipefail`, sources
`scenario-lib.sh`), header in the house form: what it is (*s001.firstwalk —
`guides/first-run.md` performed as written, timed*), where it runs, usage,
knobs (`KENNEL_S001_BUDGET` 600 · `KENNEL_S001_TARGET` 300 · `KENNEL_S001_VMAX`
0.5 · `KENNEL_S001_VX_TOL` 0.20 · `KENNEL_S001_EVIDENCE`
`demo/evidence/s001-firstwalk` · `KENNEL_CONSOLE_PORT` 8000 — the checklist's
own console, not a scenario server), exit codes 0 / 1 / 2.

Preconditions, each naming its fix (exit 2):
- `scenario_preflight firstwalk nostack` — the lib's preflight with **one
  appended optional argument** that skips the Meshcat line: the other verbs
  need a stack up, this one needs it **down**. The lib's header and
  `scenario-disturb.sh`'s call are unchanged; the argument defaults to the
  old behaviour.
- `verify-meshcat-host.sh --quiet` must **fail** — a stack already up would be
  reaped by `run`'s launcher and the timing would not be *from a provisioned
  guest*; the message says `kennel-demo.sh down`.
- port `KENNEL_CONSOLE_PORT` must be **free** — the checklist's first step
  starts the console; a server already there is one the newcomer would not
  have (the message says `kennel-demo.sh console stop`). `PORT` for
  `start_chrome` is that port: set `KENNEL_SCENARIO_PORT="$KENNEL_CONSOLE_PORT"`
  before sourcing the lib.
- `guides/first-run.md` exists and parses into ≥ 1 fence.

The sequence:

1. `mkdir -p "$OUT_DIR"`; `KENNEL_TIMINGS="$OUT_DIR/00-timings.txt"`; `p22-clock.sh ratio 5` into `00-host-clock.txt` (the dry run's rule: prove the clock before trusting it); `p22-clock.sh mark start`.
2. Parse the fences, in order, with their `###` step headings, into `$tmp/steps.tsv` (`n \t kind \t text`). Print the parsed list at the top of the transcript, so a reader sees what the verb believes the checklist says.
3. For each step, `banner "step $n · $heading"`, `p22-clock.sh mark "step-$n"`, then:
   - **bash**: `echo "CMD: $line" >> "$OUT_DIR/01-commands.txt"`; run `bash -c "$line"` from `$REPO_ROOT` with `2>&1 | tee "$OUT_DIR/02-step-$n.txt"`; `check $? "step $n ran: $line"`; for `console`, additionally `start_chrome` afterwards (the human's browser is the tab `console` opened; the verb's is headless on the same URL — deviation D1, stated) and `page` gets `--serve "$PORT"`.
   - **click**: for each line, `echo "PAGE: $line" >> 01-commands.txt`; `hold N` → `observe walk "$N" --rows` (the lib's, sim seconds, the guest's own monitor) into `04-traces/`; everything else → `page $line`. The `boot` step is **not** in the checklist: the verb runs `page boot` itself right after `teleop` ran and before the `dashboard` fence, because the page must be re-read after `/api/health` gained the bridge URL — this is the verb's re-load of a page the human simply already has open, and it is logged as `PAGE: boot (the verb's reload; not a checklist step)`.
   - after every step: `check` that the step's success text (a fourth column parsed from the step's table row — the verb reads the *Success looks like* cell's first backticked string) appears in the step's transcript or in the DOM. That is the mechanical version of "obey the prose": if the prose promises a line the tool does not print, the check fails **and that is an F-row**, not a script fix.
4. After `hold 10`: from the trace, `x_travel > 0`; the mean planar speed over the **last 3 sim-s** within `KENNEL_S001_VX_TOL` of `KENNEL_S001_VMAX` (`0.40–0.60`; PR #82 measured 0.467–0.476); `tilt_over_frac ≤ 0.02`; from the page: `nobanner`, `health` with **no `red`** (s001's *no error state in any panel*), `__stat('mode') == live`. Then `p22-clock.sh mark walking` — **the timer stops here**, before `release`.
5. `release` (the checklist's own last line), `page errors`, `shot 05-walking.png`.
6. **The trace assertion**: `sort -u` of the `CMD:` lines ⊆ the bash fences ∪ the lines of `~/kennel-staging`'s applied `commands.txt` (fetched over ssh — s001's *"or the console's generated block"*, included so the assertion is the scenario's, even though the checklist never types those lines); `PAGE:` lines ⊆ click fences ∪ `{boot}`. Printed as two checks with the set differences.
7. `p22-clock.sh report` → `00-report.txt`; total = `walking − start` on the RAW column; `check` total ≤ `KENNEL_S001_BUDGET`; `note` whether it is within `KENNEL_S001_TARGET`; `totals`.
8. Trap on every exit: `page release`, `page disconnect` (best effort), `kennel-demo.sh teleop stop` (zero, STAND, bridge down), kill Chrome, `kennel-demo.sh console stop` (the verb started it through the checklist), print what was left: *stack up at STAND, the stock run applied*. The stack is **left up** on purpose — the checklist ends with a walking robot and the next thing a newcomer reads is the walkthrough.

**`scenario-page.py`**, appended steps (docstring list too):

| step | does | asserts |
|---|---|---|
| `preset NAME` | `__click('Compose')`; the `__presetSel()`/`__presetOpt()` helpers of §2.2 (copied, not imported); `__setSel` | `preset · NAME` in the DOM within 3 s; both panes non-empty |
| `send` | click `__sendBtn()` | the strip says `saved ` within 15 s; the path it names exists on the host and holds the four artifacts |
| `dashboard` | `__click('Dashboard')` | the Interventions header is there; `__bridgeInput().value` starts with `ws://` (the URL came from `/api/health` — `boot`'s existing check, factored so `boot` = navigate + `dashboard`) |

`connect`, `gait`, `stick`, `release`, `errors`, `shot` are as they are.

**The record's F-log.** The implementer runs the verb **before** editing the
prose to fit it: every check that fails because the prose promised something
the tool does not print, every place the verb needed a line the file did not
have, is an F-row in `demo/scenarios.md` §s001 — numbered **F10 onwards**,
continuing `dry-run.md`'s series so an F-number is unique across the repo
(§7.8) — with the fix made in the prose and the verb run again. Two green
runs, cold (row 6) and warm (row 7), are the acceptance.

### 3.7 Records for #73

- **`kennel_console/guides.md`** (new): the route and its allow-list, the
  renderer's subset and the escaping rule, the `click` callout, the shell's
  item and the feature-detection rule with both halves asserted, the suite's
  groups and count, the limits — *guides are served from the repo by the host,
  not yet shipped in-image (#74 the manifest, #76 the image); no search; the
  markdown subset; the frame is same-origin by construction.*
- **`demo/scenarios.md` §6 "s001.firstwalk — `kennel-demo.sh scenario
  firstwalk`"** (appended; §0 gains a one-line pointer): the method (obey the
  prose; the fence convention; D1 — an agent's clicks are scripted, a person
  should still perform it once), the timings table from `00-report.txt`
  (RAW, with the ratio column), the F-log, the trace assertion's two set
  differences (empty), the evidence index, the limits (one host, one operator,
  a provisioned guest not an imported appliance).
- **`docs/README.md`**: a **Guides** section between *Start here* and *Plan*
  (the three files, one line each, and *served from the console's `Guides`
  item*); the Console section gains `guides.md`; the Demo section's
  `scenarios.md` line names s001.
- **`README.md`**: one line under *Quick start*: *New here? `guides/first-run.md`
  is the checklist — eight steps to a robot walking under your command.*
- **`CLAUDE.md`**: the repo map gains a `guides/` row (*the newcomer's
  checklist, the walkthrough, the diagnosis primer — served by `serve.py`,
  audited by `scenario firstwalk`; `img/` is copies and crops of renders that
  exist elsewhere*); the console row says **nine** suites (`… runs, guides`);
  the driver verbs line names `scenario firstwalk`.
- **`demo/runbook.md`**: §1 one sentence pointing a newcomer at
  `guides/first-run.md`; §3 *Also there when needed* gains `scenario
  firstwalk` (*s001 as a test: the checklist performed and timed, ~3 min,
  needs the stack DOWN*); §4 the `KENNEL_S001_*` knobs.
- **`kennel_console/serve.md`** §1.1 one sentence: `--guides`.
- **`plan/design/05-guides.md`, `plan/scenarios.md`**: nothing (design §7).

---

## 4. Live-guest protocol — in this order

`EV` is the evidence directory named per row; every transcript opens with
`=== what ===` and `date -u +%FT%TZ`, captured with `2>&1 | tee`. Negative
controls **before** the code that changes them. The maintainer's console
server on `:8000` is stopped for rows 6–7 and restarted at the end.

| # | Do | File | Must show |
|---|---|---|---|
| 0 | `kennel-demo.sh status`; `curl -s localhost:8000/api/health`; `ls -t ~/kennel-runs \| head -3` | `kennel_console/composer-scope/evidence/00-before.txt` | the §0 state: applied run `run-20260908T232641Z`, stack down, bridge down, newest folder the stock composition |
| 1 | **negative control, before commit 2**: `KENNEL_PRESET=stock-go2-walk kennel-demo.sh compose` | `01-preset-refused-before.txt` | exit 2, *no preset 'stock-go2-walk'. The one that exists is 'stress'* — the driver's table is the only thing that knows presets today |
| 2 | commits 1–2 in place: `KENNEL_PRESET=stress kennel-demo.sh compose`; then `diff` the new folder's two YAMLs against `stack/stress/evidence/red-osqp1/runs/run-20260908T184703Z/` | `02-stress-by-text.txt` | p22's `[compose] preset -> stress`, `preset · Stress` read back, `PRESET_MPC_SOLVER=mpc_solver: "PARTIAL_CONDENSING_OSQP"`, `…CONDENSED_SIZE=mpc_condensed_size: 1`; **both diffs empty** — the page's data is byte-identical to the composition the driver's table produced in #70. Then `KENNEL_PRESET="Solver benchmark B (OSQP)"` composes rate `0.0` / OSQP; `KENNEL_PRESET=nonsense` → exit 1 with the line naming the four; `KENNEL_PRESET=stress KENNEL_RATE=0.5 compose` → rate `0.5` (an explicit knob wins) |
| 3 | `KENNEL_PRESET=stock-go2-walk kennel-demo.sh all` | `03-all-stock.txt` | compose → `pass=10 fail=0` → walking; `expect solver PARTIAL_CONDENSING_HPIPM (from run-…/run.json)`; the checklist's composition proven through the scripted path before the checklist is written |
| 4 | `KENNEL_PRESET=stress kennel-demo.sh all` | `04-all-stress.txt` | compose, transfer, launch green; `verify` files **`verdict fell`** (check 9) and exits 1, so `all` stops there **by design** — the issue's *"runs the stress composition end to end"* is read as *through the chain to a verdict*, and the record says so (§7.15); then `kennel-bridge.sh recover` or `run` of the stock folder to stand it up |
| 5 | `kennel-demo.sh scenario diagnose` (the `KENNEL_PRESET=stress` consumer, unchanged) | `demo/evidence/s003-diagnose/10-after-72.txt` | green: `fell k of 3, k ≥ 2`, the same bypass rows — the retired table changed nothing it reads |
| 6 | **#73 cold**: `kennel-demo.sh down`; `kennel-demo.sh console stop`; `kennel-demo.sh reset`; `kennel-demo.sh scenario firstwalk` | `demo/evidence/s001-firstwalk/00-reset.txt`, `00-host-clock.txt`, `00-timings.txt`, `00-report.txt`, `01-commands.txt`, `02-step-*.txt`, `03-scenario-cold.txt`, `04-traces/`, `05-walking.png` | 12/12 from the revert; every step's check green, the success texts found; `x_travel > 0`, speed in band, no red block, no banner; the two set differences **empty**; total on the RAW clock — expected 2–3 min, ceiling 600 s; **the F-rows** from the first attempt, if any, fixed in the prose before this row is the one that is kept |
| 7 | `kennel-demo.sh down`; `scenario firstwalk` again (warm: no reset) | `06-scenario-warm.txt` | green again; the second number beside the first in `scenarios.md` §6 |
| 8 | the nine console suites; `git status --porcelain` | `demo/evidence/s001-firstwalk/09-suites.txt` | nine greens with the new counts (scope, runs, guides); nothing but the intended files changed |
| 9 | leave the guest: `kennel-demo.sh walk stop` (the audit's stack is up on the stock run — that is the maintainer's own newest composition, so leave it applied); `kennel-demo.sh console --no-open` (the maintainer's server back on `:8000`); move this plan's probe run folders **out** of `~/kennel-runs` if any are newer than the audit's (so `run` still picks the newest by right); `status` | `10-after.txt` | stack up at STAND, bridge down, console on `:8000`, the newest folder the audit's own send |

Row 6 is the acceptance of #73 and the one whose numbers the record quotes;
row 2's empty diffs are the acceptance of the driver change; rows 3–4 are
#72's acceptance as written.

---

## 5. Records and doc touches

| File | Change |
|---|---|
| `kennel_console/composer-scope.md` | **§7 Named presets** (§2.5); §4 the group-11 row and the new count; §6 #72 done |
| `kennel_console/guides.md` | **new** (§3.7) |
| `kennel_console/generate.md` | §5 one paragraph (§2.5) |
| `kennel_console/runs.md` | §5 group 7; §8 #72 done |
| `kennel_console/serve.md` | §1.1 `--guides` |
| `demo/scenarios.md` | **§6 s001.firstwalk** (§3.7); §0 pointer; §3 *Running them* gains the verb and its precondition (stack down) |
| `demo/runbook.md` | §1 one sentence; §3 the `scenario firstwalk` line; §3.1 presets; §4 `KENNEL_PRESET` rewritten, `KENNEL_S001_*` added; §5 two rows |
| `stack/stress.md` | §4 one sentence |
| `docs/README.md` | the Guides section; `guides.md`; s001 in the scenarios line |
| `README.md` | one line |
| `CLAUDE.md` | repo map `guides/` row; nine suites; `scenario firstwalk` in the verbs line |
| `demo/tools/kennel-demo.sh`, `p22-console-demo.sh`, `scenario-lib.sh`, `scenario-page.py`, `kennel_console/serve.py`, `verify-scope.sh`, `verify-runs.sh` | headers: version date, knobs, counts |
| `plan/scenarios.md`, `plan/design/*` | nothing |

---

## 6. The PR

### 6.1 Body skeleton (house style: PRs #59, #79, #80, #81, #82)

```
feat(console): the user surface — four shipped presets and a real save/load, the first-run checklist performed and timed, the walkthrough and the diagnosis primer served from the console

Closes #72, closes #73. Plan: plan/user-surface.md.
Two issues in one PR at the maintainer's request: they are steps 15–16 of the
milestone, and the checklist's second step loads a preset the first issue ships.
The milestone's default of one issue per PR is unchanged.

## What is here            — table: file → what changed (the page's SHIPPED_PRESETS and the toolbar; the driver and p22; serve.py's guides route and renderer; the shell's Guides item; the three guides and their images; scenario-firstwalk; the two appended groups and the ninth suite; the records)
## Measured on the live guest — the stress preset by text: two empty diffs against #70's run folder; `all` on Stock (pass=10) and on Stress (fell, by design); scenario diagnose green after the change; scenario firstwalk cold and warm: the RAW-clock total against the ≈5/10-min budget, the per-step marks, the walk's speed and travel, the empty set differences
## Findings from the live protocol — the F-rows the checklist audit produced and how the prose changed; anything rows 2–7 found
## Corrections to the plan, from measurement — say "none" otherwise
## Verification            — §6.2 with outputs; the nine suites with their counts; the six unmodified
## Bypasses                — "Stairs + Adaptive gait" (the retirement is two upstream changes, not one); guides not yet in-image (#74/#76); the checklist starts at a provisioned guest, not an imported appliance (#76)
## Still open              — a person performing first-run.md with a mouse (D1 again); the human friction session of #65
## Decisions               — §7, one line each, with where each is recorded
## Records                 — composer-scope.md §7, guides.md, scenarios.md §6, the touches of §5
```

### 6.2 Verification list — every line with its output in the PR

```bash
bash -n demo/tools/kennel-demo.sh demo/tools/p22-console-demo.sh demo/tools/scenario-*.sh guides/tools/make-img.sh kennel_console/*.sh
python3 -m py_compile kennel_console/*.py demo/tools/*.py
for s in serve scope generate export send teleop dashboard runs guides; do ./kennel_console/verify-$s.sh; echo "verify-$s exit=$?"; done   # nine greens
git diff --stat main -- kennel_console/verify-{serve,generate,export,send,teleop,dashboard}.*                                            # nothing: six unmodified
for f in verify-scope verify-runs; do git diff main -- kennel_console/$f.py | grep '^-' | grep -v '^---'; done                             # nothing removed
grep -c "preset_field" demo/tools/kennel-demo.sh                                                                                          # 0: the table is gone
KENNEL_PRESET=stress demo/tools/kennel-demo.sh compose && diff <newest>/mit_controller_sim_go2.yaml stack/stress/evidence/red-osqp1/runs/run-20260908T184703Z/mit_controller_sim_go2.yaml   # empty
KENNEL_PRESET=stock-go2-walk demo/tools/kennel-demo.sh all                                                                                # pass=10 fail=0
KENNEL_PRESET=stress demo/tools/kennel-demo.sh all; echo "exit=$?"                                                                        # verify: verdict fell, exit 1 by design
demo/tools/kennel-demo.sh scenario diagnose                                                                                               # fell k of 3, k >= 2
demo/tools/kennel-demo.sh reset && demo/tools/kennel-demo.sh scenario firstwalk                                                           # green, the RAW total
demo/tools/kennel-demo.sh scenario firstwalk                                                                                              # green again, warm
grep -n 'sleep' demo/tools/scenario-firstwalk.sh                                                                                          # the page-boot settle in the lib only; name it
grep -c 'innerHTML' "kennel_console/Kennel Console.dc.html"                                                                               # 0: the render is serve.py's
grep -n 'html.escape' kennel_console/serve.py                                                                                             # present: every text run
grep -n 'new WebSocket' "kennel_console/Kennel Console.dc.html"                                                                           # exactly one, unchanged
cmp guides/img/compose.png kennel_console/composer-scope-render.png && echo identical                                                     # every cp'd image, byte for byte
git status --porcelain                                                                                                                    # only the maintainer's slides/ entries, untouched
```

### 6.3 Acceptance, both

| Issue | Criterion | Proof |
|---|---|---|
| #72 | `KENNEL_PRESET=stress kennel-demo.sh all` runs the stress composition end to end; presets survive a reload; the round-trip group is green | rows 2, 4; `verify-scope` 11h; `verify-runs` 7 |
| #73 | a person who has never seen the repo reaches a walking robot from `guides/first-run.md` alone — performed, timed, frictions logged and the prose fixed; the audit script green | rows 6–7; `scenarios.md` §6's F-log and timings; `verify-guides` 5 |

---

## 7. Decisions this plan makes that the issues did not

Stated so the implementer knows what is the maintainer's text and what is this
plan's call — revert the call, not the issue, if measurement says otherwise.

1. **One PR for steps 15–16, #72 first.** The checklist's step 2 is a shipped
   preset; the order is forced, not chosen.
2. **Solver benchmark A/B sit at `simulator_realtime_rate: 0`.** At rate 1.0
   A would be byte-identical to *Stock Go2 walk* under a second name — a lie
   the Runs diff would expose as *no difference*. Rate 0 is what a benchmark is
   for (`stress.md` §1: the deadline is wall-clock per sim-time cycle, and
   rate 0 is 2.1× the solves per wall second), both points are measured rows of
   §2 (`hpipm-speed-5-r0`, `osqp-5-r0`, both walked), and the A/B diff is then
   exactly the solver line plus its dependent field — s005 step 5's *"one
   difference"*. It is one number in the data; revert it and A becomes Stock.
3. **Shipped presets are page data, never in `localStorage`; the driver's
   table is retired; the page is the single source.** `KENNEL_PRESET` matches
   an option by exact text or slug, and only shipped presets are reachable from
   the scripted compose (throwaway profile) — recorded as a limit, not hidden.
4. **Save overwrites a user preset of the same name and refuses a shipped
   one; duplicate always creates; delete only a loaded user preset; the label's
   `(modified)` is the emitters' byte comparison.** So *"is this still the
   preset"* means what `export.md` §2.1 means.
5. **The guides render in `serve.py` and are framed, not rendered in the
   page.** The runtime offers the template no raw-HTML binding, the page
   already frames a server document in the 3D pane, and `html.escape` is a
   stdlib function that lives where the files do. The raw `.md` is served
   too; GitHub renders the same files.
6. **s001 is `kennel-demo.sh scenario firstwalk`, not `p22-checklist-audit.sh`.**
   It is a scenario, the scenario family is the shape for *a scenario as a
   test*, and it needs exactly the lib and page driver they share. `scenario`
   with no name lists it; `demo/scenarios.md` records it. The issue's name is
   the record's description.
7. **The `click` fence.** A checklist step's action is a fenced block the verb
   can execute — `bash` or `click` — so *"every executed command string came
   from the checklist"* is a set difference, not a reading. The human reads
   the prose; the verb reads the fence; there is one file.
8. **Friction numbers continue `dry-run.md`'s series (F10…)**, so an F-number
   is unique across the repo and a later record can cite one without a prefix.
9. **`guides/img/` is copies and crops made by `make-img.sh`**, byte-identical
   copies for whole pages (git stores no new blob), PIL crops for panels at
   boxes the script records; the suite checks presence and dimensions. No new
   live capture: the s003 and dashboard renders are live already, and the
   record cites each source.
10. **The guides link only each other; repo paths are code, not links.** A
    newcomer following the checklist consults nothing else (s001 step 8), and
    the console cannot serve the repo. On GitHub the same files read the same.
11. **The verb's timer stops at `walking`, before `release`**, and starts at
    the first fence — a provisioned guest with the stack down, the console
    port free. The appliance-import half of s001 is #76's; the record says so.
12. **The stack is left up after `scenario firstwalk`**, unlike the other two
    verbs, because the checklist ends with a walking robot and that is the
    state the walkthrough assumes. `teleop stop` still runs in the trap.
13. **`scenario_preflight` gains an optional `nostack` argument** rather than
    a copy of the preflight in the new verb — the lib exists to be sourced by
    the family, the default is unchanged, and a third copy of the guest
    discovery is the drift the lib was written to prevent.
14. **`/api/health.guides` is the feature flag**, `null` when the directory is
    absent — the same shape as `bridge` and `meshcat`, resolved per request.
15. **`all` on Stress ends at `verify`'s `fell`, exit 1, by design.** The
    issue's *"runs the stress composition end to end"* is read as *through the
    chain to a verdict*; a red preset that verified green would be the bug.
16. **Limits, stated now**: one operator and it is an agent (D1 — the mouse
    session is still a person's); the checklist is audited from a provisioned
    guest, not an imported appliance; the guides are served from the repo, not
    yet from the image; the markdown subset is fixed and unknown syntax becomes
    a paragraph; user presets live in one browser profile; the panel crops are
    of one fall (s003 attempt 2) and say so in their captions.

## 8. Don'ts

- Don't write the shipped presets into `localStorage`, and don't let `save
  preset` overwrite one — the refusal is a check (11f).
- Don't reorder the toolbar or the nav; don't add an element whose exact text
  duplicates `load YAML`, `save preset`, `Compose`, `Dashboard`, `Runs`,
  `send to … →`, `generate run ↓`, `connect bridge`, `inject`, `reset sim`,
  `STAND`, `close`, `MPC`, a map card or a YAML tab. The new nav item reads
  `Guides` and nothing else does.
- Don't keep a second copy of the preset table anywhere — not in the driver,
  not in `p22-console-demo.py`. The suites restate the four compositions as
  literals **on purpose** (a suite that reads its expectations from the page
  passes whatever the page says); tools do not.
- Don't `sleep` in `scenario-firstwalk.sh`: the page-boot settle in the lib's
  `start_chrome` is the one tolerated sleep and the verb names it; the walk
  window is `observe` in sim seconds; every other wait is a bounded poll of a
  real observable.
- Don't let the verb run anything it did not parse out of `first-run.md`. If a
  step needs something else to succeed, that is an F-row and a prose fix,
  never a line in the script.
- Don't paraphrase the runbook's *Success looks like* cells in the checklist —
  quote them; and don't re-derive the `run` timings — measure them.
- Don't render markdown with `innerHTML` in the page; the render is
  `serve.py`'s and the pane is a frame. Don't pass any text through unescaped.
- Don't serve anything under `/guides/` that does not match the two name
  patterns; don't serve the repo; don't let a guide link to a file the console
  cannot serve.
- Don't modify `verify-serve`, `-generate`, `-export`, `-send`, `-teleop`,
  `-dashboard`; `verify-scope` and `verify-runs` gain appended groups only,
  and nothing is removed from either.
- Don't touch `plan/scenarios.md` or `plan/design/*`; the deviations go in
  `demo/scenarios.md` §6 and `composer-scope.md` §7.
- Don't start `scenario firstwalk` on a guest with a stack up, and don't skip
  the `reset` row — the cold number is the one s001 asks for.
- Don't take new live screenshots for the primer unless a panel has no live
  render; the s003 and dashboard renders exist and are cited by path.
- Don't put a guide image anywhere but `guides/img/` — the directory is what
  ships in-image later, whole.
- Don't make `Guides` the landing view. Compose is (`verify-serve` step 4,
  p22's first check).
- Don't `git add -A` — the maintainer's `slides/` work is in the tree.
- Don't leave the maintainer's console server down or a stress composition
  as the newest run folder at the end of the session — row 9.
