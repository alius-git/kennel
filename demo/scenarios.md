# The verification scenarios, as driver verbs

> Implementation record for [issue #69](https://github.com/alius-git/kennel/issues/69)
> (s004.disturb) and [issue #71](https://github.com/alius-git/kennel/issues/71)
> (s003.diagnose). The mechanism both of them drive is
> [#68](https://github.com/alius-git/kennel/issues/68), recorded in
> [`stack/composed-run.md`](../stack/composed-run.md) §10 and
> [`kennel_console/teleop.md`](../kennel_console/teleop.md) §13.
>
> One sentence: two of [`plan/scenarios.md`](../plan/scenarios.md)'s ten
> scenarios are now commands — `kennel-demo.sh scenario disturb` and
> `scenario diagnose` — that drive the console against the running stack and
> assert every numbered step from a witness that can actually see it.

Measured on 2026-09-08 against the live guest (`kennel-vm` at `192.168.122.32`,
8 vCPU / 16 GiB, pin `dcf53c5`).

## 0. What a scenario verb is, and what it is not

It is a **test**, not a demo phase. `run` and `walk` show the product working;
a scenario asserts that a specific narrative in `plan/scenarios.md` is true of
it, step by numbered step, and exits `0`/`1`/`2` like every other suite here.
That is why `kennel-demo.sh help` lists the two under their own heading and
`runbook.md` §3 puts them under *Also there when needed*.

Three rules they inherit, and one they add:

- **Every number about the robot comes from the guest.** `kennel-bridge.sh
  observe` runs `k13-target-monitor.py` in the container and prints one JSON
  line; the verb reads that. A number read back out of the page under test is a
  number nobody should believe ([`dashboard.md`](../kennel_console/dashboard.md) §4).
- **Every fact about the page comes from the DOM**, through `scenario-page.py`,
  one named step per invocation, so the transcript interleaves what the operator
  did with what the stack saw.
- **The helpers are copied, not imported** — from `verify-teleop-live.py` and
  `verify-dashboard.py`. Each suite is meant to be readable on its own, and a
  shared helper that drifts breaks them all silently.
- **New here: the process table.** s004's Target Verification Point is that the
  console never started or stopped a process, and §1.5 is how that becomes a
  check rather than a claim.

Both verbs **leave the stack standing at `STAND` with the bridge down**, on
every path, including their failure paths — the trap disconnects the page, runs
`teleop stop`, and recovers the robot if it is on the floor.

---

## 1. s004.disturb — `kennel-demo.sh scenario disturb`

`demo/tools/scenario-disturb.sh`. **64 checks, one bypass.** Green twice in a
row: [`evidence/s004-disturb/02-scenario-1.txt`](evidence/s004-disturb/02-scenario-1.txt),
[`03-scenario-2.txt`](evidence/s004-disturb/03-scenario-2.txt).

It refuses to run unless the guest's **applied run was composed with
disturbances on** — `/disturb_simulation` is block 4 of that run's
`commands.txt` and does not otherwise exist — and it says how to make one.

### 1.1 The steps, and what was measured

| Step (`scenarios.md` s004) | Asserted from | Run 1 | Run 2 |
|---|---|---|---|
| **0** a defined starting state (§1.3) | guest | standing at **0.3140 m**, tilt 0 | **0.3139 m**, tilt 0 |
| **1** velocity change: commanded and measured converge | the stick (page) → guest | **0.4708 m/s** against 0.5 commanded, 3.76 m travelled | **0.4761 m/s**, 3.80 m |
| **2** moderate push → stagger and recover | `inject` (page) → `/simulation_disturbance` (guest) | **100.0 N** for **0.199 sim-s**; z dips to **0.2073 m**, no fall; speed back to **0.494 m/s** | 100.0 N for **0.200 sim-s**; z **0.2165 m**; **0.4987 m/s** |
| **3** severe push → fall, banner, post-mortem | guest **and** page | **300.0 N** for 0.3 s → z_min **0.0890 m**, body past 0.5 rad in **84 %** of samples; banner *attitude — tilt over 0.5 rad in 15 % of the last 2 s*; the `Disturbance: 300 N…` line is row 3 of 8 in the pinned window, `FALL:` is row 7 | z_min **0.1307 m**, **63 %**; disturbance row 2 of 5, `FALL:` row 4 |
| **3v** the verdict | `verify.json` | `unhealthy`, robot at z 0.269 m | `unhealthy`, z 0.202 m |
| **3r/4** the record, and the reset | page + `/api/runs` | the run's row carries its verdict; *reset sim* → standing at **0.3137 m**, sim clock **3.8 s**, feed: `/reset_sim called …` then `sim clock restarted at …`; the record still listed | standing at **0.3140 m** |
| **5** manual stepping | — | **BYPASS**, §1.6 | |
| **6** the process table | guest | **six captures, six empty diffs, 25 processes** | six, six, 25 |

The magnitude, not the vector, is what is compared: the disturbance node rotates
the requested force into the robot's yaw frame before publishing
(`disturbance_node.cpp:52-53`), so `[100, 0, 0]` arrives as whatever "forward"
was at that instant — measured `[99.6, 8.5, 0]` in one window and
`[99.9, -3.3, 0]` in another. The magnitude survives the rotation; the
components do not.

### 1.2 Two findings that changed what is asserted

**A disturbance fall is real and transient.** #69 asks for `verify.json` to say
`fell` after the severe push. Measured: pushed over at 300 N the robot reaches
z 0.089–0.131 m with the body past 0.5 rad in 63–84 % of samples — a fall by
[`verify.md`](../stack/verify.md) §4's own rule, and the console detects it and
pins the post-mortem. Then it **gets up**. In one window it was back at z 0.31 m
and walking eleven sim-seconds later, inside the same observation. So the
verdict `kennel-verify.sh` reaches afterwards is about the state during **its
own** window, which opens after that, and it varies with how far the robot got:
`completed` at z 0.31, `unhealthy` at z 0.21. The verb therefore **reports** the
verdict and asserts what is true either way — that a report was filed, for this
run, carrying a verdict the recipe defines. `fell` is what you get only if the
robot is still down when the recipe looks.

*Deviation from the issue, recorded rather than smoothed over. Retirement: none
needed — s004's own step 3 asks for "the fall banner and post-mortem behave as
in s003.diagnose", which is asserted in full. The verdict expectation was the
issue's addition.*

**The fall is not always the last line in the pinned feed.** The feed's
timestamps are 0.1-second sim bins and the pin holds `[fallAt − 5, fallAt]`, so
an event can legitimately share the fall's bin and render after it. What the
post-mortem has to be true about is **time**: nothing in the window happened
later than the fall. That is what is asserted.

### 1.3 A scenario needs a defined starting state — and why that is not a nicety

The first live run of this verb crashed the simulator. The process-table check
is what caught it: `< simulator …` in the diff, `/reset_sim` answering *Service
/reset_sim does not exist*, and in the container's log

```
[simulator-1] abort: Failure at multibody/contact_solvers/sap/sap_solver.cc:342
              in CalcCostAlongLine(): condition 'd2ellA_dalpha2 > 0.0' failed.
[simulator-1] Aborted (core dumped)
[ERROR] [simulator-1]: process has died [pid …, exit code 134, …]
```

The cause was the state the scenario started from, not the push. A stack left at
`STAND` after a walk can be **sitting on the floor at z 0.132 m with the body at
0.53 rad** — measured, on a stack launched minutes earlier — and a 100 N push at
a robot in that contact configuration aborts Drake's SAP solver. Isolated
afterwards on a freshly launched stack: the same push at 0.3 m/s and at 0.5 m/s,
twice each, left the simulator alive with `tilt_over_frac 0.0` both times.

So step 0 runs `kennel-bridge.sh recover` and then **asserts the state it starts
from** (z in 0.25–0.35 m, tilt over 0.5 rad in ≤ 2 % of samples), and refuses to
measure a scenario from anything else. It is the same lesson
[`bridge.md`](../stack/bridge.md) §10.7 records for the live suite — *a live
suite needs a defined starting state* — one scenario further on, and the second
independent case of `/reset_sim`-adjacent SAP aborts from a degenerate
configuration (the first is `plan/two-scenarios.md` §0.1).

`require_sim` exists for the same reason: if a step leaves no `/clock`, the verb
prints the finding and the relaunch command and stops. **A dead simulator is a
red result, never a retry.**

### 1.4 A defect in #66 that only a cold container showed

The first run of this verb from a freshly `reset` guest failed one check: the
gait picker sat at

```
gait WALKING_TROT sent — waiting for /gait_state
```

for the whole ten seconds the step allows — while the guest's own reading, two
lines later, confirmed `/gait_state`'s signature **was** `WALKING_TROT`. The gait
had taken; the page had not noticed.

The cause is an ordering bug in [#66](https://github.com/alius-git/kennel/issues/66)'s
`setGait`, and it needs a slow service response to show. `setGait` arms a
2-second timer that says **refused** if nothing has confirmed the change, and it
sends the `SetParameters` call through a helper whose response callback says its
message *unconditionally*. On a cold container the response came back **after**
the timer had already fired — so the late `sent` was painted over the `refused`,
and the picker was left showing a message its own state machine had abandoned.

The fix is the guard, and nothing else: say `sent` only while `sent` is still
what this gait is.

```js
this.link.call(CTRL_PARAM_SRV, CTRL_PARAM_TYPE, gaitArgs(name), m => {
  if (this.gaitWant !== name || this.gaitState !== 'sent') return;
  …
});
```

Worth stating plainly: **the no-VM suite could not have caught this.**
`fake-rosbridge.py` answers instantly, so the two orderings are the same
ordering there. It took a real bridge on a cold container — which is the argument
for running a scenario against the real stack at all.

### 1.5 The process-table assert — the TVP made mechanical

```bash
sudo docker exec dfki_quad ps -e -o comm=,args= --no-headers \
  | sed 's/  */ /g' | grep -vE "$HARNESS_RE" | sort
```

Six captures — before the page connects, and after each of velocity, moderate,
severe, verify and reset — each diffed against the first. **Every diff empty, in
both runs**, over 25 processes.

Three decisions worth stating:

- **`comm` and `args`, never pids.** A pid changes on every launch and would
  make every capture differ for a reason that is not the console's. The cost is
  a stated limit: a process restarted with the *same* command line is invisible
  to this. What it catches is anything started or stopped — which includes the
  simulator dying (§1.3).
- **The exclusion list is printed at the top of every transcript.** It removes
  only the harness's own instruments (`k13-target-monitor.py`, the probe,
  `kennel-verify.sh`'s `check.py`, the `ros2` CLI probes). An exclusion list is
  exactly where a check like this goes quietly wrong, so it is in the evidence.
- **Captures are taken between steps**, when nothing of ours is inside the
  container, so the list is a safety net rather than the mechanism.

The reference capture already contains the disturber, the bridge's three nodes
and the watchdog. All of them are stack processes started by `launch` and
`teleop`; none is the console's. That is the point of taking the reference
*after* `teleop` and *before* the page connects.

### 1.6 Step 5 — manual stepping · **bypass**

`manually_step_sim` is fixed at stock in the composer
([`composer-scope.md`](../kennel_console/composer-scope.md) §1.2), so the
simulator never creates `/step_sim` (`drake_simulator.cpp:529-547` guards it on
that parameter) and the console's two step buttons have nothing to call. The verb
prints

```
  [BYPASS] 5 manual-stepping -- manually_step_sim is fixed at stock …
```

so the transcript is complete against the scenario's own numbering rather than
silently missing a step.

**Retirement:** the composer offering `manually_step_sim`, then the two step
buttons calling `/step_sim` — a `StepSimulation` service that exists at the pin
and needs only the key. It is a composer-scope disposition change, not a stack
change.

---

## 2. s003.diagnose — `kennel-demo.sh scenario diagnose`

`demo/tools/scenario-diagnose.sh`. Unlike s004 it owns its own composition: it
composes the **stress preset** ([`stack/stress.md`](../stack/stress.md)),
launches it, and drives the walk from the page with the joystick centred — the
gait picker, then the `vx` field, published at 20 Hz.

**It never loops until green.** Three attempts, a count, and an exit code from
the count: #71's own words are *"it never loops until green, and a 0-of-3 is a
red result with the traces attached"*. It stops as soon as the bar is met,
because a third attempt after two falls measures nothing new and costs five
minutes.

### 2.1 What is asserted, and what is measured

s003 asks for a walk that degrades **visibly through the MPC** — the block going
green → amber, the feed carrying deadline violations with measured solve times
and iteration counts — and then falls.

The stress preset makes that happen, and it was picked from a measured table
rather than guessed at ([`stack/stress.md`](../stack/stress.md)):
`PARTIAL_CONDENSING_OSQP` at `mpc_condensed_size: 1` on the flat plane takes
**3.44–3.57 ms** per solve against **1.16** for the same solver at stock
condensing, peaks at **7.2–10.3 ms** — over the console's 7 ms amber line every
time — and falls, three runs of three.

| s003 step | Disposition |
|---|---|
| 1 healthy run, blocks green | **BYPASS** — §2.3: a composition is in effect from the first solve, so there is no green run to watch turn amber |
| 2–3 the MPC block reaches amber | **asserted over the attempts** (measured 2 of 3 — the console tints on the worst solve in a 100 ms bin, and not every bin crosses 7 ms). `KENNEL_S003_EXPECT_MPC_AMBER=0` turns it back into a measurement |
| 3 a deadline-violation entry with a measured value | asserted (`KENNEL_S003_EXPECT_DEADLINE`) |
| 3 *something* goes amber before the fall | asserted — the tint history has to move |
| 4 contact mismatches, with leg and offset, before the fall | asserted |
| 5–6 the fall, the banner, the pinned window | asserted |
| 7 the post-mortem's order | asserted: nothing in the window happened after the fall, and the contact entries precede it |
| 6 the verdict and the Runs row | asserted |
| 8 the reset | asserted that the sim restarted and the robot left the floor; **the "clears to healthy" half is reported**, because the reset does not undo the composition (§2.3) |

The two knobs are **not waivers**. Their defaults are measured facts about this
host, `stress.md` §4 carries the numbers, and the verb prints what it measured
either way — a run that behaves differently reports it rather than being told it
cannot have happened.

### 2.2 The tint history needs a witness

`data-lvl="green|amber|red|off"` is now an attribute on each pipeline-health
card. s003's TVP is a tint **history** — green → amber → red *in step with the
counters* — and a background colour is not something a suite can read, any more
than a canvas is. Same rule and same fix as the counter strip
([`dashboard.md`](../kennel_console/dashboard.md) §4): if a number or a state is
on screen and a suite cannot read it, it is not evidence.

The verb samples `__health()` about once a second for the whole walking window
and writes `02-tint-history-attempt<n>.jsonl`, so the history is a file, not an
impression.

### 2.3 Two things a composed preset cannot do, and one it does

**It cannot produce a green → amber transition.** s003 opens on *"a run is live
and healthy: all pipeline blocks green"* and then has the harness **induce**
stress. The mechanism `design.md` §1 chose is a composed configuration — and a
composition is in effect from the controller's first solve. Measured: under the
stress preset the MPC block reads amber while the robot is still standing, before
any velocity is commanded, on some attempts (and green on others — the console
tints on the worst solve in a 100 ms bin, and at a 3.4–3.6 ms mean whether a
given bin crosses 7 ms is chance).

A *transition* needs an **event** during the run. The only event mechanism at
this pin is the disturbance service — which is s004's. The verb prints

```
  [BYPASS] 1-3 green-to-amber transition -- the composed preset degrades the
  margin from the controller's FIRST solve, so there is no green run to watch
  turn amber…
```

**Retirement:** an upstream MPC horizon or `dt` the composer could reach, or a
slower reference host — either makes the margin something a run can *cross*
rather than start beyond. `stack/stress.md` §4.2 carries the same note.

**A reset does not undo the composition.** s003 step 8 has the reset return the
stack to standing and the dashboard to healthy. `/reset_sim` does what it can —
the clock restarts and the robot respawns at 0.4 m, measured `sim t` back to
4.6 s and 6.1 s — but the stress preset is a composition that cannot hold the
body up, so it settles at z 0.15–0.20 m and the fall rule fires again within
seconds. The verb asserts the reset (the robot leaves the floor, the clock
restarts, the fallen run's record persists) and **reports** where the robot ended
up. That is the honest reading of resetting a sim that is still misconfigured.

**What it does do:** the degradation is visible, the fall is real, and the
post-mortem holds the evidence in order. The committed run —
[`evidence/s003-diagnose/01-scenario.txt`](evidence/s003-diagnose/01-scenario.txt),
**87 checks, 0 failed, 2 bypassed** — stopped after two attempts because the bar
was met:

| | attempt 1 | attempt 2 |
|---|---|---|
| fell, by [`verify.md`](../stack/verify.md) §4's rule | z_min **0.1105 m** after 17.3 m | z_min **0.0943 m** after 16.6 m |
| the MPC block reached amber | — | **✓** |
| every block red at the fall | ✓ | ✓ |
| deadline-violation entries in the pinned window | **6** | **6** |
| contact-mismatch entries, all before the fall | **11** | **11** |
| the fall entry, last, with its trigger values | *body height — z median 0.200 m, outside [0.20, 0.45] m* | the same |
| `verify.json` | **`fell`** | **`fell`** |
| the reset: the robot left the floor | 0.156 m | 0.307 m |
| … and the sim clock restarted | 5.7 s | 3.4 s |

Note the fall itself: `tilt_over_frac` is **0.0** in both. This preset does not
tip the robot over — it sags until the body height leaves the band, which is the
same mechanism `stress.md` §3 measures at `mpc_condensed_size: 1` and a different
failure from s004's push. The two scenarios exercise the two halves of
`verify.md` §4's rule between them.

The per-attempt tint histories, feeds, traces and renders sit beside the
transcript.

---

## 3. Running them

```bash
# s004 needs a run composed with disturbances on
KENNEL_DISTURBANCES=1 demo/tools/kennel-demo.sh compose
demo/tools/kennel-demo.sh run
demo/tools/kennel-demo.sh scenario disturb        # ~6 min

# s003 composes its own preset, up to three times
demo/tools/kennel-demo.sh scenario diagnose       # ~15 min

demo/tools/kennel-demo.sh scenario                # what exists
```

Knobs are environment variables, passed through to the tool that defines them
([`runbook.md`](runbook.md) §4). The ones a scenario adds are in each verb's
header.

## 4. Evidence

| File | What it shows |
|---|---|
| [`evidence/s004-disturb/02-scenario-1.txt`](evidence/s004-disturb/02-scenario-1.txt), [`03-scenario-2.txt`](evidence/s004-disturb/03-scenario-2.txt) | the verb green twice in a row, 64 checks each |
| `evidence/s004-disturb/04-traces/` | the `observe --rows` CSV of every step, with the JSON summary the assertions were made from |
| `evidence/s004-disturb/05-renders/` | the Dashboard at the moderate push, at the fall, and after the reset |
| `evidence/s004-disturb/06-process-diffs/` | the six process captures and their diffs |
| `evidence/s004-disturb/03-feed.json`, `04-feed.json` | the pinned post-mortem, and the reset's two feed lines, as the page rendered them |
| `evidence/s003-diagnose/` | the same shape for s003, plus the per-attempt tint histories |

### 2.4 A relaunch has to close the previous session first

Each attempt relaunches the stack, and `p21-launch-from-commands.sh` opens by
reaping `/tmp/k13-*.pid` — which is the bridge and the watchdog. Relaunching
under a live teleop session therefore tears the bridge out from under a page
that is still connected, and the launcher's own six-node wait then has to
converge through the DDS participants that leaves behind.

Measured, three times before the verb was fixed: `/drake_simulator` missing from
`ros2 node list` for the whole 120-second bound, on a stack that was healthy the
moment the bound expired — both `ros2 node list` and `--no-daemon` agreed six
nodes a minute later. It is [#52](https://github.com/alius-git/kennel/issues/52)'s
shape one layer along: a readiness gate that watched a graph while something else
was tearing participants out of it.

The verb now runs `page disconnect` and `kennel-demo.sh teleop stop` before each
relaunch. A launch that still does not complete is **noted, not failed**: a stack
that will not come up is a `launch` problem and not an s003 result, and the
verdict this verb owns is the fall count — if launches keep failing, that count
will not reach its bar and the verb goes red for the right reason.

## 5. Limits

- **The process-table check cannot see a restart that reproduces the same
  command line** (§1.5). Pids would catch it and would make every capture differ
  for a reason that is not the console's.
- **The verbs need a VM.** They are not among the eight no-VM console suites, for
  the same reason `verify-teleop-live.sh` is not.
- **s004's pushes are knobs with measured defaults** (`KENNEL_S004_PUSH_MODERATE`,
  `..._SEVERE`). 100 N / 0.2 s staggers and 300 N / 0.3 s fells *this* robot at
  *this* pin; a heavier robot at a later pin is a knob change, not an edit.
- **s003's asserted set depends on a measurement** (§2.1). If a future sweep
  finds a composition that moves the MPC margin, the two knobs turn the bypasses
  into checks and this record says so.
- **A person still has to look at it.** These verbs assert observables; whether
  the Dashboard *reads* like a diagnosis instrument is the human friction
  session [`bridge.md`](../stack/bridge.md) §11 leaves open.
