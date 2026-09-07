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
| [`stack/bridge/kennel-bridge.sh`](bridge/kennel-bridge.sh) | guest | `start` / `stop` / `status` for the rosbridge beside a running stack |
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

`KENNEL_EXPECT_BRIDGE=1` adds the three to an *allowed* set used only for the
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
