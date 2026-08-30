# Kennel — Plan D: drive the robot from the console (virtual teleop joystick)

One plan, written like `plan/next-goals.md` A–C: so an agent can implement it
on its own branch without re-deriving the repo. It sits **after C** — it needs
`serve.py`'s `/api/health` (#56), the `run`/`up` verbs (#54) and a resettable
guest (#51), all of which have landed.

| Goal as stated | What it becomes | Estimated |
|---|---|---|
| "a virtual teleop joystick when running the stack" | rosbridge started in the container by the driver; the Dashboard's existing joystick publishing `/quad_control_target` (+ gait select, STAND, E-STOP) over a WebSocket to it | two to three days |

One GitHub issue, one branch, one PR, landing with its implementation records
beside the tools they record (`stack/bridge.md`, `kennel_console/teleop.md`).

---

## D.0 The design constraint — read before coding

Two sentences of the design decide the shape of this plan.

- **The joystick is inside the design, verbatim.** `plan/prompts.txt:180` —
  *"Interventions toolbar: velocity/gait target commands (publish
  `/quad_control_target` — joystick widget + fields)"*;
  `plan/applications.md:80` — *"all as service calls and topic publishes
  against the already-running sim"*; `plan/design/03-console.md:27` —
  *"Dashboard's interventions are topic publishes and sim-level service calls
  through the seam — no process control anywhere"*. Publishing a topic and
  calling a service against a running sim is **not** process control. This is
  a planned feature, not a deviation, and needs no row in #26 for that part.
- **Starting rosbridge is process control.** So it is a **driver verb**
  (`kennel-demo.sh teleop`), exactly like `launch` and `walk`, and never a
  console button. `send.md` §6 already recorded why.
- **One bypass.** `design.md` §1 serves the console *from inside the VM*, so
  the bridge is same-host and needs no discovery. The MVP console runs on the
  host (`serve.py`), so the bridge URL (`ws://192.168.122.x:9090`) has to be
  handed to the page — via `/api/health`, the same way *send* learned `out`
  and `pin`. Record it as a bypass with retirement path "console served from
  the appliance", add the row to #26.
- **Never auto-connect.** Opening a WebSocket to the guest is an off-host
  request. With no bridge configured the console must open none, so the
  suites' *zero non-localhost requests* assertion keeps holding unchanged;
  with one configured, the operator clicks *connect*.

## D.1 Ground truth the implementer must know

All of it checked on 2026-08-30. `plan/next-goals.md` §0 still applies (host,
guest, discovery, container, house rules); this is the delta for teleop.

**rosbridge is already in the pinned image, never launched.** The Dockerfile at
the pin `dcf53c59` installs `ros-humble-rosbridge-server` (line 15) and
`ros-humble-teleop-tools`; at the pin the gamepad driver is `joy_linux`
(`ros-humble-joy-linux`, node `/joy_linux_node`) — the working clone at
`dfki-quad/` HEAD has moved to `joy`, and is *not* what the guest runs. No
kennel document launches or mentions rosbridge except `stack/verify.md:9`.

**The stack's command surface** (`stack/launch.md` §4, all runtime-verified):

| What | Mechanism | Shape |
|---|---|---|
| Velocity / height / attitude | topic `/quad_control_target`, `interfaces/msg/QuadControlTarget`, **continuous** (controller consumes the latest every cycle) | `body_x_dot body_y_dot world_z hybrid_theta_dot pitch roll` — six `float64`, no others |
| Gait | parameter `simple_gait_sequencer.gait` on `/mit_controller_node` → service `/mit_controller_node/set_parameters` (`rcl_interfaces/srv/SetParameters`) | node accepts `STAND STATIC_WALK WALKING_TROT TROT FLYING_TROT PACE BOUND ROTARY_GALLOP TRAVERSE_GALLOP PRONK`; an unknown string returns `successful: true` **and does nothing** (`verify.md` §4.4) |
| Emergency damping | service `/set_emergency_damping_mode`, `std_srvs/srv/Trigger` | — |
| Sim reset | service `/reset_sim`, `interfaces/srv/ResetSimulation` | out of scope here |

**The `world_z` trap** (`launch.md` §4.2): the first message overwrites the
controller's whole target; a message with `world_z` omitted commands the body
to the ground. Every message the page sends carries `world_z`, default
`0.30` (the value that pairs with the stock go2 sim config).

**`joy_to_target.py` is idle in every session** (no `/dev/input/js*`). It
publishes only when a `/joy` message arrives, scales stick→`x` by 0.5 and
yaw by 1.0, clips acceleration at `max_acceleration: 0.5` m/s², and seeds
`world_z` from `init_robot_height: 0.30` (`mit_controller_sim_go2.yaml:91`).
The plan publishes `QuadControlTarget` **directly** (option B of the
feasibility note) and copies those three numbers as defaults; it does not
fake a gamepad.

**Network.** The container runs `--network host` in the guest
(`ubuntu.server.24.dfki-quad.sh:266`); the host reaches `192.168.122.x`
directly, no forward (`vm/meshcat-exposure.md` §2.2). A rosbridge on 9090 is
reachable from the host browser exactly as Meshcat on 7000 is. The driver
already holds `GUEST_IP` after `need_guest`. Page `http://localhost:8000` →
`ws://192.168.122.x:9090` is not mixed content and WebSockets carry no CORS.

**Console** (`kennel_console/Kennel Console.dc.html`, a design-canvas page:
`sc-if`/`sc-for` templates, `{{ }}` mustaches, all logic in the
`data-dc-script` block; the suites assert zero unresolved mustaches and
`verify-generate.py` clicks tabs by text in document order — **append, never
reorder**):

| Piece | Where | Today |
|---|---|---|
| Joystick widget | template line ~321–333 (`Interventions` row) | pointer handlers `joyDown/joyMove/joyUp` (~2075), `joySet` (~2100) writes `ds.cmd.vx` (±1.2 m/s) and `ds.cmd.wz` (±1.5 rad/s) |
| Velocity fields | `velFields` (~2060): `vx vy wz` | write `ds.cmd[key]` |
| Where the command lives | `MockDataSource.cmd = {vx, vy, wz}` (~1343) | the mock reads it; nothing leaves the page |
| Feature detection | `probeKennel()` (~1499): `fetch('/api/health')` → `state.kennel` or `null` | *send* button renders iff `kennel` non-null |
| Status bar | `status[]` (~2081): `conn: MockDataSource · connected` | — |

**Two publishers that will fight the joystick** (the controller takes
whichever message arrived last):
- `p21-trot-hold.sh start` — a detached `ros2 topic pub -r 10` holding
  `body_x_dot: 0.3`; this is what `run`'s final `walk` phase leaves running.
- `kennel-verify.sh`'s `check.py walk` — its own 20 Hz publisher for checks
  6–9. **Never run `verify` while a page is connected.**

**Verify check 1** (`stack/verify/kennel-verify.sh:211`) asserts *exactly* six
nodes. The rosbridge launch adds `/rosbridge_websocket` and `/rosapi` (and
possibly `/rosapi_params` — record what the image actually spawns). With the
bridge up, check 1 fails with `extra:` — by design; see D.2 §6.

**Teardown is already solved if the bridge follows the convention.**
`k13-stop.sh` signals every `/tmp/k13-*.pid` with INT, waits, then KILL — and
`down`, `launch`'s pre-stop and the baseline-prep script all run it. A bridge
started as `ros2 launch …` with its PID in `/tmp/k13-bridge.pid` is torn
down by all three with no change to any of them. `ros2` is already in the
name sweep; the Python children die with the launch process (confirm — D.3 §3).

**Lessons from open issues that apply here.** #45: a stack tool must say what
it depends on (the bridge script depends on the launcher's `/tmp/p21-env.sh`).
#52: readiness is observed on the graph, not on a log line or a sleep — the
bridge is "up" when its node is listed **and** its port is bound.

## D.2 Deliverables

### 1. `stack/bridge/kennel-bridge.sh` — GUEST, `start | stop | status`

Header comment per house rules (version date, HOST/GUEST/container, usage,
exit codes). `set -uo pipefail` is fine — it sources no ROS file itself;
every in-container command goes through `in_ctr` sourcing `/tmp/p21-env.sh`,
copied from `p21-trot-hold.sh`.

- **`start`** — exit 2 with the fix named if the container is not running or
  `/tmp/p21-env.sh` is absent ("launch first: `kennel-demo.sh launch`" —
  the #45 lesson). Confirm the package (`ros2 pkg prefix rosbridge_server`),
  then detached: `ros2 launch rosbridge_server rosbridge_websocket_launch.xml
  port:=$PORT` → `/tmp/k13-bridge.log`, PID → `/tmp/k13-bridge.pid`.
  Idempotent: PID alive **and** port bound → say so, exit 0. Wait by
  observation, bounded by `KENNEL_BRIDGE_WAIT` (default 60 s): `ros2 node
  list` carries `/rosbridge_websocket` **and** `ss -ltn` shows `:$PORT` on a
  non-loopback bind. Exit 1 if either never comes, with the log path.
- **`stop`** — INT the recorded PID, bounded wait, KILL, remove the pidfile.
  Does **not** touch the target or gait — that is `teleop stop`'s job (§3).
- **`status`** — PID alive / port bound / node listed, one line each; exit 0
  only when all three hold. Prints the port; the URL is the driver's to
  compose (the guest does not know its own NAT address the way the host does).
- Knobs: `KENNEL_CONTAINER` (`dfki_quad`), `KENNEL_BRIDGE_PORT` (`9090`),
  `KENNEL_BRIDGE_WAIT`.

### 2. `vm/test/verify-bridge-host.sh` — HOST, sibling of `verify-meshcat-host.sh`

Same knobs, same lease-by-hostname discovery (copy the region, do not
re-derive it), same `--quiet` contract (last stdout line is the URL). Hop 1:
over SSH, `ss -ltn` in the guest shows the port bound non-loopback. Hop 2:
from the host, a real WebSocket handshake — `python3` stdlib, reusing the
`WS` class in `kennel_console/cdp.py` (it already hand-rolls the upgrade), or
`curl -i` with the `Upgrade` headers expecting `101`. Exit codes mirror
Meshcat's: 0 ok, 2 no guest IP, 3 no SSH, 4 no listener, 5 loopback-only,
6 answers but not a WebSocket, 7 bound but unreachable from the host.

### 3. `demo/tools/kennel-demo.sh` — verbs

- **`teleop`** — `need_guest` → stage `p21-trot-hold.sh` and run `stop`
  (harmless when nothing is held; zeroes the target and returns the gait to
  STAND, so the operator's first gait pick is deliberate) → stage and run
  `kennel-bridge.sh start` → `verify-bridge-host.sh --quiet` for the URL →
  write it to `$OUT/.kennel-bridge` (one line; `serve.py` reads it per
  request, so a running console needs no restart) → start the console if it
  is not answering (`do_console` logic) → print three lines: the Meshcat URL
  (`verify-meshcat-host.sh --quiet`), the console URL, and *"Dashboard →
  Interventions → connect"*. Exit codes: 0; 1 the bridge never became
  reachable; 2 no stack (`launch` first).
- **`teleop stop`** — `p21-trot-hold.sh stop` (zero, then STAND — in that
  order, as the script already does) → `kennel-bridge.sh stop` → remove
  `$OUT/.kennel-bridge`.
- **`down`** — also removes `$OUT/.kennel-bridge` (the process is already
  reaped by `k13-stop.sh`).
- **`walk`** — when `/tmp/k13-bridge.pid` is alive, `warn` that a connected
  console may be publishing too, then proceed (it is the operator's call).
- **`status`** — one more line via `verify-bridge-host.sh --quiet`:
  `bridge reachable: ws://…` / `bridge not up (kennel-demo.sh teleop)`.
- **`run`** — unchanged; its closing lines gain
  `drive it yourself:  $0 teleop`. `all` unchanged.
- **`help`** — `teleop` and `teleop stop` in the *each session* group.

### 4. `kennel_console/serve.py`

`/api/health` gains `"bridge": "<ws url>" | null`, resolved per request from
`--bridge`, else `$KENNEL_BRIDGE_URL`, else the first line of
`<out>/.kennel-bridge`, else `null`. No `virsh`, no subprocess: the server
stays stdlib-only and localhost-bound, and the driver — which already knows
the guest — is the one that discovers. Optional and cheap while here:
`"meshcat": "<http url>" | null` from `<out>/.kennel-meshcat` written by
`teleop`/`walk`, so a later one-line change can point the Dashboard's iframe
slot at the real viewer. Not required for acceptance.

### 5. Console change — `Kennel Console.dc.html`, feature-detected like *send*

- **`RosbridgeTarget`**, a small class beside `MockDataSource` — *not* the
  design's full `RosbridgeDataSource` (that is build step 3 in `design.md` §7
  and subscribes to everything; this publishes one topic and calls two
  services). Native `WebSocket`, rosbridge v2 JSON ops only, so nothing new is
  vendored and `verify-serve.sh`'s asset list is unchanged:
  - `advertise` `/quad_control_target` as `interfaces/msg/QuadControlTarget`
    on connect; `unadvertise` on disconnect.
  - `publish` at **20 Hz for as long as it is connected** — zeros when the
    stick is centred, never silence. All six fields every time; `world_z`
    from the height field.
  - `call_service` `/mit_controller_node/set_parameters`
    (`rcl_interfaces/srv/SetParameters`, `{parameters:[{name:
    'simple_gait_sequencer.gait', value:{type:4, string_value:<gait>}}]}`)
    and `/set_emergency_damping_mode` (`std_srvs/srv/Trigger`).
  - Before advertising, `subscribe` to `/quad_control_target` for one second
    (throttled); any message seen means another publisher holds the target
    (a `walk` still running, or `verify`) — show *"another publisher holds
    the target — run `kennel-demo.sh teleop`"* and refuse to publish until
    reconnect. Cheap, and it is the only defence against the two-publisher
    jitter that does not depend on the operator remembering.
- **Mapping**, copied from `joy_to_target.py` rather than invented: stick
  y → `body_x_dot = −ny × vmax` (vmax default 0.5 m/s), stick x →
  `hybrid_theta_dot = nx × 1.0` rad/s, `body_y_dot` from the `vy` field,
  `pitch`/`roll` 0, 5 % deadzone, acceleration clipped at 0.5 m/s² exactly
  as `clip_velocity` does. While connected, `joySet` and `velFields` drive
  `RosbridgeTarget` instead of `ds.cmd` — the mock keeps running for every
  other panel; **the `DataSource` seam is untouched by this plan**.
- **UI**, appended at the **end** of the Interventions row (suites click by
  text order): a `bridge` text field prefilled from `kennel.bridge` (editable
  — a lab may know its URL), `connect`/`disconnect`, a `gait` select carrying
  the node-accepted list of D.1 (the parameter path reaches more gaits than
  the upstream gamepad, `launch.md` §4.1 — say so in the record), a `STAND`
  button, an `E-STOP` button (damping), `z [m]` default `0.30`, `max v [m/s]`
  default `0.5`. The whole group renders only when `kennel` is non-null;
  under plain `http.server` the row is byte-for-byte what it is today.
- **Dead-man, best effort and stated as such**: pointer-up → an immediate zero
  message; `pagehide` / `beforeunload` / `visibilitychange: hidden` → zero,
  then close; on socket error → UI *disconnected*, and a note that the robot
  keeps its last target (a killed tab mid-hold keeps walking until `teleop
  stop`). A guest-side watchdog would be a new ROS node; record it as the
  retirement path, not as part of this plan.
- **Gait feedback is honest**: `set_parameters` answers `successful: true`
  even for a rejected gait (`verify.md` §4.4). Show *"sent"*, never *"active"*
  — and if `RosbridgeTarget` also subscribes to `/gait_state` (throttled to
  2 Hz) it can show the period/duty signature and *that* is "active". Nice to
  have; not required.
- Status bar gains one item: `bridge · ws://… · 20 Hz` / `bridge · off`.

### 6. `stack/verify/kennel-verify.sh` — one knob

`KENNEL_EXPECT_BRIDGE=1` (added to `PASSTHROUGH_ENV`) extends check 1's
expected set with the bridge node names recorded in D.3 §1; the PASS/FAIL
text becomes *"the six healthy-session nodes (+ the bridge nodes when
`KENNEL_EXPECT_BRIDGE=1`), no duplicates"*. Without the knob a bridge left up
is reported as `extra:` — that is the intended signal, not a defect; the
runbook row says so. The driver's `verify` sets the knob when
`/tmp/k13-bridge.pid` is alive. `verify.md` check-1 row updated.

### 7. Verification — `kennel_console/verify-teleop.sh` + `verify-teleop.py` + `fake-rosbridge.py`

Style of `verify-send.*`: CDP, headless Chrome, DNS blackhole except
`localhost`, throwaway profile, two origins (`serve.py` and plain
`http.server`). No VM. **`fake-rosbridge.py`** is a stdlib WebSocket server
(the server half of `cdp.py`'s `WS` — handshake, unmasking, text frames) that
appends every op it receives to a JSONL file and answers `call_service` with a
canned `service_response`. `serve.py` is started with `--bridge ws://localhost:<port>`.

Asserted from bytes on disk and CDP events, never from a JS variable:
- No controls and zero mustaches under `http.server`; controls present under
  `serve.py` with the field prefilled to the health URL.
- `Network.webSocketCreated` count is **0** until *connect* is clicked, then
  **exactly 1**, to the configured URL; `requestWillBeSent` stays all-localhost.
- After connect: one `advertise` with the right topic and type; the first
  second holds no `publish` (the foreign-publisher probe), then `publish` at
  20 ± 2 Hz with all six fields and `world_z == 0.30`.
- Drag to the top of the pad → `body_x_dot` ramps to `+0.5` at ≤ 0.5 m/s²
  (never a step); release → the next message is all-zero and zeros continue.
- Gait select → one `call_service` with the exact `SetParameters` payload;
  `E-STOP` → one `Trigger` call; `STAND` → the gait payload with `STAND`.
- Page navigated away mid-hold → the last frame the fake bridge received is
  all-zero.
- Fake bridge pre-loaded to echo a foreign message on subscribe → the page
  refuses to publish and shows the message.
- `verify-serve.sh` (assets unchanged), `verify-scope.sh`, `verify-generate.sh`,
  `verify-export.sh`, `verify-send.sh` green and unmodified.

### 8. Guest-side evidence (`stack/bridge/evidence/`, transcripts not a suite)

Against the real stack after a green `run`: `teleop` transcript; `ros2 node
list` with the bridge; `verify-bridge-host.sh` loud output; a CDP-driven
session from the host (reuse `verify-teleop.py`'s driver against the real
URL) holding the stick forward for 30 s while, in the container, `ros2 topic
hz /quad_control_target` reads ≈ 20 Hz and a 20-s `k13-monitor.py` sample
shows mean `vx ≥ 0.15` m/s; release → `vx → 0` within a few seconds; `E-STOP`
→ the controller's damping log line; a Meshcat screenshot mid-teleop
(`p21-meshcat-shot.sh`); `verify` with `KENNEL_EXPECT_BRIDGE=1` and no client
connected: `pass=10 fail=0`; the same without the knob: check 1 `extra:`.

### 9. Records and docs

- **`stack/bridge.md`** — what the pin ships, the launch line, bind/port, the
  node names it adds, the pidfile teardown, the verify knob, the two-hop URL
  (cross-ref `meshcat-exposure.md`), measured start-up time, the bypass note
  of D.0 with its retirement path.
- **`kennel_console/teleop.md`** — the four rosbridge ops and their exact
  payloads, the mapping and why it copies `joy_to_target`, the dead-man and
  its stated limit, the foreign-publisher probe, what was verified, evidence
  (`teleop-render.png`, transcripts), limits: Dashboard still on
  `MockDataSource`, no `RosbridgeDataSource`, no watchdog.
- `demo/runbook.md` — §1 gains one line (`teleop`, after `run`); phase table
  row; troubleshooting rows: *"robot jitters between two speeds"* (a `walk`
  still held — `teleop` stops it), *"connect fails"* (bridge down: `status`,
  then `teleop`), *"verify check 1 lists extra nodes"* (`KENNEL_EXPECT_BRIDGE`),
  *"tab closed while driving and the robot kept going"* (`teleop stop`).
- `README.md` quick start (one line), `docs/README.md` (two entries),
  `stack/launch.md` §4 (a pointer: the bridge is the third way to command the
  stack), `stack/verify.md` (check-1 row), `#26` (the bypass row).

## D.3 Caveats to test, not to reason about

1. **What the launch actually spawns in this image.** Humble's
   `rosbridge_websocket_launch.xml`: confirm its arguments (`port`,
   `address`), that the default bind is all interfaces (else pass
   `address:=0.0.0.0`), and the exact node names it adds (`/rosbridge_websocket`,
   `/rosapi`, possibly `/rosapi_params`). Those names go into D.2 §6 verbatim.
2. **Type resolution.** rosbridge introspects `interfaces/msg/QuadControlTarget`
   and `rcl_interfaces/srv/SetParameters` at `advertise`/`call_service` time
   from the sourced workspace; `/tmp/p21-env.sh` must reach `install/setup.bash`.
   Watch the bridge log for `Unable to import` on the first publish.
3. **Teardown leaves nothing.** After `down`, `ps` in the container shows no
   `rosbridge_websocket` / `rosapi_node` (Python children of the launch). If
   INT to the launch PID is not enough, add the names to `k13-stop.sh`'s sweep
   — mind `TASK_COMM_LEN` (`rosbridge_websocket` truncates to
   `rosbridge_webso`, the `mitcontrollerno` trap).
4. **The two-publisher jitter is real** — reproduce it once (`walk` held +
   page connected), record the `/quad_state` vx trace, then show `teleop`'s
   `trot-hold stop` and the page's probe each prevent it.
5. **Dead-man limit.** Kill the tab (not close — `kill -9` the renderer) with
   the stick held; the robot must keep walking until `teleop stop`. Record
   how long, so the runbook row is measured, not assumed.
6. **Rate under rosbridge.** 20 Hz JSON is trivial, but confirm `ros2 topic hz`
   reads ≈ 20 with no growing lag (rosbridge's default `queue_length`), and
   note the bridge's CPU on the 8-vCPU guest while the sim runs at 0.5×.
7. **Browser path.** Chrome is what the suites drive; confirm the
   `localhost → 192.168.122.x` WebSocket also in Firefox if that is the
   classroom browser (Private Network Access rules differ).
8. **Readiness race (#52's shape).** Show that neither "node listed" nor "port
   bound" alone is sufficient — one of them will be true first — so the
   bridge script's *both* wait is justified by an observation, not a guess.
9. **`verify` after `teleop`.** With a page still connected, checks 6–9 are
   meaningless (two 20 Hz publishers); the driver's `verify` warns when the
   bridge is up. Confirm the warning fires and that a disconnected page +
   `KENNEL_EXPECT_BRIDGE=1` is green.

## D.4 Acceptance

- From a green `run`: `kennel-demo.sh teleop` prints the bridge URL, the
  Meshcat URL and the console URL; in the Dashboard, *connect* → gait
  `WALKING_TROT` → push the stick: the robot in Meshcat walks where it is
  pushed; release → trots in place; `STAND` → stands; `E-STOP` → damping.
  `/quad_control_target` observed at ≈ 20 Hz in the container throughout.
- `teleop stop`: target zero, gait `STAND`, port closed; `status` reports the
  bridge as not up. `down`, `reset` and a following `launch` leave no bridge
  process behind.
- `verify-teleop.sh` green with no VM; the five existing console suites green
  and unmodified; `verify-serve.sh`'s asset list unchanged.
- Plain `python3 -m http.server`: no bridge controls, zero mustaches, zero
  WebSockets — the console is exactly what it is today.
- `verify` with the bridge up and no client, `KENNEL_EXPECT_BRIDGE=1`:
  `pass=10 fail=0`; without the knob: check 1 `extra:` naming the bridge nodes.
- Evidence folders and both records written; #26 gains the bypass row;
  `README.md` §quick start shows `teleop` as one line.

## D.5 Deliberately not in this plan

- The full `RosbridgeDataSource` (design build step 3): subscribing the
  Dashboard's panels to the live stack. This plan proves the socket, the type
  resolution and the URL hand-off it will need.
- Pointing the Dashboard's Meshcat iframe slot at the real viewer — a one-line
  follow-up once `/api/health` carries `meshcat` (D.2 §4, optional).
- Keyboard (WASD) driving on the same publisher; a guest-side target
  watchdog node (the dead-man's retirement path); a `.zip`-free lab mode
  where the console is served from the guest (the bypass's retirement path).

## Suggested issue title

**D** — "Teleop from the console: rosbridge in the container, a `teleop` verb,
and the Dashboard joystick publishing `/quad_control_target`" (`area:console`,
`area:stack`, `bypass`; feeds #26)
