# Kennel — live demo script (8 min)

Rehearsed on this host on 2026-09-11 (UTC) against `kennel-vm-baseline`: the
whole first-run path with scripted clicks (`scenario firstwalk`, **pass=40
fail=0**, 1m56s), then the `teleop` step traced on both solvers at rate 0.75.

**Drive HPIPM live, not OSQP.** Stopping the scripted trot (the first thing
`teleop` does) dropped an OSQP robot to the floor **2 of 2** times, and the MIT
controller cannot stand back up. The same verb on HPIPM held the body at
≥ 0.313 m **2 of 2**. OSQP still passes all ten verify checks, but it trots with
31–42 early contacts per window where HPIPM has 0. That is why the OSQP run is
the *comparison* in the Runs step, not the robot you drive.

Times in brackets come from those runs.

---

## Before the talk (T−30 min, ~3 min)

```bash
cd ~/kennel
export PATH="$PWD/demo/tools:$PATH"   # so you type kennel-demo.sh exactly as the slide shows
kennel-demo.sh status
```

Ready looks like: `container dfki_quad (running)`, `Meshcat not reachable`,
`bridge not up`. A stack that is **down** is the correct starting state.

```bash
kennel-demo.sh console
```

In the tab it opens, check two things, then **close the tab** (the server keeps running):

1. **send to kennel-runs →** is in the Compose toolbar.
2. **Runs** lists `run-20260911T032609Z` as **completed**. That is the diff partner:
   OSQP, flat plane, rate 0.75.

Set the stage:

- Terminal: font ≥ 18 pt, cleared, cwd `~/kennel`.
- Slidev in one browser window; a second window for the console and Meshcat (focus it
  last, so new tabs land there).
- From here on: no `reset`, no `halt`, and **compose nothing else**. `run` takes the
  newest run folder, and **right now the newest is the OSQP one**. Never type `run`
  before you have clicked send.

---

## The demo

### 0:00 — Compose  [~1:00]

```bash
kennel-demo.sh console
```

In **Compose**:

1. **Map**: the flat plane is already selected. Just point at it.
2. Pipeline → **MPC** block: leave it on **HPIPM · partial condensing**, the stock
   solver. Point at the dropdown and its other options.
3. **Sim options** → **real-time rate** → type `0.75`, press **Tab**.
4. **send to kennel-runs →**. The strip reads `saved /home/thales/kennel-runs/run-2026…Z`.
   Note the last four digits.

> "This is the console: one HTML file served from my laptop. It never starts a
> process; it only writes files. Every stage of the controller is a block. This
> one, the MPC solver, is a real choice. I keep the stock solver and slow the
> simulator to 75 %. Everything else is the pinned stack's own file, byte for
> byte. Send writes a run folder: two configs, the launch commands, and a record
> of what I chose."

### 1:00 — Run it  [~1:20]

```bash
kennel-demo.sh run
```

**Check the second line first**: `run /home/thales/kennel-runs/run-<the stamp you just saw>`.
If it says `run-20260911T032609Z`, the send did not land, and that is the OSQP run
that falls at `teleop`. Ctrl-C, click send, run again.

Talk over the phases:

- **transfer** [2 s]: four matching checksum columns, `OK`.
  > "Checksummed at every hop: staging, guest, the container's source, and what the
  > container actually reads. A run composed for a different pin is refused."
- **launch** [~30 s]: `settling 10 sim-s` … `node graph complete`.
  > "Three shells, straight from the commands file the console generated. It waits
  > by *watching* the stack: the sim clock, the leg driver, the six-node graph. The
  > docs used to say 'wait ten seconds'. That was wrong, and I only found out by
  > running the docs literally."
- **verify** [~40 s]
  > "Ten checks, driving the robot for twenty sim-seconds. Check 10 is the one a
  > component test needs: the controller really loaded the solver in my run. The
  > live parameter and the launch log agree."
- **walk** [7 s]

Done looks like:

```
pass=10 fail=0
VERDICT: PASS -- healthy and walking
[kennel-demo] verify report    …/run-…/verify.json (verdict completed)
[kennel-demo] the robot is trotting. Watch it here:
[kennel-demo]     http://192.168.122.228:7000/
```

### 2:30 — Watch it  [~0:30]

Ctrl-click the Meshcat URL. The Go2 trots, and the HUD in the corner reads ≈ 75 rtr%.

> "This is Drake's own viewer, running inside the VM. The HUD reads about 75 %:
> the rate I composed, read back from the simulator."

### 3:00 — Take the controls  [~0:45]

```bash
kennel-demo.sh teleop
```

Done looks like: `stopped the held trot (the console is the publisher now)`,
`bridge ws://192.168.122.228:9090/`, and a line about the watchdog. [19 s]

> "It stops the scripted trot first. Two publishers on one topic make the robot
> jitter between two speeds. I measured that, so the verb prevents it."

In the console tab:

1. **Reload the page (F5).** The page reads the bridge address only when it loads.
   Without the reload the rosbridge field stays empty.
2. **Dashboard**: the rosbridge field shows `ws://192.168.122.228:9090/`. Click **connect bridge**.
3. The status bar reads `MODE live` and `BRIDGE driving · 20 Hz`, and the panels fill with live data.

### 3:45 — Drive  [~1:45]

1. Click **STAND**, then choose **WALKING_TROT** in the gait picker. The line under the
   toolbar reads `gait WALKING_TROT active — /gait_state period 0.500 s …`.
   *(The picker already shows WALKING_TROT while the robot is standing, and re-choosing
   the option on display sends nothing. That is why STAND comes first.)*
2. Push the joystick square **straight up** and hold it ~8 s. The robot trots forward,
   and in **State plots** the velocity climbs toward the 0.5 m/s commanded (≈ 0.47).
3. Release: it stops within about a second. Push up and slightly sideways to turn
   (sideways is yaw).
4. Point at two panels:
   - **Pipeline health**: MPC well under a millisecond against a 10 ms deadline, all green.
   - **Event feed**: any amber "WBC missed its 2 ms deadline" lines are real misses on a
     VM, counted and narrated rather than hidden, and solver failures stay 0.
5. Click **STAND**. Stand the robot whenever you stop driving to talk; don't leave it
   trotting in place.

> "The page reads the gait back from the robot: 'active' means /gait_state really
> changed, not just that a parameter was accepted. And if I closed this tab
> mid-stride, a watchdog inside the VM would zero the command a second later.
> Before that watchdog existed, the robot walked thirteen metres and kept going."

**Do not click on stage:** **E-STOP** (it latches damping, and the way back is a guest-side
`recover`, not a verb), **reset sim**, **inject**, **step 1 tick / step 1 s**, or the
PRONK / gallop gaits.

### 5:30 — Compare two runs  [~1:15]

1. **Runs** → **refresh**.
2. Top row: the run you just made (HPIPM), **completed**. Find `run-20260911T032609Z`:
   the same map and rate with **OSQP**, also **completed**.
3. Tick **cmp** on both:
   - **Config diff**: the solver, plus its two dependent keys, each marked with which
     side actually reads it.
   - **Outcome**: both verdicts **completed**, but `headline.early_contacts` reads
     **0** against **42**.
   - **Generated YAML**: one line differs, `mpc_solver`.

> "These two runs differ in exactly one choice, and both pass the same ten checks.
> But look at early contacts: zero with HPIPM, forty-two in fifteen seconds of
> trotting with OSQP. A pass/fail hides that margin, and it is real: with OSQP,
> the robot falls over the moment the scripted trot is stopped. Two out of two
> last night. That is why the one I drove was HPIPM, and it's the kind of answer a
> component test should give you: from the robot, not from an opinion."

### 6:45 — Put it away  [~0:45]

```bash
kennel-demo.sh teleop stop
kennel-demo.sh down
```

Done looks like: `bridge stopped`, `teleop stopped…`, then
`stack stopped in container 'dfki_quad'. The container itself is left running.`

> "Stop driving, stop the stack. And if anything is ever wrong, `kennel-demo.sh
> reset` puts the whole VM back to its frozen baseline in about ninety seconds,
> running thirteen checks on the way. That's thirty-five minutes cheaper than
> rebuilding it."

### 7:30 — Back to the slides → **7 · Learnings**  [30 s buffer]

---

## If something goes wrong

| You see | Do |
|---|---|
| `run`'s second line names a stamp you did not just send | Ctrl-C → click **send** → `kennel-demo.sh run` |
| The robot falls as `teleop` starts, or when you click STAND | Check the solver: `kennel-demo.sh status` names the applied run. It is almost certainly an OSQP run. `kennel-demo.sh run ~/kennel-runs/run-20260911T030109Z` (HPIPM · 0.75, ~80 s), then `teleop` again |
| verify check 1: `missing: /joy_to_target` | `kennel-demo.sh verify`, then `kennel-demo.sh walk`. Do not relaunch. *"A known startup race; the stack was fine."* |
| `run` stops at `launch` | `kennel-demo.sh run` once more (relaunching over a stack is supported, ~90 s). If it fails twice, go to the backup slides |
| connect says `no bridge URL — start one with kennel-demo.sh teleop…` | F5, or paste the `ws://…:9090/` address that `teleop` printed |
| `another publisher is holding /quad_control_target` | Wait 2 s, then click **connect bridge** again. If it is still there, run `kennel-demo.sh teleop` and reconnect |
| Stick pushed, robot does not walk | **STAND**, then pick **WALKING_TROT** |
| Robot jitters between two speeds | `kennel-demo.sh teleop` (it stops the other publisher), then reconnect |
| FALL DETECTED while the status bar says `mode · mock` | Not connected: that is the seeded replay. Click **connect bridge** |
| The robot really falls while you drive | Do not try to stand it up: STAND cannot lift a fallen robot. Point at the fall banner and event feed (*"this is what the fall detector is for"*), then move on to **Runs**. To get it back later: `kennel-demo.sh launch` (~30 s) |
| A Runs row says `staged` | **refresh** |
| No **send** button | `kennel-demo.sh console stop && kennel-demo.sh console` |
| Anything silent for more than 30 s | Backup slides after *Thank you*: Meshcat, Dashboard, Runs, "Backup — driving it" |

## After the talk

```bash
kennel-demo.sh console stop
kennel-demo.sh reset     # optional: back to the baseline
kennel-demo.sh halt      # before closing the laptop
```
