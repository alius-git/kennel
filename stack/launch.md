# Launching the go2 sim stack headless — the canonical command set

Implementation record for
[issue #13](https://github.com/alius-git/kennel/issues/13) — the stock dfki-quad
Go2 **simulation** stack runs headless inside the guest's `dfki_quad` container:
simulator + MIT controller, ground-truth state instead of the state-estimation
node, robot standing and trotting on command.

Builds on [`vm/provisioning.md`](../vm/provisioning.md)
([#10](https://github.com/alius-git/kennel/issues/10)), which delivers the
container and the built workspace, and on
[`stack/pin.lock`](pin.lock) ([#12](https://github.com/alius-git/kennel/issues/12)),
which fixes the revision every statement below was verified against:
`dcf53c596339afd45b82f12c54b1e93e8273c2f4`.

Everything here was run end to end over SSH into `kennel-vm` on **2026-08-05**;
the evidence is in [`stack/known-good/`](known-good/).

> **Scope.** This document is the *launch surface*: what to run, in what order,
> and how to command a gait. Turning the health signals in §6 into a pass/fail
> CLI recipe was [#14](https://github.com/alius-git/kennel/issues/14) — done, in
> [`stack/verify.md`](verify.md); mapping console choices onto launch args and
> YAML keys was [#15](https://github.com/alius-git/kennel/issues/15) — done, in
> [`stack/mapping.md`](mapping.md).

## 1. The canonical command set — three commands, not two

Issue #13 sketched the launch surface as two commands. **It is three.** The
missing one is the leg driver, and the stack does not run without it:

```bash
# shell 1 — simulator (also serves Meshcat; see vm/meshcat-exposure.md)
ros2 launch simulator simulator.launch.py sim:=go2

# shell 2 — leg driver
ros2 launch drivers leg_driver_launch.py sim:=go2

# shell 3 — MIT controller
ros2 launch controllers mit_controller.launch.py sim:=go2
```

**There is no state-estimation command in sim** — see §3.

> **Do not start the controller on a timer.** Wait for the stack to be
> *observable*: `/clock` advancing and `/quad_state` present, then ~10 **sim**
> seconds for the robot to settle from its 0.4 m spawn.
>
> The console's generated `commands.txt` says "wait ~10 s" on block 3, and
> [#22](https://github.com/alius-git/kennel/issues/22) followed that literally.
> At the 10-second mark the simulator was **still enumerating joints** — no
> `/clock`, no `/quad_state`, nothing to settle onto. The number is too small
> even at `simulator_realtime_rate: 1.0`, because it accounts for the settle and
> not for simulator startup; and at any composed rate below 1.0 it is wrong
> again by the reciprocal of that rate (0.75 → 13.3 s, 0.5 → 20 s of wall for
> the settle alone). Measuring the settle in sim seconds makes it invariant
> under the one parameter the composer is most likely to change —
> [`stack/composed-run.md` §3.2](composed-run.md) is where that reasoning
> lives, and [`stack/verify.md`](verify.md) applies it to every window.

### 1.1 Why the leg driver is required, and how that was established

In WBC mode — `leg_control_mode: 0` in
`ws/src/controllers/config/mit_controller_sim_go2.yaml`, which is the stock go2
sim config — the controller and the simulator do not speak the same topic:

| Node | Publishes | Subscribes |
|------|-----------|------------|
| `mit_controller_node` | `leg_cmd`, `leg_joint_cmd` | `quad_state` |
| `leg_driver` | `joint_cmd` | `leg_cmd`, `leg_joint_cmd`, `quad_state` |
| `drake_simulator` | `quad_state`, `joint_states`, `imu_measurement`, `clock` | `joint_cmd` |

`leg_driver` is the bridge. Observed directly, with only the simulator running:

```console
$ ros2 topic info /joint_cmd
Type: interfaces/msg/JointCmd
Publisher count: 0
Subscription count: 4
```

and the controller, launched without it, blocks rather than failing loudly:

```
[mit_controller_node]: Waiting for leg driver service to become available
```

It proceeds to `Starting controller` the moment `leg_driver_launch.py` comes up.
Upstream's own README agrees — it lists "Leg Driver" among the components that
have to be launched — but the two-command sketch in the issue omitted it.

### 1.2 Launch order matters

Launch **simulator → leg driver → controller**, and let the robot settle
(~10 s) before the controller.

`mit_controller.launch.py` calls `safe_start()` *inline, before* it returns a
launch description: it subscribes to `/quad_state`, collects 3 s of samples, and
`exit(-1)`s unless pose variance and mean twist are both below 0.05. Launched
against a simulator that is still dropping the robot from its 0.4 m spawn
height, it exits before anything starts. The stock escape hatch is
`safe_start:=false`, but the settle is the intended path — do not reach for the
flag to paper over a launch-order mistake.

## 2. Every shell needs the source chain

`new_docker_shell.sh` (`docker exec -it $(docker ps -q -n1) /bin/bash`) gives an
*interactive* shell, which reads `/root/.bashrc` and is already set up. Any
**non-interactive** shell — `docker exec dfki_quad bash -c '...'`, which is what
a script, a Yuruna step, or the console's shell channel will use — reads none of
it: `.bashrc` returns immediately on `[ -z "$PS1" ]`. Those shells need:

```bash
source /opt/ros/humble/setup.bash
[ -f /root/unitree_ros2/install/setup.bash ] && source /root/unitree_ros2/install/setup.bash
source /root/ros2_ws/install/setup.bash
export PATH="/opt/drake/bin:${PATH}"
export PYTHONPATH="/opt/drake/lib/python3.10/site-packages:${PYTHONPATH}"
export LD_LIBRARY_PATH="/opt/drake/lib:${LD_LIBRARY_PATH}"
export ROS_PACKAGE_PATH="/root/ros2_ws/src"
source /root/setup_ulab_workspace.bash     # NOT setup_go2_workspace.bash -- see 2.1
```

Kept verbatim as [`known-good/tools/prelude.sh`](known-good/tools/prelude.sh).
Also note `sudo` — the guest's `yuuser24` is not in the `docker` group, so every
`docker exec` from a Yuruna step is `sudo docker exec`.

### 2.1 Naming trap: the go2 **sim** path uses `setup_ulab_workspace.bash`

The container ships two workspace setups, and the obvious choice is the wrong
one:

| Script | Alias | Sets | Correct for |
|--------|-------|------|-------------|
| `setup_ulab_workspace.bash` | `sr` | `rmw_fastrtps_cpp`, `ROS_DOMAIN_ID=100` | **sim — including `sim:=go2`** |
| `setup_go2_workspace.bash` | `sg` | `rmw_cyclonedds_cpp`, `ROS_DOMAIN_ID=0`, `CYCLONEDDS_URI` pinned to NIC `enp0s31f6` | real GO2 hardware only |

Despite its name, `setup_ulab_workspace.bash` is not ulab-robot-specific — it is
the plain DDS setup, and it is what `sim:=go2` runs under. `setup_go2_workspace.bash`
pins CycloneDDS to the physical interface `enp0s31f6`, which exists on the DFKI
lab machine wired to the robot and **not** in this guest. Upstream's README only
ever calls `sg` in its real-hardware sections; that qualifier is easy to miss.

**All three shells must agree** on `RMW_IMPLEMENTATION` and `ROS_DOMAIN_ID`.
They are process-wide environment, not launch arguments, so a single shell that
sources the other script puts its nodes on a different middleware and a
different domain: every launch still reports success, and the nodes simply never
discover each other. This is the most likely way to get a silently dead stack,
which is why the console's generated command block must emit the source chain,
not just the three `ros2 launch` lines.

## 3. Ground-truth state — no state-estimation command in sim

`ws/src/simulator/config/simulator_params_go2.yaml` carries

```yaml
publish_quad_state: true   # If the quad state should be published under /quad_state
                           # (replaces the state estimation)
```

so `drake_simulator` publishes ground-truth `/quad_state` at 1000 Hz directly.
Confirmed at runtime: with only the simulator up, `/quad_state` is present and
`ros2 topic hz` reports `average rate: 1000.026`.

The state-estimation node is launched only by
`ws/src/common/launch/hardware.launch.py`, on the real-hardware path. There is
no `state_estimation` process in a healthy sim session (§6), and no third launch
file to run. The state-estimation *services* `joy_to_target` can call —
`/reset_state_estimation_covariances` — simply have no server in sim.

## 4. Commanding stand and trot

The stock mechanism is a gamepad: `mit_controller.launch.py` unconditionally
spawns `joy_linux_node` and `joy_to_target.py`. With no `/dev/input/js*` in the
guest, both nodes start and stay up but publish nothing — harmless, and **not**
a launch failure. The headless substitute reproduces exactly what
`joy_to_target.py` does, which is two different mechanisms:

### 4.1 Gait — a parameter on the controller node

Gait is **not** a topic. `joy_to_target.py` switches gait by calling
`SetParameters` on `/mit_controller_node`, so the CLI equivalent is:

```bash
ros2 param set /mit_controller_node simple_gait_sequencer.gait WALKING_TROT
```

This takes effect live: the node's parameter handler logs `Gait related
parameter has changed, reloading gait sequencer` and rebuilds the sequencer
under a lock. Defaults are `gait_sequencer: "Simple"` and
`simple_gait_sequencer.gait: "STAND"`.

Accepted by the **node** (`MITController::GetGaitSequencerFromParams`):
`STAND`, `STATIC_WALK`, `WALKING_TROT`, `TROT`, `FLYING_TROT`, `PACE`, `BOUND`,
`ROTARY_GALLOP`, `TRAVERSE_GALLOP`, `PRONK`, and `Manual`/`MANUAL` (which reads
period/duty-factor/phase-offset from `simple_gait_sequencer.manual_gait.*`). An
unknown string is rejected with `Unknown gait type [...]` and the sequencer is
left unchanged.

Note the **gamepad reaches fewer gaits than the parameter does**: at this pin
the `TROT` and `FLYING_TROT` bindings in `joy_to_target.py` are commented out,
so a joystick can only select `STAND`, `WALKING_TROT`, `STATIC_WALK`, `PACE`,
`BOUND` and `PRONK`. The parameter path has no such restriction — worth
recording for #15, since a console gait picker driven by parameters is strictly
more capable than the upstream gamepad it imitates.

`WALKING_TROT` is the gait used for the acceptance run. With the gait set and no
velocity target published, the robot trots in place, stable and upright.

### 4.2 Velocity — a topic, published continuously

```bash
ros2 topic pub -r 20 /quad_control_target interfaces/msg/QuadControlTarget \
  "{body_x_dot: 0.3, body_y_dot: 0.0, world_z: 0.30, hybrid_theta_dot: 0.0, roll: 0.0, pitch: 0.0}"
```

20 Hz matches `joy_to_target`'s `update_freq`. All six fields of
`interfaces/msg/QuadControlTarget` are listed above; there are no others.

> **`world_z: 0.30` is mandatory, and the trap is silent.** The controller
> initialises its internal target to `target_.z = initial_height` = `0.30`
> (`mit_controller_sim_go2.yaml`), so *not publishing at all* is safe. But the
> first message that arrives overwrites it wholesale — publish a message with
> `world_z` omitted and the field defaults to `0.0`, commanding the body to the
> ground. Any console panel or generated command that emits a
> `QuadControlTarget` must fill `world_z`, and `0.30` is the value that pairs
> with the stock go2 sim config. `joy_to_target` never trips over this because
> it seeds `world_z` from its own `init_robot_height` parameter (also `0.30`).

Publishing must be **continuous**, not one-shot: the controller consumes the
latest target every cycle.

> **A third way to command both of these: the browser.** `kennel-demo.sh teleop`
> starts the rosbridge that ships unused in the pinned image, and the console's
> Interventions joystick then publishes `/quad_control_target` at the same 20 Hz
> and calls the same `SetParameters` service. Same surfaces as §4.1 and §4.2,
> reached over a WebSocket instead of the CLI — [`bridge.md`](bridge.md) and
> [`kennel_console/teleop.md`](../kennel_console/teleop.md).

### 4.3 Other controls the same node exposes

Useful when a run goes bad, and all reachable from the CLI: `/set_emergency_damping_mode`
(`std_srvs/Trigger`, drops the robot into damping) and the simulator's
`/reset_sim` (`interfaces/srv/ResetSimulation`, pose + 12 joint positions — the
call is spelled out in upstream's README). Returning to `STAND` via the same
parameter is the gentle stop.

## 5. Verified result

From the capture in [`known-good/`](known-good/) — one clean run, three shells,
no GUI, no X, no joystick:

| Phase | Result |
|-------|--------|
| Stand (gait `STAND`, no target) | z = 0.3138 m, velocity 0.000 m/s, `foot_contact` `1111`, held 10 s |
| Trot in place (`WALKING_TROT`, no target) | z ≈ 0.3195 m, drift −0.001 m over 15 s, feet cycling |
| Forward trot (target `body_x_dot: 0.3`) | **16.5 m travelled in 60 s**, vx 0.268 m/s (range 0.267–0.271), z 0.3154 m, never fell |

Velocity tracking settles ~10 % under the 0.3 m/s command, steady and without
drift — the MPC is tracking, not saturating. `foot_contact` alternates between
the diagonal pairs `1001` and `0110`, which is the trot signature.

Sustained trot well past the 60 s window is the acceptance criterion, and it
holds.

## 6. What a healthy session looks like

The reference for [#14](https://github.com/alius-git/kennel/issues/14).

**Nodes** — exactly these six, no more:

```
/drake_simulator      /leg_driver          /mit_controller_node
/joy_linux_node       /joy_to_target       /safe_start_launcher
```

`/joy_linux_node` and `/joy_to_target` are idle without a gamepad but must be
present — their absence means the controller launch did not complete.
`/safe_start_launcher` is left behind by `mit_controller.launch.py`'s inline
`safe_start()` and is expected.

**Rates**, measured under load:

| Topic | Rate |
|-------|------|
| `/quad_state` | 1000 Hz |
| `/joint_cmd` | 1000 Hz |
| `/gait_state` | 100 Hz |
| `/controller_heartbeat` | 2 Hz |

**`/controller_heartbeat`** (`interfaces/msg/ControllerInfo`) is the health
message — note the spelling, which [`plan/design.md`](../plan/design.md) §4
already flags as a contract to integrate against as-is. During the trot:

```
num_early_contacts: 10        # nonzero is normal -- early_contact_detection is on
num_mpc_solver_overtime: 0
num_wbc_overtime: 2           # small counts are benign
num_mpc_solver_fail: 0        # must stay 0
num_wbc_solver_fail: 0        # must stay 0
num_model_updates: 0          # 0 unless use_model_adaptation is enabled
keep_pose_active: false
```

`num_mpc_solver_fail` / `num_wbc_solver_fail` leaving 0, and
`QuadState.belly_contact` staying false, are the two cheapest "still walking,
not fallen" signals. `belly_contact` was false for every sample of every phase.

**Achieved realtime rate ≈ 1.0** against the `simulator_realtime_rate: 1.0`
target, with the container at ~131 % CPU (of 800 % available) and 423 MiB RSS on
the 8 vCPU / 16 GiB guest. The stack has ample headroom on the sized guest, and
the `mpc_solver:=` launch argument was **not** needed — the stock default
solver keeps up. (The rate figure in the capture reads 1.017 because the
measurement's sim-time and wall-time origins differ by ~1 s; an independent
30 s measurement gave 0.973. Both round to "realtime".)

## 7. Traps found while doing this

Recorded because each cost real time and each will recur in #14, in the Yuruna
sequences, and in anything the console generates.

1. **Wrong workspace setup silently partitions the graph.** §2.1. The failure
   mode is not an error; it is three healthy-looking launches that never see
   each other.
2. **`world_z` defaults to 0.0.** §4.2. A partially-filled `QuadControlTarget`
   commands the body into the floor.
3. **`set -u` breaks every ROS shell.** `/opt/ros/humble/setup.bash` dereferences
   `AMENT_TRACE_SETUP_FILES` while unset, so a script with `set -euo pipefail`
   that sources the workspace aborts. The first capture run launched all three
   components correctly and then no-op'd every `ros2` call after it. Use
   `set -o pipefail` without `-u` in any script that sources the workspace.
4. **`$$` inside `( … )` is the parent's PID, not the subshell's.** Recording a
   background subshell's PID with `echo $$ > file` and later `kill`ing it kills
   the *script*. Use `$BASHPID`. This made teardown kill itself and leave the
   whole stack running.
5. **`pkill -x mitcontrollernode` never matches.** Linux caps `comm` at 15
   characters, so the 17-character name appears as `mitcontrollerno`. Reaping by
   exact name has to use the truncated form.
6. **`pkill -x joy_to_target.py` never matches either** — it runs under
   `python3`, so its `comm` is `python3`. Stale copies accumulate across runs and
   show up as duplicate `/joy_to_target` entries with a "nodes share an exact
   name" warning. Match the script path instead
   (`pkill -f 'controllers/joy_to_target[.]py'`), which is specific enough not to
   match the reaping shell — the hazard that makes bare `pkill -f` unusable here,
   as [`vm/provisioning.md`](../vm/provisioning.md) §5a already records.
7. **FastRTPS writes `RTPS_TRANSPORT_SHM` errors into captured output.** They are
   benign (shared-memory port locking when several `ros2` CLI processes run at
   once) but they corrupt `ros2 topic echo --field` captures. Parse message
   fields from an rclpy subscriber rather than from CLI text.

## 8. Reproducing

[`known-good/tools/`](known-good/tools/) holds exactly what produced
[`known-good/`](known-good/): the source chain, a detached launcher, the
teardown, an rclpy monitor, and the driver that sequences all of it. Copy them
into the container and run the driver:

```bash
GUEST=$(virsh net-dhcp-leases default | awk '/kennel-vm/ {split($5,a,"/"); print a[1]}')
KEY=~/git/yuruna/test/status/ssh/yuruna_ed25519
scp -i $KEY stack/known-good/tools/* yuuser24@$GUEST:/tmp/
ssh -i $KEY yuuser24@$GUEST '
  sudo docker cp /tmp/prelude.sh dfki_quad:/root/kennel13-prelude.sh
  for f in k13-launch.sh k13-stop.sh k13-monitor.py k13-capture.sh; do
    sudo docker cp /tmp/$f dfki_quad:/root/$f && sudo docker exec dfki_quad chmod +x /root/$f
  done
  sudo docker exec dfki_quad /root/k13-capture.sh /tmp/k13-known-good'
```

`k13-capture.sh` launches each component detached with its own log — the
scripted stand-in for three `new_docker_shell.sh` shells — and tears the stack
down cleanly afterwards. `TROT_SECONDS`, `TARGET_VX` and `TARGET_Z` are
environment knobs.

These scripts are the *provenance of the evidence*, not the verification recipe;
building that recipe, with thresholds and a pass/fail verdict, is #14.
