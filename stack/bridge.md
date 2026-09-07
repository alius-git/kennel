# The rosbridge beside the stack — starting it, reaching it, tearing it down

> Implementation record for [issue #58](https://github.com/alius-git/kennel/issues/58),
> the guest-and-host half. The console's half is
> [`kennel_console/teleop.md`](../kennel_console/teleop.md).
>
> One sentence: `rosbridge_server` has been in the pinned image since before
> Kennel existed and nothing ever started it; this is the verb that does, the
> host-side proof that a browser can reach it, and the teardown that does not
> leak.

Everything below was measured on 2026-08-30 against the live guest
(`kennel-vm` at `192.168.122.32`, pin `dcf53c5`), not read off a launch file.

## 1. What is delivered

| Artifact | Runs on | Purpose |
|---|---|---|
| [`stack/bridge/kennel-bridge.sh`](bridge/kennel-bridge.sh) | guest | `start` / `stop` / `status` / `observe` / `recover` for the rosbridge and the watchdog beside a running stack |
| [`stack/bridge/tools/k13-target-monitor.py`](bridge/tools/k13-target-monitor.py) | container | the instrument §10 reads: rates, staleness, gait signature, robot, as one JSON line |
| [`stack/bridge/tools/k13-target-watchdog.py`](bridge/tools/k13-target-watchdog.py) | container | the dead man's switch a browser cannot provide (§11) |
| [`stack/bridge/verify-teleop-live.sh`](bridge/verify-teleop-live.sh) + `.py` | host | the live regression suite against the real stack: 90 checks, or 76 with the watchdog turned off (§10) |
| [`vm/test/verify-bridge-host.sh`](../vm/test/verify-bridge-host.sh) | host | proves a browser on this host can reach it, prints the `ws://` URL |
| `kennel-demo.sh teleop` / `teleop stop` | host | the operator-facing verb: both of the above, plus the URL hand-off |
| `KENNEL_EXPECT_BRIDGE=1` in [`kennel-verify.sh`](verify/kennel-verify.sh) | guest | check 1 tolerates the nodes a bridge adds |
| two lines in [`k13-stop.sh`](known-good/tools/k13-stop.sh) | container | `down` reaps the bridge like everything else |

## 2. What the pin already ships

`ros-humble-rosbridge-server` is installed by `docker/Dockerfile:15` at the pin,
alongside `ros-humble-joy-linux` and `ros-humble-teleop-tools`. Nothing in this
repo had ever launched it — [`stack/verify.md` §1](verify.md) mentions rosbridge
only to say the CLI recipe is the MVP's *substitute* for it.

> **The working clone is not what the guest runs.** `dfki-quad/` at HEAD has
> moved to the `joy` package; the pin still uses `joy_linux`, so the healthy
> session's node is `/joy_linux_node`. Read the Dockerfile through
> `git -C dfki-quad show dcf53c59:docker/Dockerfile`, never the working tree.

The launch file is `rosbridge_websocket_launch.xml`. Its two arguments that
matter are `port` (default `9090`) and `address` (default empty, meaning every
interface). It declares two nodes — but spawns **three** graph entries:

```
/rosbridge_websocket      rosbridge_websocket_launch.xml:60
/rosapi                   rosbridge_websocket_launch.xml:86
/rosapi_params            registered by rosapi_node, in no launch file
```

`/rosapi_params` is why the node list is checked and not the XML. Anything that
enumerates the graph — `kennel-verify.sh` check 1 — needs all three.

## 3. Starting it

```bash
demo/tools/kennel-demo.sh teleop          # what an operator runs
```

which stages and runs, on the guest:

```bash
ros2 launch rosbridge_server rosbridge_websocket_launch.xml port:=9090
```

detached, with its PID in `/tmp/k13-bridge.pid` and its output in
`/tmp/k13-bridge.log`.

**The stack must already be running.** rosbridge resolves
`interfaces/msg/QuadControlTarget` out of the sourced workspace, so with no stack
the script exits **2** and names `kennel-demo.sh launch` as the fix. That is
[#45](https://github.com/alius-git/kennel/issues/45)'s lesson applied on the way
in rather than filed afterwards.

Since #45 it is applied properly. This script used to *ask* that question as
"does `/tmp/p21-env.sh` exist?", which conflated two different facts — how the
stack was launched, and whether it is running at all — and so reported a stack
launched by any other means as "not launched". It now finds its environment the
same way the `p21-*` tools do (the launcher's file when present, the canonical
chain from [`known-good/tools/prelude.sh`](known-good/tools/prelude.sh)
otherwise, saying which), and asks the real question of the ROS graph:
`/mit_controller_node` present or not. Recorded in
[`composed-run.md` §9.2](composed-run.md).

**Readiness is observed twice.** The node joining the graph and the socket being
bound are different events, and neither is reliably last:

| Signal | How | Why not just the other |
|---|---|---|
| `/rosbridge_websocket` in `ros2 node list` | in the container | a bound port with no node means DDS has not come up; a publish would go nowhere |
| `:9090` in `ss -ltn` | **on the guest** | a node with no socket means the browser cannot connect yet |

`ss` runs on the guest, not in the container: with `--network host` a socket the
container opens *is* a socket in the guest
([`vm/meshcat-exposure.md` §2.1](../vm/meshcat-exposure.md)), and `ss` is in the
guest image while it is not in the container's. Waiting on one signal and
returning is exactly the shape of
[#52](https://github.com/alius-git/kennel/issues/52).

**Measured:** both signals true **3.5 s** after the launch, binding
`0.0.0.0:9090` and `[::]:9090`.

## 4. Stopping it — SIGINT does nothing, and that is the interesting part

The first implementation signalled the recorded `ros2 launch` PID and waited.
Measured, with no other change:

```
  t=1s  launch_alive=1 children=2      ...unchanged through...
  t=15s launch_alive=1 children=2
```

**SIGINT to a detached `ros2 launch` has no effect at all.** `docker exec -d
bash -c '… &'` gives it no controlling terminal and no foreground process group,
which is what ros2 launch's Ctrl-C handling actually watches for. Killing the
launch afterwards then *orphans* the children rather than stopping them: they
keep the port, and the next `teleop` finds `:9090` taken.

The children cannot be reaped by name either. Their `comm` is `python3`:

```
7481 ros2     /usr/bin/python3 …/ros2 launch rosbridge_server …
7495 python3  python3 /opt/ros/humble/lib/rosbridge_server/rosbridge_websocket …
7497 python3  python3 /opt/ros/humble/lib/rosapi/rosapi_node …
```

so `pkill -x rosbridge_websocket` never matches — the same trap
[`k13-stop.sh`](known-good/tools/k13-stop.sh) already records for
`joy_to_target.py`, and the same fix: match the executable **path**.

```bash
pkill -f 'rosbridge_server/rosbridge_websocke[t]'
pkill -f 'rosapi/rosapi_nod[e]'
```

The `[]` brackets are load-bearing. These patterns travel inside a `docker exec`
command line, so without them the pattern would match the very process carrying
it ([`launch.md` §7](launch.md) trap 6).

**Measured after the fix:** `stop` completes in **6.6 s**, no `rosbridge` or
`rosapi` process survives, the port closes, and a second `stop` is a no-op that
exits 0.

### 4.1 The graph entries outlive the processes

After a clean stop, `ros2 node list` still showed `/rosapi` and
`/rosapi_params` for **10–20 s** — a dead DDS participant timing out, the same
effect check 1's own comment describes for a killed controller. This is why
`KENNEL_EXPECT_BRIDGE` makes the bridge nodes **tolerated and never required**
(§6): requiring them would turn a correct teardown into a red run.

### 4.2 `down` gets it for free

The pidfile is `/tmp/k13-bridge.pid` **on purpose**: `k13-stop.sh` signals every
`/tmp/k13-*.pid`, and it is run by `down`, by `launch`'s pre-launch stop, and by
the baseline-prep script. With the two path patterns added to its sweep, all
three reap the bridge with no further change. Verified by running `down` alone,
with no `teleop stop`, against a running bridge:
[`evidence/11-down-reaps-bridge.txt`](bridge/evidence/11-down-reaps-bridge.txt).

## 5. Reaching it from the host

Two hops, the same shape as Meshcat's
([`vm/meshcat-exposure.md`](../vm/meshcat-exposure.md)):

```
  [ rosbridge ]     in the container, binds 0.0.0.0:9090
        |           hop 1: --network host -- the socket IS the guest's
  [ kennel-vm ]     192.168.122.32:9090
        |           hop 2: libvirt NAT, no port forward, no firewall change
  [ host browser ]  ws://192.168.122.32:9090/
```

`vm/test/verify-bridge-host.sh` asserts both and prints the URL. It does not
stop at a TCP connect — the question is whether a *browser* can speak rosbridge
to it, so it performs a real WebSocket upgrade and then calls
`/rosapi/topics`, which the rosapi node from the same launch serves:

```
guest            kennel-vm at 192.168.122.32 (libvirt 'default')
listener         0.0.0.0:9090 [::]:9090  -- non-loopback, port 9090
handshake        HTTP/1.1 101 Switching Protocols 26 topics visible
ws://192.168.122.32:9090/
```

Exit codes mirror the Meshcat script so each failure has its own fix: `2` no
guest IP, `3` no SSH, `4` no listener, `5` loopback-only, `6` answers but is not
rosbridge, `7` bound but unreachable from the host.

### 5.1 The protocol shapes, proven against the real stack

Before any of the console code existed, the exact JSON the page would send was
put on the wire by hand and the answers recorded. All of it holds:

| Op | Payload | Result |
|---|---|---|
| `advertise` | `topic: /quad_control_target`, `type: interfaces/msg/QuadControlTarget` | accepted |
| `publish` | the six fields | echoed back verbatim on a subscribe: `{"body_x_dot": 0.0, …, "world_z": 0.3, …}` |
| `call_service` | `/mit_controller_node/set_parameters`, `{name: simple_gait_sequencer.gait, value: {type: 4, string_value: WALKING_TROT}}` | `{"result": true, "values": {"results": [{"successful": true}]}}` |
| the same, with `string_value: GARBAGE` | | **also** `successful: true` |

That last row is [`verify.md` §4.4](verify.md) confirmed first-hand: the node
reports success for a gait it then refuses to load. It is why the console says
a gait was **sent** and never that it is **active**.

## 6. What it costs `kennel-verify.sh`

Check 1 asserts *exactly* the six healthy-session nodes, so a running bridge
makes a correct stack fail:

```
[FAIL] 1 node-graph -- … [missing: none][extra: /rosapi /rosapi_params /rosbridge_websocket ][duplicate: none]
```

Since [#67](https://github.com/alius-git/kennel/issues/67) a teleop session adds a
**fourth**, `/k13_target_watchdog` (§11), and check 1 tolerates all four.

`KENNEL_EXPECT_BRIDGE=1` adds them to an *allowed* set used only for the
`extra` comparison — they are never added to `missing`, for the reason in §4.1.
`kennel-demo.sh verify` sets it automatically when the bridge is reachable, and
warns that checks 6–9 command their own trot so a connected console must be
disconnected first (§7).

Measured on one stack, minutes apart:

| | check 1 | verdict |
|---|---|---|
| no bridge | PASS, six nodes | `pass=10 fail=0` |
| bridge up, `KENNEL_EXPECT_BRIDGE=1` | PASS, criterion names the three | `pass=10 fail=0` |
| bridge up, knob off | FAIL, `extra:` names the three | `pass=9 fail=1` |

## 7. The two-publisher problem

`/quad_control_target` is consumed, not merged: the controller reads the latest
message every cycle ([`launch.md` §4.2](launch.md)). Two publishers therefore do
not average — they alternate, and the robot jitters between two speeds. There
are exactly two other publishers in this repo:

| Publisher | When | Handled by |
|---|---|---|
| `p21-trot-hold.sh` | `run` ends by holding a 0.3 m/s trot | `teleop` stops it first, and says so |
| `kennel-verify.sh` `check.py walk` | checks 6–9 | `verify` warns when a bridge is up; the operator disconnects |

`teleop` can only stop the one it started. The console covers the rest by
**listening before it speaks** — see
[`teleop.md` §3](../kennel_console/teleop.md).

**Measured, both halves.** With the page driving at 0.5 m/s and
`kennel-demo.sh walk` started beside it, the guest sees `distinct body_x_dot`
`[0.3, 0.5]` on the topic, **3 publishers** where there were 2, and 30 Hz where
there were 20 — the two streams interleaved, not merged. The robot averages
0.427 m/s, between the two commands. `kennel-demo.sh teleop` puts it back to
`[0.5]` and 2 publishers.
([`evidence/live/03-jitter.txt`](bridge/evidence/live/03-jitter.txt).)

> The idle `joy_to_target` is always one of the publishers, on a guest with no
> gamepad: it never publishes anything. So the baseline is 2, not 1, and it is
> the *change* that means something.

`teleop stop` runs the trot-hold stop **before** taking the bridge down, never
after: killing the bridge under a browser that is mid-stride would leave the
controller holding the last target it received with nothing left to change it.

## 8. Evidence

In [`bridge/evidence/`](bridge/evidence/):

| File | What it shows |
|---|---|
| `01-teleop-verb.txt` | the verb, end to end, on a live guest |
| `02-api-health.txt` | the URL hand-off reaching the console server |
| `03-driven-forward.txt` | **the robot walking under browser control**: 0.467 m/s mean against a 0.500 command (93 %), 12.49 m in 27 sim-s, never fell |
| `04-release-ramps-to-zero.txt` | stick released → 0.459 m/s to ~0 in ~1 s, position then held |
| `05-meshcat-teleop.png` | the robot mid-stride at x = 59.5 m, driven from the browser |
| `06-estop.txt` | E-STOP → body height 0.311 m to 0.0754 m, velocity 0, robot sits where it was |
| `07-teardown.txt` | `teleop stop`: no processes, port closed, pidfile and URL files gone |
| `08/09/10-verify-*.txt` | the three rows of §6's table |
| `11-down-reaps-bridge.txt` | `down` alone reaps the bridge (§4.2) |

And in [`bridge/evidence/live/`](bridge/evidence/live/), everything §10 and §11
measure: the live suite green twice before the watchdog and twice with it, the
readiness race, the jitter, the load, Firefox, and the two `#66` sessions.

## 9. Limits

- **The bridge is unauthenticated and bound to every interface.** Anything that
  can route to the guest can drive the robot. That is acceptable for a
  single-operator demo host on a libvirt NAT and would not be on a lab network.
  `address:=127.0.0.1` plus an SSH tunnel is the tightening; a real answer is
  authentication, which rosbridge does not offer.
- **It is started by a verb, never by the console.** Starting a process is
  process control, which [`design.md` §2](../plan/design.md) puts outside the
  console ([`send.md` §6](../kennel_console/send.md)). Publishing a topic at an
  already-running stack is not, which is why the joystick itself is in.
- **`/reset_sim` and the disturbance injector are not wired.** Both are named in
  the Interventions spec; both are sim-level service calls this bridge could
  carry, and neither is this issue.
- ~~**No `RosbridgeDataSource`.**~~ Landed in
  [#62](https://github.com/alius-git/kennel/issues/62) /
  [#63](https://github.com/alius-git/kennel/issues/63): the Dashboard's panels
  read this bridge across the `DataSource` seam, on the same socket the
  joystick uses. What this issue proved — the socket, the type resolution and
  the URL hand-off — is what it was built on
  ([`kennel_console/dashboard.md`](../kennel_console/dashboard.md)).
  Measured with eight subscriptions and a held trot at
  `simulator_realtime_rate 0.5`: the bridge process runs at **70–90 % of one
  core**, which is the cost of serialising `/quad_state` to JSON at ~50 Hz.

## 10. Measured under load — the live regression suite ([#65](https://github.com/alius-git/kennel/issues/65))

Teleop was verified two ways after #58: 51 checks against a fake bridge with no
VM, and thirteen transcripts against the real stack (§8). The transcripts are
evidence, not a test — nothing re-ran them, and five caveats of
[`plan/teleop-joystick.md` D.3](../plan/teleop-joystick.md) had never been given
a number. [`verify-teleop-live.sh`](bridge/verify-teleop-live.sh) is the test.

It runs on the host against a guest whose stack is up: it starts its own
`serve.py` and its own headless Chrome, runs `kennel-demo.sh teleop`, drives the
page over CDP against the real `ws://` URL, and asserts on the **guest**. Every
number comes out of [`k13-target-monitor.py`](bridge/tools/k13-target-monitor.py)
running in the container, so what is asserted is what a node in the ROS graph
saw — never a variable read back out of the page under test
([`dashboard.md` §4](../kennel_console/dashboard.md)). The page's own state is
read from the DOM; the wire is read from the guest; the two never substitute for
each other.

It leaves the stack **in STAND on every path**, as `kennel-verify.sh` does.

### 10.1 It has to start somewhere

The first thing group 0 does is `kennel-bridge.sh recover`. Without it the suite
inherits whatever the last run left, and a trot commanded at a collapsed robot is
not a trot: measured, it reads as 0.33 m/s of travel with the body over 0.5 rad
of tilt in **97 %** of samples, on a stack that is perfectly healthy. A live
regression suite needs a defined starting state as much as a unit test does, and
`recover` is the cheap way there — no relaunch (§10.5).

### 10.2 D.3 §8 — which readiness signal comes first

Ten starts, measured twice.
[`evidence/live/02-bridge-race.txt`](bridge/evidence/live/02-bridge-race.txt).

`start`'s own polling loop reports the node first, every time — **and that is an
artefact of the instrument.** `ss` on the guest costs milliseconds; `ros2 node
list` inside the container costs ~0.9 s; they share one loop, so the cheap probe
only ever runs in the gaps the expensive one leaves. The port cannot be
*observed* first, so it can never be *reported* first.

Measured without that bias — two watcher processes, one clock
([`tools/race-probe.sh`](bridge/tools/race-probe.sh)):

| | min | median | max |
|---|---|---|---|
| port bound | 3.01 s | 3.06 s | 3.42 s |
| node listed | 3.50 s | 3.54 s | 5.26 s |
| delta | 0.10 s | 0.49 s | **2.18 s** |

**The port is bound first in 10 of 10 starts.** So the cheap signal is the early
one: a `start` that returned when `:9090` answered would hand the operator a URL
up to 2.2 s before `/rosbridge_websocket` was in the graph — a socket that
accepts a WebSocket and then cannot resolve
`interfaces/msg/QuadControlTarget`. That is the shape of
[#52](https://github.com/alius-git/kennel/issues/52), and it is why the wait is
both signals. Nine starts put the node 0.10–0.55 s behind; one put it 2.18 s
behind, and nothing about the median predicts that one.

### 10.3 D.3 §6 — what it costs, and whether it lags

[`evidence/live/05-cpu-lag.txt`](bridge/evidence/live/05-cpu-lag.txt). Console
connected, eight panel subscriptions live, joystick publishing at 20 Hz, robot
trotting.

| `simulator_realtime_rate` | 0.5 | 1.0 |
|---|---|---|
| page → bridge, wall rate | 20.1 Hz | 20.01 Hz |
| inter-arrival std / max | 3.65 / 67–70 ms | 1.53 / 54.7 ms |
| `rosbridge_websocket` CPU | 84.3 % | 79.0 % |
| robot speed while driven | 0.467 m/s | 0.220 m/s |
| body height (median) | 0.289 m | 0.221 m |

**No growing lag** — the gaps are tight and the maxima are tens of milliseconds,
not seconds, so rosbridge's queue is not building a backlog at 20 Hz of a
165-byte message. **The cost is one core**, and it is the subscriptions rather
than the joystick: ~50 Hz of `/quad_state` at 2.6 kB serialised to JSON. It
matches the 70–90 % #62 measured.

The robot is *worse off* at rate 1.0 — 0.220 m/s against the same command, body
sagging to 0.221 m. That is the simulator failing to keep up with wall time on
this guest, not the bridge; the bridge is slightly cheaper there because fewer
sim-seconds of data arrive per wall second.

**20 Hz is a wall-clock property** of the page's `setInterval`. Per *sim* second
it reads 20/rate — 40 Hz at rate 0.5 — which is a true number about a different
thing, and the suite asserts the wall figure.

### 10.4 D.3 §7 — Firefox

[`evidence/live/06-firefox.txt`](bridge/evidence/live/06-firefox.txt). Firefox
154 headless, driven over Marionette, connects and publishes: the guest received
**17.4 Hz** of targets from it, the DataSource went live, no console errors, and
**Private Network Access did not interfere** — no prompt, no block, for a page on
`http://localhost` opening `ws://192.168.122.32:9090/`. Two things worth knowing:
the profile must live under `$HOME/snap/firefox/` for the snap to read it, and
headless Firefox delivers a 20 Hz timer at about 17.4 Hz where headless Chrome
delivers 19.9–20.1. The controller consumes the latest target every cycle and
does not care; a suite asserting 20 ± 2 against Firefox would be asserting a
property of the browser's timer.

### 10.5 E-STOP is recoverable, and nobody had ever tried

E-STOP is `LegDriver::EMERGENCY_DAMPING`. Every session that pressed it
relaunched the stack afterwards
([`dashboard/evidence/03b-relaunch.txt`](../kennel_console/dashboard/evidence/03b-relaunch.txt)).
At the pin it **can** be left — only into `DAMPING`, by the sibling Trigger
`/set_damping_mode`, and `DAMPING` returns to `OPERATE` by itself as soon as a
leg command and a quad state arrive (`leg_driver.cpp:233-237`, `:348-374`). The
leg driver says so in its own log:

```
[leg_driver]: Swicht to ENERGENCY_DAMPING      <- the E-STOP (the typo is upstream's)
[leg_driver]: Switch to DAMPING                <- /set_damping_mode
[leg_driver]: Leg cmd message and quadt state received, switching to operation
[leg_driver]: Switch to OPERATE
```

`kennel-bridge.sh recover` is that sequence plus a `/reset_sim`, and it is what
makes the suite's E-STOP group cost no launch: **0.075 m on the floor → 0.314 m
standing**, gait `STAND`, and `verify` afterwards `pass=10 fail=0`.

### 10.6 What the suite measures about a page that dies

Group 6 kills the renderer with `kill -9` mid-stride. With `KENNEL_WATCHDOG=0`
— the behaviour before [#67](https://github.com/alius-git/kennel/issues/67) —
what is asserted is that **nothing intervenes**: no zero is ever published, the
stack is still holding the target the dead page sent, and the robot goes
somewhere with nobody watching.

What the robot *then does* is not asserted, because it varies. Two consecutive
runs of the same suite:

| | travel after the tab died | came to rest on its own |
|---|---|---|
| [`04a`](bridge/evidence/live/04a-live-suite.txt) | **13.32 m** in 30 sim-s, still going | never |
| [`04b`](bridge/evidence/live/04b-live-suite.txt) | 0.62 m, destabilised | at sim 76.5 |

Asserting the first outcome made the group a coin toss until it was written this
way. Both are an uncommanded robot carrying a stale order, and that is the
finding #67 answers.

### 10.7 Three traps this suite fell into first

- **`MAP * ~NOTFOUND` maps IP literals too.** The no-VM suites blackhole DNS with
  `EXCLUDE localhost`; a live suite has to add the guest, or the page's WebSocket
  never opens and the 3D pane never loads — which looks exactly like a bridge
  that is down. That exclusion is also what makes the "nothing but localhost and
  the guest" assertion mean something.
- **A browser the suite did not start is a browser it will drive.** An orphan
  Chrome left on the debugging port by an earlier run made a whole run
  meaningless: every CDP call went to a browser whose renderer had been killed,
  and the guest correctly reported that nothing was publishing. The suite now
  refuses to start if the port answers, and kills every browser it started.
- **"At rest" is a distance, not a speed.** A robot released in `WALKING_TROT`
  keeps trotting in place: measured, **0.355 m/s of mean body speed over twelve
  seconds in which it travelled 1.13 m** — 0.09 m/s of actual travel. Speed says
  it is moving; distance says it is going nowhere, and going nowhere is what the
  operator who let go of the stick asked for. The same shape
  [`composed-run.md` §9.2](composed-run.md) records for the standing robot that
  shuffles 5–22 cm/s under the MPC.

## 11. The watchdog — the dead man's switch the browser cannot provide ([#67](https://github.com/alius-git/kennel/issues/67))

[`kennel_console/teleop.md` §5](../kennel_console/teleop.md) listed the events
the console fires to zero the target — pointerup, `visibilitychange`, `pagehide`,
`beforeunload` — and then said the honest thing: *a killed renderer fires none of
them*. §10.6 is that limit, measured. This is the node that retires it.

[`tools/k13-target-watchdog.py`](bridge/tools/k13-target-watchdog.py) runs in the
container, started and stopped by `kennel-bridge.sh start|stop`, which is
`kennel-demo.sh teleop`. It subscribes `/quad_control_target` and publishes on
it, and it does exactly one thing.

### 11.1 The five rules

1. **Never before the first message.** Until it has seen one target it does
   nothing, forever if need be. A freshly launched stack — `joy_to_target` up and
   idle, nobody having commanded anything — is never touched.
2. **Stale and armed → one zero.** No message for `KENNEL_WATCHDOG_STALE`
   seconds *and* the last one commanding motion → publish a zero with `world_z`
   **copied from that message** (all six fields, the silent trap of
   [`launch.md` §4.2](launch.md)).
3. **A bounded burst, not "until a fresh message arrives".** The intervention is
   repeated twice more at one second, and then it is quiet. A watchdog that
   published forever after a kill would *be* a publisher on the topic, and the
   console's one-second probe would count it and refuse to drive on the next
   connect — the reconciliation #67 itself asks for. The controller's
   subscription is `RELIABLE`, so the repeats are belt and braces, not delivery.
4. **Its own echoes need no filter.** rclpy at this image's version has no
   `ignore_local_publications`, so the node hears the zeros it publishes. That is
   harmless by construction: an echoed zero sets `last` to a zero, and a zero
   never arms rule 2. Do not add a filter — there is nothing to filter.
5. **It never touches the gait.** No parameter call, no service call, ever. It
   stops the robot walking; it does not decide what the robot is.

### 11.2 Staleness is wall time; stopping is sim time

Publishers run on wall clocks whatever `simulator_realtime_rate` is, so "nobody
has published for a second" is a wall-clock fact. How long the robot then takes
to come to rest is a sim-time fact, and it is the *controller's*, not the
watchdog's — which already sends a hard zero and has nothing stronger to send.

**Measured, on a live stack at `simulator_realtime_rate 1.0`**, over two
consecutive runs of the live suite each way — same code, one knob:

| | without the watchdog | with it |
|---|---|---|
| a zero reaches the wire | **never** | 1.10 s / 1.07 s after the page's last message |
| the robot comes to rest | never | 2.7 s / 2.4 s later |
| **end to end, kill → at rest** | — | **3.79 s / 3.48 s** |
| travel in the 30 sim-s after the kill | **13.95 m / 13.93 m**, still going | 1.05 m / 1.38 m |
| travel rate over that window | 0.465 m/s | 0.035 / 0.046 m/s |

[`04a`](bridge/evidence/live/04a-live-suite.txt),
[`04b`](bridge/evidence/live/04b-live-suite.txt) ·
[`10a`](bridge/evidence/live/10a-live-suite-watchdog.txt),
[`10b`](bridge/evidence/live/10b-live-suite-watchdog.txt).

**#67 estimated ≤ 2 s for the whole thing.** The *intervention* is inside that,
every time and by construction: the zero goes out `KENNEL_WATCHDOG_STALE` seconds
after the last message, measured at 1.07–1.10 s against a 1.0 s setting. The
robot's *stopping* is not, and no watchdog can shorten it — a hard zero is the
strongest thing there is to send, and the deceleration from 0.5 m/s is the
controller's, measured between 2 and 5 sim-seconds depending on how fast it was
going. Both numbers are above rather than one hidden inside a threshold, and the
suite asserts the mechanism and *reports* the physics for that reason.

Lowering `STALE` would shorten the first number and nothing else. It is not
lowered: `kennel-demo.sh walk` publishes at 10 Hz, and a watchdog that fires
after less than a second of silence would eventually fire at a publisher that is
merely slow. One second is four missed messages from a 20 Hz page and ten from a
10 Hz hold.

### 11.3 It leaves everything else alone

Asserted by the live suite, every run:

- **A held trot is never stale.** `kennel-demo.sh walk` publishes at 10 Hz for
  ten sim-seconds; the intervention count does not move.
- **`kennel-verify.sh`'s own walk is never stale** either — the recipe publishes
  its own 20 Hz target for checks 6–9, and comes back `pass=10 fail=0` with the
  bridge and the watchdog up.
- **A page can connect again afterwards.** Because the burst is bounded, the next
  page's one-second probe finds a quiet topic and drives, rather than meeting a
  foreign publisher and refusing.
- **`down` reaps it for free.** The pidfile is `/tmp/k13-watchdog.pid`, so
  `k13-stop.sh`'s sweep signals it like everything else (§4.2), and that file
  now also clears the state file for the case where it had to be `KILL`ed.

### 11.4 One thing it caught that nobody was looking for

`p21-trot-hold.sh stop` kills its 10 Hz publisher, then checks the controller is
alive — seconds, through `ros2 topic echo --once` — and only then publishes its
zeros. **In between, the last target on the topic is 0.3 m/s with nobody
publishing it.** The watchdog fires there, correctly, on every `walk stop`. Before
#67 nothing noticed, because nothing was looking.

### 11.5 Limits

- **A reconnect inside the burst window is refused once.** For about two seconds
  after an intervention the watchdog is still repeating its zero, and a page
  connecting in that window sees a foreign publisher and declines to drive. The
  operator's action is to connect again. Teaching the probe to recognise the
  watchdog's messages would be the alternative, and it would put the seam the
  probe exists to avoid right back in.
- **It cannot shorten the stopping distance**, only the time before the stop is
  commanded. §11.2 has both numbers.
- **`KENNEL_WATCHDOG=0` still leaves the pre-#67 behaviour reachable**, on
  purpose: it is what the suite measures the watchdog against.
