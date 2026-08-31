# Driving the robot from the console — the Interventions joystick, live

> Implementation record for [issue #58](https://github.com/alius-git/kennel/issues/58),
> the console half. The guest-and-host half is
> [`stack/bridge.md`](../stack/bridge.md).
>
> One sentence: the joystick that was already in the Interventions toolbar,
> pointed at the real stack over a WebSocket, publishing
> `/quad_control_target` at 20 Hz and calling the controller's two services —
> with the Dashboard's panels left exactly as they were.

![the console driving the stack](teleop-render.png)

## 0. Why this is inside the design, and what is not

The joystick is specified, in these words:

> *Interventions toolbar:* velocity/gait target commands (publish
> `/quad_control_target` — joystick widget + fields) …
> — [`plan/prompts.txt:180`](../plan/prompts.txt)

> … all as service calls and topic publishes against the already-running sim.
> — [`plan/applications.md:80`](../plan/applications.md)

> Dashboard's interventions are topic publishes and sim-level service calls
> through the seam — **no process control anywhere**.
> — [`plan/design/03-console.md:27`](../plan/design/03-console.md)

Publishing a topic at a stack that is already running is not process control, so
no button here is a deviation and nothing here belongs in
[#26](https://github.com/alius-git/kennel/issues/26)'s log for *that* reason.
**Starting** the bridge is process control, and it is a driver verb
(`kennel-demo.sh teleop`) for exactly the reason [`send.md` §6](send.md) records.

**One bypass.** [`design.md` §1](../plan/design.md) serves the console *from
inside the VM*, where the bridge would be same-host and need no discovery. The
MVP console runs on the host, so the `ws://` URL has to be handed to the page —
`teleop` writes it to `<out>/.kennel-bridge` and `serve.py` reports it in
`/api/health`, the same shape as `send`'s `out` and `pin`.
*Retirement path:* the console served from the appliance, where the URL is
`ws://localhost:9090/` and no hand-off exists. Belongs in #26's log when that
file is written.

## 1. What is delivered

| Artifact | Purpose |
|---|---|
| `RosbridgeTarget` in [`Kennel Console.dc.html`](Kennel%20Console.dc.html) | ~180 lines: connect, probe, publish at 20 Hz, two service calls, dead man |
| teleop controls, appended to the Interventions row | bridge URL, connect, gait, `z`, `max v`, STAND, E-STOP |
| `bridge` + `meshcat` in [`serve.py`](serve.py)'s `/api/health` | the URL hand-off, resolved **per request** |
| [`verify-teleop.sh`](verify-teleop.sh) + [`verify-teleop.py`](verify-teleop.py) + [`fake-rosbridge.py`](fake-rosbridge.py) | 38 checks, no VM |

Nothing new is vendored: it is rosbridge v2's JSON protocol over a native
`WebSocket`, so `verify-serve.sh`'s asset list is unchanged.

## 2. It is not the `RosbridgeDataSource`

[`design.md` §7](../plan/design.md) build step 3 is a `RosbridgeDataSource` that
subscribes every panel to the live stack. This is not that, and does not start
it: `RosbridgeTarget` publishes **one** topic and calls **two** services. The
`DataSource` seam is untouched, `MockDataSource` still drives every panel, and
`this.ds` and `this.tp` are separate objects that never talk to each other.

What this does prove for that later work: the socket, the type resolution, and
the URL hand-off.

## 3. Listening before speaking

On connect the page **subscribes** to `/quad_control_target` for one second and
counts what arrives, before advertising anything.

If anything is publishing, it refuses outright — no advertise, no publish — and
says so:

```
another publisher is holding /quad_control_target (2 msgs in 1 s) —
a walk or a verify is still running.  Stop it:  kennel-demo.sh teleop
```

Two publishers on this topic do not merge; the controller consumes the latest
every cycle, so they alternate and the robot jitters between two speeds
([`stack/bridge.md` §7](../stack/bridge.md)). `kennel-demo.sh teleop` stops the
publisher it knows about (`p21-trot-hold.sh`, which `run` leaves holding); this
probe is what catches the ones it cannot know about — a `kennel-verify.sh` walk
phase, or a second browser.

## 4. What goes on the wire

```js
{op: 'publish', topic: '/quad_control_target', msg: {
   body_x_dot, body_y_dot, world_z, hybrid_theta_dot, pitch, roll}}
```

**All six fields, every message, `world_z` always set.** The first message
overwrites the controller's whole target, and one that omits `world_z` defaults
it to `0.0` — commanding the body to the ground. The trap is silent
([`launch.md` §4.2](../stack/launch.md)), so there is exactly one function that
builds this message and it fills all six.

**20 Hz, continuously, zeros included.** `joy_to_target`'s `update_freq`.
Silence is not a stop: the controller keeps the last target it received forever.

**The mapping is copied from `joy_to_target.py`, not invented:**

| | value | source |
|---|---|---|
| stick y → `body_x_dot` | ±`max v`, default 0.5 m/s | `scaling.x` |
| stick x → `hybrid_theta_dot` | ±1.0 rad/s | `scaling.yaw` |
| `world_z` | 0.30 m | `init_robot_height`, `mit_controller_sim_go2.yaml:93` |
| acceleration limit | 0.5 m/s² | `max_acceleration`, same file line 95 |

The ramp is `clip_velocity` field for field: it caps the **change** per tick
along the direction of the change, not each axis independently. Verified from
the bytes on the wire — no step exceeds 0.025 m/s, which is 0.5 m/s² at 20 Hz.

**Gait is a service call, not a topic:**

```js
{op: 'call_service', service: '/mit_controller_node/set_parameters',
 type: 'rcl_interfaces/srv/SetParameters',
 args: {parameters: [{name: 'simple_gait_sequencer.gait',
                      value: {type: 4, string_value: 'WALKING_TROT'}}]}}
```

The picker offers the **node's** ten gaits, not the gamepad's six: `TROT` and
`FLYING_TROT` are commented out in `joy_to_target.py` at the pin, so a
parameter-driven picker reaches gaits a joystick cannot
([`launch.md` §4.1](../stack/launch.md)).

The page reports a gait as **sent**, never as **active**. `SetParameters`
answers `successful: true` for a gait the node then refuses to load — confirmed
against the real stack, [`stack/bridge.md` §5.1](../stack/bridge.md). `/gait_state`
is the observable that could say *active*, and reading it is not this issue.

## 5. The dead man's switch, and its honest limit

The controller keeps the last target forever, so a page that goes away
mid-stride must put a zero on the wire before it does.

| Event | What happens |
|---|---|
| stick released | the command becomes zero at once; the ramp puts it on the wire over ~1 s, as releasing a gamepad does |
| `STAND` | hard zero **immediately**, then the STAND gait |
| `E-STOP` | hard zero, then `/set_emergency_damping_mode` |
| tab hidden | hard zero |
| `pagehide` / `beforeunload` | hard zero, unadvertise, close |
| socket error | the UI says disconnected — **and the stack keeps its last target** |

**The limit, stated plainly: a killed renderer fires none of these.** Kill the
tab mid-stride and the robot keeps walking until someone runs
`kennel-demo.sh teleop stop`. No amount of JavaScript fixes that; the retirement
path is a guest-side watchdog node that damps the target when it goes stale,
which is a new ROS node and not this issue.

## 6. What the Dashboard still shows, and why it is confusing

The render above is honest about it: a red **FALL DETECTED** banner and three
`stopped` pipeline blocks, while the real robot trots along at 0.47 m/s.

That is `MockDataSource`'s scripted demo — ~30 s of trot, degrading solve times,
a fall — playing out on panels this issue deliberately does not touch. The only
live things on the page are the bridge status item, the teleop message line, and
the robot itself. Until the `RosbridgeDataSource` lands, **the panels narrate a
recording while the joystick drives a robot**, and an operator has to know that.

Mitigating it properly means the seam work; mitigating it cosmetically (hiding
panels when a bridge is connected) would hide the demo Devon presents.

## 7. Feature detection, exactly like `send`

`probeKennel()` already fetched `/api/health` once on mount. It now also reads
`bridge` and prefills the URL field. The rules that keep the offline console
offline are unchanged:

- The controls render **only** when `state.kennel` is non-null — served by plain
  `python3 -m http.server`, the page is byte-for-byte what it was: no controls,
  no bridge item in the status bar, no socket, no errors.
- **A URL is never a reason to connect.** The page opens a WebSocket only on a
  click. Verified: zero sockets on load, exactly one after the button.
- The field stays editable — a lab that knows its own bridge can type it.

## 8. Verification

`kennel_console/verify-teleop.sh` — 38 checks, **no VM, no ROS, no stack**. The
far end is `fake-rosbridge.py`, the server half of `cdp.py`'s WebSocket, which
records every op to JSONL. Every assertion reads **bytes the page sent**, never
a JavaScript variable read back out of the page under test.

| Group | Asserts |
|---|---|
| 1 | controls present under `serve.py`, URL prefilled from `/api/health`, the ten gaits |
| 2 | **zero** WebSockets on load; the ops log empty |
| 3 | exactly one socket, to the configured URL; subscribe *before* advertise; no publish during the probe |
| 4 | 20 Hz ± 2; all six fields on every message; `world_z` 0.30 always; zeros published, not silence |
| 5 | the stick ramps, no step over `max_acc / rate`, saturates at `max v` |
| 6 | release returns to zero and keeps publishing zeros |
| 7 | the exact `SetParameters` and `Trigger` payloads; "sent", never "active" |
| 8 | navigating away leaves a **zero** as the last message, and unadvertises |
| 10 | a bridge with a foreign publisher is refused: subscribe, then no advertise, no publish |
| 11 | under plain `http.server`: no controls, no socket, zero placeholders, no errors |
| 12 | zero non-localhost requests |

The bridge URL reaches the page the way it does in real use — the suite writes
`<out>/.kennel-bridge` and lets `serve.py` read it — so the hand-off is
exercised rather than bypassed.

The other five suites are green and unmodified: `verify-serve.sh`,
`verify-scope.sh`, `verify-generate.sh`, `verify-export.sh`, `verify-send.sh`.

## 9. Two defects this found in existing code

- **`k13-stop.sh` would have leaked the bridge.** Its sweep is `pkill -x`, and
  rosbridge's two children run with `comm` `python3`. Fixed there, by path
  pattern, the way it already handles `joy_to_target.py`
  ([`stack/bridge.md` §4](../stack/bridge.md)).
- **A second bare "connect".** The status bar's connect/disconnect toggles
  `MockDataSource`. A second button labelled just `connect` on the same screen
  was ambiguous — and made the test selector ambiguous too, which is how it was
  noticed. The teleop button says **connect bridge**.

## 10. Limits

- **The Dashboard is still on `MockDataSource`** (§6). This is the big one.
- **No `/reset_sim`, no disturbance injector.** Both are in the Interventions
  spec, both are sim-level service calls this bridge could carry, neither is
  this issue. The existing `inject` / `reset sim` buttons still drive the mock.
- **No keyboard driving.** The same publisher would carry WASD; not built.
- **The 3D pane is still a placeholder.** `/api/health` now also carries
  `meshcat`, so pointing the iframe at the real viewer is a small follow-up.
- **One operator.** Two connected browsers are two publishers; the probe makes
  the second one refuse, which is the right outcome but not a shared-control
  design.
