# A person at the controls — the one item an agent cannot run

> Issue [#65](https://github.com/alius-git/kennel/issues/65) asks for *"one session
> with a mouse and one with a trackpad/touchscreen if available, logged as a
> friction list (F-numbers, the [`dry-run.md` §4](../../../demo/dry-run.md)
> method): dead zone, ramp, what felt wrong."*
>
> **This file is a template, and it is OPEN.** Everything else in #65 is
> measured; this is the part that needs a hand on a pointing device, and it was
> not simulated with synthetic pointer events and called done. The suite drives
> the pad with `PointerEvent`s, which proves the *code path* and says nothing
> about how the control *feels*.

## What to do

```bash
demo/tools/kennel-demo.sh run          # a green stack
demo/tools/kennel-demo.sh teleop       # bridge + console, prints both URLs
```

Then in the Dashboard: **connect bridge** → gait `WALKING_TROT` → drive. Watch the
robot in the 3D pane (or the Meshcat tab) rather than the numbers. Try, at least:

- pushing straight forward and holding a line;
- turning on the spot, then turning while moving;
- letting go suddenly, the way you would if something were about to go wrong;
- **STAND** and **E-STOP** while moving, and `reset sim` afterwards;
- small corrections — the movements that matter when a robot is near something.

## The two numbers a hand will be arguing with

Both are `joy_to_target.py`'s at the pin, copied rather than invented
([`teleop.md` §4](../../../kennel_console/teleop.md)):

| | value | where it comes from |
|---|---|---|
| dead zone | **5 %** of the pad's half-width | `joySet` in the console |
| ramp | **0 → 0.5 m/s in 1.0 s** (0.5 m/s², applied to the change, not per axis) | `max_acceleration`, `mit_controller_sim_go2.yaml:82` |
| full scale | **0.5 m/s** forward, **1.0 rad/s** yaw | `scaling.x`, `scaling.yaw` |
| publish rate | **20 Hz**, zeros included | `update_freq` |

Measured for reference, so a complaint can be checked against a number rather
than a memory: the page publishes at 20.0 Hz wall and the robot reaches
**0.467 m/s against the 0.5 m/s command** (93 %), stopping within **1.5 sim-s**
of a release ([`04a-live-suite.txt`](04a-live-suite.txt)).

## The list

The method is [`demo/dry-run.md` §4](../../../demo/dry-run.md): one F-number per
finding, what happened, why, and the fix or the bypass. Append; never rewrite.

| # | Device | What felt wrong | Cause | Fix / bypass |
|---|---|---|---|---|
| F1 | | | | |

## Sessions

| Date | Who | Device | Session length | Findings |
|---|---|---|---|---|
| | | mouse | | |
| | | trackpad / touchscreen | | |
