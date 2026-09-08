# The stress preset — the MPC solve margin, measured

> Implementation record for [issue #70](https://github.com/alius-git/kennel/issues/70).
> [`design.md` §1](../plan/design.md) chose fault injection to be *"disturbance
> service + stress preset (a composed configuration that predictably degrades
> MPC solve margin), not code-level fault hooks"*. The disturbance service is
> [#68](https://github.com/alius-git/kennel/issues/68); this is the preset, and
> the table it came out of.
>
> One sentence: nobody had ever looked at the solve margin, so this measures it
> across every composition the MVP composer can express — and the answer is both
> halves of the question, which is why the record has a §3 and a §4.

Measured 2026-09-08 on the live guest (`kennel-vm`, 8 vCPU / 16 GiB, pin
`dcf53c5`) with [`verify/tools/k14-sweep.sh`](verify/tools/k14-sweep.sh): 18 grid
points plus two red candidates three times each, every point a full compose →
transfer → launch → verify → walk → observe. Each row keeps its run folder under
`stress/evidence/`, so any of them can be re-run with
`kennel-demo.sh run <folder>`.

## 1. What the margin is, exactly

The controller runs its MPC on a **sim-time** timer every `MPC_CONTROL_DT` =
10 ms (`mit_controller_params.hpp:8`) and measures each solve with a **wall**
clock (`mit_controller_node.cpp:885`). `num_mpc_solver_overtime` increments when
a solve takes `>= MPC_CONTROL_DT` (`:910`). So the "10 ms deadline" is a
wall-clock budget per sim-time cycle — and three different things get compared
against it:

| Threshold | Belongs to | Fires when |
|---|---|---|
| **10 ms** | the controller | one solve reaches it — `num_mpc_solver_overtime` +1, and `kennel-verify.sh` check 7 allows Δ ≤ 20 per window |
| **7 ms** | the console | the worst solve in a 100 ms bin exceeds it — the Dashboard's MPC block goes **amber** ([`dashboard.md`](../kennel_console/dashboard.md)) |
| **10 ms** | the console | the same bin, **red** |

They are not the same measurement, and the sweep answers each differently. That
is the substance of §3.

Because `simulator_realtime_rate: 0` makes the sim run as fast as it can, while
the budget is wall-clock and the cycle is sim-time, the rate is the knob #70
expected to matter. Every composition is measured at 1.0 **and** 0.

## 2. The table — 18 compositions

The issue's grid, pruned by [`composer-scope.md`](../kennel_console/composer-scope.md)
§2's 2×2: HPIPM mode is read only by the two HPIPM solvers and condensed size
only by the two partial-condensing ones, so the remaining cells differ in name
and not in mechanism. Each point walked at 0.3 m/s for 20 sim-seconds under a
held trot; `outcome` is `kennel-verify.sh` check 9.

| point | solver | mode | cond | rate | mean ms | p95 | max | iters | rtf | outcome |
|---|---|---|---|---|---|---|---|---|---|---|
| `hpipm-speed-5-r1` | P&middot;HPIPM | SPEED | 5 | 1.0 | **0.685** | 0.937 | 1.649 | 14.74 | 1.0024 | walked |
| `hpipm-robust-5-r1` | P&middot;HPIPM | ROBUST | 5 | 1.0 | **1.859** | 2.31 | 3.115 | 18.64 | 1.0013 | walked |
| `hpipm-speed-1-r1` | P&middot;HPIPM | SPEED | 1 | 1.0 | **1.701** | 2.087 | 5.0 | 14.68 | 1.0009 | walked |
| `hpipm-speed-10-r1` | P&middot;HPIPM | SPEED | 10 | 1.0 | **0.69** | 0.955 | 3.377 | 14.69 | 1.0008 | walked |
| `fullhpipm-robust-r1` | F&middot;HPIPM | ROBUST | &mdash; | 1.0 | **4.468** | 5.26 | 9.761 | 16.26 | 1.0014 | walked |
| `osqp-5-r1` | P&middot;OSQP | &mdash; | 5 | 1.0 | **1.164** | 1.853 | 2.951 | 9.55 | 1.001 | walked |
| `osqp-1-r1` | P&middot;OSQP | &mdash; | 1 | 1.0 | **3.75** | 5.577 | 9.18 | 15.5 | 1.0008 | **fell** |
| `osqp-10-r1` | P&middot;OSQP | &mdash; | 10 | 1.0 | **0.939** | 1.527 | 2.484 | 10.0 | 1.0007 | walked |
| `qpoases-r1` | F&middot;QPOASES | &mdash; | &mdash; | 1.0 | **1.353** | 1.957 | 3.154 | 2.4 | 1.0008 | walked |
| `hpipm-speed-5-r0` | P&middot;HPIPM | SPEED | 5 | 0 | **0.67** | 0.916 | 2.234 | 14.75 | 2.1476 | walked |
| `hpipm-robust-5-r0` | P&middot;HPIPM | ROBUST | 5 | 0 | **1.843** | 2.327 | 3.2 | 18.73 | 2.1138 | walked |
| `hpipm-speed-1-r0` | P&middot;HPIPM | SPEED | 1 | 0 | **1.672** | 2.096 | 3.253 | 14.85 | 2.1319 | **fell** |
| `hpipm-speed-10-r0` | P&middot;HPIPM | SPEED | 10 | 0 | **0.693** | 0.97 | 2.213 | 14.74 | 1.9968 | walked |
| `fullhpipm-robust-r0` | F&middot;HPIPM | ROBUST | &mdash; | 0 | **4.604** | 5.754 | 7.472 | 16.21 | 2.034 | walked |
| `osqp-5-r0` | P&middot;OSQP | &mdash; | 5 | 0 | **1.151** | 1.858 | 3.303 | 9.31 | 2.0574 | walked |
| `osqp-1-r0` | P&middot;OSQP | &mdash; | 1 | 0 | **3.707** | 5.668 | 9.12 | 17.59 | 1.8294 | **fell** |
| `osqp-10-r0` | P&middot;OSQP | &mdash; | 10 | 0 | **0.869** | 1.4 | 2.194 | 10.35 | 2.2353 | walked |
| `qpoases-r0` | F&middot;QPOASES | &mdash; | &mdash; | 0 | **1.188** | 1.765 | 2.987 | 2.4 | 2.3104 | walked |

Full CSV: `stress/evidence/sweep/sweep.csv`. Every point's `KENNEL_JSON` line and
its whole transcript sit beside it under `points/`.

## 3. The finding, in two halves

**The margin IS composable — by a factor of 6.9.** Mean solve time runs from
**0.670 ms** (`PARTIAL_CONDENSING_HPIPM`, SPEED, condensing 5) to **4.604 ms**
(`FULL_CONDENSING_HPIPM`, ROBUST). Two knobs move it, and neither is the one the
issue expected:

- **HPIPM mode.** `ROBUST` costs 2.7× `SPEED` at the same condensing (1.859
  against 0.685 ms), because it takes 18.6 interior-point iterations instead of
  14.7.
- **Condensing size.** For OSQP, `mpc_condensed_size: 1` costs **3.2×** size 5
  (3.750 against 1.164 ms); for HPIPM the same change costs 2.5×. Fewer condensed
  stages is a bigger QP, which is the mechanism.
- The slowest walking composition in the grid is **`FULL_CONDENSING_HPIPM` +
  `ROBUST`**: 4.468 ms mean, 5.26 p95, **9.761 ms max**.

**The rate knob does almost nothing** — the half of #70's premise that does not
survive. At `simulator_realtime_rate: 0` the sim reaches rtf **2.0–2.3** on this
host, and the solve time moves by under 5 % (`osqp-5`: 1.164 → 1.151 ms;
`fullhpipm-robust`: 4.468 → 4.604). The controller solves twice as often per wall
second and each solve costs what it costs, so the margin *per cycle* is
untouched. "As fast as possible" is not fast enough to matter.

**The controller's own overtime counter never moved.** `overtime_d` is **0 in all
18 points**. So #70's acceptance as literally written — *"three runs of the amber
preset each show overtime Δ > 20"* — **is not met, and cannot be met by
composition on this host**: the worst walking composition peaks at 9.761 ms, just
under the bound. (It is not unreachable in principle — the controller logged
`MPC solver took longer [0.011784 s]` once during an s003 run — only unreachable
*reliably*.)

**The console's amber line, though, is crossed.** Four grid points exceed 7 ms on
their worst sample — `fullhpipm-robust` and `osqp-1`, at both rates — so the
Dashboard's MPC block does tint amber under them. That is the observable
s003.diagnose actually asserts against, and it is reachable.

Two more things the table says out loud:

- **`mpc_condensed_size: 1` destabilises the robot.** `osqp-1` fell at both rates
  and `hpipm-speed-1` fell at rate 0 — on the **flat plane**. It is not a
  tip-over: the body sags (z median 0.140–0.165 m against a commanded 0.30) so
  check 9 fails on height while check 8 still reports it walking. A controller
  handed a harder QP every 10 ms tracks its height worse.
- **The WBC's 2 ms deadline is the one violated in practice**, not the MPC's
  10 ms: `num_wbc_overtime` climbs into the hundreds during a fall
  ([`demo/evidence/s004-disturb/05-renders/03-fall.png`](../demo/evidence/s004-disturb/05-renders/03-fall.png)).
  It is not composable either — it is what a robot on the floor does.

## 4. The preset

`KENNEL_PRESET=stress` composes **`PARTIAL_CONDENSING_OSQP`,
`mpc_condensed_size: 1`, `simulator_realtime_rate: 1.0`, flat plane**. It fills
in only what the operator did not choose, so every knob still wins over it.

Three runs, `stress/evidence/red-osqp1/`:

| run | mean ms | max ms | verdict | check 8 | check 9 | travelled | z median |
|---|---|---|---|---|---|---|---|
| `osqp1-flat-1` | 3.555 | 7.734 | `fell` | PASS | FAIL | 5.0165 m | 0.15043 m |
| `osqp1-flat-2` | 3.571 | 10.269 | `fell` | PASS | FAIL | 4.3006 m | 0.17277 m |
| `osqp1-flat-3` | 3.442 | 7.155 | `fell` | PASS | FAIL | 6.2105 m | 0.16613 m |

**3 of 3 fell; 3 of 3 crossed the console's 7 ms amber line**, and one crossed its
10 ms red line. The margin is 3.1× the same solver at stock condensing while the
robot still walks 4.3–6.2 m. That is what s003 needs: a run that visibly degrades
and then falls.

### 4.1 Why not obstacle terrain

It was the obvious candidate — [`transfer.md` §6.3](transfer.md) already records
that map as one that does not walk — so it was measured three times too:

| run | mean ms | max ms | verdict | check 8 | check 9 | travelled | z median |
|---|---|---|---|---|---|---|---|
| `red-1` | 1.375 | 3.254 | `unhealthy` | FAIL | PASS | 0.0217 m | 0.37145 m |
| `red-2` | 1.262 | 3.45 | `fell` | FAIL | FAIL | 1.5 m | 0.24485 m |
| `red-3` | 1.206 | 3.407 | `fell` | FAIL | FAIL | 3.7373 m | 0.33682 m |

It falls 2 of 3, which meets the bar, and it shows **no degradation at all**:
1.21–1.38 ms mean, indistinguishable from the healthy baseline, with check 8
failing every time because the robot does not advance. Terrain is contact stress
with a fall attached; it is not a stress *preset* in `design.md`'s sense.
Recorded, not chosen.

### 4.2 What the preset cannot do

**It cannot produce a green → amber transition.** A composition is in effect from
the controller's first solve, so a run composed to be degraded is degraded while
the robot is still standing. s003's step 3 asks the block to *transition*, and a
transition needs an **event** during the run — and the only event mechanism at
this pin is the disturbance service, which is s004's.

Measured, the MPC block reads amber before any velocity is commanded on some
attempts and green on others: the console tints on the worst solve in a 100 ms
bin, and at this preset's 3.4–3.6 ms mean whether a given bin crosses 7 ms is
chance. Over a whole run it reached amber on **2 of 3** attempts, which is why
[`demo/scenarios.md`](../demo/scenarios.md) §2 asserts it over the attempts and
not per attempt.

The transition is recorded as a bypass in `demo/scenarios.md` §2.3 rather than
papered over. It is a property of the mechanism `design.md` §1 chose, not of this
preset.

**Retirement**, for both that and the overtime bound: an upstream MPC horizon or
`dt` the composer could reach (`MPC_PREDICTION_HORIZON` and `MPC_CONTROL_DT` are
compile-time constants at the pin), or a slower reference host. Either makes this
sweep worth re-running — `k14-sweep.sh` is the tool, and `scenario diagnose`'s
two `KENNEL_S003_EXPECT_*` knobs are how it changes with the answer.

## 5. Notes and limits

- **The `mpc_warm_start: 0` point is not in the table.** It was measured while
  this pass was being planned — mean 1.328 ms at 20.1 iterations against 12.2
  warm, so the iterations nearly double and the time does not — but
  `mpc_warm_start` is not a composer choice, and that point was produced by
  hand-editing a copy of a run folder. Outside the generation path, so recorded
  as a **bypass** rather than added as a row: a sweep row has to be something the
  console can compose.
- **`FULL_CONDENSING_QPOASES` solves in 2.4 iterations** — by far the fewest —
  and lands mid-table on time at 1.19–1.35 ms.
- **One sample per grid point.** Run-to-run variance is measured only for the two
  red candidates, three runs each. That is enough for a 6.9× spread and not for a
  5 % one.
- **One host.** All of §3 is about *this* 8-vCPU guest's margin; a slower machine
  would move every row, which is exactly why the retirement path names one.
- **The sweep owns the guest** for about 40 minutes and must not be run with a
  console connected or a trot held from another verb. It says so at the top of
  its own transcript.
