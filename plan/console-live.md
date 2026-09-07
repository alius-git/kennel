# Kennel — Plan F: the console goes live (#61 · #62 · #63 · #64), one PR

Steps 4–7 of milestone [*Finish the system*](https://github.com/alius-git/kennel/milestone/2),
written like plans A–E (`next-goals.md`, `teleop-joystick.md`, `reliability.md`)
so an agent can implement them on one branch without re-deriving the repo.
Everything in §0 was checked on **2026-09-07** with the commands shown.

| Step | Issue | One line |
|---|---|---|
| 4 | [#61](https://github.com/alius-git/kennel/issues/61) | the real Meshcat viewer in the 3D pane; every empty state names a verb that exists; a visible `mode · mock` / `mode · live` label |
| 5 | [#62](https://github.com/alius-git/kennel/issues/62) | `RosbridgeDataSource` part 1 — status bar, health strip, counters and state plots from the running stack; a recorded fixture and `fake-rosbridge.py --replay` so it is all testable with no VM |
| 6 | [#63](https://github.com/alius-git/kennel/issues/63) | part 2 — gait/contact timeline, the event-feed grammar shared by mock and live, fall detection by `verify.md` §4's rule with the pinned post-mortem |
| 7 | [#64](https://github.com/alius-git/kennel/issues/64) | the verify report lands in the run folder as `verify.json`; `/api/runs` serves it; the Runs view shows real verdicts, counters and a one-key config diff |

**One branch, one PR, closing all four.** That is the maintainer's call for this
step; the milestone's default is one issue per PR and the PR body says so (§8.1).
The order is fixed: 4 first (the 3D pane, the mode label and the suite skeleton
everything else extends); then 5 (the fixture, the replayer, the link and the
source); then 6 (the remaining panels on the same source and fixture); then 7,
whose Runs view reads the report that `run` writes and whose `fell` verdict
needs 6's rule to have been proven live.

Budget: roughly two hours of live-guest time (§6), the rest is editing. The
guest work is ordered so the stack is relaunched as few times as possible.

---

## 0. Ground truth the implementer must know

**Repo.** `origin/main` is `cb04b19` (*Merge pull request #79 from
alius-git/stack/60-reliability*, 2026-09-07 10:44 -03). The local `main` is
**behind** it at `b98aa41` — `git checkout main && git pull` before branching.
The working tree on `stack/60-reliability` is clean; that branch is merged and
can be deleted. No `console/*` branch exists. `slides/` is committed (#60).

**Host.** `google-chrome`, `python3` 3.12, `virsh`, `curl`, `ssh` present. The
six console suites need only Chrome and Python; `verify-generate.sh`'s
stock-file group needs the gitignored `dfki-quad/` clone, which is present. The
console server is already running: `~/kennel-runs/.console.pid`, `serve.py` on
`:8000`, out dir `~/kennel-runs` (13 run folders from 2026-08-30 and
2026-09-06, no `verify.json` in any of them — nothing writes one yet).

**Guest.** Domain `kennel-vm-baseline` running, lease `kennel-vm` at
`192.168.122.32`. `kennel-demo.sh status`: container `dfki_quad` running,
applied run `run-20260906T212107Z` (OSQP, flat plane, rate **0.75**), the
six-node graph complete, Meshcat reachable at `http://192.168.122.32:7000/`,
bridge not up. The stack has been up since 2026-09-06 21:21Z: the sim clock
reads **43 000 s**. During today's 12-s probe (below) the robot **tumbled**
for the first 9 s after a trot command — tilt over 0.5 rad in 52 % of samples,
max 3.08 rad, z median a normal 0.29 m — then righted itself and trotted with
the diagonal-pair contact pattern; it was upright at `STAND` when the probe
ended. Two things follow: start the protocol with `kennel-demo.sh run`, which
relaunches everything on a fresh simulator; and note for §4 that **the z-median
rule alone would not have called that fall — the sustained-tilt rule does.**
The guest's applied-run marker is `~/kennel-staging/current-run` (one line,
`run-20260906T212107Z`), written by `guest-apply-config.sh`; `~/kennel-staging/runs/`
holds the staged folders. The last verify report is on the guest at
`/tmp/kennel-verify/{report.txt,results.psv,check.py,nodes.*}` (2026-09-06
21:56Z, `pass=10 fail=0`).

**The console today** (`kennel_console/Kennel Console.dc.html`, 2466 lines).
Every Dashboard panel is gated on one flag, `live = st.conn === 'connected'`
(line 2203), which is the **mock's** running state. What the panels say:

| Panel | Header subtitle (line) | Empty state names (line) | Real observable at the pin |
|---|---|---|---|
| 3D scene | `meshcat · /tf · 30 Hz` (385); a dashed *meshcat iframe slot* + `http://localhost:7000/static/` (391–393) | `ros2 launch kennel_viz meshcat.launch.py port:=7000` (398–400) | Drake Meshcat at the URL `/api/health` already carries as `meshcat` (`serve.py:288`), updated at `visualisation_update_rate: 0.05` s |
| Pipeline health | `solve time vs deadline · ms` | `/pipeline/diagnostics` … `ros2 launch kennel_control pipeline.launch.py` (425–427) | `/solve_time` (`MPCDiagnostics`), `/wbc_solve_time` (`WBCReturn`), `/gait_state`, `/controller_heartbeat` |
| Gait/contact timeline | `/gait/plan + /contact_state · bool · 10 Hz` (440) | `/contact_state has never been seen — … kennel_control pipeline.launch.py` (454–456) | `/gait_state` (`contact[4]`, `phase[4]`, `period`, `duty_factor[4]`, `phase_offset[4]`), `/quad_state.foot_contact[4]`, `/contact_state.ground_contact_force[4]` |
| Health counters | `/diagnostics · events·s⁻¹` (463) | `/diagnostics is silent` (472–474) | `/controller_heartbeat` (`ControllerInfo`), five cumulative `num_*` counters |
| State plots | `/odom + /imu/data · m, deg, m·s⁻¹ · 10 Hz` (483); plot labels `/odom → pose.position.z`, `/imu/data → orientation`, `/cmd_vel vs /odom → twist.linear` (1930–1940) | `/odom missing — ros2 launch kennel_estimation state_estimation.launch.py` (492–494) | `/quad_state` pose, twist, `joint_state.effort[12]`; `/quad_control_target` for the command |
| Event feed | `/rosout · auto-scroll` (2319) | `nothing publishing on /rosout — ros2 launch kennel_sim go2_sim.launch.py` (515–517) | narrated from the topics above |
| Detail drawer | `/mpc/diagnostics`, `/wbc/diagnostics`, `/model/estimate` (1942–1958) | — | `/solve_time`, `/wbc_solve_time`, `/controller_heartbeat.num_model_updates` |
| Compose blocks | `BLOCKS[].topic` (726–741): `/gait/plan /mpc/solution /wbc/torque_cmd /swing/foot_target /contact_state /model/estimate` | — | `/gait_state /solve_time /wbc_target /contact_state` (`stack/known-good/06-healthy-graph.txt`); swing has no topic; adaptation is `/quad_model_update` |

None of the four `ros2 launch kennel_*` packages exists anywhere. The status
bar's first item reads `MockDataSource · connected` (2398); its right-hand
button `connect`/`disconnect` (609, 2412–2417) starts and stops the mock. The
nav-rail footer (53) says `MockDataSource · 10 Hz · scripted`. The Runs view
lists five seeded fictional runs (`SEED_RUNS`, 1683) plus in-session `staged`
rows; its diff (2185–2193) is `flatten(cfg)` over every block including the
out-of-scope stages.

**The `DataSource` contract, as `MockDataSource` (1580–1680) exposes it and
`Component` consumes it.** #62 asks for this enumeration to be written first;
here it is, read from the code, and it is what `RosbridgeDataSource` implements:

| Member | Type | Read by |
|---|---|---|
| `buf` | array of samples at **10 Hz sim time**, ≤ 900 kept: `{t, mpcMs, mpcIters, wbcMs, solverFail, planned[4], actual[4], miss[4], height, pitch, roll, vx, vy, wz, cvx, cvy, cwz, rtf, hb, c:{…counters}}` — `pitch`/`roll` in **degrees** | `win()`, `drawTimeline`, `drawSparks`, `drawPlots`, `drawDetail`, `renderVals` (`last`) |
| `counters` | `{mpcOvertime, wbcOvertime, solverFail, contactMiss, imuStale}` cumulative | `drawSparks` totals, `health`, `detailStats` |
| `lastInc[k]` | sim time of the last increment of counter `k` | `recent()` → block flash/tint |
| `events` | `[{t, sev: info\|warn\|error\|fatal, text}]`, ≤ 500 | the feed, the pinned post-mortem |
| `t` | sim seconds | status bar `sim t`, `recent()` |
| `fallen`, `fallText`, `fallAt`, `halted` | fall state | banner, pin window, health `down` |
| `timer` | truthy while running | `onReset` |
| `cmd {vx, vy, wz}` | the mock's velocity command | joystick, `velFields` |
| `start() stop() reset()` | lifecycle | status-bar toggle, `onReset`, unmount |
| `advance()`, `seedDemo(s)` | step the scripted demo | `onStep`, `onStep10`, mount |
| `inject(f)` | scripted disturbance | `onInject` |
| `last()` | newest sample | — |

`Component` makes 33 `ds.<member>` references (`grep -oE '\bds\.[a-zA-Z]+' | wc -l`); nothing else in the page
knows which source it is. That is the seam, and it holds.

**`serve.py` today** (395 lines): `GET /api/health` (`kennel, out, pin, bridge,
meshcat`, the last two read per request from `<out>/.kennel-bridge` and
`<out>/.kennel-meshcat`), `POST /api/runs`, `GET /api/runs` →
`{out, runs:[{run, path, modified, files, complete}]}` (`list_runs`, 227).
`kennel-demo.sh status` (1332) parses `/api/runs` with a `sed` on lines
matching `"run": "…"` — **any new key named `run` inside a nested object would
be listed as a run**; §5.3 avoids it.

**The verify report today.** `kennel-verify.sh` stage 2 appends every check to
`results.psv` as `STATUS|name|observable|measured|required` (`record()`, bash
199 and python 341), prints the verdict block to `report.txt` (835–851), and
stage 1 copies `/tmp/kennel-verify/.` out to the guest's `$OUT` (137). The
numbers that #64 wants — the check-7 deltas, `vx_mean`, `dx`, the z median —
exist only as floats inside `check.py`'s `phase_walk()` (565–722), formatted
into the `measured` strings. `kennel-demo.sh verify` (1178–1206) runs it over
SSH and reads the exit code; nothing reads the files back. The driver knows the
applied run only in-process (`APPLIED_RUN`, set by `do_transfer` at 1152).

**The bridge, measured today** — rosbridge `2.0.7` in the pinned image. Probe:
`kennel-demo.sh teleop` → `walk` → a stdlib WebSocket client (the `WS` class in
`kennel_console/cdp.py`) subscribing for 12 s → `walk stop` → `teleop stop`:

| Topic | `throttle_rate` | Arrived | Max message |
|---|---|---|---|
| `/clock` | 100 | 10.0 Hz | 92 B — `{"clock":{"sec":43164,"nanosec":457000000}}` |
| `/quad_state` | 20 | **49.5 Hz** | 2613 B — `pose.pose.{position,orientation}`, `twist.twist.{linear,angular}`, two 36-element `covariance` arrays, `acceleration`, `joint_state.{position,velocity,effort,acceleration}[12]`, `foot_contact[4]`, `ground_contact_force[12]`, `belly_contact` |
| `/solve_time` | 20 | 49.3 Hz | 529 B — `solve_time` (s), `acados_num_iter`, `acados_return`, `qp_residuals[4]` |
| `/wbc_solve_time` | 20 | 49.4 Hz | 267 B — `success`, `total_time`, `qp_update_time`, `qp_solve_time` (s) |
| `/gait_state` | 20 | 49.3 Hz | 297 B — `period`, `duty_factor[4]`, `phase_offset[4]`, `contact[4]`, `phase[4]`, `gait_sequencer` — **no header** |
| `/contact_state` | 20 | 49.3 Hz | 234 B — `ground_contact_force[4]`, **four scalars**, not 4×3 as the spec's wording suggests |
| `/controller_heartbeat` | 0 | 1.5 Hz wall = 2 Hz sim at rate 0.75 | 322 B — the six `num_*` and `keep_pose_active` |
| `/quad_control_target` | 0 | 9.7 Hz | 165 B — the six fields; the held trot publishes at 10 Hz |
| `/no_such_topic_kennel` | 0 | 0, **no error op** | a subscribe to a topic that does not exist is accepted silently and delivers once it appears — panels can come alive without resubscribing |

3218 publishes in 12.0 s, 2.31 MB of JSONL, **571 kB gzipped** (4:1 — a 30-s
fixture is ~1.4 MB in git as `.jsonl.gz`). Inter-arrival on `/quad_state` was
13.8–26.1 ms, median 20.2: `throttle_rate` is a floor on the gap, not a
metronome. `/clock` advanced 8.98 sim-s in 11.97 wall-s: rtf 0.750, i.e. the
composed rate, measurable from `/clock` alone. Guest CPU during the probe with
eight subscriptions and a trot: ~21 % user across 8 vCPUs (the per-process
figure is §6's to measure: `top -b -c` — plain `top` truncates rosbridge's
`COMMAND` to `python3`, which is why today's sample carries no per-process row).
rosbridge's subscriber QoS defaults to **BEST_EFFORT / VOLATILE** and adopts
TRANSIENT_LOCAL when a publisher has it
(`rosbridge_library/internal/subscribers.py:156–184` in the image), so the
controller's `QOS_BEST_EFFORT_NO_DEPTH` topics (`mit_controller_node.cpp:218–245`
at the pin) arrive without a QoS argument. `throttle_rate` is "the minimum time
in ms between messages" and the effective value for a topic is the **minimum
over its subscribers** (`capabilities/subscribe.py:132, 225`).

**Meshcat, measured today.** `curl -D - http://192.168.122.32:7000/` → `200`,
`Content-Type: text/html`, `uWebSockets: 20`, **no `X-Frame-Options`, no
`Content-Security-Policy`**; the page is Drake's fork of meshcat's `index.html`
(loads `meshcat.js` and `stats.min.js` from the same origin and opens its own
WebSocket to it). It can be framed. It needs WebGL — SwiftShader flags in
headless Chrome, as `p21-meshcat-shot.sh:104` uses; the suites' Chrome does not
need it because they frame a localhost stand-in (§2.4).

**What the six suites pin down** — read these before designing, they are the
constraints, and they are not to be modified:

- `verify-scope.py:155` asserts the Runs view contains `RUN-2026-07` under
  plain `http.server` → the seeded runs **stay in mock mode** (§5.5).
- `verify-teleop.py:187` takes `ops("subscribe")[0]` and asserts it is the
  `/quad_control_target` probe → on a shared socket the **teleop probe's
  subscribe goes on the wire before any DataSource subscribe** (§3.4).
- `verify-teleop.py:123` finds *connect bridge* inside the teleop group only,
  so the status bar may carry its own connect button; every suite's `__click`
  takes the **first** element in document order whose exact text matches, so
  never add an element whose exact text is `Dashboard`, `Runs`, `Compose`,
  `close`, `MPC`, `load YAML`, `load into composer`, `Obstacle terrain`,
  `Flat plane`, `generate run ↓`, a YAML tab name, or `send to … →` ahead of
  the existing one.
- `verify-serve.sh` step 2 greps the HTML for `src="http…"` / `href="http…"`:
  the iframe's `src` must be a template binding, never a literal URL.
- Every suite asserts zero non-`localhost` resource requests and installs an
  error collector before the page loads: nothing may throw on a 404 `/api/`, an
  absent WebSocket, or an unexpected rosbridge message.
- `verify-send.py` and `verify-export.py` assert `run.json`'s exact five keys →
  `run.json` is untouched (#64 says so too).

**Read first.** `CLAUDE.md`; `plan/design.md` §4–§5; `plan/scenarios.md`
s003, s005, s007; `plan/prompts.txt` View 2 (both parts); `kennel_console/teleop.md`
§2, §6, §7, §10; `kennel_console/send.md` §2.1, §3; `kennel_console/export.md`
§3, §5; `stack/verify.md` §1.1, §2, §4; `stack/bridge.md` §3, §5.1, §7, §9;
`stack/composed-run.md` §9.2 (the four defects a live protocol found — the
species of bug to expect here too); PR #59's body for the PR shape.

---

## 1. Shape of the work

- Branch `console/61-console-live` from `origin/main` (`cb04b19`).
- Five commits, in this order, house form `<type>(<area>): <what> (#N)`:
  1. `feat(console): the 3D pane frames the real viewer, empty states name real verbs, the mode is labelled (#61)` — includes this plan file.
  2. `feat(console): RosbridgeDataSource, part 1 — status bar, health strip, counters and plots from the stack; fixture and replay (#62)`
  3. `feat(console): RosbridgeDataSource, part 2 — timeline, event grammar, fall detection by verify.md's rule (#63)`
  4. `feat(runs): the verify report lands in the run folder, /api/runs serves it, the Runs view shows real verdicts and a diff (#64)`
  5. `docs(console): record the console-live pass — dashboard.md, runs.md, evidence, the doc touches (#61, #62, #63, #64)`
- New files: `kennel_console/verify-dashboard.sh` + `.py`, `verify-runs.sh` +
  `.py`, `record-fixture.py`, `dashboard-shot.sh`, `fixtures/`, `dashboard.md`,
  `runs.md`, `dashboard-render.png`, `runs-render.png`,
  `dashboard/evidence/`, `runs/evidence/`. Modified: the console HTML,
  `serve.py`, `fake-rosbridge.py`, `stack/verify/kennel-verify.sh`,
  `demo/tools/kennel-demo.sh`, and the records named in §7.
- Every touched script keeps its header truthful (`# Version:` date, what,
  **where it runs**, usage, exit codes). Python tools carry the same block as a
  docstring, as `serve.py` and `fake-rosbridge.py` do.
- **Append, never reorder** in the console: new controls go after the last
  existing one in their row; new status items go after `run`; new columns after
  `counters`.
- **One WebSocket per page.** The architecture after step 5:

```
                 connect bridge (Interventions)  /  connect (status bar, kennel mode)
                                  │
                           RosbridgeLink  ── one socket, id-routed ops
                          ┌───────┴────────┐
                  RosbridgeTarget    RosbridgeDataSource   (this.ds when live)
                  (#58, publishes)   (subscribes, bins at 10 Hz sim → buf)
                                            │
                        MockDataSource (this.ds when not) — paused while live
```

- Nothing here launches a process. The bridge is started by `kennel-demo.sh
  teleop` as before; the page **never auto-connects**.

---

## 2. Step 4 — #61, the dashboard truth pass

### 2.1 The 3D pane

Replace lines 388–394 (the *meshcat iframe slot* branch) with two branches on a
new flag `hasScene = !!(st.kennel && st.kennel.meshcat)`:

```html
<sc-if value="{{ hasScene }}" hint-placeholder-val="{{ true }}">
  <div style="flex:1;min-height:0;position:relative;background:#0a0e14">
    <iframe src="{{ meshcatUrl }}" title="Drake Meshcat" style="position:absolute;inset:0;width:100%;height:100%;border:0;background:#0a0e14"></iframe>
  </div>
  <div style="padding:4px 11px;border-top:1px solid #1f2731;font:400 9px 'IBM Plex Mono';color:#5d6875">{{ meshcatUrl }} · pose {{ poseText }}</div>
</sc-if>
<sc-if value="{{ noScene }}" hint-placeholder-val="{{ true }}">   <!-- was: the dashed slot -->
  … the empty state of §2.2, row "3D scene" …
</sc-if>
```

`meshcatUrl: st.kennel && st.kennel.meshcat ? st.kennel.meshcat : ''`,
`noScene: !hasScene`. The URL is what `serve.py` validated against `URL_RE`
and what `teleop`/`walk` wrote to `<out>/.kennel-meshcat`; the page never
composes one. The iframe lives inside `isDash`, so it mounts only on the
Dashboard and Meshcat reconnects on each visit — cheap, and it keeps the
Compose view free of a WebGL context. The `pose` strip under it is the DOM
mirror the suite reads (§2.4 group 1). Header subtitle (385) becomes
`meshcat · 20 Hz (visualisation_update_rate 0.05 s)`.

Feature detection is exactly `send`'s and teleop's: `probeKennel()` (1766)
already stores `h` whole, so `state.kennel.meshcat` is present when
`/api/health` carried it. Under plain `http.server` there is no iframe, no
strip, no new element — the text fix of §2.2 is the only difference.

### 2.2 The empty-state audit

The rule: the only commands a panel may name are `kennel-demo.sh` verbs or the
three `ros2 launch` lines of `COMMAND_BLOCKS`. Every empty state becomes three
lines — what is missing (the real topic), the verb, and in mock mode a third
line about the demo. Replace the six literal blocks:

| Panel (line) | Line 1 | Line 2 |
|---|---|---|
| 3D scene (398–400) | `No viewer attached` / `Meshcat is served by the simulator and reaches this page through /api/health` | `kennel-demo.sh run` — `walk` or `teleop` to see it move |
| Pipeline health (425–427) | `No controller heartbeat` / `/controller_heartbeat, /solve_time and /wbc_solve_time are silent` | `kennel-demo.sh run` (block 3 of commands.txt: `ros2 launch controllers mit_controller.launch.py sim:=go2`) |
| Timeline (454–456) | `No gait or contact stream` / `/gait_state and /quad_state are silent` | `kennel-demo.sh run` |
| Counters (472–474) | `No counters` / `/controller_heartbeat is silent` | `kennel-demo.sh run` |
| State plots (492–494) | `No state stream` / `/quad_state is silent — the simulator publishes it with publish_quad_state: true` | `kennel-demo.sh run` (block 1: `ros2 launch simulator simulator.launch.py sim:=go2`) |
| Event feed (515–517) | `No events` / `the feed narrates /controller_heartbeat, /solve_time, /wbc_solve_time and /quad_state` | `kennel-demo.sh run` |

Third line, rendered only when the current source is the mock (`!isLive`):
`mock — the scripted demo is paused; connect resumes it`. The verb strings are
one constant each (`VERB_RUN = 'kennel-demo.sh run'`) so the audit grep of
§2.4 group 3 has one place to read.

Fix the header subtitles and plot labels in the §0 table to the real topics in
the same pass (`/gait_state + /quad_state.foot_contact + /contact_state`,
`/controller_heartbeat · Δ per s`, `/quad_state pose + twist vs
/quad_control_target · m, deg, m·s⁻¹`, `narrated · auto-scroll`,
`/quad_state → pose.position.z`, `/quad_state → pose.orientation`,
`/quad_control_target vs /quad_state → twist.linear`, `/solve_time`,
`/wbc_solve_time`, `/controller_heartbeat.num_model_updates`), and
`BLOCKS[].topic` to `/gait_state`, `/solve_time`, `/wbc_target`, `(internal —
no topic at the pin)`, `/contact_state`, `/quad_model_update`. The spec says
every plot labels its source topic; a live plot under a fictional label is the
dishonesty this pass removes. No suite asserts any of these strings (checked:
`grep -n '/odom\|/gait/plan\|/mpc/solution\|kennel_viz' kennel_console/verify-*.py`
is empty).

### 2.3 The mode label

Status bar (2397–2411): the first item becomes
`{label:'mode', value: isLive ? 'live' : 'mock (scripted demo)', color: isLive ? '#3fbf7f' : '#e0a63c'}`,
followed by `{label:'conn', …}` as today but reading the link in live mode
(`connected` / `connecting` / `disconnected`). `isLive = this.ds instanceof
RosbridgeDataSource` — in step 4 that class does not exist yet, so
`isLive = false` and the label always reads mock; wiring it is §3.5. The
nav-rail footer (53) becomes `{{ sourceName }}<br>{{ sourceRate }}`:
`MockDataSource · 10 Hz · scripted` / `RosbridgeDataSource · <url> · ≤ 50 Hz`.

### 2.4 `verify-dashboard.sh` + `verify-dashboard.py`

The shape of `verify-teleop.sh`: both servers, one headless Chrome, DNS
blackholed with `localhost` excluded, a temp `--out`. Two fixtures it starts
itself:

- **A fake Meshcat** on `localhost:<meshcatPort>`: `python3 -m http.server`
  in a temp dir holding one `index.html` (`<title>fake meshcat</title>`), its
  stderr — the access log — teed to `meshcat-access.log`. The suite writes
  `http://localhost:<meshcatPort>/` to `<out>/.kennel-meshcat` **before** the
  page loads, so the hand-off is exercised, and reads the log for the `GET /`
  the iframe makes. Decided over "assert the attribute without navigating":
  a `src` nobody fetched proves the string, not the pane; and over pointing at
  the real guest: the DNS blackhole does not stop IP literals, and the suites
  must run with no VM.
- `fake-rosbridge.py` in `--replay` mode (from step 5; in step 4's commit the
  bridge fixture is started but only the teleop-style checks below use it).

Groups, each check printed `[PASS]/[FAIL]` as the other suites do:

| Group | Asserts |
|---|---|
| 1 · the pane | under `serve.py` with `.kennel-meshcat` written: exactly one `<iframe>` on the Dashboard, `src === health.meshcat`; the fake Meshcat's log gains a `GET /` line **after** `Dashboard` is clicked and holds none before (bytes on the wire, the house style); the `pose` strip is present; no iframe on Compose or Runs |
| 2 · no URL, no pane | delete `.kennel-meshcat`, reload: no iframe, the 3D empty state names `kennel-demo.sh run` |
| 3 · the audit | a grep of the HTML's Dashboard section (from `isDash` to `isRuns`) for `kennel-demo.sh [a-z]+` and `ros2 launch [^<"]+` yields a set ⊆ {the verbs of `kennel-demo.sh help`} ∪ {the three `ros2 launch` lines of `COMMAND_BLOCKS`}; and no string matching `kennel_(viz\|control\|estimation\|sim)` anywhere in the file |
| 4 · mode label | `mode · mock (scripted demo)` present on load under both servers; `live` absent |
| 5 · plain `http.server` | no iframe, zero mustaches, no errors, the audit-fixed empty states present (toggle `disconnect` to reveal them) |
| 6 · network | zero non-localhost requests; zero WebSockets on load |

The `.py` side reuses `verify-teleop.py`'s `HELPERS` verbatim where it can
(`__click`, `__btn`, `__txt`, the socket and error collectors) — copy, do not
import, as the other suites do.

### 2.5 Record, render, runbook

`kennel_console/dashboard.md` §1 (the record's shape is `teleop.md`'s: what is
delivered, decisions, verification table, limits). `dashboard-render.png`: the
Dashboard with the real viewer inside the pane after `walk` — taken with
`kennel_console/dashboard-shot.sh` (§6.1, a HOST tool modelled on
`p21-meshcat-shot.sh`: Chrome with the SwiftShader flags, CDP, wait for the
iframe's document to reach `complete` and for the pane's `pose` strip to change
twice, then `Page.captureScreenshot`). `demo/runbook.md` §5: there is no row
"the 3D pane says start the visualizer" today — add it: *the 3D pane says no
viewer attached* → `kennel-demo.sh run` (the URL reaches the page through
`/api/health` after `walk` or `teleop`).

### 2.6 Acceptance for step 4

After `run` → `walk`, the pane shows the robot trotting inside the page ·
`verify-dashboard.sh` green with no VM · the six suites green and unmodified ·
under plain `http.server` no iframe and no new control.

---

## 3. Step 5 — #62, `RosbridgeDataSource` part 1

### 3.1 The fixture recorder — `kennel_console/record-fixture.py`

HOST tool, stdlib, beside `fake-rosbridge.py`; reuses the `WS` class from
`cdp.py` (it already does the handshake, masking and JSON framing). Today's
probe is its skeleton:

```
record-fixture.py --url ws://GUEST:9090/ --seconds 30 --out fixtures/healthy.jsonl.gz [--run ~/kennel-runs/run-<stamp>]
```

- Subscribes, in this order and with these throttles (ms): `/clock 100`,
  `/quad_state 20`, `/solve_time 20`, `/wbc_solve_time 20`, `/gait_state 20`,
  `/contact_state 20`, `/controller_heartbeat 0`, `/quad_control_target 0`;
  `queue_length: 1` on all. The two #63 topics are recorded from the start —
  one fixture format, and re-recording later would cost a guest session.
- Line 1 is metadata: `{"kennel_fixture":1,"recorded_at":"<UTC>","bridge":"<url>","run":"<stamp>","pin":"<sha>","topics":[…],"throttle_ms":{…}}`.
  Then one `{"t":<wall s since start>,"op":"publish","topic":…,"msg":…}` per
  message **as it arrived** — never edited, never reordered. `--run` copies that
  folder's `run.json` beside the fixture as `<name>.run.json`.
- gzip at write time (`gzip.open`); the replayer reads `.jsonl` or `.jsonl.gz`.
- Exit `0` recorded · `2` could not connect / no message in 10 s.
- Header: what, HOST, usage, knobs, exit codes, and the sentence "never
  hand-edit a fixture — regenerate it".

### 3.2 `fake-rosbridge.py --replay FIXTURE [--loop]`

Same file, same op log (the log stays the witness the suites read). New:

- On the first `subscribe`, start a replay clock. Deliver each recorded
  `publish` whose topic has a subscriber at its recorded `t`, honouring the
  subscription's `throttle_rate` the way rosbridge does (minimum gap between
  sends per topic, minimum over subscribers) — so a page asking 20 ms from a
  20-ms fixture gets the fixture's rate, and a page asking 100 ms gets 10 Hz.
- `--loop`: when the file ends, restart and **rebase sim time**: add the
  fixture's sim span (last `/clock` − first `/clock`) to every `clock` and
  `header.stamp` it replays, so the page sees monotonic sim time across loops.
- `--foreign` and `--refuse-service` keep working (the teleop suite depends on
  them); a `--replay` bridge also answers `call_service` as today.
- Never bind anything but `127.0.0.1`.

### 3.3 `RosbridgeLink` — one socket, id-routed

Refactor `RosbridgeTarget` (1392–1578) to a client of a new class rather than
the owner of the socket. Behaviour on the wire is unchanged; the suites prove it.

```js
class RosbridgeLink {
  constructor(url, sink) { this.url = url; this.sink = sink; this.ws = null;
    this.state = 'idle';                 // idle | connecting | open | error | closed
    this.subs = {}; this.calls = {}; this.seq = 0; this.onOpen = []; this.onClose = []; }
  open() { return !!this.ws && this.ws.readyState === 1; }
  connect() { … new WebSocket(this.url); onopen → state 'open', this.onOpen.forEach(f => f());
              onmessage → this.route(JSON.parse(e.data)); onerror/onclose → state, onClose.forEach … }
  send(obj) { if (this.open()) try { this.ws.send(JSON.stringify(obj)); } catch (e) {} }
  subscribe(topic, type, throttle, cb) { const id = 'kennel-sub-' + (++this.seq);
    this.subs[topic] = (this.subs[topic] || []).concat([{id, cb}]);
    this.send({op:'subscribe', id, topic, type, throttle_rate: throttle, queue_length: 1}); return id; }
  unsubscribe(topic, id) { … send({op:'unsubscribe', id, topic}) … }
  call(service, type, args, cb) { const id = 'kennel-call-' + (++this.seq); this.calls[id] = cb;
    this.send({op:'call_service', service, type, args, id}); }
  route(m) { if (m.op === 'publish') (this.subs[m.topic] || []).forEach(s => s.cb(m.msg));
    else if (m.op === 'service_response') { const cb = this.calls[m.id]; delete this.calls[m.id]; if (cb) cb(m); }
    else if (m.op === 'status' && m.level !== 'info') this.sink('bridge: ' + m.msg, m.level === 'error'); }
  close() { … }
}
```

`RosbridgeTarget` keeps its states and every message it sends, with three
changes: it takes `(link, sink)`; `connect()` registers `probe` on
`link.onOpen` **first** (before the DataSource registers — the suite's
`ops("subscribe")[0]` must be the `/quad_control_target` probe) and calls
`link.connect()`; on refusal it stops (`state = 'refused'`, no advertise, no
publish) but **does not close the link** — subscribing is harmless, and
watching a `verify` walk live is exactly what #71 will need; `leave()`,
`disconnect()` unadvertise only if `state === 'driving'` (today's guard is the
socket being open, which would now send a stray `unadvertise`). The probe's
own subscribe/unsubscribe keeps its literal `id: 'kennel-probe'`.

### 3.4 `RosbridgeDataSource`

Implements the §0 table. The one design decision that keeps every drawing
routine untouched: **the live source bins the throttled streams into the same
10 Hz sim-time samples the mock emits.** Windowed statistics are computed from
what arrives at ≤ 50 Hz (the issue's wording; full-rate `/quad_state` over JSON
would be 1.5 MB/s and is not what "throttle aggressively" means).

```js
class RosbridgeDataSource {
  constructor(link, sink) { this.link = link; this.sink = sink; this.reset(); }
  reset() { this.buf = []; this.events = []; this.counters = {earlyContacts:0, mpcOvertime:0, wbcOvertime:0, mpcFail:0, wbcFail:0};
    this.lastInc = {}; this.t = 0; this.epoch = null; this.fallen = false; this.fallText = ''; this.fallAt = undefined; this.halted = false;
    this.timer = null; this.cmd = {vx:0, vy:0, wz:0};
    this.latest = {}; this.seen = {};          // per topic: last msg, wall time of last msg
    this.bin = this.newBin(); this.simWall = [];   // (sim, wall) pairs for rtf
    this.hb = null; this.hbWall = 0; }
  start() { if (this.timer) return; this.timer = true;
    LIVE_TOPICS.forEach(s => this.link.subscribe(s.topic, s.type, s.throttle, m => this.on(s.topic, m))); }
  stop() { … unsubscribe all …; this.timer = null; }
  fresh(topic, s) { const w = this.seen[topic]; return w !== undefined && (performance.now() - w) / 1000 < (s || 1.0); }
  on(topic, m) { this.seen[topic] = performance.now(); this.latest[topic] = m;
    if (topic === '/clock') return this.tick(m.clock.sec + m.clock.nanosec / 1e9);
    if (topic === '/controller_heartbeat') return this.onHeartbeat(m);
    if (topic === '/solve_time') { const ms = m.solve_time * 1000; if (ms > this.bin.mpcMs) { this.bin.mpcMs = ms; this.bin.mpcIters = m.acados_num_iter; } if (m.acados_return !== 0) this.bin.solverFail = true; }
    if (topic === '/wbc_solve_time') { this.bin.wbcMs = Math.max(this.bin.wbcMs, m.total_time * 1000); if (!m.success) this.bin.solverFail = true; }
    if (topic === '/quad_state') this.onState(m);           // §4.3 adds the contact edge detection here
  }
  tick(sim) { if (this.epoch === null) this.epoch = sim;
    if (sim < this.t + this.epoch - 1.0) { this.epochRestart(sim); }        // sim clock went backwards: /reset_sim, a relaunch, a looped replay without rebase
    this.simWall.push([sim, performance.now() / 1000]); while (this.simWall.length > 20) this.simWall.shift();
    while (sim - this.epoch >= this.t + 0.1) this.closeBin(); }
  closeBin() { const q = this.latest['/quad_state'], c = this.latest['/quad_control_target'];
    const s = Object.assign({t: this.t}, this.bin, {
      height: q ? q.pose.pose.position.z : 0, …roll/pitch in degrees from the quaternion (the formula of check.py roll_pitch)…,
      vx: q ? q.twist.twist.linear.x : 0, vy: …, wz: q ? q.twist.twist.angular.z : 0,
      cvx: c ? c.body_x_dot : 0, cvy: c ? c.body_y_dot : 0, cwz: c ? c.hybrid_theta_dot : 0,
      planned: …, actual: q ? q.foot_contact.slice() : [false,false,false,false], miss: [false,false,false,false],   // §4
      rtf: this.rtf(), hb: this.hbAge(), c: Object.assign({}, this.counters)});
    this.buf.push(s); if (this.buf.length > 900) this.buf.splice(0, 200);
    this.t = Math.round((this.t + 0.1) * 10) / 10; this.bin = this.newBin(); this.sink(); }
  newBin() { return {mpcMs: 0, mpcIters: 0, wbcMs: 0, solverFail: false}; }
  rtf() { const a = this.simWall[0], b = this.simWall[this.simWall.length - 1]; return a && b && b[1] > a[1] ? (b[0] - a[0]) / (b[1] - a[1]) : 0; }
  hbAge() { return this.hbWall ? (performance.now() - this.hbWall) / 1000 : 9.99; }
  onHeartbeat(m) { … map num_early_contacts→earlyContacts, num_mpc_solver_overtime→mpcOvertime, num_wbc_overtime→wbcOvertime,
    num_mpc_solver_fail→mpcFail, num_wbc_solver_fail→wbcFail; for each key that increased: this.lastInc[k] = this.t and an event (§4.2 grammar) …; this.hbWall = performance.now(); }
  last() { return this.buf.length ? this.buf[this.buf.length - 1] : null; }
  advance() {} seedDemo() {} inject() {}      // live: the interventions that drive the mock are not wired here (#66, #68) -- say so in the feed
}
```

Notes the implementer needs:

- **The counters are renamed in the mock too**, to the five `ControllerInfo`
  fields the spec names: `earlyContacts, mpcOvertime, wbcOvertime, mpcFail,
  wbcFail`. The mock's `imuStale` row goes (no live source; keep its event if
  you like, not the counter); `solverFail` → `mpcFail`; `contactMiss` →
  `earlyContacts`. Sparkline labels (1847–1853) become `num_early_contacts`,
  `num_mpc_solver_overtime`, `num_wbc_overtime`, `num_mpc_solver_fail`,
  `num_wbc_solver_fail`; `health` and `detailStats` follow. No suite asserts
  the old names.
- **A DOM mirror of the totals.** Canvas text cannot be read by a suite. Append
  one strip under the sparkline canvas: `early_contacts 90 · mpc_overtime 0 ·
  wbc_overtime 142 · mpc_fail 0 · wbc_fail 104` (the live totals; the mock's in
  mock mode). Same for the status bar's `rtf`, `heartbeat`, `sim t` — already DOM.
- **Heartbeat age threshold.** The status bar tints `heartbeat` amber above
  0.2 s (2404); live heartbeats are 0.5 s apart in sim time, so the threshold
  becomes **1.5 s wall** (three missed beats), and the value shown is the age of
  the last one.
- **Health strip rules, live** (`health`, 2144–2166, reading the composite
  sample): gait → `fresh('/gait_state', 0.5)` green else `off`; MPC → red if
  `mpcMs ≥ 10` or `solverFail`, amber above 7, green; sub shows `iters` and
  `/solve_time`; WBC → red if `wbcMs ≥ 2` or a `success:false` in the bin,
  amber above 1.5; swing/contact → tint from `recent('earlyContacts')`;
  adaptation → `off` while `num_model_updates` stays 0 (it does at the pin,
  `use_model_adaptation` off), `converged` when it moves. Flash on the
  increments the heartbeat reports, as the mock does.
- **State plots**: the three existing plots keep their series; the velocity
  plot's dashed `cmd vx` is now `/quad_control_target` — zero when nobody
  publishes, and the label says so. Torques: `joint_state.effort[12]` is in
  `/quad_state`; add a fourth plot only if the pane's height comfortably holds
  it (it does not at the default row height — leave it to the detail drawer:
  clicking WBC shows `effort` max/mean, DOM).
- `epochRestart(sim)` clears `buf`, `simWall`, resets `t` and `epoch`, and emits
  the reserved `reset` event (§4.2) — a sim clock that goes backwards is a
  relaunch, a `/reset_sim` (#66) or a replay loop that did not rebase.
- **Never `sleep`.** No `setInterval` drives the live source; `/clock` does,
  which makes every window a sim-time window for free (verify.md §1.1).

### 3.5 The switch

`teleopToggle()` (2427) becomes `linkToggle()`:

```js
linkToggle() {
  if (this.link && (this.link.state === 'connecting' || this.link.state === 'open')) { this.goMock('disconnected'); return; }
  const url = (this.state.bridgeUrl || '').trim();
  if (!url) { this.setState({teleopHint: 'no bridge URL — start one with  kennel-demo.sh teleop, or type it here if you know it'}); return; }
  this.link = new RosbridgeLink(url, (msg, err) => this.say(msg, err));
  this.tp = new RosbridgeTarget(this.link, () => this.setState(s => ({tick: s.tick + 1})));   // registers its probe on onOpen FIRST
  this.tp.z = …; this.tp.maxv = …;
  const live = new RosbridgeDataSource(this.link, () => this.setState(s => ({tick: s.tick + 1})));
  this.link.onOpen.push(() => { this.mock.stop(); this.ds = live; live.start();
    live.events.push({t: 0, sev: 'info', text: narrate('mode', {source: 'live', url})}); this.setState({detail: null, pinFall: false}); });
  this.link.onClose.push(() => this.goMock('the bridge closed the connection'));
  this.link.connect();
}
goMock(why) { if (this.ds !== this.mock) { this.ds.stop(); this.ds = this.mock; this.mock.start();
  this.mock.events.push({t: this.mock.t, sev: 'info', text: narrate('mode', {source: 'mock', why})}); }
  if (this.tp) { this.tp.disconnect(); this.tp = null; }  if (this.link) { this.link.close(); this.link = null; } this.setState(…); }
```

`componentDidMount` keeps `this.mock = new MockDataSource(...)` and sets
`this.ds = this.mock`. The status bar's `onToggleConn` (2413): under a kennel
server with a bridge URL it calls `linkToggle()` and its label reads
`connect bridge` / `disconnect bridge`; otherwise it keeps today's mock
start/stop with `connect` / `disconnect`. The Interventions button (already
`connect bridge`) calls the same `linkToggle()`. "Said out loud": the `mode`
event in the feed and the `mode` status item. The mock keeps its position while
live and resumes on disconnect — "the mock demo still plays untouched".

### 3.6 `verify-dashboard.sh`, extended

The bridge fixture becomes `fake-rosbridge.py --replay fixtures/healthy.jsonl.gz --loop`
plus the `--foreign` twin (unchanged). New groups:

| Group | Asserts |
|---|---|
| 7 · going live | click `connect bridge` → exactly one WebSocket; the first `subscribe` on the wire is `/quad_control_target` (the teleop probe); then subscribes for every `LIVE_TOPICS` entry; `/quad_state`'s `throttle_rate ≥ 17` (≤ 60 Hz) and `queue_length: 1`; `mode · live` in the status bar within 5 s; the feed carries the `mode` entry |
| 8 · panels leave their empty states | health strip, counters, state plots, status bar `rtf`/`heartbeat`/`sim t`: no empty-state text, canvases present, `rtf` within ±0.05 of the fixture's `/clock`-vs-`t` ratio, `sim t` advancing; the counters strip equals the fixture's **last** heartbeat values (known deltas); the `pose` strip's `z` within 5 mm of the fixture's median z; the timeline and feed show #63's states (in step 5's commit: their empty states naming `kennel-demo.sh run`) |
| 9 · back to mock | click the status bar's `disconnect bridge` → socket closed, `mode · mock (scripted demo)`, the mock's `sim t` resumes from where it paused (not from 0), the mock's own FALL still arrives at ~32.4 s of mock time — the demo is untouched |
| 10 · never auto | reload: zero sockets, mode mock; the foreign bridge: teleop refused **and** the panels still go live (the link stays open) |

Groups 1–6 stay as they were.

### 3.7 Record

`dashboard.md` §2: the contract table of §0 (that is the `DataSource` contract
of `design.md` §4, now written down), the binning decision, the topic→sample
map, the health rules, the switch, the fixture provenance (`run.json`, date,
bridge, the guest CPU numbers), the verification table, limits (interventions
not wired live: #66, #68; one operator). Rewrite `teleop.md` §6 (no longer
true for these panels — say which are live now and which wait for #63) and
§10's first bullet; `stack/bridge.md` §9 last bullet ("No
`RosbridgeDataSource`") → done, pointer to `dashboard.md`.

---

## 4. Step 6 — #63, `RosbridgeDataSource` part 2

### 4.1 The fall fixture — `fixtures/fall.jsonl.gz`

Recorded honestly with the same recorder: a healthy trot, then at ~12 s
**E-STOP mid-stride** from the guest —
`ros2 service call /set_emergency_damping_mode std_srvs/srv/Trigger` — and
~10 s more. Chosen over obstacle terrain: terrain's fall is a tip-over that
takes a variable number of metres and does not repeat run to run
(`transfer.md` §6.3); the damping collapse is deterministic, is one of the two
falls `verify.md` §4.1 was calibrated on (z 0.311 → 0.075 m, `bridge.md` §8
row `06-estop.txt`), and takes one command. **Say which in the record**, and
say that this fixture exercises the z rule while today's tumble (§0) is the
evidence for the tilt rule.

### 4.2 The event-feed grammar — one function, both sources

```js
// s007 step 6: "same event-feed grammar". Mock and live both call this; nothing else builds an event text.
function narrate(kind, d) {
  switch (kind) {
    case 'deadline':   return d.stage + ' exceeded ' + d.deadline + ' ms deadline (' + d.ms.toFixed(1) + ' ms' + (d.iters ? ', ' + d.iters + ' iters' : '') + ') — ' + (d.stage === 'MPC' ? 'previous solution held' : 'torque command late');
    case 'solverFail': return d.stage + ' solver failed (' + d.detail + ') — falling back to the last feasible plan';
    case 'contact':    return (d.ms < 0 ? 'Early' : 'Late') + ' contact ' + d.leg + ' ' + (d.ms < 0 ? '−' : '+') + Math.abs(d.ms).toFixed(0) + ' ms vs planned touchdown';
    case 'fall':       return 'FALL: ' + d.trigger + ' — ' + d.values + ' — controller latched to damping mode';
    case 'mode':       return 'data source: ' + d.source + (d.url ? ' (' + d.url + ')' : '') + (d.why ? ' — ' + d.why : '');
    case 'reset':      return 'sim clock restarted at ' + d.sim.toFixed(1) + ' s — windows cleared';           // #66
    case 'disturb':    return 'Disturbance: ' + d.mag.toFixed(0) + ' N for ' + d.duration.toFixed(2) + ' s (' + d.fx + ', ' + d.fy + ', ' + d.fz + ')';   // #68
    case 'stale':      return d.topic + ' stale for ' + d.s.toFixed(2) + ' s';
  }
}
```

The mock's `emit(...)` calls (1613–1660) are rewritten to `narrate`; its texts
change slightly (the suite asserts the *grammar*, not the old literals — no
suite asserted them). Live: `deadline` fires on a heartbeat increment of
`mpcOvertime`/`wbcOvertime`, carrying the max solve time seen since the last
heartbeat (the counter is the authoritative count at ≤ 50 Hz sampling; the
sample is the best available measurement); `solverFail` on `mpcFail`/`wbcFail`
increments with `acados_return`/`success` detail; `contact` from §4.3; `fall`
from §4.4.

### 4.3 The timeline

Planned stance for leg `i` from the latest `/gait_state`: `contact[i]`
directly (the sequencer publishes it), with `period`, `duty_factor[i]`,
`phase_offset[i]` and `phase[i]` kept on the sample for the drawer. Actual from
`/quad_state.foot_contact[i]`; force from `/contact_state.ground_contact_force[i]`
(four scalars) drawn as bar height under the actual band. Touchdown timing in
`on('/quad_state')`: for each leg keep the sim time of the last planned
false→true edge (from `/gait_state`) and detect the actual false→true edge;
`offsetMs = (tActual − tPlanned) × 1000`; when `|offsetMs| > 25` set `miss[i]`
on the sample and emit `contact`. At 20-ms samples the offset is quantised to
the sample period — say so in the record; the legend's "> 25 ms" stays.
`drawTimeline` (1812–1842) is unchanged except for the force bars; the mock
gains `forces: [0,0,0,0]`.

### 4.4 The fall rule — `verify.md` §4's, as constants named after the knobs

```js
// stack/verify/kennel-verify.sh's knobs, same names, same defaults (verify.md §4):
const Z_MIN = 0.20, Z_MAX = 0.45;             // median body height, m
const TILT_MAX_RAD = 0.5;                       // roll or pitch past this is "over"
const FALL_WINDOW_S = 2.0;                      // sim seconds of samples the rule looks at
// verify's FALL_TOLERANCE is 2 % of a 15-s window = 0.3 s of sustained tilt; over a 2-s
// window the same 0.3 s is 15 %. The duration is what is preserved, not the percentage.
const FALL_TILT_FRACTION = 0.15;
function fallRule(win) {           // win: the last FALL_WINDOW_S of /quad_state-derived samples {z, tiltRad, belly}
  if (win.length < 10) return null;
  if (win.some(s => s.belly)) return {trigger: 'belly_contact', values: 'belly_contact=true'};
  const zs = win.map(s => s.z).sort((a, b) => a - b), zMed = zs[zs.length >> 1];
  if (zMed < Z_MIN || zMed > Z_MAX) return {trigger: 'body height', values: 'z median ' + zMed.toFixed(3) + ' m outside [' + Z_MIN + ', ' + Z_MAX + ']'};
  const f = win.filter(s => s.tiltRad > TILT_MAX_RAD).length / win.length;
  if (f > FALL_TILT_FRACTION) return {trigger: 'attitude', values: 'tilt over ' + TILT_MAX_RAD + ' rad in ' + (100 * f).toFixed(0) + '% of ' + FALL_WINDOW_S + ' s'};
  return null;
}
```

Evaluated on every `/quad_state` arrival over a ring of the last 2 sim-seconds
(kept separately from `buf`, at the arrival rate). First hit: `fallen = true`,
`fallAt = t`, `fallText = trigger — values`, the `fall` event, and — unlike the
mock — the stream **keeps flowing** (`halted` stays false; the banner and the
pin stay until *unpin* or a `reset` event). Health blocks tint red while
`fallen`, as today.

### 4.5 `verify-dashboard.sh`, groups 11–13

| Group | Asserts |
|---|---|
| 11 · timeline live | on the healthy fixture the four rows populate (canvas present, the drawer for Gait Sequencer shows `period 0.5 · duty 0.6 · offsets 0/0.5/0.5/0` in DOM); the feed carries ≥ 1 `contact` entry with a leg and an offset iff the suite's own offline pass over the fixture finds an edge pair > 25 ms apart (it re-implements the edge detection in Python — an independent witness) |
| 12 · the fall | replay `fall.jsonl.gz` (no loop): the banner appears; the `fall` event's `t` is within ±0.5 s of the sim time at which the suite's Python `fallRule` first fires on the fixture; the feed is pinned to `[fallAt − 5, fallAt]`; the pinned text contains, in order, any `deadline`/`solverFail` entries, the `contact` entries, then `FALL:` with the trigger and values (s003 step 7); the healthy fixture never raises it over two full loops |
| 13 · grammar parity | in mock mode, collect the feed after 35 s of mock time (use `step 1 s` 35 times — no waiting); every line matches one of `narrate`'s patterns; the mock's own FALL still arrives at 32.4 s with the pinned window |

### 4.6 Record and evidence

`dashboard.md` §3: the rule with the derivation of `FALL_TILT_FRACTION`, the
two real falls it was checked against (the E-STOP fixture; today's tumble from
§0 as the tilt case), the timeline's quantisation, the grammar table. Evidence:
the fixture provenance, the live post-mortem text from §6.6 verbatim, the
render with the banner.

---

## 5. Step 7 — #64, real run records

### 5.1 `kennel-verify.sh` writes `report.json`

Two small additions inside the existing file, no new file to stage:

- **`check.py` writes `metrics.json`.** At the end of `phase_observe()` and
  `phase_walk()` (before `node.stop()`, 721), dump the numbers it already holds:
  `state_hz, hb_hz, realtime_rate` (observe); `d_mpc_fail, d_wbc_fail,
  d_overtime, d_early_contacts, n_heartbeats, hb_first{…}, hb_last{…},
  vx_mean, dx, sim_window, buckets_ok, z_median, z_p01, z_min, z_max, z_p2p,
  tilt_max, tilt_over_frac, belly_hits, n_samples, gait{period, duty_factor,
  phase_offset, gait_sequencer}` (walk) — merged into one JSON object at
  `$WORK/metrics.json` (`json.dump` of a dict, updating an existing file).
- **The verdict block assembles `report.json`** (after 836, with `python3` —
  it is in the container, `check.py` just ran there):

```json
{ "schema": "kennel-verify/1",
  "verdict": "completed | fell | solver-failed | unhealthy",
  "exit": 0, "pass": 10, "fail": 0,
  "finished_at": "<UTC ISO>", "run": "<KENNEL_RUN or null>", "pin": "<KENNEL_PIN or null>",
  "expect_solver": "…", "active_solver": "…", "gait": "WALKING_TROT",
  "windows_sim_s": {"observe": 5, "settle": 5, "trot": 15},
  "knobs": { every PASSTHROUGH_ENV threshold in effect },
  "checks": [ {"n": 1, "name": "node-graph", "status": "PASS", "observable": "…", "measured": "…", "required": "…"}, … INFO rows with "n": null … ],
  "metrics": { …metrics.json… },
  "headline": {"early_contacts": 47, "mpc_overtime": 0, "wbc_overtime": 0, "mpc_fail": 0, "wbc_fail": 0} }
```

Verdict, in this order: check 9 `FAIL` → `fell`; `d_mpc_fail + d_wbc_fail > 0`
→ `solver-failed`; exit 0 → `completed`; else `unhealthy`. On exit 2 nothing is
written (the driver then files nothing). `KENNEL_RUN` and `KENNEL_PIN` join
`PASSTHROUGH_ENV` (63); the driver passes both. `headline` is check 7's deltas
— the Runs table's counters, by name. `report.txt` is unchanged.

### 5.2 `kennel-demo.sh verify` files the report

In `do_verify` (1178–1206): after the `ssh … kennel-verify.sh …` line capture
`rc=$?`; resolve the run folder —

```bash
applied_run_dir() {   # the folder `verify` reports into: this process's, else the guest's marker
    if [ -n "$APPLIED_RUN" ]; then echo "$APPLIED_RUN"; return 0; fi
    local name; name="$(ssh "${SSH_OPTS[@]}" "$TARGET" 'cat ~/kennel-staging/current-run 2>/dev/null')"
    [ -n "$name" ] && [ -d "$OUT/$name" ] && { echo "$OUT/$name"; return 0; }
    return 1
}
```

— then, unless `rc = 2`: `scp` the guest's `/tmp/kennel-verify/report.json` to
`<run>/verify.json` and `report.txt` to `<run>/verify.txt`, overwriting a
previous verify of the same run (the newest verdict is the record; the previous
file is not evidence of anything the folder does not already say), and `say
"verify report    <run>/verify.json (verdict <X>)"`. When no folder resolves,
`warn` and leave the report where it is. `run.json` is never opened for
writing. Pass `KENNEL_RUN=$(basename …)` and `KENNEL_PIN=$PIN` on the ssh line.
Header: the `verify` line gains "and files the report in the run folder".

### 5.3 `serve.py`

- `list_runs` (227): per run add `"run_id"` and `"choices"` (parsed from
  `run.json`; `null` if it does not parse) and `"verify"` — a **summary
  without a top-level `run` key** (`kennel-demo.sh status` seds `"run":` lines
  out of this document): `{verdict, exit, pass, fail, finished_at,
  active_solver, headline, checks:[{n, name, status}]}`, or `null`. `files`
  gains `verify.json`/`verify.txt` when present (`complete` still means the
  four export artifacts).
- `GET /api/runs/<stamp>/<file>`: `<stamp>` must match `RUN_DIR_RE`, `<file>`
  must be one of `ARTIFACT_NAMES + ("verify.json", "verify.txt")`; anything
  else `404`; served with `Content-Type` `application/json` or `text/plain`,
  `Cache-Control: no-store`; read-only; `localhost` as everything else. The
  path is built from the two validated segments, never from the request.

### 5.4 The Runs view, live

When `state.kennel` is non-null the table is the server's list: fetch
`/api/runs` on mount, on entering the Runs view, after a successful send, and
from a `refresh` control appended after `diffHint`. Rows (columns unchanged,
`cmp run map pipeline dur verdict counters`, then `load`; append a `verify`
column after `counters` when the row has one, linking `/api/runs/<stamp>/verify.txt`):

- `run` = the stamp (`run-20260906T212107Z`), not the `RUN-2026-0724-…` id —
  export.md §3 calls that prototype furniture; it stays in `run.json`.
- `map`, `pipeline` from `choices` (`world_urdf` → the map name; `mpc_solver`
  → the label from `BLOCKS`); `dur` = `verify.metrics.sim_window` sim-s or `—`.
- `verdict` = `verify.verdict` badge, or `staged` — the existing colours,
  plus `unhealthy` amber and `solver-failed` amber.
- `counters` = `headline` as `early 47 · mpc_over 0 · wbc_over 0 · fail 0`, or
  `not yet run`.
- `load` → `cfg` rebuilt from `choices` (a `cfgFromChoices()` beside
  `cfgFromYaml()`: map from `world_urdf`, rate, `publish_quad_state`, the three
  MPC keys through `normalizeCfg`) → Compose.

Diff on two selected rows: the differing keys of the two `choices` objects,
and when `mpc_solver` differs also the two dependent keys with an
applicability note from `PARAMS.mpc[].appliesTo` — `applies to A only / B
only / both / neither` (`composer-scope.md` §2's 2×2). Then a second block,
"YAML pair", a positional line diff of the two `mit_controller_sim_go2.yaml`
and the two `simulator_params_go2.yaml` fetched from `/api/runs/<stamp>/…`
(the files are deterministic and equal in line count — generate.md §4 group 5 —
so index-aligned comparison is exact; if lengths differ, say so instead of
guessing). A `verify` row appended to the diff when both have one: `verdict`
A vs B and each headline counter.

Seeded runs: **kept only when `state.kennel` is null**, each row tagged `demo`
in the `run` column and the sub-header reading `5 demo manifests · seeded, not
real runs`; in kennel mode they are absent. In-session `staged` rows from
`generate run ↓` are kept only in mock mode too — in kennel mode a downloaded
run appears once `kennel-demo.sh run` has unpacked it into `~/kennel-runs`
(then it is on the server as `staged`).

### 5.5 `verify-runs.sh` + `verify-runs.py`

Both servers, one Chrome, a temp `--out`. Groups:

| Group | Asserts |
|---|---|
| 1 · three real runs | drive the console to **send** three runs: OSQP/flat, HPIPM-partial/flat, OSQP/terrain (the `verify-send.py` helpers do this); copy `fixtures/verify-completed-osqp.json`, `verify-completed-hpipm.json`, `verify-fell.json` (real reports captured in §6.7) into the first, second and third folders as `verify.json` |
| 2 · the API | `/api/runs` lists three with `choices` and `verify` summaries and **no** nested `run` key; `/api/runs/<stamp>/verify.json` serves the file; `/api/runs/../x`, `/api/runs/<stamp>/../serve.py` and `/api/runs/<stamp>/other.txt` → `404`, nothing else in the response |
| 3 · the table | rows in server order with badges `completed`, `completed`, `fell`; counters equal each `headline`; a fourth run sent during the test shows `staged` after `refresh`; no `RUN-2026-07` text anywhere |
| 4 · the diff | select runs 1 and 2 → rows: `mpc_solver` (differs), `mpc_hpipm_mode` (`B only`), `mpc_condensed_size` (`both`), nothing else; the YAML block shows exactly the `mpc_solver` line and its note line for the controller file and nothing for the simulator file; select 1 and 3 → `world_urdf` only |
| 5 · plain `http.server` | the Runs view shows the five seeded rows **tagged `demo`**, the sub-header says seeded, no fetch of `/api/runs` is attempted more than once (the probe's 404), no errors |
| 6 · network | zero non-localhost requests |

### 5.6 Record

`kennel_console/runs.md`; `stack/verify.md` §8 "The report file" with the
schema of §5.1 and the verdict mapping; `demo/runbook.md` §3's `verify` row
gains "and files `verify.json` + `verify.txt` in the applied run's folder";
§5 a row for "the Runs view says `staged` after a green run" → the folder had
no `verify.json` (verify ran standalone with no applied run on this host).

---

## 6. Live-guest protocol — one session, in this order

`EV=kennel_console/dashboard/evidence` and `EVR=kennel_console/runs/evidence`;
every transcript opens with `=== what ===` and `date -u +%FT%TZ`, captured with
`2>&1 | tee`. `G` is the guest ssh (`SSH_KEY`, `yuuser24@192.168.122.32`).
Do the negative controls **before editing** the files they concern.

| # | Do | File | Must show |
|---|---|---|---|
| 0 | `kennel-demo.sh status`; in the browser, the Dashboard as it is today (fictional commands, FALL while nothing runs) — screenshot with `dashboard-shot.sh` once it exists, or by hand | `00-before.png`, `00-status.txt` | the negative control for #61 |
| 1 | compose by hand in the console: OSQP, flat plane, **rate 0.5** → *send*; `kennel-demo.sh run` | `01-run-rate05.txt` | `pass=10 fail=0`; with §5.2 in place, `verify report  …/verify.json (verdict completed)` — if step 7 is not yet implemented when you get here, come back for the runs of row 8 |
| 2 | `teleop`; `record-fixture.py --seconds 30 --run <that run>` while `walk` starts 5 s in and `walk stop` ends it at ~25 s | `fixtures/healthy.jsonl.gz`, `.run.json`, `02-record-healthy.txt` | ~1 500 `/quad_state` lines, the heartbeat counters moving, the gait signature |
| 3 | `walk`; `record-fixture.py --seconds 25`; at ~12 s on the guest `sudo docker exec dfki_quad bash -c 'source /tmp/p21-env.sh; ros2 service call /set_emergency_damping_mode std_srvs/srv/Trigger'`; `walk stop` | `fixtures/fall.jsonl.gz`, `03-record-fall.txt` | z falls to ~0.075 m within a second of the call; the suite's offline `fallRule` fires at a `t` you note in the record |
| 4 | `kennel-demo.sh launch` (relaunch after the damping latch); `teleop`; open the console, Dashboard, **connect bridge**; 60 s live; `dashboard-shot.sh $EV/04-live.png`; on the guest `top -b -c -d 5 -n 3 -p "$(pgrep -d, -f 'rosbridge_websocket\|rosapi_node')"`; on the host `top -b -d 5 -n 3 -p "$(pgrep -d, -f 'type=renderer' \| head -c 40)"` | `04-live.png`, `04-cpu.txt`, `04-live-60s.txt` (the status bar values copied every 10 s) | `mode · live`, rtf ≈ 0.50, heartbeat age < 1.5 s, counters equal to `ros2 topic echo --once /controller_heartbeat` on the guest at the same moment |
| 5 | `walk` with the console still connected (the probe refuses teleop — expected — the panels stay live); watch the timeline populate; `dashboard-shot.sh $EV/05-timeline.png` | `05-timeline.png`, `05-feed.txt` (the feed text via CDP `__txt()`) | four rows, ≥ 1 highlighted mismatch, `contact` lines with leg and offset |
| 6 | `walk stop`; `teleop` again if the trot-hold refusal closed anything; drive from the joystick, then press **E-STOP** in the console | `06-fall-live.png`, `06-postmortem.txt` | the banner within a second; the pinned window's text in order — deadline/solver entries if any, contacts, `FALL: body height — z median 0.0xx m …` |
| 7 | `teleop stop`; `kennel-demo.sh run` on the rate-0.5 run again (clean relaunch) → green; compose HPIPM-partial/flat → *send* → `run` → green; compose OSQP/**terrain** → *send* → `run` (verify fails: check 8, maybe 9; try twice; if neither run tips, during the second attempt's `measuring 15 sim-s of commanded trot` line call the damping service from a second guest shell — and **record which** produced the `fell`) | `EVR/01-run-osqp.txt`, `02-run-hpipm.txt`, `03-run-terrain.txt`; copy the three `verify.json` into `kennel_console/fixtures/verify-*.json` | three folders in `~/kennel-runs` with `verify.json`; verdicts `completed`, `completed`, `fell` |
| 8 | Runs view in the browser; select OSQP and HPIPM; `dashboard-shot.sh --view runs $EVR/04-runs.png` | `04-runs.png`, `04-api-runs.json` (`curl localhost:8000/api/runs`) | the three badges and counters, the one-key diff with its two dependent rows |
| 9 | `kennel-demo.sh down`; the eight suites on the host (§8.2) | `EV/09-suites.txt` | eight greens |

Row 7 is where #64's acceptance is won or lost; if terrain refuses to fall
twice, the E-STOP-during-verify variant is a real fall by the recipe's own
rule (check 9 fails on the collapsed body) and the record says so plainly.

### 6.1 `dashboard-shot.sh`

HOST tool beside the suites, modelled on `p21-meshcat-shot.sh` (same Chrome
flags, same `cdp.py` import, same preconditions checked): opens the served
console, clicks a view (`--view dashboard|runs`), optionally clicks
`connect bridge` (`--connect`), waits — bounded, polling — for the iframe's
`contentWindow` document `readyState === 'complete'` (readable: same origin?
no — cross-origin; poll instead for the `pose` strip to change twice, which
proves both the page and the stream are live) and for `mode · live` when
`--connect`, then `Page.captureScreenshot` to the path given. Exit `0` written
· `2` preconditions · `3` the wait timed out (names what never happened).

---

## 7. Records and doc touches

| File | Change |
|---|---|
| `kennel_console/dashboard.md` | new: §0 why it is inside the design (the seam; `prompts.txt` View 2), §1 #61, §2 #62, §3 #63, §4 verification (the groups of §2.4/§3.6/§4.5 in one table), §5 evidence, §6 limits, §7 what this feeds (#65, #66, #68, #71) |
| `kennel_console/runs.md` | new: #64 — the report's path from container to folder, the schema pointer, the view, the diff rule, the seeded-runs decision, verification, evidence, limits (still not the Run Manifests foundation; `run_id` furniture) |
| `kennel_console/teleop.md` | §6 rewritten (which panels are live now), §10 first and fourth bullets resolved with pointers |
| `stack/bridge.md` | §9 last bullet → done, pointer to `dashboard.md` |
| `stack/verify.md` | §8 "The report file": schema, verdict mapping, where the driver files it |
| `demo/runbook.md` | §3 `verify` row; §5: the FALL row rewritten (mock mode — connect the bridge), the new 3D-pane row, the `staged` row |
| `docs/README.md` | Console section: `dashboard.md`, `runs.md` |
| `CLAUDE.md` | repo map: "eight `verify-*.sh` suites (… dashboard, runs)"; one new rule if the protocol earns one (see §9.8) |
| `plan/next-goals.md` header / `plan/reliability.md` | nothing — historical records |

---

## 8. The PR

### 8.1 Body skeleton (house style: PRs #53, #59, #79)

```
feat(console): the console goes live — the real viewer in the 3D pane, every panel on the running stack, real run records

Closes #61, closes #62, closes #63, closes #64. Plan: plan/console-live.md.
Four issues in one PR at the maintainer's request: they are steps 4–7 of the
milestone, 5–7 share one fixture and one suite, and 7's `fell` needs 6 proven live.

## What is here            — table: file → what changed (console, serve.py, fake-rosbridge.py, record-fixture.py, kennel-verify.sh, kennel-demo.sh, the two suites, the two records)
## The DataSource contract — the §0 table, now written in dashboard.md §2, and the sentence "33 member references, none changed"
## Measured on the live guest — rtf, heartbeat age, bridge CPU %, renderer CPU % at 0.5×; fixture sizes; the fall's detection latency; the three verdicts
## Corrections to the plan, from measurement — only if there were any; say "none" otherwise
## Verification            — §8.2 with outputs; the suite counts
## Bypasses                — none expected; the one wait that is not an observation if any survives (say where)
## Decisions               — §9, one line each, with where each is recorded
## Records                 — dashboard.md, runs.md; the touches of §7
```

### 8.2 Verification list — every line with its output in the PR

```bash
bash -n demo/tools/kennel-demo.sh stack/verify/kennel-verify.sh kennel_console/*.sh
python3 -m py_compile kennel_console/*.py
for s in serve scope generate export send teleop dashboard runs; do ./kennel_console/verify-$s.sh; echo "verify-$s exit=$?"; done   # eight greens; the first six unmodified: git diff --stat main -- kennel_console/verify-{serve,scope,generate,export,send,teleop}.* prints nothing
KENNEL_SERVE_CMD='python3 kennel_console/serve.py --port PORT' ./kennel_console/verify-serve.sh    # the offline contract on serve.py, as send.md §4 did
grep -oE 'kennel-demo\.sh [a-z]+|ros2 launch [^<"]+' "kennel_console/Kennel Console.dc.html" | sort -u     # ⊆ the verbs of `kennel-demo.sh help` ∪ the three COMMAND_BLOCKS launches
grep -c 'kennel_viz\|kennel_control\|kennel_estimation\|kennel_sim\|/odom\|/imu/data\|/cmd_vel\|/rosout\|/gait/plan\|/mpc/solution\|/pipeline/diagnostics' "kennel_console/Kennel Console.dc.html"   # 0
grep -n 'new WebSocket' "kennel_console/Kennel Console.dc.html"          # exactly one, inside RosbridgeLink.connect
grep -n 'sleep' kennel_console/verify-dashboard.sh kennel_console/verify-runs.sh kennel_console/dashboard-shot.sh   # only poll intervals and the documented boot settle the other suites use
python3 -c "import json,gzip;[json.loads(l) for l in gzip.open('kennel_console/fixtures/healthy.jsonl.gz','rt')]" && echo fixture parses
python3 -c "import json;d=json.load(open('$HOME/kennel-runs/<stamp>/verify.json'));print(d['schema'],d['verdict'],d['headline'])"
git status --porcelain                                                   # empty
```

### 8.3 Acceptance, all four

| Issue | Criterion | Proof |
|---|---|---|
| #61 | after `run`, the pane shows the robot inside the page; empty states name only real verbs; `mode ·` label present; `verify-dashboard.sh` groups 1–6 green with no VM; the six suites green and unmodified; plain `http.server` has no iframe and no new control | `04-live.png`, `dashboard-render.png`, `09-suites.txt`, the audit grep |
| #62 | `run` → `teleop` → *connect bridge*: `mode · live`, the strip, counters and plots move with the robot; disconnect → mock, said in the feed; groups 7–10 green; the fixture and `--replay` committed with provenance | `04-*.txt`, `04-cpu.txt`, `02-record-healthy.txt`, `dashboard.md` §2 |
| #63 | live, a real fall raises the banner with a readable, ordered post-mortem; healthy runs never do; the timeline highlights mismatches with offsets; groups 11–13 green | `05-timeline.png`, `06-fall-live.png`, `06-postmortem.txt`, `03-record-fall.txt` |
| #64 | two by-hand runs (OSQP, HPIPM) → real verdicts and counters in the Runs view and a one-key diff; a fell run shows `fell`; `verify.json` beside an untouched `run.json`; `verify-runs.sh` green | `EVR/01–04`, `runs.md`, `git diff` shows no change to any `run.json` |

---

## 9. Decisions this plan makes that the issues did not

Stated so the implementer knows what is the maintainer's text and what is this
plan's call — revert the call, not the issue, if it turns out wrong.

1. **The live source bins to the mock's 10 Hz sim-time samples** (§3.4). The
   alternative — feeding ≤ 50 Hz samples straight into `buf` — would have
   touched every drawing routine's assumptions (bar width, the 10-sample
   sparkline delta, the 900-sample ring) and broken s007's "same panels" claim
   in the code rather than in the data.
2. **Windowed statistics come from the throttled stream, not from full rate.**
   The issue says so; the spec's "keep full-rate for statistics" would cost
   1.5 MB/s of JSON for `/quad_state` alone. Recorded as a limit with the
   retirement path (a bridge-side aggregator).
3. **One `RosbridgeLink`; teleop's refusal no longer closes the socket** (§3.3).
   Watching a `verify`/`walk` live while not driving is what #71 needs, and the
   teleop suite asserts bytes, not socket closure.
4. **The status bar's button becomes the DataSource switch in kennel mode and
   stays the mock's start/stop otherwise** (§3.5). Two labels, one mechanism,
   feature-detected exactly like send and teleop.
5. **`verify-dashboard.sh` frames a localhost stand-in for Meshcat and reads its
   access log** (§2.4), never the guest and never the attribute alone.
6. **The mock's counters are renamed to the five `ControllerInfo` fields and
   `imu_stale` goes** (§3.4). The spec names those five; a row with no live
   source would have been a permanent mock-only artefact.
7. **The fall fixture is an E-STOP mid-trot, not obstacle terrain** (§4.1);
   the tilt case is covered by today's measured tumble. The `fell` run record
   for #64 tries terrain first and falls back to a damping call during the trot
   window — with the record saying which.
8. **`FALL_TILT_FRACTION = 0.15` over a 2-s window preserves verify's 0.3 s of
   sustained tilt, not its 2 %** (§4.4). If the protocol shows false positives
   on a healthy trot, widen the window before touching the fraction, and add
   the rule to `CLAUDE.md` only if it bit.
9. **Seeded runs survive only in mock mode, tagged `demo`** (§5.4) — because
   `verify-scope.py:155` asserts them under plain `http.server`, and because
   Devon's demo is the mock.
10. **`/api/runs` embeds a verify *summary* with no `run` key** (§5.3), so the
    driver's `status` keeps working unmodified.
11. **`check.py` writes `metrics.json` and the bash stage assembles `report.json`**
    (§5.1), rather than regex-parsing `measured` strings on the host: the numbers
    exist as floats in exactly one place.
12. **The Runs table shows the stamp, not `run_id`** (§5.4); `run.json` and the
    export/send suites are untouched.
13. **The Compose blocks' topic labels are corrected in the same pass** (§2.2).
    Not in #61's list, but the spec's "label the source topic" applies to the
    pipeline diagram the Dashboard reuses, and no suite asserts them.

## 10. Don'ts

- Don't open a WebSocket on load, on `/api/health`, or on a URL appearing —
  only on a click. Group 10 and the teleop suite both assert it.
- Don't `sleep` to wait; `/clock` is the tick, `performance.now()` the wall
  reference. In the suites, poll the op log or the DOM inside a bounded loop.
- Don't reorder anything in the console; don't add an element whose exact text
  duplicates a label the suites click, ahead of the existing one.
- Don't put a literal URL in `src=`/`href=` — `verify-serve.sh` step 2 greps for
  it; bind it.
- Don't modify the six existing suites, `run.json`'s emitter, or
  `kennel-verify.sh`'s checks and thresholds — only add the report.
- Don't hand-edit a fixture; don't commit one without its `.run.json` and the
  metadata line.
- Don't fetch anything from the guest inside a suite — the fixture, the fake
  Meshcat and the replay bridge are the whole far end.
- Don't relaunch the stack more than §6 needs; each `run` is ~5 minutes, and the
  rate-0.5 run is the one every #62 number is measured on.
- Don't rewrite history in `teleop.md` §6/§10 or `bridge.md` §9: say what
  changed and point forward, leave the finding as found.
