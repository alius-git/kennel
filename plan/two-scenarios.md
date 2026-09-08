# Kennel — Plan H: the two scenarios (#68 · #69 · #70 · #71), one PR

Steps 11–14 of milestone [*Finish the system*](https://github.com/alius-git/kennel/milestone/2),
written like plans A–G (`next-goals.md`, `teleop-joystick.md`, `reliability.md`,
`console-live.md`, `teleop-hardened.md`) so an agent can implement them on one
branch without re-deriving the repo. Everything in §0 was checked on
**2026-09-08** with the commands shown; the live probes' numbers are quoted
where they decide something, and they decide a lot this time.

| Step | Issue | One line |
|---|---|---|
| 11 | [#68](https://github.com/alius-git/kennel/issues/68) | the disturbance path: a `disturbances` toggle composes **block 4** (`ros2 run simulator sim_disturber`), the launcher starts and waits for it, `KENNEL_EXPECT_DISTURBER=1` tolerates its node, `k13-stop.sh` reaps it **by name**, and the console's `inject` calls `/disturb_simulation` over the bridge — never awaited |
| 12 | [#69](https://github.com/alius-git/kennel/issues/69) | `kennel-demo.sh scenario disturb` — s004 as a verb: velocity → moderate push (recovers) → severe push (falls, verdict `fell`) → reset (standing, record kept), with the container's process set captured and **identical** around every step |
| 13 | [#70](https://github.com/alius-git/kennel/issues/70) | `k14-sweep.sh` measures the MPC solve margin across the MVP knobs — **§0 already shows it cannot be degraded by composition on this guest** — and ships `KENNEL_PRESET=stress` as the red composition (obstacle terrain), with the negative result recorded in `stack/stress.md` |
| 14 | [#71](https://github.com/alius-git/kennel/issues/71) | `kennel-demo.sh scenario diagnose` — s003 as a verb on the stress preset: healthy → contact mismatches → fall, narrated live, post-mortem pinned, `verify.json` says `fell`, reset restores; up to three attempts, never a loop-until-green |

**One branch, one PR, closing all four.** That is the maintainer's call for this
step, as it was for E, F and G; the milestone's default is one issue per PR and
the PR body says so (§8.1). The order is fixed: 11 first (the fourth block and
the console's `inject` are the mechanism both scenarios use); then 12 (s004 —
buildable the moment `inject` is live, and its process-table assert is the
design's hard constraint made mechanical); then 13 (the sweep runs unattended
for ~2 h and settles what 14 can assert); then 14 (s003, whose shape depends on
13's table). Budget: about **four and a half hours of live-guest time** (§6),
of which the sweep is two; the rest is editing.

---

## 0. Ground truth the implementer must know

**Repo.** `origin/main` is `109a4af` (*Merge pull request #81 from
alius-git/stack/65-teleop-hardened*, 2026-09-08). Local `main` is at it. **The
working tree carries uncommitted deck work** — `M slides/slides.md` and five
untracked files under `slides/` — that is the maintainer's and is not this
PR's: branch from `main`, never `git add -A`, stage files by name. No
`stack/68-*` or `demo/68-*` branch exists.

**Host.** `google-chrome` 151.0.7922.71, `firefox` 154, `python3` 3.12.3,
`virsh`, `ssh`. `serve.py` is running on `:8000` (`/api/health`: `kennel: true`,
out dir `~/kennel-runs`, pin `dcf53c59…`, `bridge: null`, `meshcat: null`).
`~/kennel-runs` holds the maintainer's run folders, newest
`run-20260907T202843Z` (OSQP, flat plane, **`simulator_realtime_rate 1.0`**,
`verify.json` verdict `completed`). `.kennel-bridge` / `.kennel-meshcat` absent.
This plan's probes composed twice through the running console
(`kennel-demo.sh compose`), which overwrote `~/kennel-runs/02-console-compose.png`
— a `p22-console-demo.sh` side effect, harmless — and the two probe run folders
were **moved out** of `~/kennel-runs` afterwards, because `kennel-demo.sh run`
picks the newest folder and would otherwise have launched a qpOASES/rate-0
composition the maintainer never composed.

**Guest.** `kennel-vm` at `192.168.122.32` (user `yuuser24`, key
`~/git/yuruna/test/status/ssh/yuruna_ed25519`), 8 vCPU / 16 GiB, container
`dfki_quad` running, guest clone at the pin. **Left as found**: applied run
`run-20260907T202843Z`, relaunched by this plan's last probe at 15:16Z through
`kennel-demo.sh run <that folder>` → `pass=10 fail=0`, gait `STAND`, target
zero, bridge down, no `/tmp/k13-*.pid`, no disturber, no probe tools in
`/root`. The staging directory holds the maintainer's five runs only. The sim
clock is young (the stack was relaunched three times today).

### 0.1 The disturbance path, probed live (rate 1.0, `ros2 run simulator sim_disturber` started detached)

| Observation | Value | Consequence |
|---|---|---|
| the binary | `install/simulator/lib/simulator/sim_disturber → build/simulator/sim_disturber` (symlink-install) | `ros2 run simulator sim_disturber` is the fourth command, as `mapping.md` §4.6 says |
| the graph, 1 s after the start | **`/disturbance_node`** — the node name is `rclcpp::Node("disturbance_node")` in `disturbance_node.cpp:16`, not the executable's | the launcher waits for `/disturbance_node`; `kennel-verify.sh` tolerates that name |
| the service | `/disturb_simulation [interfaces/srv/DisturbSim]` — `float64[3] force, float64[3] tau, float64 time → bool success` | the console's payload, exactly |
| the topic | `/simulation_disturbance` `interfaces/msg/SimulationDisturbance`, RELIABLE/VOLATILE, **1 publisher** (`disturbance_node`), **1 subscriber** (`drake_simulator`) | the guest-side witness for "the exact injected parameters" is a subscriber on this topic |
| the yaw rotation | request `force [100, 0, 0]` arrived on the topic as **`[23.10, 97.30, 0.0]`**, then `[0, 0, 0]` | the request's `+x` is the robot's forward; the witness compares the **magnitude** (100.0 ± 0.5 N), never the components |
| the call blocks | `time: 0.2` → response after **0.201 s**; `time: 0.3` → **0.301 s** (an rclpy client; `ros2 service call` adds ~2.2 s of its own start-up, so never time it through the CLI) | the issue's warning holds; the page must not wait for the answer |
| the launcher, with the disturber on the graph | `NB the graph also carries: /disturbance_node` — reported, not fatal | the six-node wait is untouched; block 4 gets its own wait |
| `kennel-verify.sh` check 1, disturber running | **`[FAIL] 1 node-graph … [extra: /disturbance_node]`, `pass=9 fail=1`, verdict `unhealthy`** (this plan's rate-0 run) | `KENNEL_EXPECT_DISTURBER=1` is not optional — a run composed with disturbances on cannot be green without it |
| **the pidfile trap** | started as `ros2 run … & echo $! > /tmp/k13-disturber.pid`, the pid is the **`ros2` python wrapper** (`comm` `ros2`). `k13-stop.sh` INT/KILLed it on the next launch; the binary **`sim_disturber` survived with ppid 1** and kept serving `/disturb_simulation` across **two** relaunches, until `pkill -KILL -x sim_disturber` | the issue's `/tmp/k13-disturber.pid` is exactly the wrong instrument. Block 4 is reaped **by name**, like the simulator and the leg driver (§2.4); `comm` is `sim_disturber`, 13 chars, under the 15-char cap |
| the process set across two pushes | `ps -e -o comm=,args=` sorted, 19 rows, **diff empty** before/after | s004 step 6 is true of the mechanism; the verb makes it a check |

**The pushes, on a freshly launched robot walking under the held trot**
(`p21-trot-hold.sh start`: vx 0.257 m/s, z 0.292 m, tilt 0 — the "defined
starting state" #65 found necessary; the same 100 N push on the 15-hour-old
robot the session began with gave a different, meaningless number and is why the
rule stands):

| Push | Effect (`kennel-bridge.sh observe 8 --rows`) |
|---|---|
| **100 N +x, 0.2 s** | vx spikes to **1.12 m/s**, z dips to **0.212 m**, `tilt_over_frac` **0.0**, walking again at 0.26 m/s within ~1 s; window: vx_mean 0.285, z_median 0.287 — **a stagger and a recovery**, s004 step 2 |
| **300 N +y, 0.3 s** | a tumble: contacts `0000`, vx −1.34 m/s, z_min **0.129 m**, `tilt_over_frac` **0.525** — a fall by `verify.md` §4's rule, s004 step 3 |
| `kennel-bridge.sh recover` after it | `/reset_sim` `success: True`, standing at **0.3137 m**, simulator alive |

**A finding that changes the verbs.** The session's first `recover` — on the
robot as found, 15 h into its session at sim t ≈ 55 000 s, collapsed to z < 0.15
*without* an E-STOP, the disturber running — went `/set_damping_mode` →
`/reset_sim` → *"Simulation reset was performed"* and then

```
[simulator-1] abort: Failure at multibody/contact_solvers/sap/sap_solver.cc:342 in CalcCostAlongLine(): condition 'd2ellA_dalpha2 > 0.0' failed.
[simulator-1] Aborted (core dumped)
[ERROR] [simulator-1]: process has died [pid 178583, exit code 134, …]
```

No `/clock`, no `/quad_state`, `recover` timed out with *z median unknown*, and
the graph kept showing `/drake_simulator` for a while. The identical sequence on
a fresh disturbance fall worked (table above), and #66's evidence has it working
from E-STOP. So `/reset_sim` has a **crash mode** that costs a relaunch, and it
was reached from a stale, collapsed state. Consequences, all in this plan: every
scenario verb starts from a **fresh launch**, never from a stack older than the
verb's own session; every post-reset wait treats "no `/clock` within the bound"
and "the simulator process gone from the table" as a **red result naming the
relaunch**, never as something to retry; and the process-table assert of s004 is
what catches a simulator that died under a console action.

### 0.2 The MPC solve margin, measured — #70's premise does not hold on this guest

Four points, each 20 sim-s under the held 0.3 m/s trot, read by an rclpy
subscriber on `/solve_time`, `/wbc_solve_time`, `/controller_heartbeat`
(`scratchpad/probe/probe-solve.py`, promoted to a tool in §4.1):

| Composition | rtf | MPC solve ms mean / p50 / p95 / max | iters | ≥ 10 ms of 2000 | overtime Δ / fail Δ | WBC ms mean / p95 / max | controller CPU |
|---|---|---|---|---|---|---|---|
| OSQP, rate **1.0** (the maintainer's run) | 1.00 | **1.18** / 1.11 / **1.78** / 8.00 | 12.2 | **0** | 0 / 0 | 0.121 / 0.177 / 2.07 | 33 % of a core |
| OSQP, rate **0** ("as fast as possible") | **2.16** | 1.12 / 1.00 / 1.77 / 4.53 | 13.3 | 0 | 0 / 0 | 0.094 / 0.132 / 1.48 | 67 % (simulator 113 %) |
| FULL_CONDENSING_QPOASES, rate 0 | 2.20 | 1.22 / 1.10 / 1.85 / 4.22 | 2.4 | 0 | 0 / 0 | 0.093 / 0.126 / 1.42 | 67 % |
| OSQP, **`mpc_warm_start: 0`** (the one honest widening, a Tier-2 key held fixed by the composer), rate 1.0 | 1.00 | 1.33 / 1.31 / 1.66 / 4.07 | **20.1** | 0 | 0 / 0 | 0.108 / 0.143 / 1.23 | 33 % |

`kennel-verify.sh` agreed on every point: check 7 `d_overtime=0 d_mpc_fail=0`,
check 2 *"advanced 5.00 sim-s in 2.5 s wall"* at rate 0, `rtf` 1.99 and 2.23
reported. The 8.0 ms maximum in row 1 is the stale robot's tumble at the start of
that window (`tilt_over_frac` 0.028); the fresh rows never exceed 4.5 ms.

What this means, stated plainly so nobody spends the sweep looking for it:
**the 10 ms deadline sits an order of magnitude above every MVP-scope
composition on the 8-vCPU guest, and "as fast as possible" is only 2.2×.** The
likely lever the issue names does not move the number; cold start doubles the
iterations and not the time; the slowest solver family is not slower. The
sweep in §4 still runs — the issue asks for one table, and eighteen points are
the honest form of "measurements, not guesses" — but the plan is built on the
**negative result** the issue's third bullet allows (*"record the negative
result and stop"*), with the branch for the other outcome stated in §9.1. The
red preset is obstacle terrain (`transfer.md` §6.3: falls or trots in place,
not stable run to run — the sweep measures three); the "amber" composition does
not exist at this pin on this host, and `stack/stress.md` says so with the table.

Two incidental observations, recorded because the sweep will see them again:
`FULL_CONDENSING_QPOASES` walked the cleanest of the four (z median 0.3145,
tilt max 0.010 rad); and with `mpc_warm_start: 0` the robot walked at **z
0.398 m** instead of the commanded 0.30 (check 9 passed — the band is 0.20–0.45
— and the height-tracking INFO line said so). Neither is this plan's problem;
both go in `stress.md` as findings.

### 0.3 At the pin (`git -C dfki-quad show dcf53c59:<path>` — never the working tree)

- `ws/src/simulator/src/disturbance_node.cpp`: node `disturbance_node`;
  `quad_state` subscription keeps the yaw quaternion (`:31–37`); the handler
  rotates `force`/`tau` into it, publishes once, **`this->get_clock()->sleep_for(time)`**,
  publishes zeros, answers `success = true` (`:39–65`). The node never declares
  `use_sim_time`, so its clock is **wall** time unless the launch passes
  `--ros-args -p use_sim_time:=true` — at rate 0.5 a 0.2 s request would push for
  0.1 sim-s. **Not measured** (this plan's probes were all at rate 1.0): §6 row 3
  measures it and §9.4 says what to do with either answer.
- `ws/src/simulator/src/drake_simulator.cpp:355–372, :400`: the disturbance is
  an `ExternallyAppliedSpatialForce` on `reference_link` (`base_link`) at its
  origin, world frame, connected to the plant's applied-force port. `:147–148`:
  `belly_contact` is **always false** (`// TODO: set belly contact correct`) —
  which `verify.md` §4.1 already records; the fall rule is height and attitude.
- `ws/src/simulator/CMakeLists.txt:38, :104`: `sim_disturber` is built from
  `disturbance_node.cpp` and installed to `lib/simulator/`; no launch file
  references it (`simulator.launch.py` declares one node, `drake_simulator`).
- `ws/src/controllers/src/mit_controller_node.cpp:841–911`: the MPC runs on a
  **sim-time** timer every `MPC_CONTROL_DT` = 0.01 s (`mit_controller_params.hpp:8`);
  `solve_time` is `std::chrono` **wall** time around `GetWrenchSequence`;
  `num_mpc_solver_overtime++` when `total_solver_time >= MPC_CONTROL_DT`,
  `num_mpc_solver_fail++` when `!solver_info.success`. `/solve_time` carries
  `acados_num_iter` and `acados_return` (`interfaces/msg/MPCDiagnostics.msg`).
  So the "10 ms deadline" is a wall-clock budget per sim-time cycle, and at rate 0
  the controller solves 2.2× more often per wall second — which is why rate 0
  was the plausible lever, and why 2.2× was not enough.
- `ws/src/simulator/config/simulator_params_go2.yaml`: `initial_robot_height:
  0.4`, `simulator_realtime_rate: 1.0`, `manually_step_sim: false` (twice).

### 0.4 What the existing suites pin down — constraints, all of which stay green

- `verify-generate.py:153–155`: **`len(cmds) == 3`** with default choices; the
  `__cmds()` helper counts every `<div>` whose text starts with `source /opt/ros`.
  The `disturbances` toggle defaults **off**, so nothing changes until the
  appended group turns it on.
- `verify-export.py:170–171`: `list(rj.keys()) == ["run_id", "run", "generated_at",
  "pin", "choices"]` — **in that order**; `:184–188`: `sorted(choices)` equals
  **exactly the seven** composer-owned fields; `:193`: `commands.txt` has exactly
  three `ros2 launch `; `:191–192`: every UI block appears verbatim. Therefore
  `choices.disturbances` is **written only when on** (§2.1) and block 4 is a
  `ros2 run`, not a launch.
- `verify-send.py:185`: a sent run folder holds exactly the four artifacts —
  unchanged.
- `verify-scope.py:89–90`: the only `<select>` whose options match `CONDENSING`
  is the solver's; `:101–111`: the ground-truth row is found as the `<div>`
  whose text is exactly `ground-truth state` with two children, and its toggle
  as the descendant with `border-radius: 10px`. The new row is **appended after
  it** with the same shape, so both helpers keep finding the first match.
- `verify-teleop.py:187–190`: `ops("subscribe")[0]` is the `/quad_control_target`
  probe; `:264–277`: the last message ever is a zero and an `unadvertise` was
  sent; groups 13–17 pin `reset sim`'s sequence. `inject` adds a `call_service`
  and nothing on the topic.
- `verify-dashboard.py:637–645` (`GRAMMAR`): `^Disturbance: \d+ N for [\d.]+ s at
  body CoM \(.+\)$` is already a grammar line — the live `inject` uses
  `narrate('disturb', …)` unchanged; `:489–490`: the health strip must contain
  `/solve_time` and `deadline 10 ms`; `:643`: `sim clock restarted at …`;
  group 12 pins the fall banner's text and the 5-s pin window.
- `verify-runs.py:195`: no key named `run` nested anywhere in `/api/runs`.
- Every suite's `__click` takes the **first** element whose exact text matches
  — never add an element reading `inject`, `reset sim`, `STAND`, `Dashboard`,
  `Runs`, … ahead of the existing one. The existing `inject` button **is** the
  live control; nothing new reads `inject`.
- `p21-launch-from-commands.sh:98–104`: `n -ne 3` is fatal and a block ends at
  its `ros2 launch` line — both change (§2.2), and the reconstruct-the-file
  check (`:110–113`) must keep holding for four blocks.
- `kennel-verify.sh:242–252`: the tolerated set is `BRIDGE_NODES` under
  `KENNEL_EXPECT_BRIDGE`; `:73–74`: the passthrough env list; `:968`: the knobs
  recorded in `report.json`.

**Read first.** `CLAUDE.md`; `plan/scenarios.md` s003 and s004 (the numbered
steps are the verbs' checklists); `plan/design/seq.s003.diagnose.md`,
`seq.s004.disturb.md`; `plan/design.md` §1 (the fault-injection row); `stack/mapping.md`
§4.6; `stack/composed-run.md` §3.1, §9.1–§9.2 (the launcher's shape and the
four defect species a live protocol finds); `stack/verify.md` §2, §4, §7;
`kennel_console/generate.md` §3, `export.md` §3, `composer-scope.md` §1.1–§1.2;
`kennel_console/teleop.md` §12, `dashboard.md` §2.2, §3.1–§3.4, §4;
`stack/bridge.md` §10–§11 (the live suite and the watchdog, whose instrument
`observe` the verbs reuse); `stack/bridge/verify-teleop-live.sh` and `.py`
(**the model for the scenario verbs**); `demo/dry-run.md` §4 (the F-numbered
friction format); PR #81's body for the shape.

---
## 1. Shape of the work

- Branch `stack/68-two-scenarios` from `origin/main` (`109a4af`).
- Six commits, in this order, house form `<type>(<area>): <what> (#N)`:
  1. `feat(stack): block 4 — sim_disturber launched, waited for and reaped by name; KENNEL_EXPECT_DISTURBER (#68)` — includes this plan file.
  2. `feat(console): the disturbances toggle composes block 4; inject calls /disturb_simulation over the bridge, never awaited (#68)`
  3. `feat(demo): kennel-demo.sh scenario disturb — s004 as a verb, the process table identical around every step (#69)`
  4. `feat(stack): k14-sweep.sh measures the MPC margin across the MVP knobs; KENNEL_PRESET=stress is the red composition (#70)`
  5. `feat(demo): kennel-demo.sh scenario diagnose — s003 as a verb, narrated live, verdict fell recorded (#71)`
  6. `docs: record the two-scenarios pass — demo/scenarios.md, stack/stress.md, the block-4 records, evidence (#68, #69, #70, #71)`
- New files: `demo/tools/scenario-disturb.sh`, `demo/tools/scenario-diagnose.sh`,
  `demo/tools/scenario-lib.sh`, `demo/tools/scenario-page.py` (HOST);
  `stack/verify/tools/k14-sweep.sh` (HOST), `stack/verify/tools/k14-solve-probe.py`
  (CONTAINER); `stack/stress.md` + `stack/stress/evidence/`; `demo/scenarios.md`;
  `demo/evidence/s004-disturb/`, `demo/evidence/s003-diagnose/`;
  `stack/bridge/evidence/live/21-…` (the #68 live rows).
- Modified: `kennel_console/Kennel Console.dc.html`, `fake-rosbridge.py`,
  `verify-teleop.sh` + `.py`, `verify-generate.py`, `verify-export.py` (all
  **appended** groups); `stack/composed-run/tools/p21-launch-from-commands.sh`;
  `stack/verify/kennel-verify.sh`; `stack/known-good/tools/k13-stop.sh`;
  `stack/bridge/tools/k13-target-monitor.py` (one more witness);
  `demo/tools/kennel-demo.sh`, `demo/tools/p22-console-demo.sh` + `.py` (knobs);
  the records of §7.
- Every touched script keeps its header truthful (`# Version:` date, what,
  **where it runs**, usage, knobs, exit codes); the Python tools carry the same
  block as a docstring.
- **No new copy of the container source chain.** Block 4 carries the console's
  own prelude like blocks 1–3; the launcher's polls run through `/tmp/p21-env.sh`
  as they do today; everything the verbs and the sweep do on the guest goes
  through `kennel-bridge.sh`, `p21-trot-hold.sh`, `kennel-verify.sh` and
  `kennel-demo.sh`'s verbs over ssh. The probe tool is a CONTAINER tool
  `kennel-bridge.sh observe` copies in and runs, exactly as the monitor is.
  `composed-run.md` §9.2's registry stays at four copies.
- **Append, never reorder** in the console: the toggle row after `ground-truth
  state`, the new `narrate` kinds before `default`, attributes added to existing
  elements rather than elements inserted before them.
- Nothing the console does starts or stops a process. Block 4 is started by the
  launcher from `commands.txt`, like the other three; `inject` is a service call.

The architecture after step 14:

```
 host                                     guest (kennel-vm)                 container (dfki_quad)
 ────────────────────────────────────     ─────────────────────────────     ───────────────────────────────────────────────
 console: disturbances ON ─► commands.txt (4 blocks) ─ transfer ─► p21-launch ─► blocks 1–3 (six nodes) + block 4: ros2 run simulator sim_disturber
                                                                                    └─ /disturbance_node ─► /disturb_simulation ─► /simulation_disturbance ─► drake_simulator
 console: inject ── ws ──► rosbridge ── call_service /disturb_simulation (blocks `time`; the page never waits) ──┘
 kennel-demo.sh scenario disturb|diagnose ─► scenario-*.sh ─┬─ ssh: kennel-bridge.sh observe / recover, ps -e (the table), kennel-verify.sh
                                                            └─ headless Chrome via scenario-page.py: stick, inject, reset, feed, health, Runs
 k14-sweep.sh ─► compose (knobs) ─► run ─► observe with k14-solve-probe.py ─► one CSV row per point ─► stack/stress.md
```

---

## 2. Step 11 — #68, the disturbance path

### 2.1 The composer: a `disturbances` toggle, and what it generates

**State.** `SIM_DEFAULT` (console `~929`) gains `disturbances: false`;
`normalizeCfg` (`~980`) coerces it to a boolean (a legacy preset without the key
is off); `flatten` gains `sim.disturbances` so the Runs diff can name it. It is
the first composer choice that lives in **no YAML** — `cfgFromYaml` (`~1451`)
cannot recover it and does not try; `cfgFromChoices` (`~1476`) does:
`if (ch.disturbances !== undefined) cfg.sim.disturbances = !!ch.disturbances;`.

**UI.** One more row in `simFields` (`~2940`), **appended after** `ground_truth_state`:
`{k:'disturbances', label:'disturbances', type:'bool'}` — selectable, not in
`SIM_FIXED`. Under the row, an `sc-if` note (appended after the ground-truth
caution) shown only when on: *"a fourth command is generated:
`ros2 run simulator sim_disturber` — the disturbance service the Interventions
`inject` button calls (mapping.md §4.6). The launcher starts it after the
controller."* `verify-scope.py`'s two ground-truth helpers keep finding the
first matching row; the `stock (MVP)` badge count stays five.

**Generation policy** (`generate.md` gains a §1.4 for it):

| Toggle | `commands.txt` | `run.json` | the two YAMLs |
|---|---|---|---|
| off (default) | **byte-identical** to today: three blocks, header *"THREE shells"* | byte-identical: seven `choices` | unchanged |
| on | header *"FOUR shells"*; `COMMAND_BLOCKS` (`~1276`) is extended at generation time with block 4; the three blocks above it are byte-identical to the off case | `choices` gains an **eighth** key, `disturbances: true`, appended last | unchanged |

Block 4, exactly (the prelude is `LAUNCH_PRELUDE`, verbatim, as in the other three):

```
# 4 · sim disturber — the disturbance service (composed: disturbances on). Needs block 1 up; the launcher starts it last
<LAUNCH_PRELUDE>
ros2 run simulator sim_disturber --ros-args -p use_sim_time:=true
```

The `use_sim_time` argument is **§9.4's decision**, taken so that `time` is a
sim-second like every other window in this repo, and **measured before it
ships** (§6 row 3): if the sleep proves to be wall time regardless, the argument
is dropped and the console's label says *wall s*. Either way the block's text is
fixed by that row, not by taste.

`emitRunJson` (`~1317`): after `mpc_condensed_size`, `...(cfg.sim.disturbances
? {disturbances: true} : {})` — spread last so the seven keys keep their order
and the eighth appears only when on. `emitCommandsTxt` (`~1296`): the *THREE
shells* sentence becomes a function of the block count; the *"not a script"*
phrase and the precondition lines are untouched (the export suite greps them).

**Suites, appended.** `verify-generate.py` group 10 *"the fourth block"*: toggle
on → `__cmds()` has four entries, the fourth ends in
`ros2 run simulator sim_disturber --ros-args -p use_sim_time:=true`, carries the
source chain and `cd /root/ros2_ws`, has no `ros2 launch`; the first three are
byte-equal to the off case; toggle off → three again. `verify-export.py` group 8
*"disturbances on, exported"*: with the toggle on, the archive's `commands.txt`
contains the block-4 line and **still** exactly three `ros2 launch `;
`run.json.choices` has eight keys, `disturbances` last and `true`; toggle off and
export again → `commands.txt` and `choices` **byte-equal** to the group-1 export
(the acceptance's *"unchanged byte for byte"*, asserted). The seeded run
history (`~2437`) is untouched — no seeded run composes disturbances.

### 2.2 `p21-launch-from-commands.sh` — block 4 launched and waited for

- The splitter (`:96–104`): a block ends at `ros2 launch *` **or** `ros2 run *`;
  `n` may be 3 or 4 — `n -ne 3 && n -ne 4` is fatal with the message naming both
  shapes. The reconstruction check (`:110–113`) concatenates `block1..n`.
- The canonical-three assertion (`:118–129`) stays for blocks 1–3; when `n = 4`,
  block 4's last line must match `^ros2 run simulator sim_disturber( --ros-args -p use_sim_time:=true)?$`
  — a generated file whose fourth block ran anything else is a #18 regression,
  and running it would report a green stack for the wrong stack.
- `EXPECTED_NODES` is **unchanged** (the six); the six-node wait is unchanged.
  After it, when `n = 4`: `start_block 4 disturber` (log `/tmp/p21-disturber.log`),
  then a bounded wait (`KENNEL_GRAPH_TIMEOUT`, the same 2-s poll) for **two
  signals**, both required (#52's shape, `bridge.md` §3): `/disturbance_node` in
  `ros2 node list` and `/disturb_simulation` in `ros2 service list`. Exit 1
  names the missing one and the log. Measured in §0: the node is on the graph
  within one poll.
- The *extra* report (`:279–285`): when `n = 4`, `/disturbance_node` is part of
  the expected set for that message, not an extra; the NB line still names
  anything else. The final `say` lists four logs when there are four.
- Header: usage, the two shapes, exit codes; `KENNEL_SETTLE_SIM_SECONDS` etc.
  untouched.

### 2.3 `kennel-verify.sh` — `KENNEL_EXPECT_DISTURBER=1`

The bridge pattern (`:236–252`), one more set: `DISTURBER_NODES="/disturbance_node"`,
`[ "${KENNEL_EXPECT_DISTURBER:-0}" = 1 ] && TOLERATED_NODES="$TOLERATED_NODES
$DISTURBER_NODES"`. **Tolerated, never required** — its participant lingers
after a stop like the bridge's. `NODE_CRITERION` (`:261–262`) becomes a sentence
built from the two knobs (*"… plus the four a teleop session adds (KENNEL_EXPECT_BRIDGE=1), plus the disturber (KENNEL_EXPECT_DISTURBER=1)"*).
The usage text (`:90–98`) gains the knob; `PASSTHROUGH_ENV` (`:70–74`) and
`knob_names` (`:965–969`) gain `KENNEL_EXPECT_DISTURBER` so `report.json` says
it. No threshold changes.

`kennel-demo.sh do_verify` (`:1210`): beside `solver_of_run`, a
`disturbances_of_run` (`sed -n 's/.*"disturbances"[[:space:]]*:[[:space:]]*true.*/1/p'`)
read from `APPLIED_RUN`'s `run.json`, or from `applied_run_dir` when the verb
runs alone — the same two-step resolution `runs.md` §2 records — and
`KENNEL_EXPECT_DISTURBER=$expect_disturber` on the ssh line, with a `say`
naming the source. `verify-teleop-live.sh`'s verify group needs nothing: it
calls the driver.

### 2.4 `k13-stop.sh` — reaped by name

One word in the sweep (`:33`): `for n in simulator leg_driver mitcontrollerno
log_cpu_power joy_linux_node sim_disturber ros2`. The comment above it gains the
§0.1 measurement: the `ros2 run` wrapper is reaped by the existing `ros2` entry,
and without this word the binary survives as an orphan with ppid 1 and keeps
serving. **No pidfile** for block 4 (§9.2): the launcher starts it exactly as it
starts blocks 1–3 — a detached `bash /tmp/p21-block4.sh` — and none of those
has a pidfile either. §6 row 4 proves the reap by running `down` alone against
a running disturber.

### 2.5 The console: `inject` over the bridge

Constants beside `RESET_SRV` (`~1535`): `DISTURB_SRV = '/disturb_simulation'`,
`DISTURB_TYPE = 'interfaces/srv/DisturbSim'`. On `RosbridgeTarget`, after
`resetSim` (`~1890`), in the style of `call()` (`~1829`):

```js
// The disturbance (#68). A service that BLOCKS for `time` before it answers
// (disturbance_node.cpp:60-63; measured 0.201 s for a 0.2 s request), so nothing
// here waits: the link routes the answer to a callback whenever it comes, and
// the 20 Hz tick is never in that path. The fake bridge delays its answer 2 s to
// prove it (verify-teleop.py group 18).
disturb(f) {                      // f = {fx, fy, fz, duration}, newtons and seconds
  if (!this.open()) { this.say('not connected — nothing was sent', true); return false; }
  const mag = Math.hypot(f.fx, f.fy, f.fz);
  const args = {force: [f.fx, f.fy, f.fz], tau: [0, 0, 0], time: f.duration};
  this.say('disturbance requested: ' + mag.toFixed(0) + ' N for ' + f.duration.toFixed(2)
           + ' s — the service answers when the push ends', false);
  this.link.call(DISTURB_SRV, DISTURB_TYPE, args, m => {
    if (m && m.result === false) {
      this.say('the disturbance service refused: ' + JSON.stringify(m.values || '')
               + ' — is the disturber running?  compose with disturbances on', true);
      return;
    }
    this.say('disturbance done: ' + mag.toFixed(0) + ' N for ' + f.duration.toFixed(2) + ' s', false);
  });
  return true;
}
```

`tau` is always zero: the Interventions row has no torque fields and the
mapping note says a torque is not part of the MVP surface. The force is
whatever the four fields hold — the page copies no defaults; `mag: 100` in
`onInject` (`~3328`) stays the mock's fallback only.

The Component's `onInject` (`~3328`) becomes, mirroring `onReset`'s shape:

| State | Action |
|---|---|
| mock (no link, or plain `http.server`) | exactly today: `ds.inject(…)` |
| link open, **newest run** composed with disturbances off, or no run known | nothing on the wire; `ds.emit('nolive', 'info', 'inject is off: the newest run (' + id + ') was composed with disturbances off — compose with the toggle on (run.json choices.disturbances)', 5)` |
| link open, newest run has `choices.disturbances === true` | `tp.disturb(st.dist)`; `ds.emit('dist' + ds.t, 'info', narrate('disturb', {mag, duration, fx, fy, fz}), 0)` — the feed logs **the exact injected parameters** in the grammar line the dashboard suite already pins |

"The newest run" is `serverRuns[0]` (`/api/runs` is newest-first, `serve.py:284`)
— the same convention the status bar's run id uses (#62: *run id = newest of
`/api/runs`*). `fetchRuns()` (`~2548`) is also called when *connect bridge* is
clicked, so the Dashboard has the list without a visit to Runs. The button
itself (`~343`) keeps its text `inject` and gains two style bindings, `{{ injectBd }}`
/ `{{ injectFg }}`, dimmed when the guard says off, and a `title="{{ injectWhy }}"`
carrying the reason — appended attributes, no new element. `RosbridgeDataSource.inject()`
(`~2231`) keeps its *not wired* line for one case only — a call with no target
— and the text names *the run*, not #68.

The **third `narrate` kind is not needed**: the request and the answer are the
target's status line (the DOM the suites read); the feed line is the existing
`disturb` grammar. `dashboard.md` §6's *"inject … still #68"* → done.

### 2.6 The guest witness: `k13-target-monitor.py` subscribes `/simulation_disturbance`

One more subscription (RELIABLE, the publisher's QoS), one more block in the
JSON: `"disturbance": {"n": 2, "first_sim": 3.41, "last_sim": 3.61, "sim_gap":
0.20, "wall_gap": 0.20, "force_max_norm": 100.0, "force_max": [23.1, 97.3, 0.0]}`
— `n` counts messages in the window, the two gaps are between the first non-zero
and the following zero (the push's duration in **both** clocks: §6 row 3 reads
them), `force_max_norm` is what the verb compares with the magnitude the page
sent. Absent (`null`) when nothing arrived. The scenario verbs read it through
`kennel-bridge.sh observe` like everything else; nothing new to stage.

### 2.7 `fake-rosbridge.py` and `verify-teleop.*` — groups 18–21, appended

- `--service-delay SERVICE:SECONDS` (repeatable): answer that service after the
  delay **on a `threading.Timer`**, never by sleeping in the read loop — a fake
  that blocks its own loop stamps the page's next 2 s of publishes at once and
  the 20 Hz assertion would fail for the fake's reason, not the page's. Answer
  shape for `/disturb_simulation`: `values: {success: true}` (`response_values`,
  `:336`).
- The suite writes one run folder into its own out dir before Chrome starts —
  `run-20260101T000000Z/run.json` with the four provenance keys and
  `choices.disturbances: true` (a fixture, cited as such) — so `/api/runs`
  lists a newest run composed with disturbances on. `serve.py`'s `list_runs`
  (`:284–330`) must tolerate a folder holding only `run.json`; if it does not,
  write the four artifacts (the generate suite's emitters produce them).

| # | Asserts (wire = the fixture's ops log; DOM = `__txt()`) |
|---|---|
| 18 | *inject while driving* (main fake, `--service-delay /disturb_simulation:2`): set the four fields through the Interventions inputs (helper `__distInput(label)`: `Fx [N]` 100, `Fy [N]` 0, `Fz [N]` 0, `dur [s]` 0.2), click `inject` → exactly one `call_service` with `service == /disturb_simulation`, `type == interfaces/srv/DisturbSim`, `args == {force: [100, 0, 0], tau: [0, 0, 0], time: 0.2}`; DOM says `disturbance requested`; **during the 2-s delay** the `publish` gaps on `/quad_control_target` stay within the tolerance group 4 already uses for 20 Hz (nothing froze); after the answer, DOM `disturbance done: 100 N for 0.20 s`; the feed has `Disturbance: 100 N for 0.20 s at body CoM (100, 0, 0)` |
| 19 | *inject with the newest run composed off*: remove the fixture run folder (or write it with `disturbances` absent), reload, connect → click `inject` → **no** `call_service` in the log; the feed names the run and *disturbances off* |
| 20 | *inject refused by the stack* (the foreign fake answers `result: false`): connect (refused to drive — the socket stays open), click `inject` → the call **is** sent (a disturbance needs no publisher), the answer is `result:false`, DOM says `the disturbance service refused` and names the toggle |
| 21 | *plain `http.server`*: `inject` drives the mock exactly as before — the mock's `Disturbance:` feed line, zero sockets, nothing thrown |

Expected count: 76 → about 92 checks; `verify-teleop.sh`'s header and the
*fake bridges recorded …* line say so.

### 2.8 Live evidence and records

§6 rows 1–6. `kennel_console/teleop.md` **§13 "The disturbance over the
bridge"**: the payload, the not-awaited decision with the measured block time,
the guard, the guest witness, the suite groups, the transcripts.
`stack/composed-run.md` **§10 "Block 4"**: the split, the wait, the reap by name
with the orphan finding, the `KENNEL_EXPECT_DISTURBER` knob. `stack/mapping.md`
§4.6: the bypass is **retired within the MVP** — the console generates the
fourth command when disturbances are on — and the upstream retirement (the
launch file) stays as written; append, do not rewrite. `composer-scope.md` §1.1
gains the row *disturbances · on/off · off · block 4 of `commands.txt` + `run.json`
(no YAML key)*. `stack/verify.md` §2's check-1 row names the knob.

---
## 3. Step 12 — #69, `scenario disturb`

### 3.1 The verb family

`kennel-demo.sh scenario <name>` (`:1490` dispatch, `usage`, the header's verb
table) → `do_scenario` validates the name against the files that exist and
execs `$HERE/scenario-<name>.sh "$@"` with every `KENNEL_*` knob in the
environment — the driver adds orchestration only, and a scenario is a **test
that re-runs**, so it lives beside the driver as `verify-teleop-live.sh` lives
beside the bridge. `scenario` with no name lists the two. The usage line at
`:1508` gains `scenario`.

Three files, HOST, `set -uo pipefail` (nothing sources a ROS file):

- **`demo/tools/scenario-lib.sh`** — sourced by both verbs: the lease-by-hostname
  region and `SSH_OPTS` (copied from `verify-teleop-live.sh:60–107`, not
  re-derived); `check`/`num_ok`/`jget`/`observe`/`observe_bg` copied from the
  same file (`:132–188`) so a scenario transcript reads like the live suite's;
  `stage_bridge_tools` (the three `guest_stage` calls `do_teleop` makes);
  `capture_ps NAME` (§3.3); `page STEP [ARG]` calling `scenario-page.py`;
  `start_chrome` with the live suite's flags **including `EXCLUDE localhost,
  <guest>`** (`bridge.md` §10.7 — the DNS blackhole maps IP literals too);
  `evidence_dir` → `demo/evidence/<scenario>/` with a numbered file per step.
- **`demo/tools/scenario-page.py`** — the page half, one named step per
  invocation like `verify-teleop-live.py`; `HELPERS` copied verbatim from it
  (**copy, do not import** — the suites' rule), plus `__feed()` and `__stat()`
  copied from `verify-dashboard.py:279–290`, `__distInput(label)` (the
  Interventions number input under the label `Fx [N]` …), `__velInput(label)`,
  `__health()` (§5.3's witness), `__runsRows()` (the Runs table's rows as text
  arrays). Steps: `boot`, `connect`, `disconnect`, `gait NAME`, `stick NY`
  (`__stick(0, NY, 'pointerdown')`; `NY = -1` is full forward), `release`,
  `vx V` (the `vx [m/s]` input), `inject FX FY FZ DUR`, `reset`, `unpin`,
  `feed FILE` (JSON dump of `__feed()`), `health FILE` (one sample of the six
  levels), `banner` (asserts `FALL DETECTED` present), `nobanner`, `runs FILE`
  (open Runs, dump rows, back to Dashboard), `shot FILE`
  (`Page.captureScreenshot`, as `p22-console-demo.py` does), `errors`.
- **`demo/tools/scenario-disturb.sh`** — the sequence below.

Preconditions (exit 2, each naming its fix, the `verify-teleop-live.sh` list):
Chrome; a checkout (`cdp.py`); the guest; a stack up (`verify-meshcat-host.sh --quiet`);
the applied run composed with **disturbances on** — read from
`applied_run_dir`'s `run.json`, else *"compose with the toggle on, then
`kennel-demo.sh run`"*; `/disturb_simulation` in the guest's `ros2 service
list` (the block-4 wait already proved it, but a verb that starts its own
session checks again); the console port free. **The bridge may be up** —
`teleop` is idempotent; the verb runs it and says whether it was already there.

`trap` on every exit: `page disconnect` (best effort), `kennel-demo.sh teleop
stop`, kill Chrome and the server, print `left: gait STAND, bridge down`. If
the robot is on the floor at exit, `kennel-bridge.sh recover` first, bounded,
and the transcript says whether it stood — a failed scenario must not cost
the next one a relaunch it can avoid.

### 3.2 The sequence — every step with its witness

`OUT=demo/evidence/s004-disturb/`, files numbered per step; sim windows via
`observe`, page facts via the DOM, the wire via the guest. Exit `0` every check
passed · `1` a check failed · `2` could not run. `[PASS]/[FAIL]` per line, the
totals last.

| # | Step (`scenarios.md` s004) | Does | Asserts — and from which witness |
|---|---|---|---|
| 0 | seed | `kennel-demo.sh teleop` (stops any held trot, starts the bridge + watchdog); `capture_ps before`; `boot`, `connect` → `driving`; `observe 3` | `driving` (DOM); `target.hz` 20 ± 2, `distinct_vx == [0.0]` (guest); `disturbance == null`; **the process table is the "before"** — it already contains the disturber, the bridge's three, the watchdog |
| 1 | velocity change | `gait WALKING_TROT` (picker → `active`, DOM); `stick -1` (0.5 m/s, `TELEOP_VMAX`); `observe 8 --rows` | `gait.name == WALKING_TROT`; over the **last 3 sim-s** of the window the mean planar speed is within **20 %** of 0.5 m/s (`0.40–0.60`; PR #81 measured 0.467); `x_travel > 0`; `tilt_over_frac ≤ 0.02`. `capture_ps after-velocity` → **diff vs before empty** |
| 2 | moderate push | `inject 100 0 0 0.2` from the page's fields; `observe 8 --rows` started **before** the click (`observe_bg`, wait for `KENNEL_MEASURING`) | guest: `disturbance.n == 2`, `force_max_norm` **100.0 ± 0.5**, `sim_gap` recorded; the robot **recovers**: `tilt_over_frac ≤ 0.02`, `z_min ≥ 0.15`, and from 3 sim-s after the push's first message every row's `z` is in `[0.20, 0.45]` and the last-3-s mean planar speed is back within 20 % of 0.5; DOM: `disturbance requested` then `disturbance done: 100 N for 0.20 s`; feed: `Disturbance: 100 N for 0.20 s at body CoM (100, 0, 0)`; no `FALL DETECTED`. `capture_ps after-moderate` → diff empty. `shot 02-moderate.png` |
| 3 | severe push | `inject 0 300 0 0.3` (the §0 push that fells it) under `observe 10 --rows` | guest: `force_max_norm` 300 ± 1; **a fall** by the rule: `tilt_over_frac > 0.15` **or** `z_min < 0.15`; page: `FALL DETECTED` banner within 10 s (DOM); `feed 03-feed.json`: the pinned rows lie in `[fallAt − 5.05, fallAt + 0.05]`, the **`Disturbance: 300 N …` line is in the pinned window before the `FALL:` line**, and `FALL:` is last (s004 step 3, s003 step 6–7); `shot 03-fall.png`. `capture_ps after-severe` → diff empty. Then `release`, `disconnect` (the page must not be publishing during the recipe's own trot) |
| 3v | the verdict | `kennel-demo.sh verify` (the driver sets `KENNEL_EXPECT_BRIDGE` and `KENNEL_EXPECT_DISTURBER` from the applied run) | exit **1** is the expected exit here; `verify.json` in the applied run's folder says **`verdict: fell`** (check 9 failed on a fallen robot outranks everything, `runs.md` §1); the verb copies it to `03-verify-fell.json`. `capture_ps after-verify` → diff empty (the recipe's own `check.py` has exited) |
| 3r | the record | `connect` again (the probe sees nothing: the watchdog has gone quiet — if it says `refused`, wait for `state idle` and connect once more, `bridge.md` §11.5); `runs 03-runs.json` | the Runs table has a row for the applied run with verdict `fell` and its counters (`early N` in the counters cell, as `verify-runs.py:233–240` reads them); `curl /api/runs` (the wire) agrees |
| 4 | reset | `reset` (the page's button, #66's sequence; the robot is down so `/set_damping_mode` runs first); `observe 10` polled until `z_median` in `[0.25, 0.35]` (bounded: ten 1-sim-s looks, `recover`'s own shape) | standing; DOM: `nobanner`, the feed's two lines `/reset_sim called …` then `sim clock restarted at …` **in that order**; `__stat('sim t')` < 15 s; the Runs row for the fallen run **still** says `fell` (`runs 04-runs.json`); `/api/runs` unchanged. `capture_ps after-reset` → diff empty — and if the simulator process is **gone** from the table, or `observe` exits 2 (no `/clock`), the verb prints the §0.1 SAP finding and `kennel-demo.sh launch`, and exits 1 without retrying. `shot 04-reset.png` |
| 5 | manual stepping | **out** — `manually_step_sim` is fixed at stock (`composer-scope.md` §1.2); recorded as a bypass in `demo/scenarios.md` with `/step_sim` as the retirement path | the verb prints one `[BYPASS] 5 manual-stepping` line, so the transcript is complete against the scenario's numbering |
| 6 | the process table | every capture diffed against `before` | **every diff empty** — six captures, six empty diffs, each printed as its own check; the diffs are files under `06-process-diffs/` |
| 9 | the page | `errors` | zero uncaught errors; nothing fetched but localhost and the guest |

Traces per step: the `observe --rows` CSVs under `04-traces/`; renders under
`05-renders/`; the transcript is `02-scenario-<n>.txt` (`tee`).

### 3.3 The process-table assert — the TVP made mechanical

```bash
capture_ps() {   # $1 = label -> $OUT/06-process-diffs/ps-$1.txt
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "sudo docker exec $CONTAINER ps -e -o comm=,args= --no-headers" \
      | sed 's/  */ /g' | grep -v -E "$HARNESS_RE" | sort > "$OUT/06-process-diffs/ps-$1.txt"
}
```

`HARNESS_RE` excludes **only the harness's own instruments** — `k13-target-monitor[.]py`,
`k14-solve-probe[.]py`, `^ps `, `ros2 (topic|service|param|node) ` (the
CLI probes `recover` and the polls run), `kennel-verify|check[.]py` — and is
**printed at the top of the transcript**, because an exclusion list is where a
check like this goes quietly wrong. Captures are taken **between** steps, when
no harness tool is inside the container, so the list is a safety net and not
the mechanism. The watchdog, the bridge's three and the disturber are stack
processes and are in every capture. A non-empty diff is printed in full and is
a FAIL; the simulator's line disappearing is the SAP finding's signature.
`comm` **and** `args` because a relaunched process with the same name and a new
pid is invisible to both — pids are deliberately not captured: a restart the
console caused would show as a *changed* line only if its args changed, and the
record says so as a limit (§9.7).

### 3.4 Twice in a row, from a `reset` guest

The acceptance: green twice in a row from a `reset` guest, so #52's fix is
exercised cold. §6 rows 7–9: `reset` → `KENNEL_DISTURBANCES=1 kennel-demo.sh
compose` → `run` (`pass=10 fail=0` with the knob, block 4 up) → `scenario
disturb` → `scenario disturb` again. The second invocation starts from a standing
robot at `STAND` with the bridge up — the verb's step 0 says *bridge already
up*, and its `before` capture is taken at that state. Both transcripts are kept;
the second's numbers are the ones `demo/scenarios.md` quotes.

`p22-console-demo.sh` + `.py` gain the knob **`KENNEL_DISTURBANCES`** (`0`/`1`,
default 0): the toggle row is clicked the way `verify-scope.py:101–111` clicks
the ground-truth one (the row whose exact text is `disturbances`, then the
`border-radius: 10px` descendant), and the pane check reads the fourth block
back. Two more knobs land in the same file for §4: **`KENNEL_MAP`**
(`flat_plane` | `obstacle_terrain`, the card clicked by its label as
`verify-export.py` does) and **`KENNEL_HPIPM_MODE`** / **`KENNEL_CONDENSED`**
(the MPC drawer opened with `__click('MPC')`, the field set, `__click('close')` —
`verify-scope.py:60–66`'s mechanics), each optional and each read back from the
YAML pane. Knobs, not arguments; the driver passes them through (`do_compose`,
`:1137`), and the runbook's §4 gains the rows.

### 3.5 Record

`demo/scenarios.md` (new) **§s004**: one subsection per step with what is
asserted, the measured numbers from the second run, the bypass for step 5, the
SAP finding, and the exclusion list verbatim. `demo/runbook.md` §3 gains the
two `scenario` rows under *Also there when needed* (they are tests, not demo
phases) and §1 one sentence; `docs/README.md` one line; `CLAUDE.md`'s repo map
row for `demo/` names `scenarios.md`.

---

## 4. Step 13 — #70, the sweep and the stress preset

### 4.1 `stack/verify/tools/k14-solve-probe.py` — CONTAINER, the instrument

`scratchpad/probe/probe-solve.py`, given the header block, the monitor's CLI
(`--sim-seconds N [--label L]`) so that **`KENNEL_MONITOR=/tmp/k14-solve-probe.py
kennel-bridge.sh observe 20 --label <point>`** runs it with no change to the
bridge script, and the `KENNEL_MEASURING` / `KENNEL_JSON` markers. It subscribes
`/clock` (RELIABLE), `/solve_time`, `/wbc_solve_time`, `/controller_heartbeat`
(BEST_EFFORT — the controller's `QOS_BEST_EFFORT_NO_DEPTH`), `/quad_state`
(RELIABLE), and prints one line:

```json
{"label": L, "sim_window": 20.0, "wall_window": 9.5, "rtf": 2.16,
 "mpc": {"n": 2050, "mean_ms": 1.12, "p50_ms": 1.00, "p95_ms": 1.77, "max_ms": 4.53,
         "over_10ms": 0, "iters_mean": 13.3, "acados_return_nonzero": 0},
 "wbc": {"n": 10212, "mean_ms": 0.094, "p95_ms": 0.132, "max_ms": 1.48, "over_2ms": 0, "fail": 0},
 "hb_deltas": {"num_mpc_solver_overtime": 0, "num_mpc_solver_fail": 0, "num_wbc_overtime": 0,
               "num_wbc_solver_fail": 0, "num_early_contacts": 75},
 "z_median": 0.261, "z_min": 0.188, "tilt_over_frac": 0.198}
```

Exit `0` · `2` no `/clock` or `/quad_state` within 20 wall-s; the window is
bounded by `N / 0.2 + 30` wall-s like the monitor's. `kennel-bridge.sh`'s
header lists it beside the monitor under `KENNEL_MONITOR`; `do_teleop` does
**not** stage it (the sweep and the verbs stage what they use).

### 4.2 `stack/verify/tools/k14-sweep.sh` — HOST, the table

```
k14-sweep.sh [--points FILE] [--out DIR]      # default points: the 18 below; DIR = stack/stress/evidence/sweep-<stamp>/
```

Per point: `compose` with the knobs (`KENNEL_SOLVER`, `KENNEL_RATE`,
`KENNEL_HPIPM_MODE`, `KENNEL_CONDENSED`, `KENNEL_MAP` — §3.4) → `transfer` →
`launch` → `verify` → **its exit code is recorded, never fatal** (a terrain
point that falls during the recipe's trot is a data point, and `run` would stop
there) → `walk` → `KENNEL_MONITOR=/tmp/k14-solve-probe.py kennel-bridge.sh
observe 20 --label <point>` → `walk stop` → one CSV row:

`point,solver,hpipm_mode,condensed,rate,map,rtf,mpc_mean_ms,mpc_p95_ms,mpc_max_ms,iters,over_10ms,overtime_d,mpc_fail_d,wbc_p95_ms,wbc_over_2ms,walked,fell,verdict,run`

`overtime_d`/`mpc_fail_d` come from **both** the probe's `hb_deltas` and
`verify.json`'s `headline` (two windows, both recorded); `walked`/`fell` are
check 8 / check 9's status; `verdict` is `verify.json`'s. The run folder is
kept under the evidence dir (the four artifacts + `verify.json`), so every row
is reproducible by `kennel-demo.sh run <folder>`. Bounded per point by the
tools' own bounds; a point whose `launch` fails is recorded as `launch-failed`
and the sweep continues. Exit `0` every point produced a row · `1` a point could
not be measured · `2` could not start (no guest, no Chrome, the console port).

The default points — the issue's knobs, pruned to the cells that differ in
mechanism (`composer-scope.md` §2's 2×2 makes the others duplicates): rate
{1.0, 0} × { `PARTIAL_CONDENSING_HPIPM` SPEED/5, ROBUST/5, SPEED/1, SPEED/10;
`FULL_CONDENSING_HPIPM` ROBUST; `PARTIAL_CONDENSING_OSQP` 5, 1, 10;
`FULL_CONDENSING_QPOASES` } = **18 points ≈ 100 min unattended**; then the red
candidate **three times**: obstacle terrain at the demo's default composition
(OSQP, rate 1.0 — three more rows, `fell` counted). The one widening the plan
already measured (`mpc_warm_start: 0`, §0.2) is not composable; it is recorded
from §0's run with the scratch method named (a hand-edited copy of a run
folder, a **bypass** of the generation path, kept out of the tool).

### 4.3 The decision rule, written before the sweep runs

An **amber** composition exists iff some flat-plane point has `mpc_p95_ms ≥ 7`
(the console's amber threshold, `~3011`) **or** `overtime_d > 20` per 20 sim-s
(check 7's budget) **and** `walked` with no `fell`. A **red** composition is
one that `fell` on ≥ 2 of 3 runs. From §0.2 the expected table has no amber
row; the plan proceeds on that and §9.1 states the other branch.

`KENNEL_PRESET=stress` (`kennel-demo.sh`, read in the knobs region beside
`SOLVER`/`RATE`): `stress` → `KENNEL_MAP=obstacle_terrain` with the solver and
rate left at their knobs (the measured red composition); empty → nothing;
anything else → exit 2 naming the one preset that exists (#72 adds the rest).
`compose` and `all` honour it; `run` needs nothing (it launches what was
composed). If the three terrain runs fall **fewer than two** times, the preset
still ships as *the composition that falls most*, `stress.md` says the rate, and
§9.1's second branch applies to s003.

### 4.4 `stack/stress.md` — the record

Numbered so the verbs and `demo/scenarios.md` can cite it: **§1** the four
§0.2 points as the pre-measurement that shaped the plan; **§2** the sweep table
(all rows, the CSV linked, the point list and the pruning); **§3 the finding** —
*the MPC solve margin at this pin cannot be degraded by any composed
configuration on the 8-vCPU reference guest; the deadline is wall-clock and the
simulator's "as fast as possible" is 2.2×* — with the mechanism (§0.3) and the
retirement path (an upstream MPC horizon / dt **parameter**, or a slower
reference host, either of which makes the sweep worth re-running); **§4 the red
preset**: `KENNEL_PRESET=stress`, its three runs with their `verify.json`
verdicts and traces, the fall rate; **§5** the two incidental observations and
the limits (§9.7). Evidence under `stack/stress/evidence/`.

---
## 5. Step 14 — #71, `scenario diagnose`

### 5.1 Shape

`demo/tools/scenario-diagnose.sh`, the same lib and page driver as §3.1. It
owns its composition: `KENNEL_PRESET=stress kennel-demo.sh compose` once
(disturbances **off** — s003 induces nothing through the service; the toggle
stays at its default so the run is the plain red composition), then **up to
three attempts**, each a fresh `transfer` → `launch` (never `run`: the recipe's
own trot would fall on terrain and stop the chain at `verify`, and the fall has
to happen under the console's eyes). It never loops until green: three
attempts, a count, an exit code from the count.

The walk is commanded from the page with the **joystick centred**, as the issue
says: `gait WALKING_TROT` through the picker (→ `active`), then `vx 0.3` through
the `vx [m/s]` input — the same 0.3 m/s check 8's band is tuned for, published
by the page at 20 Hz, ramped by the page. Nothing else publishes: `teleop`
stopped any held trot.

### 5.2 One attempt

| # | Step (`scenarios.md` s003) | Does | Asserts — and from which witness |
|---|---|---|---|
| 1 | healthy | `teleop`; `boot`, `connect` → `driving`; `health 01-health-green.json` | every block `green` or `off` (adaptation is `off` by composition); `__stat('mode') == live`; no banner; `shot 01-green.png` |
| 2 | induce stress | `gait WALKING_TROT`, `vx 0.3`; `observe 60 --rows` in the background; the page polled at ~2 Hz for `FALL DETECTED` **and** `health` sampled into `02-tint-history.jsonl` on every poll (time, the six levels) | the robot walks on terrain: within the first 5 sim-s `x_travel > 0` (from the rows). The attempt's outcome is decided here: **fell** (banner within 60 sim-s) or **no-fall** (60 sim-s without one — the trot-in-place outcome `transfer.md` §6.3 saw) |
| 3 | MPC green → amber | from the tint history | `mpc` was `green` at least once **before** the fall; `mpc` reached `amber` before the fall — **`[BYPASS]` by default** (§5.4): counted and printed, asserted only when `KENNEL_S003_EXPECT_MPC_AMBER=1`; `gait` or `contact` or `swing` reached `amber` before the fall — asserted (early contacts are what terrain produces); every block is `red` at the fall (`down` → red, `~3024`) |
| 3f | the feed's deadline line | `feed 03-feed.json` at the fall | `≥ 1` line matching `^MPC missed its 10 ms deadline` with a measured ms and `iters` — **`[BYPASS]` by default** (§5.4), counted; `MPC solver failed (…)` lines counted too (a tumble may make the QP infeasible: the mock's own narrative, and `dashboard.md` §5 saw 104 WBC fails in a real tumble) |
| 4 | contact mismatches | the same feed | `≥ 1` line matching `^(Early\|Late) contact (FL\|FR\|RL\|RR) [−+]\d+ ms vs planned touchdown$` **before** the `FALL:` line |
| 5–6 | the fall, the banner, the pin | `banner`; the feed | `FALL: <trigger> — <values> — controller latched to damping mode` is the **last** pinned line; `pinned · last 5 s before fall` in the DOM; every pinned row's `t` in `[fallAt − 5.05, fallAt + 0.05]`; the earliest pinned row's `t ≤ fallAt − 2` (the window holds more than the fall itself — the mock's suite asks for ≥ 2 entries; five seconds of a tumbling robot has dozens); the guest agrees: `tilt_over_frac > 0.15 \|\| z_min < 0.15` over the window; `shot 03-red.png`; `shot 02-amber.png` taken at the first poll that saw any `amber` |
| 7 | the order | the pinned rows | in `t` order: every deadline/solver-failed line (if any) and every contact line precede `FALL:`; contact lines are present; **the pinned window is the post-mortem, read from the DOM, not a screenshot** |
| 6v | the verdict | `release` (vx 0), `disconnect`; `kennel-demo.sh verify` → exit 1 expected; copy `verify.json` to `04-verify-attempt-<n>.json` | `verdict: fell`; `headline.early_contacts > 0` recorded |
| 6r | the Runs view | `connect` again; `runs 05-runs.json` | the applied run's row says `fell` with its counters; `/api/runs` (curl) agrees |
| 8 | reset | `reset`; `observe` until standing (bounded, §3.2 row 4) | standing in `[0.25, 0.35]`; `nobanner`; the two reset lines in order; the Runs row **still** `fell`; the simulator still in the process table — else the SAP finding, exit 1 |

A **no-fall** attempt records its 60-s trace and tint history, `release`,
`disconnect`, `kennel-bridge.sh recover`, and moves on. After three: `fell k of
3`; exit `0` if `k ≥ 2` and every fell-attempt's asserted rows passed; `1`
otherwise — with the traces attached, never a fourth attempt. The verb prints a
per-attempt block so a 1-of-3 is readable as what it is.

### 5.3 The tint-history witness — a DOM attribute, appended

The health cards (`~409`) are DOM already, but the level is only a colour. One
attribute appended to the card's `<div>`: **`data-lvl="{{ h.lvl }}"`** (the
mapped object gains `lvl: down ? 'red' : h.lvl` beside `dot`). `__health()` is
then `[...document.querySelectorAll('[data-lvl]')].map(d => [d.querySelector('div + div > div').textContent.trim(), d.dataset.lvl])`
— the block name and its level, six pairs. No element is added ahead of
anything; the dashboard suite's `deadline 10 ms` text is untouched.
`dashboard.md` §4 records it as the fourth DOM witness beside the counter strip.

### 5.4 What is asserted and what is measured — the `[BYPASS]` rows

§0.2 says the MPC block will not go amber and the feed will hold no deadline
line on this guest, and the sweep (§4) either confirms that in a table or
finds the composition that changes it. The verb is written for **both**
outcomes without a code change:

- `KENNEL_S003_EXPECT_MPC_AMBER` (default from `stack/stress.md`'s finding:
  `0`) and `KENNEL_S003_EXPECT_DEADLINE` (default `0`): at `0` the rows print
  `[BYPASS] 3 mpc-amber -- measured: never before the fall; stack/stress.md §3
  — not reachable by composition at this pin on this host` and do not count in
  the exit code; at `1` they are ordinary checks. The row is **printed either
  way**, with the measured count, so the transcript is complete against the
  scenario's TVP and a run that does produce a deadline line shows it as a
  PASS-shaped measurement. This is a knob whose default is a measured fact,
  not a flag that waives a check — the difference is that `stress.md` names
  the number that would flip it.
- The contact-mismatch line, the FALL line, the order, the pin window, the
  verdict, the Runs row, the reset — **always asserted**.

`demo/scenarios.md` §s003 records step 3 as a **bypass**: *induced MPC
degradation is not a composed configuration at this pin on the reference host;
what the red preset induces is contact stress (early contacts on terrain) and
the fall; retirement: the same as `stress.md`'s.* `plan/scenarios.md` is not
edited (design §7: *scenario docs change only if implementation forces a
contract deviation — note it*; the note is `demo/scenarios.md`'s, and the
milestone's close-out step 24 collects bypasses).

### 5.5 Record

`demo/scenarios.md` **§s003**: the per-attempt table with the measured
numbers (which attempts fell, at what sim time, the first amber block and when,
the deadline/solver-fail counts, the contact-line counts, the pin window's
bounds, the reset's standing height), the bypass, the evidence files.
`kennel_console/dashboard.md` §4 (the `data-lvl` witness), §6 (*inject* done;
the tint history readable). Runbook and README rows as §3.5.

---

## 6. Live-guest protocol — in this order

`EV` is the evidence directory named per row; every transcript opens with
`=== what ===` and `date -u +%FT%TZ`, captured with `2>&1 | tee`; `G` is the
guest ssh. Negative controls **before** the code that changes them. Every
file's header line names the composed rate. The sweep (rows 10–11) runs
unattended and should be started as soon as commit 1 exists — it needs only the
launcher and the knobs, and it is two hours.

| # | Do | File | Must show |
|---|---|---|---|
| 0 | `kennel-demo.sh status`; `G sudo docker exec dfki_quad ps -e -o comm=,args=`; `ls ~/kennel-runs` | `stack/bridge/evidence/live/21-before.txt` | the §0 state: applied run `run-20260907T202843Z`, six nodes, no disturber, no pidfiles |
| 1 | **negative control, before commit 1**: `G` start `ros2 run simulator sim_disturber` detached by hand (the §0 way); `kennel-demo.sh verify` | `22-verify-extra-disturber.txt` | `[FAIL] 1 node-graph … extra: /disturbance_node`, `pass=9 fail=1` — the knob's reason; then `G sudo docker exec dfki_quad pkill -KILL -x sim_disturber` |
| 2 | commit 1 in place: `KENNEL_DISTURBANCES=1 kennel-demo.sh compose` (rate **1.0**), `run` | `23-run-block4-rate10.txt` | the launcher: `shell 4 -> /tmp/p21-disturber.log`, `/disturbance_node in the graph`, `/disturb_simulation served`; `verify`: `expect disturber 1 (from run-…/run.json)`, `pass=10 fail=0` with the seven-node criterion; `walk` holding |
| 3 | **the clock of `time`**: `KENNEL_DISTURBANCES=1 KENNEL_RATE=0.5 compose`, `run`; `observe 8 --rows` in the background, then from `G` an rclpy client (the §0 probe, staged to `/tmp`) `force [100,0,0] time 0.2`; read `disturbance.sim_gap` and `wall_gap` | `24-disturb-clock-rate05.txt` | with `use_sim_time:=true`: `sim_gap ≈ 0.20`, `wall_gap ≈ 0.40`, response ≈ 0.40 s wall → **keep the argument** (`time` is sim seconds; the console label says *s (sim)*). If instead `sim_gap ≈ 0.10`, `wall_gap ≈ 0.20`: the sleep ignores sim time → **drop the argument** from block 4, label *s (wall)*, and record it. Either way the number goes in `teleop.md` §13 and `mapping.md` §4.6 |
| 4 | teardown by name: with the rate-0.5 stack up and the disturber running, `kennel-demo.sh down` **without** `teleop stop` | `25-down-reaps-disturber.txt` | after `down`: no `sim_disturber` in `ps`, no `ros2 run` wrapper, `/disturbance_node` gone from the graph within 20 s; then `run` again at **rate 1.0** (the rest of the protocol runs there) |
| 5 | commit 2 in place, #68 from the console: `teleop`; connect; fields 100/0/0/0.2; `inject`; `observe 8 --rows` started first; then 0/300/0/0.3 | `26-inject-live.txt`, `26-feed.txt`, `26-moderate.png`, `26-fall.png` (`dashboard-shot.sh --connect` or the page driver's `shot`) | the DOM's `disturbance requested` → `done`; the feed's `Disturbance: 100 N for 0.20 s at body CoM (100, 0, 0)`; guest `force_max_norm 100.0`, the stagger (§0.1's numbers or better); then the fall: `FALL DETECTED`, the `Disturbance: 300 N` line inside the pinned window before `FALL:`; `/simulation_disturbance` echoed on `G` (`ros2 topic echo`, two messages per push) |
| 6 | the guard: `teleop stop`; apply the maintainer's run (disturbances off) with `kennel-demo.sh run ~/kennel-runs/run-20260907T202843Z`; `teleop`; connect; `inject` | `27-inject-guarded.txt` | no call on the wire (the bridge's log at `/tmp/k13-bridge.log` shows no `call_service` for `/disturb_simulation`; `observe` shows `disturbance null`); the feed names the run and *disturbances off* |
| 7 | **#69 cold**: `kennel-demo.sh reset`; `KENNEL_DISTURBANCES=1 compose`; `run` | `demo/evidence/s004-disturb/00-reset.txt`, `01-run.txt` | `12/12 PASS` from the revert; `pass=10 fail=0` on a cold container with block 4 |
| 8, 9 | `kennel-demo.sh scenario disturb` **twice** | `02-scenario-1.txt`, `03-scenario-2.txt`, the traces, renders and diffs | both `ALL CHECKS PASSED`; six empty diffs each; `verify.json` `fell` then the reset's standing height; the second run's numbers are the record's |
| 10 | **#70**: `k14-sweep.sh` (18 points, unattended) | `stack/stress/evidence/sweep-<stamp>/` — the CSV, every run folder, every `KENNEL_JSON` line | eighteen rows; the expected shape is §0.2's; any row with `mpc_p95_ms ≥ 7` or `overtime_d > 20` is **the finding** and flips §9.1 |
| 11 | the red candidate ×3: `KENNEL_PRESET=stress compose`; `run` three times (each `verify` exit recorded, not fatal); the probe each time | `stack/stress/evidence/red-{1,2,3}.txt` + the three `verify.json` | `fell` on ≥ 2 of 3 — or the measured rate, honestly, and §9.1's second branch |
| 12 | **#71 cold**: `reset`; then `kennel-demo.sh scenario diagnose` | `demo/evidence/s003-diagnose/00-reset.txt`, `01-scenario.txt`, per-attempt traces, tint histories, feeds, renders, `verify.json` copies | `fell k of 3` with `k ≥ 2`; on each fell attempt the asserted rows green and the `[BYPASS]` rows printed with their counts; the pinned post-mortem verbatim in `01-scenario.txt` |
| 13 | `scenario diagnose` once more on the **same** stack (no reset) | `02-scenario-warm.txt` | green again — the reset step really restores the terrain world's spawn |
| 14 | non-interference: with the disturber up and the bridge up, `verify-teleop-live.sh` (`KENNEL_LIVE_QUICK=1`) | `stack/bridge/evidence/live/28-live-suite-with-disturber.txt` | green — check 1's criterion names the seven; the watchdog's intervention count unchanged by two pushes |
| 15 | the eight console suites on the host; `git status --porcelain` | `demo/evidence/s003-diagnose/09-suites.txt` | eight greens (`teleop`, `generate`, `export` with their new counts); nothing but the intended files changed |

Row 3 is where block 4's text is settled. Row 10 is where §9.1 is: if a row
flips it, `stress.md` names the composition, `KENNEL_PRESET=stress` becomes
*that composition on terrain* (the issue's own red), and rows 12–13 run with
`KENNEL_S003_EXPECT_MPC_AMBER=1 KENNEL_S003_EXPECT_DEADLINE=1` and the bypass
paragraph is not written. Row 11 is where §9.1's second branch is. Row 8 is
where the SAP crash mode would show if it is reachable from a fresh fall: if a
reset ever kills the simulator on a young stack, the finding moves from *stale
state* to *reset after a tumble*, and the verbs' reset step is preceded by
`/set_damping_mode` unconditionally only if the transcript proves that is what
avoids it — measured, not guessed.

---

## 7. Records and doc touches

| File | Change |
|---|---|
| `demo/scenarios.md` | **new** — §s004, §s003 (§3.5, §5.5); the exclusion list; the bypasses (step 5 of s004, step 3 of s003) with retirement paths; the SAP finding; the evidence index |
| `stack/stress.md` | **new** — §4.4 |
| `kennel_console/teleop.md` | **§13 The disturbance over the bridge** (§2.8); §10's *inject* limit struck with a pointer |
| `kennel_console/dashboard.md` | §4 the `data-lvl` witness; §6 *inject* done, the two step buttons remain (`manually_step_sim` fixed — a pointer to `demo/scenarios.md`'s s004 step-5 bypass) |
| `kennel_console/generate.md` | §1.4 the toggle's generation policy; §3 the fourth block; §4 group 10 |
| `kennel_console/export.md` | §3 `run.json`'s eighth key, when it appears; §4 group 8 |
| `kennel_console/composer-scope.md` | §1.1 the `disturbances` row; §1.2 unchanged (`manually_step_sim` stays fixed) |
| `stack/composed-run.md` | **§10 Block 4** (§2.8); §9.2's copy registry unchanged (say so) |
| `stack/mapping.md` | §4.6 appended: retired within the MVP, the upstream retirement kept; the `time` clock finding (row 3) |
| `stack/verify.md` | §2 check-1 row and the paragraph under the table: the disturber knob; §7 the report's `knobs` |
| `stack/bridge.md` | §5.1 the `/disturb_simulation` row; §6 the second knob; §11.3 one sentence — a push does not make the watchdog fire (row 14) |
| `stack/launch.md` | §6 one line: a seventh node when composed with disturbances; §7 gains **trap 8** — *a pidfile of a `ros2 run` wrapper reaps the wrapper, not the node* (§0.1) |
| `demo/runbook.md` | §1 one sentence; §3 the two `scenario` rows; §4 knobs `KENNEL_DISTURBANCES`, `KENNEL_MAP`, `KENNEL_HPIPM_MODE`, `KENNEL_CONDENSED`, `KENNEL_PRESET`, `KENNEL_S003_EXPECT_*`; §5 rows: *verify says `extra: /disturbance_node`* (the knob), *inject says disturbances off*, *the simulator died after reset* (the SAP finding, `launch`), *`scenario diagnose` says fell 1 of 3* |
| `docs/README.md` | Demo section: `demo/scenarios.md`; Stack section: `stack/stress.md` |
| `CLAUDE.md` | repo map: `demo/` row names `scenarios.md` and the two verbs; `stack/` row names `stress.md`; the console row's *eight suites* count is unchanged (the scenario verbs need a VM, like the live suite). One new rule only if the protocol earns it (§9.9) |
| `plan/scenarios.md`, `plan/design/seq.*` | nothing — the deviations are recorded in `demo/scenarios.md`, as design §7 asks |

---
## 8. The PR

### 8.1 Body skeleton (house style: PRs #59, #79, #80, #81)

```
feat(scenarios): the two scenarios — the disturbance path over the bridge, s004 and s003 as driver verbs, the MPC margin measured and the stress preset recorded

Closes #68, closes #69, closes #70, closes #71. Plan: plan/two-scenarios.md.
Four issues in one PR at the maintainer's request: they are steps 11–14 of the
milestone, #68 is the mechanism both scenarios drive, #70's table is what #71
can assert, and the two verbs share one page driver. The milestone's default of
one issue per PR is unchanged.

## What is here            — table: file → what changed (block 4 end to end; the console's toggle and inject; the two scenario verbs, the lib, the page driver; the sweep and the probe; kennel-bridge.sh untouched but reused; the records)
## Measured on the live guest — the pushes (100 N: stagger and recovery; 300 N: the fall) with the service's block time; the process table identical around every step, twice; the MPC margin across the sweep (the table's extremes); the red preset's fall rate; the clock of `time`; s003's per-attempt numbers
## Findings from the live protocol — the orphan behind a ros2-run pidfile; /reset_sim's SAP crash mode from a stale collapsed state; the deadline sits 10× above every composed configuration; whatever rows 3, 8, 10, 11 found
## Corrections to the plan, from measurement — say "none" otherwise
## Verification            — §8.2 with outputs; the two verbs twice each; the sweep's row count; the eight suites with their counts
## Bypasses                — s004 step 5 (manual stepping; /step_sim); s003 step 3 (induced MPC degradation; the retirement); the hand-edited warm-start point (a measurement outside the generation path)
## Still open              — the human friction session from #65 is still the maintainer's; nothing new
## Decisions               — §9, one line each, with where each is recorded
## Records                 — demo/scenarios.md, stack/stress.md, the touches of §7
```

### 8.2 Verification list — every line with its output in the PR

```bash
bash -n demo/tools/kennel-demo.sh demo/tools/scenario-*.sh stack/verify/tools/k14-sweep.sh stack/composed-run/tools/p21-launch-from-commands.sh stack/verify/kennel-verify.sh stack/known-good/tools/k13-stop.sh kennel_console/*.sh
python3 -m py_compile kennel_console/*.py demo/tools/*.py stack/verify/tools/*.py stack/bridge/tools/*.py
for s in serve scope generate export send teleop dashboard runs; do ./kennel_console/verify-$s.sh; echo "verify-$s exit=$?"; done     # eight greens
git diff --stat main -- kennel_console/verify-{serve,scope,send,dashboard,runs}.*                                                     # nothing: five unmodified
for f in verify-teleop verify-generate verify-export; do git diff main -- kennel_console/$f.py | grep '^-' | grep -v '^---'; done       # nothing removed
demo/tools/kennel-demo.sh scenario disturb; demo/tools/kennel-demo.sh scenario disturb                                                 # green twice (rows 8, 9)
demo/tools/kennel-demo.sh scenario diagnose                                                                                            # fell k of 3, k >= 2 (row 12)
wc -l stack/stress/evidence/sweep-*/sweep.csv                                                                                          # 19 lines: header + 18 points (+ 3 red)
for t in stack/bridge/kennel-bridge.sh stack/composed-run/tools/p21-*.sh; do diff <(sed -n "/^ENV_CHAIN='/,/^cd \/root\/ros2_ws'$/p" "$t" | sed "s/^ENV_CHAIN='//; s/'$//") <(grep -v '^#' stack/known-good/tools/prelude.sh | grep -v '^$') && echo "$t chain identical"; done
grep -n 'new WebSocket' "kennel_console/Kennel Console.dc.html"           # exactly one
grep -n 'await' "kennel_console/Kennel Console.dc.html" | grep -i disturb # nothing: the call is never awaited
grep -c "sleep" demo/tools/scenario-*.sh stack/verify/tools/k14-sweep.sh   # poll intervals inside bounded loops only; name each
grep -n 'sim_disturber' stack/known-good/tools/k13-stop.sh                 # the name in the sweep
git status --porcelain                                                     # only the maintainer's slides/ entries, untouched
```

### 8.3 Acceptance, all four

| Issue | Criterion | Proof |
|---|---|---|
| #68 | a run composed with disturbances on launches four blocks and verifies `pass=10 fail=0` with the knob; `inject` from the console pushes the real robot and the feed says so; a run composed with it off is unchanged byte for byte | rows 2, 5; `verify-export.py` group 8; `26-*`, `23-*` |
| #69 | `scenario disturb` green twice in a row from a `reset` guest, the process set identical in every capture | rows 7–9; `02-`/`03-scenario-*.txt`, `06-process-diffs/` |
| #70 | one table, measured; two compositions picked **or the negative result recorded and stopped**; `KENNEL_PRESET=stress` for `compose`/`all`; three runs of the red preset with their verdicts | rows 10–11; `stack/stress.md`; the acceptance's *amber shows overtime Δ > 20 on three runs* is **not met** on this host and the record says why (§0.2, §4.4) |
| #71 | `scenario diagnose` green from a `reset` guest; every s003 TVP observable asserted from the page or the run folder — the MPC-amber and deadline observables **measured and printed as `[BYPASS]`** with the finding, the rest asserted | rows 12–13; `demo/scenarios.md` §s003 |

---

## 9. Decisions this plan makes that the issues did not

Stated so the implementer knows what is the maintainer's text and what is this
plan's call — revert the call, not the issue, if measurement says otherwise.

1. **The negative result is the basis, and the branch is written down.** §0.2
   measured four points at 1.1–1.3 ms against a 10 ms deadline; the plan builds
   #70 on *"record the negative result and stop"* and #71 on a red preset that
   induces contact stress, not solver stress. **If the sweep (row 10) finds a
   flat-plane row with `mpc_p95_ms ≥ 7` or `overtime_d > 20` that still walks**,
   that composition is the amber preset, `KENNEL_PRESET=stress` is *it on
   terrain*, rows 12–13 run with both `KENNEL_S003_EXPECT_*` knobs at `1`, and
   the bypass paragraphs are not written. If the red candidate falls on fewer
   than two of three runs (row 11), the preset ships as the composition that
   falls most, the rate is recorded, and `scenario diagnose` reports what it
   measured — the plan does **not** fall back to injecting a push inside s003,
   because that would make s003 a copy of s004 and the record would say the
   stack degraded when a service pushed it.
2. **Block 4 has no pidfile and is reaped by name**, like the simulator and the
   leg driver (§2.4). The issue's `/tmp/k13-disturber.pid` was tried and it
   holds the `ros2 run` wrapper; the binary outlived two relaunches (§0.1).
3. **Block 4 is launched last, after the six-node graph is complete**, with its
   own two-signal wait (node and service). `EXPECTED_NODES` is unchanged; the
   six-node wait is unchanged.
4. **`--ros-args -p use_sim_time:=true` on block 4**, so `time` is a sim-second
   like every window in this repo — decided by §6 row 3: kept if the two gaps
   say sim time, dropped and labelled *wall* if they do not.
5. **`run.json` writes `disturbances` only when on**, as an eighth key after the
   seven; off is byte-identical to today. The composer's first choice that lives
   in no YAML; `cfgFromYaml` does not pretend to recover it.
6. **The `inject` guard reads the newest run of `/api/runs`**, the convention the
   status bar already uses, because the console cannot know which run the guest
   has applied; the stack's own `result: false` on a missing service is the
   second guard, and the feed names the toggle either way.
7. **Limits, stated now**: the process-table compares `comm` + `args`, not pids
   — a restart that reproduces the same command line is invisible to it, and
   the record says so; the exclusion list is printed and is a safety net, the
   mechanism is capturing between steps; the clock of `time` is measured at one
   rate (0.5) and inferred for the rest; the sweep's 18 points prune the issue's
   grid by `composer-scope.md` §2's 2×2 (the pruned cells are duplicates in
   mechanism, not in name); the two `[BYPASS]` rows are knobs whose defaults are
   measured facts; the scenario verbs need a VM and are not among the eight
   no-VM suites.
8. **s004's velocity change is the stick; s003's walk is the `vx` input with the
   stick centred** — the issue's wording for each, and two different code paths
   exercised.
9. **A new `CLAUDE.md` rule only if the protocol earns it.** The candidate, from
   §0.1, is *"a pidfile holds the process the node runs in, never a wrapper's
   — `ros2 run` is a wrapper"*; it lands in `launch.md` §7 as trap 8 regardless,
   and becomes a house rule only if a second instance turns up in this pass.
10. **The scenario verbs are HOST tests beside the driver**, dispatched by
    `kennel-demo.sh scenario <name>`, sharing one sourced bash lib and one page
    driver whose JS helpers are **copied** from the suites, never imported.
11. **The red preset is never run through `run`** inside a verb: `transfer` +
    `launch`, then the page commands the walk, so the fall happens under the
    console and `verify` runs afterwards as the verdict mechanism — its exit 1
    is the expected exit there, and the verb reads `verify.json`, not the code.
12. **Every verb session starts from a fresh launch, and a dead simulator is a
    red result, not a retry** (§0.1's SAP finding). `recover` at exit is
    best-effort and bounded.
13. **`tau` is always zero** on the wire; the Interventions row has no torque
    fields and the record says a torque is not part of the MVP surface.
14. **The tint history is a DOM attribute** (`data-lvl`) appended to the health
    cards — the fourth DOM witness beside the counter strip, so a level is a
    string a suite reads and not a colour it guesses at.
15. **`manually_step_sim` stays fixed** and s004 step 5 is a printed `[BYPASS]`
    line, so the transcript numbers the scenario's steps completely.
16. **The `use_sim_time` measurement, the pushes' magnitudes (100 N / 0.2 s and
    300 N / 0.3 s) and the 20 % velocity band** are the numbers from §0.1 and
    PR #81, cited where they are used; the verbs take them from knobs
    (`KENNEL_S004_PUSH_MODERATE`, `KENNEL_S004_PUSH_SEVERE`, `KENNEL_S004_VX_TOL`)
    whose defaults are those numbers, so a heavier robot at a later pin is a
    knob and not an edit.

## 10. Don'ts

- Don't `await` the disturbance call anywhere, and don't put its callback in
  the tick's path; the fake's 2-s delay is what proves it.
- Don't start the disturber from the console, from `teleop`, or from anything
  but block 4 of `commands.txt` through the launcher — s004 step 6 is the
  design's hard constraint and the verb measures it.
- Don't record a `ros2 run` wrapper's pid as if it were the node's.
- Don't `sleep` to wait — `observe` measures in sim seconds; the block-4 wait is
  a bounded poll of two observables; the post-reset wait is `recover`'s shape.
  The 2.5-s page boot settle the suites use is the only tolerated `sleep`, and
  the verbs name it.
- Don't run `verify` while the page is driving (checks 6–9 publish their own
  trot) — the verbs `disconnect` first, every time, and reconnect after.
- Don't let `run.json` carry `disturbances: false` — off is *absent*, and the
  export suite's exact-seven check is the guard.
- Don't reorder anything in the console; don't add an element whose exact text
  duplicates a label the suites click; don't change the `Disturbance:` grammar
  line, the `deadline 10 ms` strip text, or the reset lines.
- Don't modify the five other console suites, the seven checks' thresholds in
  `kennel-verify.sh`, or `p21-launch-from-commands.sh`'s six-node wait — the
  tolerated set and the fourth block are the only changes.
- Don't tune the pushes until the robot falls "more nicely", and don't tune the
  fall rule — 300 N / 0.3 s is the measured felling push and the rule is
  `verify.md` §4's.
- Don't make `scenario diagnose` loop until it sees a fall; three attempts, a
  count, an exit code.
- Don't inject a push inside `scenario diagnose` to get the fall s003 wants.
- Don't compose obstacle terrain into anything but the stress preset; the
  demo's default stays the flat plane (`runbook.md` §3.1).
- Don't run the sweep with a page connected or a trot held from another verb;
  it owns the guest for two hours and says so at the top of its transcript.
- Don't add a fifth copy of the container source chain; the probe is a
  CONTAINER tool `kennel-bridge.sh observe` runs through `KENNEL_MONITOR`.
- Don't `git add -A` — the maintainer's `slides/` work is in the tree.
- Don't edit `plan/scenarios.md` or the sequence diagrams to match what was
  built; the deviations go in `demo/scenarios.md` and the milestone's step 24
  collects them.
- Don't leave the guest at rate 0 or on terrain at the end of a session; the
  last row of any protocol day is a `run` of the maintainer's flat-plane
  composition and a `walk stop`.
