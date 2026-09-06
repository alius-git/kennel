# The CLI walking/health verification recipe

Implementation record for
[issue #14](https://github.com/alius-git/kennel/issues/14) — a written,
scriptable recipe that decides **"healthy and walking"** for the dfki-quad Go2
sim stack from a VM shell alone, packaged as one in-VM script with a pass/fail
exit code.

This is the MVP's substitute for the console/rosbridge dashboard asserts
(bypass, tracking issue [#5](https://github.com/alius-git/kennel/issues/5)) and
the exact assert step [#24](https://github.com/alius-git/kennel/issues/24)'s
Yuruna sequence runs. Work item 4 — reading the active MPC solver from a running
stack — is the mechanism
[#21](https://github.com/alius-git/kennel/issues/21) needs to prove a composed
config took effect.

Builds on [`stack/launch.md`](launch.md)
([#13](https://github.com/alius-git/kennel/issues/13)), which is the launch
surface this verifies, and on its capture in
[`stack/known-good/`](known-good/), which is where every threshold below comes
from. Pin: `dcf53c596339afd45b82f12c54b1e93e8273c2f4`
([`stack/pin.lock`](pin.lock)).

Everything here was run end to end over SSH into `kennel-vm` on **2026-08-05**;
the four evidence runs are in [`stack/verify/evidence/`](verify/evidence/).

## 1. Running it

```bash
GUEST=$(virsh net-dhcp-leases default | awk '/kennel-vm/ {split($5,a,"/"); print a[1]}')
KEY=~/git/yuruna/test/status/ssh/yuruna_ed25519
scp -i $KEY stack/verify/kennel-verify.sh yuuser24@$GUEST:/tmp/
ssh -i $KEY yuuser24@$GUEST 'chmod +x /tmp/kennel-verify.sh && /tmp/kennel-verify.sh'
```

One file, run on the **guest**. It copies itself into the `dfki_quad` container,
re-executes there behind the source chain, runs ten checks and copies the report
back out to `/tmp/kennel-verify` on the guest (`--out DIR` to change that). It is
a single file on purpose: #24's step is one `sshFetchAndExecute`.

| Exit | Meaning |
|------|---------|
| `0` | every assert passed — healthy and walking |
| `1` | at least one assert failed — the stack is up but not healthy/walking |
| `2` | infrastructure error — could not even look (no container, source chain broken, bad arguments) |

The `1` / `2` split is for #24: a failed assert means collect the stack logs and
report a red run; an infrastructure error means the step never got as far as
looking, which is a different bug in a different place.

```
--expect-solver NAME    assert mpc_solver == NAME (check 10 asserts instead of reporting)
--controller-log PATH   in-container path to the controller launch log, for the
                        construction-time solver corroboration (default /tmp/k13-ctrl.log)
--out DIR               where to leave the report on the guest
```

Every threshold is an environment knob with the default in the table below; the
script's header lists them all.

### 1.1 The recipe commands the trot itself

Two design decisions worth stating plainly, because #24 and #21 both depend on
them:

**It drives the robot.** "Walking" cannot be observed without a command, and in
#24's sequence nothing else issues one. So the recipe sets
`simple_gait_sequencer.gait` and publishes `/quad_control_target` itself, exactly
as [`launch.md`](launch.md) §4 prescribes — including the mandatory
`world_z: 0.30`. On the way out, on **every** path including failure, it
commands a standstill and returns the gait to `STAND`: the controller keeps the
last target forever, so merely ceasing to publish would leave the robot walking.

**Everything is measured in simulation time.** Guest wall clock is unreliable
([`vm/provisioning.md`](../vm/provisioning.md) §6a), and #21 runs this stack at
`simulator_realtime_rate: 0.5`, which halves every wall-clock rate. Rates are
therefore messages per **sim**-second and windows are **sim**-seconds, both taken
from `/clock`. This is sound for the whole graph, not just the simulator:
`mit_controller.launch.py` sets `use_sim_time` from the `sim` argument, and the
heartbeat timer is built on the node clock, so `/controller_heartbeat` is 2 Hz in
sim time too. Evidence run 03 measured a realtime rate of 0.627 and every rate
band still held.

## 2. The checks

Each line of output names the observable it read:

```
[PASS] 4 controller-alive     -- /controller_heartbeat rate: measured 2.00 Hz per sim-second, required 1.50-2.50 Hz per sim-second
```

| # | Check | Observable | Threshold | Provenance |
|---|-------|-----------|-----------|------------|
| 1 | `node-graph` | `ros2 node list` | exactly the six healthy-session nodes, no duplicates — plus the three rosbridge nodes *tolerated* when `KENNEL_EXPECT_BRIDGE=1` | [`launch.md`](launch.md) §6, [`known-good/06-healthy-graph.txt`](known-good/06-healthy-graph.txt), [`bridge.md`](bridge.md) §6 |
| 2 | `sim-clock` | `/clock` vs monotonic wall clock | advances ≥ 90 % of the requested window within the wall budget | §1.1; realtime rate reported, never asserted |
| 3 | `state-stream` | `/quad_state` message count ÷ sim-seconds | 900–1100 Hz | 1000 Hz measured, [`launch.md`](launch.md) §6 |
| 4 | `controller-alive` | `/controller_heartbeat` count ÷ sim-seconds | 1.5–2.5 Hz | 2 Hz measured; `controller_heartbeat_dt` default 0.5 s |
| 5 | `gait-command` | `ros2 param set` / `get` `simple_gait_sequencer.gait` | `Set parameter successful` and read-back equals the requested gait | [`launch.md`](launch.md) §4.1 |
| 6 | `gait-active` | `/gait_state` `period`, `duty_factor`, `phase_offset` | the requested gait's signature — `WALKING_TROT` is `0.5 / 0.6 / [0, 0.5, 0.5, 0]` | `GaitDatabase::getGait`, `controllers/src/mit_controller/gait.cpp` at the pin |
| 7 | `solver-health` | `/controller_heartbeat` counter **deltas** over the window | `num_mpc_solver_fail` Δ0, `num_wbc_solver_fail` Δ0, overtime Δ ≤ 20 | [`known-good/README.md`](known-good/README.md); counters are cumulative, so deltas are the signal |
| 8 | `walking` | `/quad_control_target` vs `/quad_state` twist and pose | mean vx 0.20–0.35 m/s for a 0.3 m/s command, dx ≥ 0.15 m/s × window, and advance in each fifth of the window | 0.268 m/s measured, [`launch.md`](launch.md) §5 |
| 9 | `no-fall` | `/quad_state` `belly_contact`, `z`, attitude | `belly_contact` false in every sample, **median** z in 0.20–0.45 m, tilt > 0.5 rad in ≤ 2 % of samples | §4 — every part of this was forced by an observed failure |
| 10 | `composed-config` | `ros2 param get mpc_solver` + controller launch log | reports the active solver; asserts equality when `--expect-solver` is given | §3 |

`KENNEL_EXPECT_BRIDGE=1` adds `/rosapi`, `/rosapi_params` and
`/rosbridge_websocket` to the *allowed* set only — they are tolerated, never
required. Without it a bridge left running reports them as `extra:`, which is
the intended signal. `kennel-demo.sh verify` sets the knob when it can reach a
bridge, and warns that checks 6–9 command their own trot, so a console that is
connected and driving must be disconnected first — two publishers on
`/quad_control_target` do not merge ([`bridge.md`](bridge.md) §7).

Checks 2–4 are the **liveness gate**. If they fail, 5–9 are reported as failing
and skipped rather than run: there is no point commanding a gait at a stack that
is not answering, and a 20-second trot against a dead controller only wastes
#24's timeout budget. Check 1 is deliberately *not* part of the gate — see §4.1.

Two `INFO` lines carry numbers that are useful but must not gate a run: the
achieved realtime rate (0.5 is legitimate under #21) and the height tracking
(gait bob is config-dependent — §4.2).

### 2.1 Why an rclpy subscriber and not `ros2 topic echo`

Every message field is read from an rclpy subscriber embedded in the script.
FastRTPS writes `RTPS_TRANSPORT_SHM` warnings into captured output when several
`ros2` CLI processes run at once, which corrupts `ros2 topic echo --field`
captures — [`launch.md`](launch.md) §7 trap 7. Only `ros2 node list` and
`ros2 param get/set`, whose output is line-oriented and parsed with a single
`sed`, are read from the CLI.

## 3. Reading the active MPC solver — the mechanism #21 needs

Two independent observables, both verified at the pin:

**Live, from the running node.** `ros2 param get /mit_controller_node mpc_solver`.
The node declares the parameter with default `PARTIAL_CONDENSING_HPIPM`
(`mit_controller_node.cpp:67` at the pin) and reads it **once at construction**
to build the MPC (`:523–538`). It is not in the dynamic-parameter handler, so the
value the node reports is the value it was constructed with.

**Construction-time, from the launch log.** The controller prints exactly one
solver-family line on stdout: `Set hpipm mode to <MODE>` for the two HPIPM
solvers, `Set osqp linear system solver to <X>` for OSQP (`mpc.cpp:232` and
`:240`). `FULL_CONDENSING_DAQP`, `FULL_CONDENSING_QPOASES` and
`PARTIAL_CONDENSING_QPDUNES` print neither, and the script says so rather than
guessing. An unknown name is fatal and loud — `Unknown mpc solver: <name>` then
`exit(-1)` — which is the failure mode #21's negative control is looking for.

The script cross-checks the two and reports the pair. Demonstrated in evidence
run 02, where the stack was launched with
`mpc_solver:=PARTIAL_CONDENSING_OSQP`:

```
[PASS] 10 composed-config -- ros2 param get /mit_controller_node mpc_solver:
       measured PARTIAL_CONDENSING_OSQP, launch log agrees with the running value
       ([mitcontrollernode-1] Set osqp linear system solver to qdldl),
       required PARTIAL_CONDENSING_OSQP
```

and the same stack asserted against the stock value fails only that check,
`pass=9 fail=1`, exit 1 — the assert bites, it is not decorative.

> **`/solve_time` does not carry solver identity.** `MPCDiagnostics` has timings,
> iteration counts and an acados return code, and no solver name. Do not look
> there.

## 4. Defining the fall condition — what the evidence forced

The issue asks for the fall condition to be defined "from available signals".
Three signals are available and **not one of them works alone**. Each of the
three statistics in check 9 was forced by an observed failure.

### 4.1 `belly_contact` never fires

[`known-good/README.md`](known-good/README.md) suggests `QuadState.belly_contact`
as the cheapest "did not fall" signal. It is not one. It stayed **false**
through both falls we could produce:

| Forced fall | Body state | `belly_contact` |
|-------------|-----------|-----------------|
| `/set_emergency_damping_mode` (evidence run 04) | flat on the floor, z = 0.0754 m, motionless | false, 0/15000 samples |
| spontaneous tip-over after ~12 m of OSQP trot | inverted, roll = −2.90 rad (166°), one foot in contact | false |

`belly_contact` never *false-positives*, so any hit is a fall and the check keeps
it — but its absence proves nothing, and a recipe that trusted it would have
passed a robot lying on its back.

The related trap: **`ros2 node list` is not a liveness signal either.** In an
early controller-down run it still listed `/mit_controller_node`,
`/joy_linux_node` and `/joy_to_target` seconds after the processes were
`SIGKILL`ed — a DDS participant lingers until discovery times it out. The
heartbeat rate went to zero immediately and caught it. That is why the liveness
gate is checks 2–4, message rates, and check 1 is a completeness check that
reports staleness rather than gating on it.

The mirror image of that trap is [#52](https://github.com/alius-git/kennel/issues/52),
and it is not this recipe's to fix: check 1 samples the graph **once**, so a node
that has not *yet* arrived reads exactly like one that is missing. On a cold
container `/joy_to_target` could still be registering when `launch` returned, and
this check failed a stack that was entirely healthy — `verify` re-run alone
against it gave 10/10. Sampling twice here would have hidden a real defect behind
a retry; instead the launcher now does not return until the graph is complete
([`composed-run.md` §9.1](composed-run.md)), so by the time this check looks, the
six nodes are there or something is genuinely wrong.

### 4.2 Body height needs a median, not a per-sample bound

The first draft asserted z within `[0.25, 0.40]` in **every** sample, from the
known-good `0.3130–0.3168`. It rejects a perfectly healthy composed config:

| Config | z median | z range | peak-to-peak | verdict |
|--------|----------|---------|--------------|---------|
| stock HPIPM (run 01) | 0.3142 m | 0.3100–0.3168 | 0.0068 m | walking |
| composed OSQP (run 02) | 0.2874 m | 0.2322–0.3287 | 0.0965 m | walking, vx 0.269 m/s, 4.04 m in 15 s |
| damping collapse (run 04) | 0.0754 m | flat | 0.0000 m | fallen |

The OSQP gait bobs **14× more** than HPIPM's and rides ~25 mm lower, and after a
long session it dips below 0.16 m while still walking. Any per-sample floor
tuned to one solver rejects the other. The **median** separates fallen from
walking by a factor of four — 0.075 m against 0.287–0.314 m — and is what
check 9 asserts. The per-sample spread is still reported, as the
`height-tracking` INFO line, because it is exactly the kind of composed-config
difference #21 wants visible.

### 4.3 Attitude is a sustained fraction

Tilt is the only signal that catches a tip-over: 2.90 rad against ≤ 0.13 rad in
every walking capture. It is asserted as a *sustained* violation — over 0.5 rad
in more than 2 % of samples — because a tipped robot holds its attitude while a
gait transient does not. The run in which the robot tipped over mid-window
recorded 95.83 % of samples over the bound.

So the fall condition is: **`belly_contact` in any sample, or median z outside
`[0.20, 0.45]` m, or tilt over 0.5 rad in more than 2 % of samples.** All four
observed states — HPIPM walking, OSQP walking, damping collapse, tip-over — are
classified correctly by it.

### 4.4 Proving the gait took, and why check 5 is not enough

`ros2 param set ... simple_gait_sequencer.gait GARBAGE` reports **`Set parameter
successful`**, and the read-back returns `GARBAGE`. The node's parameter
callback logs `Unknown gait type`, `GetGaitSequencerFromParams` returns null, and
`if (gs)` leaves the running sequencer untouched (`mit_controller_node.cpp:484–496`
at the pin). The parameter and the sequencer disagree, and nothing on the
parameter path says so.

`/gait_state` is the observable that does. It carries no gait *name*, but it
carries what a gait *is* — `period`, `duty_factor`, `phase_offset` — and those
come straight from `GaitDatabase::getGait`. `WALKING_TROT` is
`period 0.5, duty 0.6, offsets [0, 0.5, 0.5, 0]`; `STAND` is `0.5 / 1.0 /
[0,0,0,0]`. The script carries the ten-entry table and checks the signature, so
check 6 fails if the sequencer did not follow even when check 5 passes.

## 5. Evidence

Four runs, all with the script as committed. Every one starts from a freshly
launched stack — a session that has trotted several times accumulates enough
drift to fall on its own, which is how the tip-over in §4.1 was found.

| File | Scenario | Exit | Result |
|------|----------|------|--------|
| [`01-healthy.txt`](verify/evidence/01-healthy.txt) | stock stack, healthy session | **0** | `pass=9 fail=0` — the acceptance criterion |
| [`02-composed-osqp.txt`](verify/evidence/02-composed-osqp.txt) | stack launched `mpc_solver:=PARTIAL_CONDENSING_OSQP` | **0** then **1** | `--expect-solver PARTIAL_CONDENSING_OSQP` → `pass=10 fail=0`; the same stack asserted against the stock solver → `pass=9 fail=1`, only check 10 |
| [`03-controller-down.txt`](verify/evidence/03-controller-down.txt) | controller launch killed, simulator and leg driver left up | **1** | `pass=2 fail=8` — check 4 reads 0.00 Hz, gate fails, 5–9 skipped, check 10 has no value to read |
| [`04-forced-fall.txt`](verify/evidence/04-forced-fall.txt) | `/set_emergency_damping_mode` on a healthy standing stack | **1** | `pass=7 fail=2` — the stack is alive and answering (1–7 pass); 8 and 9 fail on a motionless body at 0.0754 m |

Run 04 is the sharper of the two negatives: the stack passes every liveness and
health check and still fails, which is the distinction between "the stack is up"
and "the robot is walking" that the whole recipe exists to make.

Run 02 also pre-clears #21's other requirement — the walking criterion passes on
the composed config, with the composed value proven by the same run.

## 6. Notes for #24 and #21

**#24 (Yuruna MVP sequence).** One step:
`sshFetchAndExecute kennel-verify.sh`, plus `--expect-solver` for the
composed-value assert. Budget roughly 60 s of wall time at realtime rate 1.0
(5 s observe + 5 s settle + 15 s trot, plus discovery and two `ros2 param`
round-trips) and scale it by the inverse of the realtime rate. Branch log
collection on the exit code: `1` wants the simulator and controller logs, `2`
wants the container state. The report is left at `/tmp/kennel-verify/report.txt`
on the guest whether the run passed or failed, so the fetch step is
unconditional.

**#21 (composed config).** `--expect-solver PARTIAL_CONDENSING_OSQP` is the
solver half. For `simulator_realtime_rate: 0.5`, the `realtime-rate` INFO line
already reports the measured `/clock`-vs-wall ratio, which is the observable #21
names — it is reported rather than asserted so that the same recipe passes at
both rates; assert it in #21's own step against that number. Expect the OSQP run
to look different in the `height-tracking` line (§4.2); that is the composition
being visible, not a fault.

## 7. Reproducing the evidence

The stack has to be up first. [`verify/tools/k14-stack-up.sh`](verify/tools/k14-stack-up.sh)
is what the evidence runs used: the first half of
[`known-good/tools/k13-capture.sh`](known-good/tools/) with the capture and
teardown removed, so it launches the three components and leaves them running.
Copy it into the container alongside the #13 tools
([`launch.md`](launch.md) §8), then:

```bash
sudo docker exec dfki_quad /root/k14-stack-up.sh        # stock
# or, for evidence run 02:
sudo docker exec -e EXTRA_ARGS=mpc_solver:=PARTIAL_CONDENSING_OSQP \
     dfki_quad /root/k14-stack-up.sh
```

```bash
# 01 — healthy
/tmp/kennel-verify.sh

# 02 — composed config (relaunch the controller with mpc_solver:=PARTIAL_CONDENSING_OSQP first)
/tmp/kennel-verify.sh --expect-solver PARTIAL_CONDENSING_OSQP

# 03 — controller down
sudo docker exec dfki_quad bash -c '
  kill -INT $(cat /tmp/k13-ctrl.pid); sleep 5
  pkill -KILL -x mitcontrollerno            # comm is capped at 15 chars -- launch.md §7 trap 5
  pkill -KILL -x joy_linux_node
  pkill -KILL -f "controllers/joy_to_target[.]py"'
/tmp/kennel-verify.sh

# 04 — forced fall
sudo docker exec dfki_quad bash -c '
  source /root/kennel13-prelude.sh
  ros2 service call /set_emergency_damping_mode std_srvs/srv/Trigger'
/tmp/kennel-verify.sh
```

`/reset_sim` (`interfaces/srv/ResetSimulation`) puts the robot back on its feet
after run 04 without relaunching, but relaunching is what the evidence used.
