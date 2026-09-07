# Kennel — Plan G: teleop hardened (#65 · #66 · #67), one PR

Steps 8–10 of milestone [*Finish the system*](https://github.com/alius-git/kennel/milestone/2),
written like plans A–F (`next-goals.md`, `teleop-joystick.md`, `reliability.md`,
`console-live.md`) so an agent can implement them on one branch without
re-deriving the repo. Everything in §0 was checked on **2026-09-07** with the
commands shown; the live probe's transcript is quoted where it decides something.

| Step | Issue | One line |
|---|---|---|
| 8 | [#65](https://github.com/alius-git/kennel/issues/65) | `stack/bridge/verify-teleop-live.sh` — the teleop path asserted on the **real** stack from the host, exit `0/1/2`, green twice in a row; the five D.3 caveats of `plan/teleop-joystick.md` given numbers |
| 9 | [#66](https://github.com/alius-git/kennel/issues/66) | *reset sim* calls `/reset_sim` through the bridge in a measured safe sequence; the gait picker says **active** (or **refused**) from `/gait_state`, never only *sent* |
| 10 | [#67](https://github.com/alius-git/kennel/issues/67) | `k13-target-watchdog.py` — the guest-side dead man's switch that zeros a stale non-zero target; started and stopped with the bridge; the killed-tab limit retired |

**One branch, one PR, closing all three.** That is the maintainer's call for this
step, as it was for E and F; the milestone's default is one issue per PR and the
PR body says so (§7.1). The order is fixed: 8 first (the live suite is the
instrument that measures the killed-tab number 10 retires, and the caveats are
measured **before** the watchdog exists — the negative control); then 9 (the
console changes, whose live evidence the suite records); then 10 (the watchdog,
after which the suite's kill group asserts the opposite of what it asserted in 8).

Budget: about two hours of live-guest time (§5), the rest is editing. The
protocol is ordered so the stack is relaunched twice at most (once per composed
realtime rate).

---

## 0. Ground truth the implementer must know

**Repo.** `origin/main` is `37ab3f4` (*Merge pull request #80 from
alius-git/console/61-console-live*, 2026-09-07). Local `main` is at it. **The
working tree carries uncommitted deck work** — `M slides/slides.md` and four
untracked files under `slides/` — that is the maintainer's and is not this PR's:
branch from `main`, never `git add -A`, stage files by name. No `stack/65-*`
branch exists.

**Host.** `google-chrome` 151, **`firefox` 154 (snap)**, `python3` 3.12, `virsh`,
`ssh`. The console server is running on `:8000` (`serve.py`, out dir
`~/kennel-runs`, five run folders, `verify.json` in the newest three);
`~/kennel-runs/.kennel-bridge` and `.kennel-meshcat` are absent — `teleop stop`
removed them. Nothing is holding `/quad_control_target` from the host.

**Guest.** `kennel-vm` at `192.168.122.32` (user `yuuser24`, key
`~/git/yuruna/test/status/ssh/yuruna_ed25519`), container `dfki_quad` running,
applied run `run-20260907T144210Z` (OSQP, flat plane, **`simulator_realtime_rate
0.5`**), stack launched 15:59Z by the p21 launcher (`/tmp/p21-env.sh` is the
canonical chain verbatim; `/tmp/p21-{sim,legdrv,ctrl}.log`). Bridge **not** up;
no `/tmp/k13-*.pid`, no `/tmp/p21-trot-pub.pid`. The container's `/root` holds
only `k13-stop.sh` and `kennel-verify.sh` — every other tool is staged per use.
`kennel-demo.sh status` reports Meshcat reachable, bridge not up.

**The live probe this plan ran** (`scratchpad/probe-reset.py`, an rclpy node in
the container; 4 s baseline, three gait changes, one `/reset_sim`, 25 s after):

| Observation | Value | Consequence |
|---|---|---|
| the robot as found, 3.5 h into the session, gait `STAND`, no publisher | **z = 0.1325 m**, x = 12.05 m, all four feet in contact | the long-session collapse `dashboard.md` §5 recorded, seen a third time; it is #66's "fallen robot" case for free |
| `simple_gait_sequencer.gait = STATIC_WALK` | `/gait_state` = `1.25 / 0.8 / [0, 0.5, 0.75, 0.25]` **within 1 s** | `gait.cpp:756` at the pin, verbatim; *active* is decidable from the wire |
| `= GARBAGE` | `successful: true`; signature **unchanged** for 3 s | *refused* is a real state, and the 2-s bound of #66 is generous |
| `= STAND` | `0.5 / 1.0 / [0,0,0,0]` within 1 s | — |
| `/reset_sim {pose.position.z: 0.4, orientation.w: 1, joint_positions: []}` | `success: true` in **0.01 s** wall; sim log *"No or the wrong number of joint positions specified, joint positions will be reset to default values"*, *"Simulation reset was performed"* | an **empty** joint list makes the simulator use its own `initial_joint_positions` — the stock spawn, no constants in the page |
| the sim clock | **4573.371 → 0.000** | `RosbridgeDataSource.restart()` already narrates this (`sim clock restarted at … — windows cleared`); nothing to add |
| the controller across the jump | heartbeat 2 Hz sim throughout (14 → 38 beats in 12.5 sim-s), `/gait_state` ~50 Hz, `/quad_state` 1 kHz sim, no gap | rcl re-bases its timers on a backwards jump; **no stall, no relaunch** |
| the robot after the reset | z 0.318 at 0.25 sim-s (falling from 0.4), 0.260 at 0.5 (landing), 0.302 at 1.0, settles **0.3126 m**; x 12.05 → 0.034; vx 0 | from a collapsed robot at STAND with a zero target, `/reset_sim` alone restores standing in **≈ 1 sim-s**; the controller's target survives the reset untouched (`mit_controller_node.cpp:793–798` copies only what arrives) — which is exactly why the zero must go first |

The guest was left **standing at the origin, gait `STAND`, sim clock young**
(it read ~12 s when the probe ended). The `run` in §5 row 1 relaunches anyway.

**At the pin** (`git -C dfki-quad show dcf53c59:<path>` — never the working tree):

- `ws/src/interfaces/srv/ResetSimulation.srv`: `geometry_msgs/Pose pose`,
  `float64[] joint_positions` → `bool success`. `ros2 service type /reset_sim`
  on the guest says the same.
- `ws/src/simulator/src/drake_simulator.cpp:477–527`: the handler stops the sim
  thread, builds a **new default context** (so the clock restarts at 0), sets the
  19-vector `[q_w q_x q_y q_z x y z, 12 joints]` from the request, uses the
  parameter's joint positions when the request does not carry exactly 12, and
  answers `success: true`. `initial_robot_height` is **0.4** in
  `ws/src/simulator/config/simulator_params_go2.yaml` (the composer never touches
  it — `composer-scope.md`); the controller's `initial_height` is 0.30
  (`mit_controller_sim_go2.yaml:4`), which is where it stands afterwards.
- `ws/src/controllers/src/mit_controller_node.cpp:649–651`: the
  `/quad_control_target` subscription is **`QOS_RELIABLE_NO_DEPTH`** — reliable,
  volatile (`ros2 topic info -v` confirms; so is `joy_to_target`'s publisher). One
  delivered zero is enough; the watchdog's repeat (§4.1) is for a *reconnect*, not
  for a lost datagram.
- `ws/src/controllers/src/mit_controller/gait.cpp:748–783`: the ten signatures,
  identical to `GAIT_TABLE` in `kennel-verify.sh`'s embedded `check.py`
  (`stack/verify/kennel-verify.sh:337–349`). Copy from there, cite both.
- `ws/src/drivers/src/leg_driver.cpp:348–374`: **E-STOP is
  `LegDriver::EMERGENCY_DAMPING`, and it can be left** — only into `DAMPING`, by
  the sibling Trigger **`/set_damping_mode`** (`:340–346, :366–369`); `DAMPING`
  returns to `OPERATE` by itself as soon as a leg command and a quad state
  arrive (`:233–237`, *"Leg cmd message and quadt state received, switching to
  operation"*). Nobody has used this: the console-live pass relaunched the stack
  after every E-STOP (`dashboard/evidence/03b-relaunch.txt`, `04-relaunch.txt`).
  It is what lets the live suite E-STOP and still be *green twice in a row on a
  running stack*, and what `reset sim` needs to restore a damped robot (§3.1).
- `ws/src/interfaces/msg/GaitState.msg`: `period`, `duty_factor[4]`,
  `phase_offset[4]`, `contact[4]`, `phase[4]`, `gait_sequencer` — no name, no header.

**The image.** rosbridge `2.0.7`. rclpy's `Node.create_subscription` has **no
`ignore_local_publications`** (checked: `msg_type, topic, callback, qos_profile,
*, callback_group, event_callbacks, qos_overriding_options, raw`), so a node that
publishes on a topic it subscribes to hears its own messages. §4.1 designs
around it rather than filtering echoes.

**What the existing suites pin down** — these are constraints, and the six older
suites plus `verify-dashboard.sh`/`verify-runs.sh` stay green; `verify-teleop.*`
is the one #66 explicitly extends (appended groups only):

- `verify-teleop.py:236–254` (group 7): after the gait response the page text must
  contain `sent` and must **not** contain `gait WALKING_TROT active`. The plain
  fake bridge never publishes `/gait_state`, so *active* can only ever come from
  a message — keep it that way (§3.4) and make gait-following an **opt-in** fake
  mode used only by the appended groups (§3.5).
- `verify-teleop.py:187–190`: `ops("subscribe")[0]` is the `/quad_control_target`
  probe; `verify-dashboard.py:461–467`: the same, then every `LIVE_TOPICS` entry
  subscribed. A further `/gait_state` subscribe from the target, **after**
  `advertise`, breaks neither.
- `verify-teleop.py:264–277` (group 8): the last message the bridge ever received
  is a zero and an `unadvertise` was sent. `leave()` is untouched.
- `verify-dashboard.py:643`: the feed line `^sim clock restarted at [\d.]+ s —
  windows cleared$` — `narrate('reset', …)` stays byte-identical; the reset
  *button's* own line is a new `narrate` kind (§3.3).
- Every suite's `__click` takes the **first** element whose exact text matches:
  never add an element reading `reset sim`, `STAND`, `E-STOP`, `connect bridge`,
  `Dashboard`, … ahead of the existing one. Append at the end of the row.
- `verify-serve.sh`: no new vendored asset, no literal `http`/`ws` URL in `src=`/`href=`.
- Zero non-localhost requests and no thrown error on any bridge message: a
  `service_response` whose `values` has a shape the page did not expect must be
  ignored, not dereferenced.

**Read first.** `CLAUDE.md`; `plan/teleop-joystick.md` D.3 (the caveats, verbatim
— they are #65's checklist); `kennel_console/teleop.md` §3–§5, §8, §10;
`stack/bridge.md` §3–§7; `stack/verify.md` §1.1, §2, §4.4; `stack/launch.md` §4,
§7; `stack/composed-run.md` §9.2 (the four defects a live protocol found — the
species to expect again); `kennel_console/dashboard.md` §2.2, §2.4, §5, §6;
`plan/scenarios.md` s004 steps 1 and 4; PR #59's and #80's bodies for the shape.

---

## 1. Shape of the work

- Branch `stack/65-teleop-hardened` from `origin/main` (`37ab3f4`).
- Four commits, in this order, house form `<type>(<area>): <what> (#N)`:
  1. `test(teleop): verify-teleop-live.sh asserts the teleop path on the real stack; the five D.3 caveats measured (#65)` — includes this plan file.
  2. `feat(console): reset sim calls /reset_sim in the measured sequence; the gait picker reports active or refused from /gait_state (#66)`
  3. `feat(stack): k13-target-watchdog.py — the guest-side dead man's switch, started and stopped with the bridge (#67)`
  4. `docs(stack): record the teleop-hardened pass — bridge.md §10–§11, teleop.md §5/§11/§12, evidence, runbook rows (#65, #66, #67)`
- New files: `stack/bridge/verify-teleop-live.sh` + `verify-teleop-live.py`
  (HOST), `stack/bridge/tools/k13-target-monitor.py` and
  `stack/bridge/tools/k13-target-watchdog.py` (CONTAINER),
  `stack/bridge/evidence/live/`. Modified: `stack/bridge/kennel-bridge.sh`,
  `demo/tools/kennel-demo.sh`, `stack/verify/kennel-verify.sh`,
  `kennel_console/Kennel Console.dc.html`, `kennel_console/fake-rosbridge.py`,
  `kennel_console/verify-teleop.sh` + `.py` (appended groups), and the records
  of §6.
- Every touched script keeps its header truthful (`# Version:` date, what,
  **where it runs**, usage, knobs, exit codes); the Python tools carry the same
  block as a docstring, as `record-fixture.py` does.
- **No new copy of the container source chain.** Everything guest-side goes
  through `kennel-bridge.sh`, which already carries the marked chain and
  `in_ctr`; the two Python tools are CONTAINER tools it copies in and runs
  through `in_ctr`. `composed-run.md` §9.2's registry of copies is unchanged.
  The host suite never sources anything — `set -uo pipefail` is fine there.
- **Append, never reorder** in the console; new controls at the end of their
  row, new `narrate` kinds at the end of the `switch`.
- Nothing here launches a process from the console. The watchdog is a child of
  `kennel-bridge.sh start`, i.e. of the `teleop` verb.

The architecture after step 10:

```
 host                         guest (kennel-vm)                      container (dfki_quad)
 ─────────────────────────    ───────────────────────────────────    ──────────────────────────────
 kennel-demo.sh teleop ─ssh─▶ kennel-bridge.sh start ── in_ctr ────▶ ros2 launch rosbridge_server …   /tmp/k13-bridge.pid
                              │  (KENNEL_WATCHDOG=1)  ── in_ctr ────▶ python3 k13-target-watchdog.py   /tmp/k13-watchdog.pid
 verify-teleop-live.sh ─ssh─▶ kennel-bridge.sh observe N ─ in_ctr ─▶ python3 k13-target-monitor.py     (one JSON line back)
   └ headless Chrome ── ws://GUEST:9090 ──────────────────────────▶ /rosbridge_websocket ──▶ /quad_control_target ◀── watchdog (only when stale)
                                                                                         └─▶ /mit_controller_node (RELIABLE, latest wins)
```

---

## 2. Step 8 — #65, the live suite and the caveats

### 2.1 `stack/bridge/tools/k13-target-monitor.py` — CONTAINER, the instrument

An rclpy node in the style of `check.py` (`spin_until`, `envf`, one `record`-like
printer), run through `kennel-bridge.sh observe` (§2.2). It watches the topics
that decide every #65/#67 assertion for a window measured in **sim seconds** from
`/clock` (the publisher is RELIABLE; subscribe BEST_EFFORT as `check.py` does
for the controller's topics, RELIABLE for `/quad_state` and
`/quad_control_target` as `k13-monitor.py` and `check.py` already do).

```
k13-target-monitor.py --sim-seconds N [--label L] [--rows]
```

Per-row CSV every 0.5 wall-s when `--rows` (`wall,sim,z,x,vx,wz,contacts,tgt_vx,tgt_wz,tgt_z,n_tgt,gait`),
and **one JSON line last** — the suite reads only that:

```json
{"label": L, "sim_window": 20.0, "wall_window": 40.1, "rtf": 0.50,
 "target": {"n": 401, "hz": 20.05, "gap_mean_ms": 49.9, "gap_std_ms": 3.1, "gap_max_ms": 71.0,
            "distinct_vx": [0.5], "last_wall": 1788806000.1, "last_sim": 31.2,
            "last_msg": {"body_x_dot": 0.5, "body_y_dot": 0, "world_z": 0.3, "hybrid_theta_dot": 0, "pitch": 0, "roll": 0},
            "last_nonzero_sim": 31.2, "last_nonzero_wall": 1788806000.1,
            "first_zero_after_nonzero_sim": null, "first_zero_after_nonzero_wall": null},
 "vx_mean": 0.46, "vx_min": 0.31, "vx_max": 0.55, "x_travel": 9.2,
 "z_median": 0.305, "z_min": 0.28, "z_max": 0.33, "tilt_over_frac": 0.0,
 "vx_below_0_05_since_sim": null,
 "gait": {"period": 0.5, "duty": 0.6, "offsets": [0, 0.5, 0.5, 0], "name": "WALKING_TROT"},
 "gait_changes": [{"sim": 12.3, "name": "WALKING_TROT"}],
 "n_state": 20010, "n_hb": 40, "hb_hz": 2.0}
```

- `hz`, `gap_*` are the inter-arrival statistics of `/quad_control_target` over
  the window — the `ros2 topic hz -w` numbers, from the same subscription that
  records the messages, so the rate and the payloads are one witness.
- `vx_below_0_05_since_sim`: the first sim time after which `|vx| < 0.05` has
  held for ≥ 0.5 sim-s (a threshold with hysteresis; a single sample under 0.05
  mid-stride is not a stop).
- `gait.name` is the table lookup (period ±1e-3, every duty and offset ±1e-3);
  `null` when nothing matches, which is itself a finding.
- `tilt_over_frac` uses `check.py`'s `roll_pitch` formula and `TILT_MAX_RAD` 0.5.
- Exit `0` · `2` no `/clock` or no `/quad_state` within 20 wall-s (prints which).
  Windows are bounded by `(N / rtf_floor) + 30` wall-s with `rtf_floor` 0.2 so a
  stalled sim cannot hang the suite.

### 2.2 `stack/bridge/kennel-bridge.sh` — two knobs, two verbs (both this step)

- **`observe SIM_SECONDS [--rows] [--label L]`** — `docker cp
  /tmp/k13-target-monitor.py` (staged by the caller, exit 2 naming the file if
  absent) to `/root/k13-target-monitor.py`, run it through `in_ctr`, pass stdout
  through untouched. Preconditions as `start`: container running, a live
  controller. Exit code is the tool's.
- **`recover`** — leaves emergency damping when the robot is down, and resets
  the simulator to the stock spawn, in the measured order (the same four steps
  the console's button runs, §3.1): `ros2 topic pub --times 10 -r 10
  /quad_control_target … zeros with world_z 0.30` → `ros2 param set … STAND` →
  `observe 1` for `z_median` → **only if `z_median < 0.15`**: `ros2 service call
  /set_damping_mode std_srvs/srv/Trigger` → `ros2 service call /reset_sim
  interfaces/srv/ResetSimulation "{pose: {position: {z: 0.4}, orientation: {w:
  1.0}}, joint_positions: []}"` → wait, bounded, for `/quad_state` z in
  `[0.25, 0.35]` for 1 sim-s (a second short `observe`, never a sleep). Prints
  each step's answer and whether the un-damping step ran. Exit `0` standing ·
  `1` the robot did not come back within the bound (names z) · `2` no stack. It
  is what the live suite runs after its E-STOP group so the stack is *left
  standing at STAND on every path*, and the guest-side proof of §3.1 before the
  console button exists.
- **`KENNEL_BRIDGE_POLL`** (default `1`, seconds) — the poll interval of
  `start`'s two-signal wait; and both `say` lines gain the elapsed time since the
  launch (`  /rosbridge_websocket in the graph (+2.31 s)`, `  port 9090 bound
  (+2.90 s)`) using `date +%s.%N`. That is D.3 §8's instrument (§2.6).
- **`KENNEL_BRIDGE_WAIT`** is measured in polls today; make it seconds
  (`WAIT / POLL` iterations) and say so in the header — the same
  iteration-count trap `composed-run.md` §9.3 left alone in `KENNEL_TOPIC_TIMEOUT`.

`start`'s watchdog half is step 10 (§4.2); do not add it here.

### 2.3 `stack/bridge/verify-teleop-live.sh` — HOST, the suite

Sibling of `verify-bridge-host.sh` in where it runs and how it finds the guest
(copy the lease-by-hostname region and `SSH_OPTS`, do not re-derive), and of
`verify-teleop.sh` in how it drives the page. Header: what, HOST, usage, knobs,
exit codes `0` every check passed · `1` a check failed · `2` could not run (no
Chrome, no guest, no stack, a port in use, not run from a checkout).

Knobs: `KENNEL_LIVE_PORT` (its own `serve.py`, default 8093, `--out $HOME/kennel-runs`
or `KENNEL_DEMO_OUT` — the **real** out dir, so `.kennel-bridge` written by
`teleop` reaches the page the way it does in use), `KENNEL_LIVE_CDP` (9293),
`KENNEL_LIVE_DRIVE_SIM_S` (20), `KENNEL_LIVE_QUICK=1` (skips the two-minute
`verify` group of step 10), and the pass-throughs `KENNEL_WATCHDOG`,
`KENNEL_WATCHDOG_STALE` (step 10; unknown to `teleop` until then and harmless).

Preconditions, checked (exit 2, each naming its fix): `google-chrome`;
`kennel_console/cdp.py` present (run from a checkout); the guest discovered and
`verify-meshcat-host.sh --quiet` green (a stack is up — else `kennel-demo.sh run`);
port `KENNEL_LIVE_PORT` free. **The bridge may already be up** — `teleop` is
idempotent — but the suite says so, because a page connected elsewhere would be
the second publisher.

Fixtures it owns: its `serve.py`; one headless Chrome —
`--headless --disable-gpu --no-sandbox --no-zygote --user-data-dir=<tmp>
--host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost" --remote-debugging-port=$CDP`
(`--no-zygote` so the renderer is a **direct child** of the browser process and
`pgrep -P "$chrome" -f -- '--type=renderer'` finds it for group 6; the DNS
blackhole does not stop the `ws://192.168.122.x` IP literal, which is the point).
Staged to the guest by the suite itself: `stack/bridge/tools/k13-target-monitor.py`
(`scp` to `/tmp/`, exactly as `guest_stage` does).

`trap` on every exit: `kennel-demo.sh teleop stop` (zero, STAND, bridge down —
in that order, as the verb does), kill Chrome and the server, remove the temp
dir, print `left: gait STAND, bridge down`. The E-STOP group (7) is followed by
`recover` inside the suite, so the trap never has to undo damping.

| # | Group | Does | Asserts — and from which witness |
|---|---|---|---|
| 0 | the verb | `kennel-demo.sh teleop` | exit 0; `curl :$PORT/api/health` carries `bridge` equal to the URL `verify-bridge-host.sh --quiet` prints, and `meshcat` (wire: the suite's own server) |
| 1 | connect | load the page, Dashboard, `connect bridge` | the page reaches `driving` within 5 s (DOM: the bridge status item); `observe 5` on the guest: `target.hz` 20 ± 2, every `distinct_vx` is `0.0`; `mode · live` (DOM) |
| 2 | drive | gait `WALKING_TROT` via the picker, `__stick(0,-1,'pointerdown')`, then `observe $DRIVE_SIM_S` | `target.hz` 20 ± 2; `gap_std_ms` recorded (D.3 §6); `vx_mean ≥ 0.15`; `x_travel > 0`; `z_median` in `[0.20, 0.45]`; `tilt_over_frac ≤ 0.02`; `gait.name == WALKING_TROT`; the page's status says `driving · 20 Hz · N msgs` with N growing (DOM) |
| 3 | release | `pointerup`, `observe 6` | `target.first_zero_after_nonzero_sim` is set; `vx_below_0_05_since_sim − first_zero_after_nonzero_sim ≤ 3.0` |
| 4 | STAND | click `STAND`, `observe 3` | `gait.name == STAND`; `target.last_msg` all zero; (after step 9: the picker says `active` — DOM) |
| 5 | the probe refuses a held trot | click `disconnect bridge` **first** (a page already driving is past its probe — that case is row 3 of §5, the jitter); `kennel-demo.sh walk`; `connect bridge` → the page's bridge item shows `refused`; `walk stop`; `disconnect bridge`, `connect bridge` again | `refused` and `another publisher is holding` (DOM); after `walk stop` and the reconnect, `driving` — D.3 §4's *"the probe refusing"* half, asserted |
| 6 | **the killed renderer** | gait `WALKING_TROT`, stick forward until `observe 4` shows `vx_mean ≥ 0.15`; start `observe 30 --rows` in the background over ssh (`> $tmp/kill.json`); `kill -9` **every** `--type=renderer` child of the browser (there are at least two: the page's, and the cross-origin Meshcat iframe's — site isolation gives it its own process); assert the kill took: `kill -0` fails for each PID within 1 s and `Runtime.evaluate` on the page target now fails; wait for the observe | **step 8:** `vx_mean` over the window `≥ 0.15` and `vx_below_0_05_since_sim == null` — the robot kept walking with nobody at the controls; `target.last_wall` is inside the first seconds of the window (publishing really stopped — the guest is the witness, not Chrome); then `kennel-demo.sh teleop stop` and `observe 5`: `vx_below_0_05_since_sim` set. The record's number is `x_travel` and `sim_window` of the kill observe: **how far and how long it walked unattended** (D.3 §5). **Step 10 rewrites this cell** (§4.5) |
| 7 | E-STOP | start a new Chrome (the old one is dead), connect, gait `WALKING_TROT`, drive 3 sim-s, click `E-STOP`, `observe 4` | `z_median < 0.15`; `target.last_msg` zero; the page says `emergency damping requested` (DOM); then `kennel-bridge.sh recover` → exit 0 and a final `observe 3`: `z_median` in `[0.25, 0.35]`, `gait.name == STAND` |
| 8 | teardown | `kennel-demo.sh teleop stop` | exit 0; over ssh: `ss -ltn` has no `:9090`; in the container `ps` has no `rosbridge_websocke[t]` / `rosapi_nod[e]`; `kennel-demo.sh status` prints `bridge not up`; `/api/health` `bridge` is `null` |
| 9 | the page | | zero uncaught errors (the collector of `verify-teleop.py`); zero requests to anything but `localhost` and the guest IP (the guest is the one permitted off-host origin, and the suite says so) |

Every guest number is read from the JSON the monitor printed, every page fact
from the DOM, every wire fact from the guest — never a variable read back out of
the page under test (`dashboard.md` §4's rule). `[PASS]/[FAIL]` per line, the
totals last, the way the other suites print.

### 2.4 `stack/bridge/verify-teleop-live.py` — the CDP driver

`from cdp import attach` after `sys.path.insert(0, <repo>/kennel_console)`; the
`HELPERS` block of `verify-teleop.py` copied verbatim (copy, do not import — the
other suites' rule), plus `__bridgeItem()` (the status-bar `bridge` value) and
`__gaitMsg()` (the teleop message line). It takes the ports, the bridge URL and
the guest's JSON files as arguments, and does the page half of each group; the
bash side runs `observe`, the kill, and the verbs, and calls the driver once per
group with a `--group N` argument so the two halves interleave in the order of
the table. The kill is bash's: `pgrep -P "$chrome" -f -- '--type=renderer'`
must return **at least one** PID (else FAIL — nothing to kill means the flags
changed), and every one of them gets `kill -9`; the transcript records how many
there were and which one Chrome's `/json` had named as the page.

### 2.5 Twice in a row

The acceptance is *green twice in a row on a running stack*. Group 7 ends with
`recover`, group 8 with `teleop stop`, so the second invocation starts from a
standing robot at `STAND` with no bridge. Run it twice, keep both transcripts
(§5 rows 4a/4b); the second run's numbers are the ones the record quotes,
because the first run's kill group is also the negative control for step 10.

### 2.6 The caveats of D.3, each with a number

| D.3 | How | Evidence (`stack/bridge/evidence/live/`) | Where the number goes |
|---|---|---|---|
| §4 two-publisher jitter | the *reproduction*: page driving at 0.5 m/s, then `kennel-demo.sh walk` (the driver warns, proceeds) → `observe 10 --rows`: `target.hz` ≈ 30, `distinct_vx` = `[0.3, 0.5]`, the vx rows alternating; then `kennel-demo.sh teleop` → `observe 5`: `distinct_vx` = `[0.5]`. The *prevention* half is suite group 5 | `03-jitter.txt` | `bridge.md` §7 gains the measured trace; runbook row *"jitters between two speeds"* cites it |
| §5 killed renderer | suite group 6, step-8 form, twice | `04a-`, `04b-live-suite.txt` | runbook row *"You closed the browser tab and the robot kept walking"*: **measured** `x_travel` m in `sim_window` s at rate r, *then* retired by step 10 |
| §6 bridge CPU and lag | during group 2 of each suite run, on the guest: `sudo docker exec dfki_quad top -b -d 5 -n 3 -p "$(sudo docker exec dfki_quad pgrep -f 'rosbridge_server/rosbridge_websocke[t]')"`; `gap_std_ms`/`gap_max_ms` from the group-2 JSON; once at rate 0.5 (row 4) and once at **1.0** (row 5: `KENNEL_RATE=1.0 kennel-demo.sh compose` → `run`) | `05-cpu-lag-rate05.txt`, `05-cpu-lag-rate10.txt` | `bridge.md` §10 table |
| §8 readiness race | `for i in 1..10: KENNEL_BRIDGE_POLL=0.1 kennel-bridge.sh start; kennel-bridge.sh stop` over ssh, keeping the two `(+x.xx s)` lines of each start | `02-bridge-race.txt` — a 10-row table: which signal first, by how much | `bridge.md` §3 *"Readiness is observed twice"* gains the observed distribution; if one signal is **always** last, say so and keep the wait anyway (it costs nothing and #52 is the shape) |
| §7 Firefox | Firefox 154 is on the host. Drive it once: `firefox --headless --marionette -P <throwaway profile> http://localhost:$PORT/…`, then a stdlib TCP client on port 2828 speaking Marionette (`<len>:<json>` frames; `[0, id, "WebDriver:NewSession", {}]`, `"WebDriver:Navigate"`, `"WebDriver:ExecuteScript"` with the same `HELPERS` and `__connectBtn().click()`), then `observe 5` on the guest: `target.hz` 20 ± 2. Snap confinement may block the profile path or the port — try `$HOME/snap/firefox/common/` for the profile. If neither headless path works, run it **by hand** in a normal Firefox window (the maintainer's, or the implementer's if a display exists) and record `observe`'s JSON; if a private-network-access prompt or block appears, record its exact text | `06-firefox.txt` | `teleop.md` §11: *works / blocked, with what*; runbook §2 prerequisites if a browser setting is needed |

### 2.7 A person at the controls — the one item this agent cannot do

An agent has no mouse. Create `stack/bridge/evidence/live/20-friction-human.md`
as the template the maintainer fills: the `dry-run.md` §4 method (F-numbered
findings, one per line, *what felt wrong → cause → fix or bypass*), a row each
for mouse and for trackpad/touch, and the two numbers a hand would feel already
filled from the suite — the 5 % dead zone (`joySet`), and the ramp: 0 → 0.5 m/s
in **1.0 s** at 0.5 m/s² (group 2's `first_zero`/ramp rows). The PR body lists
this under *still open* (§7.1); it does not block the merge and the record says
who owes it.

### 2.8 Record

`kennel_console/teleop.md` **§11 "Tested live"**: the suite, its groups, the
twice-in-a-row transcripts, the caveat table with numbers, the Firefox result,
the open human session. `stack/bridge.md` **§10 "Measured under load"**: CPU and
lag at both rates, the race distribution, the jitter trace, and the verbs
`observe`/`recover` with the un-damping finding (nobody had left
`EMERGENCY_DAMPING` before — cite `leg_driver.cpp`). `demo/runbook.md` §3 gains
the `verify-teleop-live.sh` row under *Also there when needed* (it is a test, not
a demo phase); §5 rows updated per the table above.

---

## 3. Step 9 — #66, `/reset_sim` and *active*

### 3.1 The sequence, measured — what the button does

From §0's probe: zero target → `STAND` → `/reset_sim {z: 0.4, w: 1, joint_positions: []}`
restores a collapsed robot to standing in ≈ 1 sim-s, the controller never
stops, and the trailing `STAND` the issue expected is not needed (the gait is
already `STAND` when the call goes out; a second set would only reload the
sequencer). What the probe did **not** cover is a robot in emergency damping
(§0: E-STOP is `LegDriver::EMERGENCY_DAMPING`, left only through
`/set_damping_mode`). A reset that leaves the driver damped spawns a robot that
crumples on landing — a "reset" that restores nothing. So the sequence has one
conditional step:

```
1. hard zero on the wire            publish()  (only if driving — there is nothing of ours to zero otherwise)
2. STAND                            call_service SetParameters  … await the response
3. if the robot is down (z < 0.15)  call_service /set_damping_mode std_srvs/srv/Trigger  … await   ← leaves EMERGENCY_DAMPING; DAMPING → OPERATE by itself
4. reset                            call_service /reset_sim interfaces/srv/ResetSimulation {pose:{position:{x:0,y:0,z:0.4},orientation:{x:0,y:0,z:0,w:1}}, joint_positions: []}
```

`z` is the newest `/quad_state` height the DataSource holds
(`ds.last().height`); 0.15 is the issue's own E-STOP criterion and well below
the fall rule's 0.20 floor. Step 3 is **runtime-verified first** (§5 row 7, on
the guest with `kennel-bridge.sh recover`) and then wired; if the from-`OPERATE`
case ever needs it (it should not: the guard skips it), the leg driver's blip
through `DAMPING` is one cycle and the record says so. **Never** call
`/set_damping_mode` unconditionally — a standing robot is not to be touched.

What the *reset sim* button does, by state (`onReset`, console `~3169`):

| State | Action |
|---|---|
| mock (no link, or under plain `http.server`) | exactly today: `ds.stop(); ds.reset(); ds.start()` |
| link open, target `driving` | the sequence above; the feed gets §3.3's line; `gaitSel` → `STAND` |
| link open, target `refused` | nothing on the wire; message *"another publisher is holding /quad_control_target — `kennel-demo.sh walk stop`, then reset"* — a reset under a held trot is the two-publisher trap with a fall attached |
| link open, target `probing` | *"listening for another publisher — try again in a second"* |
| link `connecting`/`error`/`closed` | *"not connected — nothing was sent"* |

The DataSource's own `restart()` fires when `/clock` jumps back and clears the
windows — s004 step 4's *"plots and counters cleared"*. The controller's
cumulative `num_*` counters are **not** cleared by a sim reset (the controller
was not restarted), and the health counters on screen are the controller's own
values (`dashboard.md` §2.5): the record says so, and the feed line makes it
visible rather than surprising.

### 3.2 `RosbridgeTarget.resetSim(zNow)` — console `~1635–1797`

```js
const RESET_SRV = '/reset_sim';
const RESET_TYPE = 'interfaces/srv/ResetSimulation';
const UNDAMP_SRV = '/set_damping_mode';          // leg_driver.cpp:54-55 at the pin: leaves EMERGENCY_DAMPING
const RESET_Z = 0.40;                             // simulator_params_go2.yaml initial_robot_height at the pin; the composer never changes it
const DOWN_Z = 0.15;                              // #66's E-STOP criterion; below verify.md §4.2's 0.20 floor
function resetArgs() { return {pose: {position: {x: 0, y: 0, z: RESET_Z},
                                      orientation: {x: 0, y: 0, z: 0, w: 1}},
                               joint_positions: []}; }   // [] -> the simulator's own initial_joint_positions (drake_simulator.cpp:508-512)

resetSim(zNow) {
  if (this.state === 'refused') { this.say('another publisher is holding ' + TELEOP_TOPIC + ' — kennel-demo.sh walk stop, then reset', true); return; }
  if (this.state === 'probing') { this.say('listening for another publisher — try again in a second', true); return; }
  if (!this.open()) { this.say('not connected — nothing was sent', true); return; }
  this.panic();                                                    // 1. the zero, now
  this.say('reset: target zeroed, STAND …', false);
  this.link.call(CTRL_PARAM_SRV, CTRL_PARAM_TYPE, gaitArgs('STAND'), () => {      // 2.
    const go = () => this.link.call(RESET_SRV, RESET_TYPE, resetArgs(), m => {   // 4.
      if (m.result === false) this.say('the simulator refused the reset: ' + JSON.stringify(m.values || ''), true);
      else this.say('sim reset — spawned at z ' + RESET_Z.toFixed(2) + ' m, the simulator\'s own joint positions; the sim clock restarts', false);
      this.gaitWant = 'STAND'; this.gaitState = 'sent'; this.gaitT0 = performance.now();   // STAND is what /gait_state must now show (§3.4)
    });
    if (typeof zNow === 'number' && zNow < DOWN_Z) {                                // 3.
      this.say('the robot is down (z ' + zNow.toFixed(3) + ' m) — leaving emergency damping first', false);
      this.link.call(UNDAMP_SRV, ESTOP_TYPE, {}, go);
    } else go();
  });
}
```

`gaitArgs(name)` is the payload `setGait` already builds, factored so the two
share one function. The Component's `onReset` becomes: `if (tp && link open)
{ tp.resetSim(ds.last() ? ds.last().height : NaN); ds.emit('resetSim', 'info',
narrate('resetSim', {z: RESET_Z}), 0); this.setState({gaitSel: 'STAND', pinFall:
false, detail: null}); } else { today's mock branch }`. No `setState` inside
the target; the `sink` renders.

### 3.3 The feed

One new `narrate` kind, appended before `default`:
`case 'resetSim': return '/reset_sim called — spawn at z ' + d.z.toFixed(2) + ' m, the simulator\'s own joint positions; the sim clock restarts';`
The existing `'reset'` case (*sim clock restarted at … — windows cleared*) is
**unchanged** — `verify-dashboard.py:643` matches it by regex. Live, the two
lines appear in that order a few hundred ms apart; the suite asserts the first
from the DOM, the live evidence shows both.

### 3.4 Gait **active** / **refused** — `RosbridgeTarget`, and only there

The DataSource already holds the newest `/gait_state` (`ds.latest`), but the
target must not reach into the DataSource (`teleop.md` §2: `this.ds` and
`this.tp` never talk). The target subscribes itself, **in `drive()` after
`advertise`** — so `ops("subscribe")[0]` stays the probe and nothing is
subscribed when refused — with `throttle_rate: 100` (10 Hz is plenty; rosbridge
takes the minimum over subscriptions, so the DataSource's 20 ms is untouched):

```js
const GAIT_TABLE = {   // GaitDatabase::getGait, gait.cpp:748-783 at the pin == check.py's GAIT_TABLE (kennel-verify.sh:337-349). Three copies; a drift shows as `refused` on a gait that loaded, which is loud.
  STAND: [0.5, 1.0, [0, 0, 0, 0]], STATIC_WALK: [1.25, 0.8, [0, 0.5, 0.75, 0.25]],
  WALKING_TROT: [0.5, 0.6, [0, 0.5, 0.5, 0]], TROT: [0.5, 0.5, [0, 0.5, 0.5, 0]],
  FLYING_TROT: [0.4, 0.4, [0, 0.5, 0.5, 0]], PACE: [0.35, 0.5, [0, 0.5, 0, 0.5]],
  BOUND: [0.4, 0.4, [0, 0, 0.5, 0.5]], ROTARY_GALLOP: [0.4, 0.2, [0, 0.8571, 0.3571, 0.5]],
  TRAVERSE_GALLOP: [0.5, 0.2, [0, 0.8571, 0.3571, 0.5]], PRONK: [0.5, 0.5, [0, 0, 0, 0]]
};
const GAIT_SETTLE_MS = 2000;   // #66: refused when the signature has not changed 2 s after `successful: true`; measured switch time < 1 s (plan G §0)
function sigMatches(g, want) { const [T, duty, off] = want; const near = (a, b) => Math.abs(a - b) < 1e-3;
  return !!g && near(g.period, T) && (g.duty_factor || []).length === 4 && g.duty_factor.every(d => near(d, duty))
         && (g.phase_offset || []).length === 4 && g.phase_offset.every((o, i) => near(o, off[i])); }
```

State on the target: `gaitWant`, `gaitState` (`idle | sent | active | refused`),
`gaitT0`, `gaitSig` (the newest message), `gaitSubId`. `setGait(name)` sets
`gaitWant = name; gaitState = 'sent'; gaitT0 = now`, sends the call as today, and
on `successful: true` says *`gait NAME sent — waiting for /gait_state`* and arms
one bounded timer (`GAIT_SETTLE_MS`): if still `sent` when it fires →
`refused`, *"gait NAME refused — /gait_state unchanged 2.0 s after the node
reported success (it ignores names it does not know; launch.md §4.1)"*. The
subscription callback: `gaitSig = m; if (gaitState === 'sent' && gaitWant in
GAIT_TABLE && sigMatches(m, GAIT_TABLE[gaitWant])) { gaitState = 'active';
say('gait NAME active — /gait_state ' + T + ' / ' + duty + ' / [' + offsets + '] in ' + ((now − gaitT0)/1000).toFixed(2) + ' s'); }`.
Selecting the gait that is already running goes `sent → active` on the next
message, which is right. `close()`/`disconnect()` unsubscribe `gaitSubId` and
clear the timer; `leave()` is untouched (the socket is closing).

The wording keeps `verify-teleop.py:251–252` true by construction: *active*
appears only after a `/gait_state` message, and the plain fake never sends one.
The message line (`teleopMsg`, template `~374`) is the DOM the suites read; the
status-bar `bridge` item is unchanged.

### 3.5 `kennel_console/fake-rosbridge.py`

- **Answer each service in its own shape** — today every `call_service` gets
  `{results: [{successful: true}]}`. Keep that for `set_parameters`; answer
  `/reset_sim` with `values: {success: true}`, a `std_srvs/srv/Trigger` with
  `values: {success: true, message: ''}`, anything else with `{}`.
  `--refuse-service` keeps answering `result: false` for all.
- **`--gait-follow`** (opt-in; the existing fixtures are byte-for-byte as they
  behave today): the fake carries the ten-entry table (a fourth copy — a test
  fixture's, cited), starts at `STAND`, and on a `set_parameters` call whose
  parameter is `simple_gait_sequencer.gait` with a **known** name switches its
  current signature (an unknown name still answers `successful: true` and
  changes nothing — exactly the node). On a `/gait_state` subscribe it starts a
  10 Hz thread publishing `{period, duty_factor[4], phase_offset[4], contact[4],
  phase[4], gait_sequencer: 0}` with the current signature until unsubscribe or
  close. The throttle rule and the send lock already exist.
- **`--drop TOPIC`** (repeatable, replay mode): never deliver that topic from the
  fixture. Both recordings carry the held trot's `/quad_control_target` at
  10 Hz, so a page connecting to a plain replay **refuses** to drive — the very
  render in `dashboard.md` (`BRIDGE refused`, panels live). Group 14 needs a
  fallen robot *and* a driving page, so its replay drops the target topic.

### 3.6 `verify-teleop.sh` + `verify-teleop.py` — groups 13–17, appended

Two more fixtures, on `BRIDGE_PORT + 2` (`--gait-follow`) and `+ 3`
(`--replay fixtures/fall.jsonl.gz --drop /quad_control_target`, the 25-s fall
recording the dashboard suite already uses, minus the held trot that would
make the probe refuse), started beside the others; groups 1–12 untouched.

| # | Asserts (wire = the fixture's ops log; DOM = `__txt()`) |
|---|---|
| 13 | *reset while driving* (main fake): connect, drive, click `reset sim` → in the log, in `t` order: one all-zero `publish`, a `call_service` `set_parameters` with `STAND`, then `call_service` `service == /reset_sim`, `type == interfaces/srv/ResetSimulation`, `args` **equal** to `resetArgs()` above (`joint_positions` is `[]`); **no** `/set_damping_mode` call (the plain fake publishes no `/quad_state`, so z is unknown and the guard skips); DOM: `sim reset —`; the feed contains `/reset_sim called` |
| 14 | *reset from a fallen robot* (the fall replay on `+3`): connect, wait for the fall banner (the dashboard suite's own wait, `FALL` in the DOM, ≤ 25 s), click `reset sim` → `/set_damping_mode` **precedes** `/reset_sim` in the log, both after the `STAND` call |
| 15 | *reset refused under a held trot* (the foreign fake): connect (refused), click `reset sim` → no `call_service` at all in the foreign log; DOM names `walk stop` |
| 16 | *active / refused* (`--gait-follow` on `+2`): connect, drive; the log shows a `/gait_state` subscribe **after** the `advertise`; pick `WALKING_TROT` → DOM `gait WALKING_TROT active` within 3 s and the `in 0.xx s` figure present; inject an option into the picker from the suite (`const o = document.createElement('option'); o.value = 'GARBAGE'; __gaitSel().appendChild(o)`) and `__set(__gaitSel(), 'GARBAGE')` → the wire carries `string_value: GARBAGE`, DOM `gait GARBAGE refused` after ≥ 2 s and never `active`; pick `STAND` → `active`; disconnect → an `unsubscribe` for `/gait_state` |
| 17 | *plain `http.server`*: `reset sim` still resets the mock — the status bar's `sim t` returns to `0.0 s`; zero sockets, zero errors, zero placeholders |

Expected count: 51 → about 70 checks. `verify-teleop.sh`'s header and the
`fake bridges recorded …` line list the four fixtures.

### 3.7 Live evidence and records

§5 rows 7–9. `kennel_console/teleop.md` **§12 "Interventions over the bridge"**:
the sequence with the probe's numbers, the un-damping step and why it is
conditional, the state table of §3.1, the signature table with its three
sources, the wording rules, the suite groups, the live transcripts.
`stack/launch.md` §4.3 rewritten from *"the call is spelled out in upstream's
README"* to the measured sequence (and that the README's example joint vector
is a real robot's pose, not the sim's spawn — the empty list is the sim's).
`stack/bridge.md` §5.1 gains the `/reset_sim` and `/set_damping_mode` rows and
the un-damping finding under §10. `teleop.md` §10's *"No `/reset_sim`"* bullet
→ struck, pointer to §12; `dashboard.md` §6's *"The interventions still drive
the mock"* → *reset* done, *inject* still #68 (say so, do not rewrite). #68 is
untouched: `inject` keeps saying it is not wired.

---

## 4. Step 10 — #67, the watchdog

### 4.1 `stack/bridge/tools/k13-target-watchdog.py` — CONTAINER

An rclpy node `k13_target_watchdog` (graph name `/k13_target_watchdog`), the
`check.py` style, ~120 lines. Subscribes `/quad_control_target` RELIABLE depth
10; publishes the same topic RELIABLE depth 1 (matching the controller's
`QOS_RELIABLE_NO_DEPTH` subscription, §0). A 0.1-s wall timer
(`time.monotonic()` — staleness is a property of *publishers*, which run on
wall clocks whatever the composed rate; the robot's stopping time is measured
in sim seconds by the monitor, and the record states both).

Rules, in order:

1. **Never before the first message.** `last is None` → do nothing, forever if
   need be. A fresh stack, where `joy_to_target` is idle and nothing has spoken,
   is never touched.
2. **Stale and armed → intervene.** `age = now − last.wall ≥ STALE` **and**
   `nonzero(last.msg)` (`body_x_dot`, `body_y_dot`, `hybrid_theta_dot` — any
   non-zero) → publish the zero: all six fields, **`world_z` copied from
   `last.msg`**, pitch and roll 0 (`launch.md` §4.2 — the one function that
   builds the message fills all six, as the page's does). Count it as one
   intervention, log it, and set `last = (zero, now)` — the controller's
   subscription is reliable, so what it now holds is known.
3. **Bounded repeat, not "until fresh".** The intervention arms a burst:
   `REPEAT − 1` further zeros at 1-s intervals (default `REPEAT = 3`), cancelled
   by any message that is **not** our own zero. The issue's *"once per second
   until a fresh message arrives"* would make the watchdog a permanent
   publisher after a kill — and the page's probe, on reconnect, would count its
   zeros as a foreign publisher and **refuse**, which is the reconciliation the
   same issue asks for. Two seconds of repeats, then silence, keeps both.
4. **Own echoes need no filter.** rclpy cannot ignore local publications (§0),
   so the watchdog hears its own zeros. It does not matter: an echo sets
   `last` to a zero, which never triggers rule 2, and the burst runs on its own
   counter. A page that reconnects and drives sends non-zero targets, which
   re-arm it. The record says this in one paragraph so nobody adds a filter.
5. **Never touches the gait.** No parameter call, no service call, ever.

Log (`/tmp/k13-watchdog.log` by redirect), one line per event:
`[watchdog] ready — stale after 1.0 s, repeat 3, waiting for the first target`,
`[watchdog] armed: vx=0.500 wz=0.000 z=0.300 (first non-zero target)`,
`[watchdog] INTERVENTION #1: stale 1.04 s, last vx=0.500 vy=0.000 wz=0.000 z=0.300 → zero published, world_z 0.300 kept; repeating 2× at 1 s`,
`[watchdog] quiet: fresh target from another publisher`. It also rewrites
`/tmp/k13-watchdog.state` on every change — `armed|idle <wall> <vx> <wz> <z>
interventions=<n>` — the observable `stop` and `status` read (§4.2).

Knobs: `KENNEL_WATCHDOG_STALE` (1.0), `KENNEL_WATCHDOG_REPEAT` (3). Exit `0` on
SIGINT/SIGTERM after a final `[watchdog] interventions=<n>` line · `2` rclpy
could not initialise.

### 4.2 `kennel-bridge.sh` — `start | stop | status` grow the watchdog

- `start`: after the bridge's two signals, when `KENNEL_WATCHDOG` ≠ `0`: require
  `/tmp/k13-target-watchdog.py` on the guest (exit 2: *"the watchdog tool is not
  staged — run through `kennel-demo.sh teleop`, or `KENNEL_WATCHDOG=0`"*),
  `docker cp` it to `/root/`, launch detached through `in_ctr` with
  `> /tmp/k13-watchdog.log 2>&1 & echo $! > /tmp/k13-watchdog.pid` (the PID is
  `python3`'s own — no `$$`-in-a-subshell trap, `launch.md` §7 trap 4), then
  wait, bounded by `KENNEL_BRIDGE_WAIT`, for **two** signals: `/k13_target_watchdog`
  in `ros2 node list` and the `ready` line in the log. Idempotent like the
  bridge (pid alive → *"already up"*). `k13-stop.sh` reaps `/tmp/k13-*.pid` by
  PID, so `down`, the pre-launch stop and the baseline prep script get it for
  free — **verify this by running `down` alone against a running watchdog**
  (§5 row 11), as `bridge.md` §4.2 did.
- `stop`: **the bridge first, the watchdog last.** After the bridge is down a
  page that was mid-hold goes silent, and the watchdog's whole purpose is the
  next `STALE` seconds. So: bridge stop as today → then poll
  `/tmp/k13-watchdog.state` until it reads `idle`, bounded by
  `STALE + REPEAT + 2` s → then INT the watchdog's PID, bounded wait, KILL,
  remove pidfile and state file. If the bound expires still `armed`, a
  publisher the bridge did not carry is holding a non-zero target (a `walk`):
  say so, stop the watchdog anyway (it never fires against a fresh publisher),
  exit 0.
- `status`: one more line — `watchdog  pid N alive · idle · interventions 0` /
  `watchdog  not running`; part of the exit code only when
  `KENNEL_WATCHDOG` ≠ `0`.
- Header: the verbs, the two knobs, the ordering argument, the `[]`-bracket rule
  is not needed here (the PID is the process).

### 4.3 `demo/tools/kennel-demo.sh`

`do_teleop` stages `stack/bridge/tools/k13-target-watchdog.py` beside
`kennel-bridge.sh` and passes `KENNEL_WATCHDOG` and `KENNEL_WATCHDOG_STALE`
on the ssh line (knobs are environment variables, passed through to the tool
that defines them — runbook §4 gains both rows); the closing lines say *the
watchdog zeros a stale target within N s if this page dies*. `teleop stop` is
unchanged (the script's `stop` does the ordering). `status`: after the bridge
line, the watchdog line from `kennel-bridge.sh status` when the bridge is up.
`help` and the header: nothing new to list — knobs are not verbs.

### 4.4 `stack/verify/kennel-verify.sh` check 1

`BRIDGE_NODES` (`:242–245`) gains `/k13_target_watchdog`; the comment,
`NODE_CRITERION` (`:261`) and the usage text (`:90–93`) say *"the four nodes a
teleop session adds (three rosbridge, one target watchdog)"*; `stack/verify.md`
§2's check-1 row and the paragraph under the table, `bridge.md` §6, and the
runbook's `extra:` row name four. Tolerated, never required — the watchdog's
participant lingers after a stop exactly as the bridge's do.

### 4.5 `verify-teleop-live.sh`, with the watchdog

- Group 1 gains: the watchdog log holds **no** `INTERVENTION` line after the
  connect and 5 s of driving zeros — the probe saw nothing because the watchdog
  said nothing (#67's reconciliation, asserted from the guest's log, not from
  the page).
- Group 6 becomes knob-aware. With `KENNEL_WATCHDOG=1` (default): from the kill
  observe's JSON, `first_zero_after_nonzero_wall − last_nonzero_wall ≤ STALE + 0.5`
  (the watchdog fired on time, in the clock it measures with) and
  `vx_below_0_05_since_sim − first_zero_after_nonzero_sim ≤ 2.0` (the robot
  stopped inside the issue's 2 s, in sim seconds); the log shows exactly one
  `INTERVENTION`; `state` reads `idle`. With `KENNEL_WATCHDOG=0`: the step-8
  assertions, unchanged — the old behaviour stays reachable and measured.
- New group 6b: reconnect **after** the burst (wait for `state` = `idle`, ≥ 3 s
  after the kill), `connect bridge` → `driving`, not `refused`. The limit
  (§8.4) is recorded, not asserted.
- New group 5b: `kennel-demo.sh walk` held for 10 sim-s → `observe 10`:
  `vx_mean ≥ 0.15`, and the log's intervention count **unchanged** — the 10 Hz
  hold is never stale. Then `walk stop`.
- New group 9b (skipped under `KENNEL_LIVE_QUICK=1`): with the page
  disconnected, `kennel-demo.sh verify` → exit 0, `pass=10 fail=0`, check 1's
  criterion naming the four nodes, and the intervention count unchanged across
  the recipe's own 20 Hz walk.

### 4.6 Records

`stack/bridge.md` **§11 "The watchdog"**: the five rules, the burst decision,
the echo paragraph, the stop ordering, the measured stop times at both rates
(wall and sim), the `walk`/`verify` non-interference, the `down` reap, the
reconnect-within-burst limit. `kennel_console/teleop.md` **§5 rewritten**: the
table keeps its rows, the last paragraph becomes *the retirement is done — a
killed renderer is caught by the guest in ≤ STALE s; measured …*, with the
pre-watchdog number kept in the sentence as the finding it was.
`demo/runbook.md` §5: the *"closed the browser tab"* row → *the watchdog stops
it within ≈ N s; before #67 it walked X m (…)*; §4 the two knobs.

---

## 5. Live-guest protocol — one session, in this order

`EV=stack/bridge/evidence/live`; every transcript opens with `=== what ===` and
`date -u +%FT%TZ`, captured with `2>&1 | tee`; `G` is the guest ssh. Negative
controls **before** the code that changes them. Note the composed rate in every
file's header line — half the numbers are rate-dependent.

| # | Do | File | Must show |
|---|---|---|---|
| 0 | `kennel-demo.sh status`; `G sudo docker exec dfki_quad ps ax`; `G ss -ltn` | `00-before.txt` | bridge down, no `k13-*`/`p21-trot` pidfiles; the sim clock young (this plan's probe reset it) |
| 1 | `kennel-demo.sh run` (the applied run, rate 0.5) | `01-run-rate05.txt` | `pass=10 fail=0`, `walk` holding; then `walk stop` |
| 2 | D.3 §8: over `G`, ten times `KENNEL_BRIDGE_POLL=0.1 /tmp/kennel-bridge.sh start; /tmp/kennel-bridge.sh stop` (stage the new script first) | `02-bridge-race.txt` | ten pairs of `(+x.xx s)` lines; the table in `bridge.md` §3 |
| 3 | D.3 §4 as §2.6 says — page driving, then `walk`; then `teleop` | `03-jitter.txt` | `distinct_vx [0.3, 0.5]` and the alternating rows; then `[0.5]` |
| 4a, 4b | `verify-teleop-live.sh` **twice** (commit-1 form: no watchdog) | `04a-live-suite.txt`, `04b-live-suite.txt` | both `ALL CHECKS PASSED`; group 6's `x_travel`/`sim_window` — the unattended walk, the number the runbook row gets |
| 5 | during 4b's group 2, the `top` line of §2.6 on the guest; then `KENNEL_RATE=1.0 kennel-demo.sh compose` → `run` → the suite once more, `top` again | `05-cpu-lag-rate05.txt`, `05-cpu-lag-rate10.txt`, `05-run-rate10.txt` | bridge CPU % and `gap_std_ms`/`gap_max_ms` at both rates. **Stay at 1.0** for the rest: the watchdog's wall-time numbers are cleanest there, and say so |
| 6 | D.3 §7 Firefox, per §2.6 | `06-firefox.txt` | `target.hz` 20 ± 2 from a Firefox page, or the exact block/prompt text |
| 7 | #66 negative control and the un-damping finding, **before the console change**: `teleop`; drive; `E-STOP` from the page; `teleop stop`; `G /tmp/kennel-bridge.sh recover` | `07-recover-from-estop.txt` | z 0.075 → the leg-driver log's *Switch to DAMPING* then *switching to operation* → `/reset_sim` → standing at 0.31 m within ~1 sim-s; `verify` afterwards `pass=10 fail=0` |
| 8 | #66 from the console (commit 2 in place): `teleop`, connect, drive, `E-STOP`, click **reset sim** | `08-reset-from-console.txt`, `08-feed.txt`, `08-reset.png` (`dashboard-shot.sh --connect`, after) | `observe 5`: standing; the feed: `/reset_sim called …` then `sim clock restarted at 0.x s — windows cleared`; the picker says `STAND active`; `verify` afterwards `pass=10 fail=0` (`KENNEL_EXPECT_BRIDGE` set by the driver) |
| 9 | #66 *active* / *refused* live: pick `WALKING_TROT` (note the `in 0.xx s`), inject the `GARBAGE` option via CDP (the suite's own snippet) and pick it, then `STAND` | `09-gait-active-refused.txt` | `active` with a sub-second figure; `refused` after 2.0 s with the controller log's `Unknown gait type [GARBAGE]` beside it; `active` again |
| 10a, 10b | commit 3 in place: `verify-teleop-live.sh` **twice** with the watchdog (default) | `10a-`, `10b-live-suite-watchdog.txt` | green twice; group 6: stale detected at ≈ 1.0 s wall, robot at rest within ≤ 2 sim-s; group 6b `driving` on reconnect; the watchdog log copied into the transcript |
| 10c | once more with `KENNEL_WATCHDOG=0` | `10c-live-suite-no-watchdog.txt` | the step-8 assertions still green — the old behaviour is still measured |
| 11 | non-interference and teardown: `teleop` (watchdog up); `walk` 10 sim-s, `walk stop`; `verify`; `verify` again with `KENNEL_EXPECT_BRIDGE=0` forced; then `kennel-demo.sh down` **without** `teleop stop` | `11-walk-verify-watchdog.txt`, `11-verify-without-knob.txt`, `11-down-reaps-watchdog.txt` | interventions unchanged across both; `pass=10` with the four-node criterion; `extra:` naming four without it; after `down` no `python3 …k13-target-watchdog` process and no `/tmp/k13-watchdog.pid` |
| 12 | the eight console suites on the host; `git status --porcelain` | `12-suites.txt` | eight greens (`verify-teleop` with its new count); nothing but the intended files changed |

Row 7 is where #66 is won or lost: if `/set_damping_mode` does **not** bring the
driver back (the log says *Can't switch from state EMERGENCY_DAMPING*), the
conditional step is dropped, `recover` becomes *relaunch first*, and the record
says a damped robot needs `kennel-demo.sh launch` — with the transcript that
proved it. Row 10 is where #67 is: if the stop takes longer than 2 sim-s at 1.0×,
the number is the finding and the acceptance row says so; do not tune `STALE`
below 1.0 to pass — the 20 Hz page and the 10 Hz hold need the margin.

---

## 6. Records and doc touches

| File | Change |
|---|---|
| `kennel_console/teleop.md` | §5 rewritten (the retirement done, the measured before/after); §10 `/reset_sim` bullet struck with a pointer; **§11 Tested live** (#65); **§12 Interventions over the bridge** (#66) |
| `stack/bridge.md` | §1 table (+ `observe`, `recover`, the two tools, the live suite); §3 the race distribution; §5.1 two rows; §6 four nodes; §7 the measured jitter trace; §8 pointer to `evidence/live/`; **§10 Measured under load** (#65, incl. the un-damping finding); **§11 The watchdog** (#67); §9 limits: the reconnect-within-burst case, the unauthenticated bridge unchanged |
| `stack/launch.md` | §4.3 rewritten to the measured reset sequence and the E-STOP exit; §7 gains no trap unless the protocol earns one |
| `stack/verify.md` | §2 check-1 row and paragraph: four nodes; §4.4 gains one sentence — the console now reads the same signature live |
| `demo/runbook.md` | §3 *Also there when needed*: `verify-teleop-live.sh`; §4 knobs `KENNEL_WATCHDOG`, `KENNEL_WATCHDOG_STALE`; §5 rows: *closed the tab* (measured, then retired), *jitters* (cites the trace), `extra:` (four nodes), a new row *reset sim says another publisher is holding the target* |
| `kennel_console/dashboard.md` | §6 *interventions still drive the mock* → reset done (#66), inject still #68 |
| `docs/README.md` | Stack section: `bridge.md`'s line mentions the live suite and the watchdog |
| `CLAUDE.md` | repo map, `stack/` row: `bridge/` (the bridge, its live suite, the watchdog); the console row keeps *eight* suites — the live one needs a VM and is a different kind; one new rule only if the protocol earns it (§8.11) |
| `plan/console-live.md`, `plan/teleop-joystick.md` | nothing — historical; D.3's caveats are answered in `teleop.md` §11, not edited in place |

---

## 7. The PR

### 7.1 Body skeleton (house style: PRs #59, #79, #80)

```
feat(teleop): teleop hardened — a live regression suite on the real stack, reset and gait truth over the bridge, a guest-side dead man's switch

Closes #65, closes #66, closes #67. Plan: plan/teleop-hardened.md.
Three issues in one PR at the maintainer's request: they are steps 8–10 of the
milestone, 8's suite is the instrument that measures what 10 retires, and 9's
evidence is recorded by that suite. The milestone's default of one issue per PR
is unchanged.

## What is here            — table: file → what changed (the live suite + driver, the monitor, the watchdog, kennel-bridge.sh verbs/knobs, kennel-demo.sh, kennel-verify.sh check 1, the console, fake-rosbridge.py, verify-teleop.* groups 13–17, the records)
## Measured on the live guest — the unattended walk before/after the watchdog (both rates, wall and sim); the race distribution; bridge CPU and lag at 0.5× and 1.0×; the reset sequence's timings; active/refused timings; Firefox
## Findings from the live protocol — E-STOP is recoverable (leg_driver.cpp), nobody had done it; the long-session collapse seen again; whatever rows 7 and 10 found
## Corrections to the plan, from measurement — say "none" otherwise
## Verification            — §7.2 with outputs; the live suite twice, the eight suites, the counts
## Bypasses                — none expected; the human friction session is OPEN (who owes it, the template file)
## Decisions               — §8, one line each, with where each is recorded
## Records                 — teleop.md §5/§11/§12, bridge.md §10/§11, the touches of §6
```

### 7.2 Verification list — every line with its output in the PR

```bash
bash -n demo/tools/kennel-demo.sh stack/verify/kennel-verify.sh stack/bridge/kennel-bridge.sh stack/bridge/verify-teleop-live.sh kennel_console/*.sh
python3 -m py_compile kennel_console/*.py stack/bridge/*.py stack/bridge/tools/*.py
for s in serve scope generate export send teleop dashboard runs; do ./kennel_console/verify-$s.sh; echo "verify-$s exit=$?"; done     # eight greens
git diff --stat main -- kennel_console/verify-{serve,scope,generate,export,send,dashboard,runs}.*                                     # nothing: seven unmodified; verify-teleop.* appended only
git diff main -- kennel_console/verify-teleop.py | grep '^-' | grep -v '^---'                                                          # nothing removed
stack/bridge/verify-teleop-live.sh; stack/bridge/verify-teleop-live.sh                                                                 # green twice, transcripts 10a/10b
KENNEL_WATCHDOG=0 stack/bridge/verify-teleop-live.sh                                                                                   # green, transcript 10c
for t in stack/bridge/kennel-bridge.sh stack/composed-run/tools/p21-*.sh; do diff <(sed -n "/^ENV_CHAIN='/,/^cd \/root\/ros2_ws'$/p" "$t" | sed "s/^ENV_CHAIN='//; s/'$//") <(grep -v '^#' stack/known-good/tools/prelude.sh | grep -v '^$') && echo "$t chain identical"; done
grep -n 'new WebSocket' "kennel_console/Kennel Console.dc.html"           # exactly one
grep -c "sleep" stack/bridge/kennel-bridge.sh stack/bridge/verify-teleop-live.sh stack/bridge/tools/*.py   # poll intervals inside bounded loops only; name each
grep -n "STALE\|REPEAT" stack/bridge/tools/k13-target-watchdog.py | head    # the two knobs, their defaults
git status --porcelain                                                     # only the maintainer's slides/ entries, untouched
```

### 7.3 Acceptance, all three

| Issue | Criterion | Proof |
|---|---|---|
| #65 | `verify-teleop-live.sh` green twice in a row on a running stack; every D.3 caveat has a number or a transcript; the runbook rows carry measured values; the human session is the one open item and says so | `04a/04b`, `02`, `03`, `05-*`, `06`, `teleop.md` §11, `20-friction-human.md` |
| #66 | from a fallen robot, *reset sim* in the console → standing and the Dashboard clears (s004 step 4); the picker shows *active* for `WALKING_TROT` and *refused* for a name the node ignores; `verify-teleop.sh` groups 13–17 green with no VM; `verify` after a reset `pass=10 fail=0` | `07`, `08-*`, `09`, `12-suites.txt`, `teleop.md` §12 |
| #67 | killed tab → the robot stops in ≤ 2 s; `walk`, `verify` and teleop unaffected; `verify-teleop-live.sh` green with the watchdog running; `down` reaps it | `10a/10b/10c`, `11-*`, `bridge.md` §11 |

---

## 8. Decisions this plan makes that the issues did not

Stated so the implementer knows what is the maintainer's text and what is this
plan's call — revert the call, not the issue, if measurement says otherwise.

1. **The watchdog repeats a bounded burst (3 zeros over 2 s), not "until a fresh
   message arrives"** (§4.1). The issue's own reconciliation requirement — a
   reconnecting page's probe must see nothing — is impossible for a watchdog that
   publishes forever after a kill. The controller's subscription is reliable, so
   the repeats are for belt and braces, not delivery.
2. **No echo filter.** rclpy cannot ignore local publications; the state machine
   is written so hearing its own zero is harmless (§4.1 rule 4).
3. **At `stop`, the watchdog outlives the bridge** and is stopped only when its
   state file reads `idle` or the bound expires (§4.2) — observed, not slept.
4. **A reconnect inside the burst window is refused once.** Recorded as a limit
   in `bridge.md` §9 with the operator's action (*connect again*), not designed
   around: the alternative is teaching the probe to recognise the watchdog's
   messages, which is the seam the probe exists to not have.
5. **Staleness is wall time; the stop is sim time.** Publishers run on wall
   clocks whatever the composed rate; the robot's deceleration is the
   controller's, in sim seconds. Both numbers are recorded, at both rates.
6. **`joint_positions` is empty**, so the simulator uses its own
   `initial_joint_positions` (§0): the stock spawn with no constants copied into
   the page. `z` is the one value that has to be sent; `0.40` is cited to the
   sim yaml at the pin.
7. **No trailing `STAND`** after the reset — measured unnecessary; the
   `gaitWant = STAND` bookkeeping makes the picker show `STAND active` from the
   next `/gait_state` message instead.
8. **`/set_damping_mode` is called only when the robot is down (z < 0.15)** —
   the minimal intervention that still makes *reset* restore a robot after
   E-STOP; verified on the guest (row 7) before it is wired (§3.1).
9. **`reset sim` refuses under a foreign publisher** rather than resetting into a
   held trot (§3.1 table).
10. **The target subscribes `/gait_state` itself, after `advertise`**, rather than
    reading the DataSource's `latest` — `teleop.md` §2's separation holds, the
    suites' first-op assertions hold, and the fake's gait-following is opt-in so
    group 7 of the existing suite is untouched (§3.4–§3.5).
11. **`observe` and `recover` live in `kennel-bridge.sh`**, not in a new guest
    script — one chain, no new copy to register in `composed-run.md` §9.2; the
    two Python tools are CONTAINER tools it copies in. If the protocol finds a
    fifth copy unavoidable, mark it and register it there. A new `CLAUDE.md`
    rule is earned only if this pass finds a fresh species of defect; the
    candidate, if row 7 or 10 bites, is *"a service that answers `success` is not
    an observation of the effect"* — which is already what `verify.md` §4.4 says.
12. **The live suite lives in `stack/bridge/`**, needs a VM, and is not one of the
    console's eight no-VM suites; `CLAUDE.md`'s count stays eight and the row
    names it separately.
13. **`--no-zygote` and `pgrep -P`** kill the renderers, not a CDP process query —
    every step of the kill is visible from bash; "the page died" is asserted
    from `kill -0` and a failing `Runtime.evaluate`, and "publishing stopped"
    from the guest's `target.last_wall`, never from Chrome's own bookkeeping.
16. **The fall replay drops `/quad_control_target`** (`--drop`, §3.5) so the
    page can drive while the recording's robot falls; the recording itself is
    untouched — never hand-edit a fixture.
14. **The human friction session stays open** in the PR rather than being
    simulated with synthetic pointer events and called done (§2.7).
15. **The reset button's feed line is a new `narrate` kind**; the clock-restart
    line is untouched because a suite regex pins it (§3.3).

## 9. Don'ts

- Don't open a WebSocket on load, on `/api/health`, or on a URL appearing — only
  on a click. The teleop and dashboard suites both assert it.
- Don't `sleep` to wait — `observe` measures in sim seconds from `/clock`; the
  watchdog's timer is a poll inside a bounded loop; `stop` reads a state file.
  The one 3-s boot settle the other suites use is the only tolerated `sleep`,
  and it is named.
- Don't run `verify` while a page is connected (checks 6–9 publish their own
  trot); the suite disconnects first, the protocol says so per row.
- Don't tune `KENNEL_WATCHDOG_STALE` below 1.0 to meet the 2-s acceptance; the
  10 Hz `walk` hold needs the margin, and a longer stop is a finding.
- Don't let the watchdog touch the gait, call any service, or publish before
  the first message it has ever seen.
- Don't call `/set_damping_mode` on a standing robot; don't call `/reset_sim`
  under a foreign publisher.
- Don't reorder anything in the console; don't add an element whose exact text
  duplicates a label the suites click, ahead of the existing one; don't change
  `narrate('reset', …)`'s text.
- Don't modify the seven other console suites, `run.json`'s emitter, or
  `kennel-verify.sh`'s checks and thresholds — check 1's tolerated set is the
  only change.
- Don't add a fifth copy of the container source chain; go through
  `kennel-bridge.sh`.
- Don't `git add -A` — the maintainer's `slides/` work is in the tree.
- Don't relaunch the stack more than §5 needs (two `run`s, one per rate); each
  is ~5 minutes, and `recover` is what makes E-STOP cheap.
- Don't rewrite history in `teleop.md` §5/§6/§10 or `bridge.md` §9: say what
  changed, keep the finding as found, point forward.
