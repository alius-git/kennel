# The PoC moment — a composed config runs the stack, and the values took effect

Implementation record for
[issue #21](https://github.com/alius-git/kennel/issues/21) — a config composed
in the console UI, with observable non-stock choices, runs the go2 sim stack;
the robot walks; and the running stack demonstrably uses the composed values.

This is the issue every other one has been feeding. It consumes them unchanged:
[#18](https://github.com/alius-git/kennel/issues/18) generated the YAMLs,
[#19](https://github.com/alius-git/kennel/issues/19) exported them,
[#20](https://github.com/alius-git/kennel/issues/20) transferred them
([`stack/transfer.md`](transfer.md)),
[#13](https://github.com/alius-git/kennel/issues/13) established the launch
surface and [#14](https://github.com/alius-git/kennel/issues/14) the verification
recipe ([`stack/verify.md`](verify.md)). Pin:
`dcf53c596339afd45b82f12c54b1e93e8273c2f4` ([`stack/pin.lock`](pin.lock)).

Verified 2026-08-06 on `kennel-vm`. Evidence in
[`stack/composed-run/evidence/`](composed-run/evidence/).

## 1. The composition

| Choice | Stock | Composed | Why this one |
|---|---|---|---|
| `mpc_solver` | `PARTIAL_CONDENSING_HPIPM` | **`PARTIAL_CONDENSING_OSQP`** | Solver identity is readable from the running node and echoed in the launch log |
| `simulator_realtime_rate` | `1.0` | **`0.5`** | Observable as sim-time against wall-time, and independent of the solver |
| map | flat plane | *(left at stock)* | See below |

This is exactly the pair issue #21 suggests. The map is deliberately **not**
composed: [`stack/transfer.md` §6.3](transfer.md) established that the Obstacle
terrain world does not walk — the robot trots in place or tumbles, differently
on each run — and #21's acceptance requires the walking criterion to pass. That
finding is what made this composition the right one rather than a lucky guess.

The two choices are also independent on purpose: one lives in the **controller**
YAML and one in the **simulator** YAML, so a transfer that silently dropped
either file would fail a different assert. The export driver asserts that
`run.json` differs from stock in exactly these two fields and nothing else — an
accidental third choice would make "prove each composed value" ambiguous.

## 2. What is delivered

| Artifact | Purpose |
|----------|---------|
| [`stack/composed-run/tools/p21-launch-from-commands.sh`](composed-run/tools/p21-launch-from-commands.sh) | Launch the stack **from the console's generated `commands.txt`** |
| [`stack/composed-run/tools/p21-prove-realtime-rate.sh`](composed-run/tools/p21-prove-realtime-rate.sh) | Turn the realtime rate from an `[INFO]` line into a pass/fail |
| [`stack/composed-run/tools/p21-trot-hold.sh`](composed-run/tools/p21-trot-hold.sh) | Hold a commanded trot, so the view can be photographed mid-stride |
| [`stack/composed-run/tools/p21-meshcat-shot.sh`](composed-run/tools/p21-meshcat-shot.sh) | Capture the Meshcat view from the host, aimed at the robot |
| [`stack/composed-run/evidence/`](composed-run/evidence/) | The run folder, the transcripts, the launch logs, the screenshot |

> **Since [#45](https://github.com/alius-git/kennel/issues/45) these tools stand
> on their own.** `p21-trot-hold.sh` used to require that
> `p21-launch-from-commands.sh` had launched the stack — every in-container call
> sourced `/tmp/p21-env.sh`, which only that launcher writes — and failed with
> `timeout: failed to run command 'ros2': No such file or directory` otherwise.
> It now uses that file when it exists and builds the same source chain itself
> when it does not, so the reconstruction recipe this section used to carry is no
> longer needed. `p21-meshcat-shot.sh` never had this dependency at all; it had
> four different undeclared preconditions, which it now checks. Both are recorded
> in [§9.2](#92-45--the-tools-own-their-environment).

## 3. The three decisions

### 3.1 Launch from `commands.txt`, not from a hand-written copy of it

`commands.txt` was the one console output no issue had ever executed. #13
established the three commands by hand; #14 and #20 drove them through
[`stack/verify/tools/k14-stack-up.sh`](verify/tools/k14-stack-up.sh), which is a
faithful but **hand-written** copy. A generated file that had quietly drifted
from that copy would have gone unnoticed by every test in the repo.

So the launcher reads the file and runs *it*. Before it runs anything it asserts
two things:

- **The three blocks reconstruct the file byte for byte** (`cat block1 block2
  block3 | cmp - payload`). Without this the splitter could drop a `source` line
  and the failure would surface much later as a mystery CMake or DDS error.
- **The launches are the canonical three of [`stack/launch.md` §1.1](launch.md)**,
  in order. A generated file that launched something else is a #18 regression,
  and running it anyway would report a green stack for the wrong stack.

The readiness waits are deliberately **not** in `commands.txt`. Launch *order*
and settling are properties of the stack (launch.md §1.2) and belong to whoever
runs the commands; the file is a faithful record of what the console composed.
The console's own comment says as much — "THREE shells, in this order — this is
not a script".

This also answers #24's open "non-blocking launch pattern over SSH" work item:
each blocking `ros2 launch` is started with `docker exec -d`, and the script then
waits by **observing the stack** — `/quad_state` appears, the sim clock advances,
the controller logs `Starting controller` — never by sleeping and hoping.

### 3.2 The settle is measured in sim seconds, not wall seconds

`commands.txt` says "wait ~10 s for the robot to settle first". At
`simulator_realtime_rate: 0.5` that is *twenty* wall seconds, and a `sleep 10`
would run `safe_start()` on a robot still dropping from its 0.4 m spawn.

The launcher therefore reads `/clock` and waits for 10 **sim** seconds, which is
invariant under the very parameter this issue composes. It is the same principle
[`stack/verify.md`](verify.md) applies to all its observation windows, and this
run is precisely the case that motivated it.

### 3.3 The realtime rate gets its own assert

#14's recipe reports the rate as `[INFO] realtime-rate` — informative, never
asserted, because #14 could not know what any given run would compose. #21 does
know, and its acceptance is "prove each composed value", so the same observable
is measured again as a pass/fail against `0.5 ± 0.1`.

The measurement is `/clock` against the guest's **monotonic** clock, not its wall
clock: [`vm/provisioning.md` §6a](../vm/provisioning.md) documents a host whose
NTP-adjusted clocks run ~10 % slow. That defect is the host's and this
measurement is the guest's, but the ratio is the entire result, so it is taken
from the one clock that cannot be re-railed underneath it. The ±0.1 window is
wide for the same reason — 0.5 against 1.0 is a factor of two, and no precision
claim is needed to tell them apart.

## 4. The result

```console
$ stack/transfer/kennel-transfer.sh apply run-20260806T183045Z
  simulator_params_go2.yaml      ef249170  ef249170  ef249170  ef249170  OK
  mit_controller_sim_go2.yaml    3c69d87f  3c69d87f  3c69d87f  3c69d87f  OK

$ ~/p21-launch-from-commands.sh
[p21-launch] split            3 shells, 30 payload lines, reconstructs the file exactly
[p21-launch] launches         the canonical three, in order (stack/launch.md 1.1)
[p21-launch]   settling 10 sim-s (sim clock at 1s)
[p21-launch]   settled at sim 12s
[p21-launch] stack is up, launched from the console's generated commands.txt

$ ~/kennel-verify.sh --expect-solver PARTIAL_CONDENSING_OSQP --controller-log /tmp/p21-ctrl.log
[INFO]   realtime-rate  -- measured 0.501
[PASS] 8 walking        -- vx_mean=0.261 m/s, dx=3.910 m over 15.00 sim-s, advanced in all 5 sub-windows: yes
[PASS] 10 composed-config -- measured PARTIAL_CONDENSING_OSQP, launch log agrees with the running value
                             ([mitcontrollernode-1] Set osqp linear system solver to qdldl)
pass=10 fail=0
VERDICT: PASS -- healthy and walking

$ ~/p21-prove-realtime-rate.sh 0.5 0.1 30
[PASS] realtime-rate -- /clock vs guest monotonic: measured 0.500 (15.722 sim-s in 31.450 s),
                        required 0.5 +/- 0.1 i.e. [0.400, 0.600]
```

**Both composed values are proven, by different mechanisms, on one run.** No
`mpc_solver:=` launch argument exists anywhere in `commands.txt` — the console's
generator deliberately emits none ([`stack/mapping.md` §2.1](mapping.md)) — so
the only path from the composer to the running node is the YAML.

![The composed run walking in Meshcat](composed-run/evidence/05-meshcat-walking.png)

The screenshot carries a third, unplanned corroboration: Drake's own HUD, top
left, reads **`49 rtr%`** — its realtime-rate meter, independently reporting the
composed 0.5 from inside the simulator.

## 5. Negative control — [`evidence/06-negative-controls.txt`](composed-run/evidence/06-negative-controls.txt)

Issue #21 asks for "a deliberately broken generated YAML (bad key) fails loudly
at launch, not silently — record the failure mode". Three corruptions of the same
exported controller YAML, each transferred and launched exactly like the good
one. The question is not whether the stack breaks; it is whether it *says so*.

| # | Corruption | Failure mode |
|---|---|---|
| A | `mpc_solver "…"` — colon removed | **Loud.** `mitcontrollernode` aborts before starting: *"Couldn't parse params file … Error parsing a event near line 32"* — names the file and the line. Launcher exits 1 |
| B | `mpc_solver: "NO_SUCH_SOLVER"` | **Loud, and better.** Upstream validates the value: *"Unknown mpc solver: NO_SUCH_SOLVER"*, node dies with exit 255 |
| C | `mpc_solverr:` — key misspelled | **SILENT.** See below |

**Case C is the finding.** The stack launches cleanly, exits 0, logs no
complaint about the unknown key, and quietly runs the **stock** solver. An
operator watching that launch sees a completely healthy stack running a
configuration nobody composed. The composed value was not rejected — it was
never read.

This is ROS 2 behaving as designed (an undeclared parameter in a params file is
not an error), which makes it a property to defend against rather than a bug to
report. The defense already exists, and this is the argument for it:

```
[FAIL] 10 composed-config -- ros2 param get /mit_controller_node mpc_solver:
       measured PARTIAL_CONDENSING_HPIPM, launch log agrees with the running value
       ([mitcontrollernode-1] Set hpipm mode to SPEED),
       required PARTIAL_CONDENSING_OSQP
pass=9 fail=1
VERDICT: FAIL
```

Nine checks pass. The stack **is** healthy and **is** walking. Check 10 is the
only thing between a silent typo and a believed result — which is exactly why
#14 built a read-back instead of trusting the launch, and why
[#24](https://github.com/alius-git/kennel/issues/24) is right to assert the
composed value rather than "something runs".

Worth a line on [#28](https://github.com/alius-git/kennel/issues/28): upstream
could `declare_parameter` strictly, or the mapping layer could validate generated
keys against the pin's schema before transfer.

## 6. Notes for whoever touches this next

### 6.1 `kennel-verify.sh` needs `--controller-log` unless #13's launcher ran

The recipe's launch-log corroboration falls back to a hardcoded
`/tmp/k13-ctrl.log` ([`kennel-verify.sh`](verify/kennel-verify.sh) line 176) —
the log of #13's launcher. A stack launched any other way, including from
`commands.txt`, writes somewhere else, and the recipe then reads **a stale file
from a previous run**.

It bit this issue. The first composed-run verification reported *"launch log
agrees with the running value (Set osqp …)"* while reading a `k13-ctrl.log` left
over from #20's runs hours earlier. It was accidentally right, which is the worst
kind of wrong. Every run recorded here passes `--controller-log /tmp/p21-ctrl.log`
explicitly.

**The assert itself was never affected** — `ros2 param get` reads the live node —
only the corroboration text beside it. #24 should pass the flag; a better default
would be for #14 to take the newest matching log, or to refuse to corroborate
from a file older than the node.

### 6.2 The Meshcat camera needs aiming, and the frame is not what it looks like

Two traps, both recorded in the shot tool's header:

- **The default camera frames the world origin, and the robot leaves it.** At
  0.3 m/s it is 10 m away after half a minute — a speck near the horizon. The
  first three attempts at this screenshot looked like "the robot is not in the
  scene".
- **Meshcat is Y-up, the Drake scene is Z-up, and `viewer.camera` sits under a
  `rotated` parent.** Setting `camera.position` to a Z-up coordinate puts the
  camera *under the ground plane*, looking up at the robot's underside. The tool
  sidesteps the whole question: it keeps the default camera's own direction
  vector and simply re-centres it on the robot, so it cannot get the convention
  wrong whichever axis is up.

Headless Chrome also has no GPU here — without `--use-gl=swiftshader` the canvas
renders empty, which looks identical to the first trap. The tool checks the PNG
is not a blank frame before accepting it.

### 6.3 The trot is commanded twice, deliberately

`kennel-verify.sh` commands its own trot and always returns the gait to STAND on
the way out, including on its failure paths — correctly, but it means the robot
is standing by the time the verdict prints. The screenshot therefore needs its
own trot, from `p21-trot-hold.sh`. Perturbing #14's measurement windows to get a
photograph would have traded evidence for a prop.

### 6.4 The launcher's "stopping anything already running" needs a staged stopper

The first thing `p21-launch-from-commands.sh` does is

```bash
sudo docker exec "$CONTAINER" bash -c '[ -x /root/k13-stop.sh ] && /root/k13-stop.sh'
```

which does nothing at all unless something has already put `k13-stop.sh` inside
the container. Nothing in this tool does; `kennel-demo.sh down` does, with a
`docker cp`. So on a guest that has not run `down` since it came up — a fresh
`provision`, or anything after a `reset` — a **second** launch used to stack a
second simulator on the first: the sim clock continues from the previous session
instead of restarting near zero, the robot is still lying where the previous
controller dropped it, and the new controller never reaches "Starting
controller" through a stream of `early contact` faults.

Since [#54](https://github.com/alius-git/kennel/issues/54), `kennel-demo.sh
launch` stages the stopper into the container before invoking this tool, so the
guard is true on every launch. **Anything that calls this launcher directly must
do the same**, or accept that its stop is a no-op. The symptom to recognise is a
settle line reporting a sim clock in the tens of seconds on what should be a
cold start. Recorded in [`demo/runbook.md` §7.3](../demo/runbook.md).

## 7. Limits

- **One composition.** Two of the composer's seven fields are exercised. The
  other five are mapped ([`stack/mapping.md`](mapping.md)) but not demonstrated
  end to end.
- **The screenshot is evidence of a moment, not a measurement.** The walking
  criterion is check 8; the photograph shows what check 8 asserts.
- **`run.json` is provenance, not config.** The negative controls corrupt the
  YAML and leave `run.json` claiming OSQP — as it should, since nothing reads it.
  A run folder is not self-validating, which is the point of the read-back.
- **The guest was left at stock** (`restore-stock`, `git status` clean), so this
  issue leaves no state behind for the next one.

## 8. What this feeds

| Issue | What it takes from here |
|---|---|
| [#24](https://github.com/alius-git/kennel/issues/24) | The non-blocking launch pattern (§3.1), the sim-time settle (§3.2), and the `--controller-log` trap (§6.1). Its fixture can be `evidence/run-20260806T183045Z/`, which is a real export and has now been run end to end |
| [#27](https://github.com/alius-git/kennel/issues/27) | The whole §4 sequence is the quickstart's happy path, and §5 is what to tell an operator whose run "worked" but did not |
| [#28](https://github.com/alius-git/kennel/issues/28) | The silently-ignored misspelled key (§5) |

## 9. The reliability pass — [#52](https://github.com/alius-git/kennel/issues/52) and [#45](https://github.com/alius-git/kennel/issues/45)

Two defects filed against these tools by the issues that first ran them without
their sibling. Both are the same shape: **a tool that is right about what it does
and silent about what it depends on.** Fixed together because they share one
validation protocol — a cold container, which is what `reset` guarantees.

### 9.1 #52 — the launcher waits for the graph, not for a log line

`p21-launch-from-commands.sh` gated its last block on the controller reaching
`Starting controller` in `/tmp/p21-ctrl.log`, and returned. But that block also
starts `joy_to_target.py`, a **separate `python3` process** that registers with
the ROS graph on its own schedule, and nothing waited for it. The `verify` that
follows samples `ros2 node list` exactly once ([`verify.md`](verify.md) §4.1), so
a node that had not *yet* arrived read exactly like one that was missing:

```
[FAIL] 1 node-graph -- ros2 node list: measured /drake_simulator /joy_linux_node
       /leg_driver /mit_controller_node /safe_start_launcher
       [missing: /joy_to_target ][extra: none][duplicate: none]
```

Re-running `verify` alone against the same untouched stack: `pass=10 fail=0`.
The stack was always fine; the readiness gate was not.

**Cold containers are what lose the race.** There is no `--restart` policy, by
design ([`vm/provisioning.md`](../vm/provisioning.md) §3.2), so `reset` and a
fresh `provision` both `docker start` seconds before the launch. That makes the
workflow [#51](https://github.com/alius-git/kennel/issues/51) added — `reset`
then `all` — the one that exposes it. Recorded at green **2 of 4**
([`vm/snapshot.md`](../vm/snapshot.md) §6 F5).

**The fix.** The last gate is now the graph itself: all six healthy-session nodes
present, none of them twice. Three details are deliberate:

- **Duplicates are part of the criterion, not a separate check.** A killed node's
  DDS participant lingers 10–20 s in `ros2 node list`
  ([`bridge.md`](bridge.md) §4.1), so just after the launcher's own pre-launch
  stop the graph can hold all six names *and* a stale twin. "All six, none twice"
  converges on its own; "six present" would have returned into the same race one
  layer down.
- **The same view `verify` will read.** The poll goes through the ros2 daemon
  inside the container, which is exactly what `kennel-verify.sh` uses a moment
  later. `--no-daemon` would have been a second opinion, not the same one.
- **Extras are reported, never fatal.** A rosbridge left running adds three nodes
  ([`bridge.md`](bridge.md) §4); that verdict belongs to `verify` and its
  `KENNEL_EXPECT_BRIDGE` knob, so the launcher only says so.

The same file's `sleep 15` after the leg driver went the same way, for the same
reason ([`dry-run.md`](../demo/dry-run.md) F8): it now waits for `/leg_driver` in
the graph **and** a publisher on `/joint_cmd` — the transition
[`launch.md`](launch.md) §1.1 measures at `Publisher count: 0` with only the
simulator up. Being early was never fatal (the controller blocks on the leg
driver's service and proceeds when it appears), but a fixed 15 s is a guess in
both directions, and it was wrong in both.

Exit 0 now means *all three are up, the controller reached "Starting controller",
and the graph is complete*. Exit 1 names the node that never arrived.

#### Measured — [`evidence/08-52-cold-runs/`](composed-run/evidence/08-52-cold-runs/)

Four `reset` → `all` cycles, every one on a cold container, after the change:

| Cycle | `reset` | leg driver up | graph complete after *Starting controller* | `launch` | `verify` | verdict |
|---|---|---|---|---|---|---|
| cold 1 | 1m22s | 5 s | 1 s | 34 s | 42 s | `pass=10 fail=0` |
| cold 2 | 1m23s | 2 s | 1 s | 31 s | 42 s | `pass=10 fail=0` |
| cold 3 | 1m23s | 2 s | 1 s | 30 s | 42 s | `pass=10 fail=0` |
| cold 4 | 1m24s | 5 s | 1 s | 35 s | 42 s | `pass=10 fail=0` |
| warm ([`09-52-warm-run.txt`](composed-run/evidence/09-52-warm-run.txt)) | — | 2 s | 1 s | 29 s | 41 s | `pass=10 fail=0` |

**4 of 4 green on cold containers**, against the 2 of 4 recorded before. `all`
exits 0 every time, and check 1 passes every time.

And `launch` got **faster**: 43–46 s before the change (the two negative-control
runs), 29–35 s after. Both new waits are net positive.

- The **graph** figure is the time from `Starting controller` to a complete
  graph, and 1 s is the cost of the first observation itself — on these runs the
  graph was *already* complete when first looked at. That is exactly what the
  race not being lost looks like, and it is the point: the launcher no longer
  depends on that being true. What it costs when the race is won is one second.
- The **leg driver** is where the saving is. It was up in 2–5 s every time, so
  the `sleep 15` it replaced was three to seven times longer than the wait it
  stood in for — and would have been too short on a host slower than this one.

#### The negative control, and what it does not prove — [`evidence/07-52-cold-before.txt`](composed-run/evidence/07-52-cold-before.txt)

Two cold `reset` → `all` cycles on the **unmodified** launcher, before any edit:
both green, `pass=10 fail=0`. **So #52 did not reproduce on this host today.**

That is recorded rather than smoothed over. It is not evidence the race is
absent — it is what an intermittent race looks like when it is not lost, and at
the recorded rate of green-2-of-4 two consecutive greens are about a 1-in-4
outcome. The defect is already reproduced twice, on two different guests, both
cold-started, with the re-runs that prove the stack was healthy:
[`10-all-after-reset.txt`](../vm/snapshot/evidence/10-all-after-reset.txt) /
[`11-verify-rerun.txt`](../vm/snapshot/evidence/11-verify-rerun.txt) and
[`16-all-on-cold-provisioned.txt`](../vm/snapshot/evidence/16-all-on-cold-provisioned.txt) /
[`17-verify-rerun-2.txt`](../vm/snapshot/evidence/17-verify-rerun-2.txt).

What the four post-change runs therefore prove is **4 of 4 green**, not "the race
was caught and fixed in the act". What the change removes is the dependence on
luck: the launcher cannot return while a node it started is still arriving,
whatever the container's temperature.

### 9.2 #45 — the tools own their environment

`p21-trot-hold.sh` said "runs on the GUEST, against an already-running stack" and
then silently required that the stack had been launched by
`p21-launch-from-commands.sh`: every in-container call did
`source /tmp/p21-env.sh`, which only that launcher writes, and the `>/dev/null
2>&1` on the source made the missing file silent. Launched any other way — by
hand per [`launch.md`](launch.md) §1.1, through
[`verify/tools/k14-stack-up.sh`](verify/tools/k14-stack-up.sh), or from a Yuruna
step — every call failed as

```
timeout: failed to run command 'ros2': No such file or directory
```

which points at `ros2` rather than at the cause. Found by
[#22](https://github.com/alius-git/kennel/issues/22), the first issue to run the
trot tool without its sibling.

#### What the review actually found, tool by tool

The issue asked for "the same review" of `p21-meshcat-shot.sh`. It turned out not
to share the defect at all — it runs on the **host** and never touches
`/tmp/p21-env.sh` — but it had four undeclared preconditions of its own. The
callout in [§2](#2-what-is-delivered) that lumped the two together was wrong
about it, and has been corrected.

| Tool | Runs on | Before | Now |
|---|---|---|---|
| [`p21-launch-from-commands.sh`](composed-run/tools/p21-launch-from-commands.sh) | GUEST | **writes** `/tmp/p21-env.sh` | unchanged — still the only writer |
| [`p21-trot-hold.sh`](composed-run/tools/p21-trot-hold.sh) | GUEST | silent failure naming `ros2` | uses the file when present, builds the chain when not, **says which**; preflights on the container, on `ros2` resolving, and on a **live** controller, each naming cause and fix |
| [`p21-prove-realtime-rate.sh`](composed-run/tools/p21-prove-realtime-rate.sh) | GUEST | fell back to a **partial** chain — no unitree overlay, no Drake exports, no `ROS_PACKAGE_PATH` | the whole chain, shared with the others |
| [`../bridge/kennel-bridge.sh`](bridge/kennel-bridge.sh) | GUEST | exited 2 correctly, but asked *"does the env file exist?"* to mean *"is a stack running?"* | asks the ROS graph: `/mit_controller_node` present or not |
| [`p21-meshcat-shot.sh`](composed-run/tools/p21-meshcat-shot.sh) | **HOST** | never used the env file; needed a repo checkout, an arrived scene and a moving robot, and said so about none of them | all four checked — see below |

#### The design: one chain, copied under test, never written back

Each guest-side tool carries the source chain between `# --- CHAIN BEGIN` and
`# --- CHAIN END` markers, and uses it **only** when `/tmp/p21-env.sh` is absent:

```bash
ENV_PRELUDE="if [ -f /tmp/p21-env.sh ]; then source /tmp/p21-env.sh; else $ENV_CHAIN; fi >/dev/null 2>&1"
```

Three decisions in that one line:

- **A copy, not a shared file.** These tools are staged to the guest one file at
  a time (`kennel-demo.sh`'s `guest_stage`), so nothing beside them is on disk to
  source. That is the same situation `kennel-verify.sh` is in, and it already
  carries the chain with a "change both together" comment. What is new here is
  that the copies are *proven* identical rather than asked to be — the markers
  exist so the check can diff them against
  [`known-good/tools/prelude.sh`](known-good/tools/prelude.sh):

  ```bash
  diff <(sed -n "/^ENV_CHAIN='/,/^cd \/root\/ros2_ws'$/p" "$tool" | sed "s/^ENV_CHAIN='//; s/'$//") \
       <(grep -v '^#' stack/known-good/tools/prelude.sh | grep -v '^$')
  ```

  This matters more than it looks: sourcing `setup_go2_workspace.bash` instead of
  `setup_ulab_workspace.bash` silently partitions the graph
  ([`launch.md`](launch.md) §2.1), so a *paraphrased* chain is a latent outage.
- **Never written back to `/tmp/p21-env.sh`.** In-process only. The launcher stays
  the single writer, so the file's presence keeps meaning "the launcher ran" for
  every tool that looks after this one — and the tools say which path they took,
  so the coupling is visible instead of papered over.
- **`${PATH}` and friends stay literal.** `ENV_CHAIN` is single-quoted, and bash
  does not re-expand a variable's value, so those reach the container's shell
  unexpanded exactly as they do in `commands.txt`.

#### `p21-meshcat-shot.sh`'s four preconditions

| It needs | Was | Now |
|---|---|---|
| `google-chrome`, and Meshcat reachable | checked, exit 2 | unchanged |
| **a repo checkout** — it imports the console's CDP client from `kennel_console/cdp.py` | unchecked; copied to `/tmp` it died as `the capture failed (rc=1)`, naming nothing | checked, exit 2, naming the file and saying it cannot be staged the way the guest tools can |
| **the scene tree to have arrived** over the websocket | `sleep 6` | polls for `base_link` in the `illustration` group, bounded by `KENNEL_SCENE_WAIT` (30 s), exit 2 with the diagnosis |
| **a live scene** — a paused or dead simulator renders a perfectly valid-*looking* PNG | unchecked | samples `base_link` 2 s apart, always prints the displacement, and **warns** under 1 cm — a frozen scene. Never fatal |

One wait in that tool is *not* an observation and stays: the 2.5 s settle between
re-aiming the camera and capturing. Meshcat renders on its own rAF loop and
exposes no completion event, so there is nothing to poll. **Recorded as a bypass**
rather than dressed up as a check; the blank-frame guard (a PNG under 20 kB is
almost certainly a SwiftShader failure) is what actually catches a bad capture.

#### Four defects the live protocol found **in this fix**

Every one was caught by running it, not by reading it, and none is visible in a
diff. They are the argument for the protocol, and they are all the same species
as the bug being fixed: **a check that looks right and tests the wrong thing.**

**F1 — graph presence is not liveness, and this tool used it as if it were.**
`start`'s new "is there a stack?" preflight asked whether `/mit_controller_node`
was in `ros2 node list`. Straight after `kennel-demo.sh down` it still was — a
killed node's DDS participant lingers 10–20 s, which is the trap
[`verify.md`](verify.md) §4.1 records and which §9.1 above *quotes* as the reason
duplicates matter. The preflight passed, the tool went on to `ros2 param set`,
and reported `Wait for service timed out`, exit 1 — the class of unhelpful
message #45 is about, one layer further in. The gate is now
`/controller_heartbeat`: the live signal, 2 Hz, the one `kennel-verify.sh`
check 4 uses. The graph check survives only to tell two diagnoses apart —
*never launched* versus *just stopped, participant still lingering* — which is a
more useful message than either alone.

**F2 — and the heartbeat check that replaced it had a trap of its own.** It
tested whether `ros2 topic echo --once` produced *any* output. With no publisher
that command does not stay silent; it prints, **on stdout**:

```
WARNING: topic [/controller_heartbeat] does not appear to be published yet
```

72 bytes, measured. So a dead controller still read as alive, and the row that
should have said "not launched" failed as `Node not found` instead. The check now
strips `^WARNING` lines before testing for content. Two rounds of the same
mistake in the same preflight is the honest reason this row has its own evidence
file.

**F3 — the bridge's detached launch still sourced the env file raw.**
`kennel-bridge.sh`'s `in_ctr` was converted to the fallback; the
`docker exec -d ... bash -c "source /tmp/p21-env.sh ...; ros2 launch ..."` that
actually starts rosbridge was not. Every preflight passed, the script reported
starting it, and the process died with `bash: line 2: ros2: command not found`.
Fixed by routing that block through the same `ENV_PRELUDE`. The generalisation is
the check that now stands in its place: **every in-container ROS entry point in
these tools goes through the fallback**, `docker exec -d` blocks included, and
the audit is one grep for `source /tmp/p21-env.sh` — whose only remaining match
is in the launcher, which writes that file itself moments earlier.

**F4 — the "is it walking?" warning could not be one, and became a liveness
check.** As first written, `p21-meshcat-shot.sh` warned when `base_link` moved
less than 1 cm in a second. It never fired. Measured on a robot `verify` had left
at `STAND` — one object, one uuid, so not a duplicate-match artifact:

```
t= 2.0s  x=5.199 y=0.314 z=0.419   moved 16.2 cm
t= 4.1s  x=5.176 y=0.302 z=0.485   moved 21.8 cm
t= 6.1s  x=5.190 y=0.306 z=0.295   moved  6.0 cm
t= 9.2s  x=5.183 y=0.317 z=0.346   moved  4.7 cm
```

Decoding the frame explains it: `world.y` is the body height (0.30–0.33 m,
steady) and `world.z` is Drake's lateral axis — so a standing quadruped under the
MPC **shuffles centimetres per second sideways**. A trot is not separable from
that by a fixed threshold, and the wall-clock distance a trot covers scales with
the composed `simulator_realtime_rate`, so a threshold tuned at 0.75 would be
wrong at 0.5. Telling standing from walking needs the *gait*, which is the
guest's to read and not this host-side tool's.

The check now asks what it can answer: **is the scene advancing at all?** It
always prints the displacement and warns only below 1 cm over 2 s. A live
standing robot measured 3.4 cm over that window — a 3× margin, which is thin
enough to state rather than imply — so it will not false-fire, and it does catch
the case that matters: a paused or dead simulator rendering a valid-looking PNG.

#### Measured

| Evidence | What it proves |
|---|---|
| [`10-45-before.txt`](composed-run/evidence/10-45-before.txt) | **the defect.** The tool as it was at `HEAD`, on a running stack with `/tmp/p21-env.sh` removed: `timeout: failed to run command 'ros2'`, exit 1 |
| [`11-45-trot-no-envfile.txt`](composed-run/evidence/11-45-trot-no-envfile.txt) | the new tool, same stack, file still absent: `env: built-in chain`, gait reads `WALKING_TROT`, the target really is on the wire at **9.999 Hz**, `STAND` after `stop`, exit 0 |
| [`12-45-trot-with-envfile.txt`](composed-run/evidence/12-45-trot-with-envfile.txt) | the normal path is untouched: file restored, `env: /tmp/p21-env.sh`, `walk` and `walk stop` from the host |
| [`13-45-trot-not-launched.txt`](composed-run/evidence/13-45-trot-not-launched.txt) | "not launched", three ways, each with its own diagnosis: **just stopped** (exit 2, in the graph but no heartbeat), **DDS timed out** (exit 2, not in the graph), **container stopped** (exit 2, names the state). `stop` is exit 0 and quiet in all three. Ends by relaunching to `pass=10 fail=0`, so the guest is left green |
| [`14-45-meshcat-shot.txt`](composed-run/evidence/14-45-meshcat-shot.txt) + [`.png`](composed-run/evidence/14-45-meshcat-shot.png) | the shot tool on a trotting robot: scene waited for, **62.4 cm in 2 s**, a 166 kB frame of the robot mid-stride 5.8 m from the origin — and exit 2 naming `cdp.py` when run from outside a checkout |
| [`14b-45-standing-shot.txt`](composed-run/evidence/14b-45-standing-shot.txt) | the same tool on a robot at `STAND`: **3.4 cm in 2 s**, no false frozen warning, exit 0 |
| [`15-45-rate-and-bridge-no-envfile.txt`](composed-run/evidence/15-45-rate-and-bridge-no-envfile.txt) | the two siblings with no env file: the rate tool `[PASS] realtime-rate ... measured 0.750`, and the bridge up on 9090, reachable from the host as `ws://…:9090/`, then torn down |

### 9.3 Limits

- **The race was not reproduced on the day it was fixed** (§9.1). Four green cold
  runs are consistent with the fix and do not, by themselves, demonstrate it.
- **`KENNEL_TOPIC_TIMEOUT` is an iteration count, not seconds.** It predates this
  pass: the two older loops run `TOPIC_TIMEOUT` iterations of a 2 s poll, so the
  bound is 360 s, not 180. The two waits added here take seconds and divide by
  the poll interval themselves. Left alone rather than silently changing a
  timeout nothing has complained about.
- **The chain is still copied four times.** Proven identical by the diff above,
  which is a check and not a guarantee: nothing stops a fifth tool from
  paraphrasing it. The real retirement is a chain the container carries itself.
- **`p21-meshcat-shot.sh` cannot tell standing from walking** (F3). It reports
  displacement and detects a frozen scene; a caller who needs "is it trotting?"
  must read `/gait_state` on the guest, as `kennel-verify.sh` check 6 does.

---

Last review: 2026-09-06
