# Mapping composer choices onto the pin — launch args and YAML keys

Implementation record for
[issue #15](https://github.com/alius-git/kennel/issues/15) — the definitive table
from each Kennel Console **Compose** choice to the mechanism that actually exists
at the stack pin.

Builds on [`stack/pin.lock`](pin.lock)
([#12](https://github.com/alius-git/kennel/issues/12)), which fixes the revision
every statement below was verified against —
`dcf53c596339afd45b82f12c54b1e93e8273c2f4` — and on
[`stack/launch.md`](launch.md) ([#13](https://github.com/alius-git/kennel/issues/13)),
which establishes the three-command launch surface this document parameterises.

The composer surface being mapped is the one specified in
[`plan/prompts.txt`](../plan/prompts.txt) (View 1 — Compose), and the mapping
layer itself is the design.md §5 mock-boundary row that this document makes
concrete.

> **Scope.** This document is the *contract*
> [#18](https://github.com/alius-git/kennel/issues/18) implements: it says which
> knob to turn, never how to render it. Every gap it records — a composer choice
> with no mechanism at the pin — carries a **`mapping-layer bypass`** marker and
> feeds [#28](https://github.com/alius-git/kennel/issues/28).
>
> Verified 2026-08-05 by source inspection at the pin **and** by runtime probes
> in the `dfki_quad` container on `kennel-vm` (§6). Findings marked
> **[runtime]** were executed, not inferred.

---

## 1. The mapping table

Files are cited at the pin. `SIM` =
`ws/src/simulator/config/simulator_params_go2.yaml`, `CTRL` =
`ws/src/controllers/config/mit_controller_sim_go2.yaml`.

### 1.1 Map picker

| Composer choice | Mechanism | Value | Latency |
|---|---|---|---|
| Flat plane | `SIM:5 world_urdf` + `SIM:6 world_fix_link` | `"src/common/model/urdf/plane.urdf"` + `"plane_base_link"` | relaunch |
| Obstacle terrain | same two keys | `"src/common/model/urdf/terrain.urdf"` + `"plane_base_link"` | relaunch |
| Brick | — | **no working value — see §4.1** | — |

**The map picker sets two keys, not one.** `world_fix_link` names the body the
world is welded to (`drake_simulator.cpp:61`); it must match a link in the chosen
world URDF. `plane.urdf` and `terrain.urdf` both declare `plane_base_link`, so
the pair is constant across those two — but the second key is part of the
contract, not an implementation detail, and a third world will not necessarily
reuse the name.

There is **no `world:=` launch argument**: `simulator.launch.py:9-17` selects a
config file from `sim:=` alone and passes it wholesale
(`simulator.launch.py:27`). Confirmed at the pin — see §4.2.

### 1.2 Sim options

| Composer choice | Mechanism | Stock value | Latency |
|---|---|---|---|
| Real-time rate | `SIM:11 simulator_realtime_rate` | `1.0` (`0` = as fast as possible) | relaunch |
| Manual stepping | `SIM:12` **and** `SIM:25` `manually_step_sim` — *duplicated key, see §4.5* | `false` | relaunch |
| Initial robot height | `SIM:26 initial_robot_height` | `0.4` | relaunch |
| Initial joint positions | `SIM:27 initial_joint_positions` (12 doubles) | stock crouch | relaunch |
| Ground-truth state | `SIM:18 publish_quad_state` | `true` | relaunch |
| IMU noise | `SIM:28 imu_noise` `[ang_vel, lin_acc]` stddev | `[0.0, 0.0]` | relaunch |
| Joint noise | `SIM:29 joint_noise` `[pos, vel, eff, acc]` stddev | `[0.0,0.0,0.0,0.0]` | relaunch |
| Meshcat visualisation | `SIM:13 visualisation` | `true` | relaunch |

`publish_quad_state` is confirmed to live in the **simulator** YAML, not the
controller YAML — this answers the open question in the issue. It is declared at
`drake_simulator.cpp:30` and read at `:80`.

There is **no initial robot *pose*** — only a height. Orientation and x/y spawn
are not parameters at the pin; `init_pose(6)` takes the height and the rest is
fixed (`drake_simulator.cpp:452`).

⚠ **The two noise toggles are inert in the MVP configuration** — see §4.4.

### 1.3 MPC stage

These three are the composer choices with **two possible routes**, and the choice
between them is not free — read §2.1 before implementing.

| Composer choice | Node parameter | Accepted values | Launch arg |
|---|---|---|---|
| MPC solver | `mpc_solver` (`mit_controller_node.cpp:67`, default `PARTIAL_CONDENSING_HPIPM`) | `PARTIAL_CONDENSING_HPIPM`, `FULL_CONDENSING_HPIPM`, `PARTIAL_CONDENSING_OSQP`, `FULL_CONDENSING_QPOASES`, `FULL_CONDENSING_DAQP`, `PARTIAL_CONDENSING_QPDUNES` (`:526-540`) | `mpc_solver:=` — **only the first four** (`mit_controller.launch.py:99-108`) |
| HPIPM mode | `mpc_hpipm_mode` (`:69`, default `SPEED`) | `SPEED_ABS`, `SPEED`, `BALANCE`, `ROBUST` | `mpc_hpipm_mode:=` — all four (`:121-130`) |
| Condensed size | `mpc_condensed_size` (`:68`, default `MPC_PREDICTION_HORIZON / 2` = **5**) | any int | `mpc_condensed_size:=` (`:110-119`) |

**The launch argument reaches fewer solvers than the parameter does** — four of
six. `FULL_CONDENSING_DAQP` and `PARTIAL_CONDENSING_QPDUNES` are reachable only
by setting the parameter directly. This is the same shape as the gait/gamepad
asymmetry recorded in [`launch.md`](launch.md) §4.1: the console driving
parameters is strictly more capable than the upstream CLI surface it imitates.

None of these three keys exist in `CTRL` at the pin — they are code defaults
only. That is precisely why the launch args work at all (§2.1).

### 1.4 Other pipeline stages

| Composer stage | Choice | Mechanism | Values |
|---|---|---|---|
| Gait Sequencer | implementation | `gait_sequencer` (`:257`, default `"Simple"`) | `Simple`, `Adaptive` — **no `Bio`, see §4.3** |
| Gait Sequencer | gait (Simple only) | `simple_gait_sequencer.gait` (`:258`, default `"STAND"`) | `STAND`, `STATIC_WALK`, `WALKING_TROT`, `TROT`, `FLYING_TROT`, `PACE`, `BOUND`, `ROTARY_GALLOP`, `TRAVERSE_GALLOP`, `PRONK`, `Manual`/`MANUAL` (`:682-720`) |
| Gait Sequencer | manual gait params | `simple_gait_sequencer.manual_gait.{period,duty_factor,phase_offset}` (`:259-261`) | used only when gait is `Manual` |
| Gait Sequencer | adaptive params | `adaptive_gait_sequencer.gait.*` (`:262-277`) — 16 keys; only `disturbance_correction` appears in `CTRL:53-55` | rest are code defaults |
| WBC | QP solver | `wbc.arc_opt.solver` (`:70`, `CTRL:62`) | `"EiquadprogSolver"` stock |
| WBC | scene | `wbc.arc_opt.scene` (`:71`) | `"AccelerationSceneReducedTSID"` stock; **not in `CTRL`** |
| WBC | control mode | `leg_control_mode` (`CTRL:5`) | `0` = WBC, `3` = inverse kinematics |
| WBC | gains / weights | `wbc.arc_opt.{mu,com_pose_weight,com_pose_Kp,com_pose_Kd,foot_pose_weight,foot_force_weight,feet_pose_Kp,feet_pose_Kd}` (`CTRL:66-76`) | doubles / arrays |
| SLC | swing height, blend | `slc_swing_height`, `slc_world_blend` (`CTRL:21-22`) | single stock implementation |
| Model Adaptation | Off | `use_model_adaptation` (`:59`, default `false`) — **not in `CTRL`** | `false` |
| Model Adaptation | Kalman Filter | `use_model_adaptation: true` + `ma_mode: 0` (`CTRL:38`) | `0` = KF (the `default:` branch, `:559-570`) |
| Model Adaptation | Least Squares | `use_model_adaptation: true` + `ma_mode: 1` | `1` = RLS |
| Contact Logic | Default | inline — **no selection key, see §4.3** | — |
| MPC params | weights, μ, force limits | `mpc_alpha`, `mpc_state_weights_stand`, `mpc_state_weights_move`, `mpc_mu`, `mpc_fmin`, `mpc_fmax`, `mpc_warm_start` (`CTRL:23-31`) | state-weight arrays must be 12 long |

**Model Adaptation is two keys, not one.** `use_model_adaptation` is the on/off
switch and `ma_mode` picks the algorithm; the composer's single three-way
dropdown (Off / KF / LeastSquares) maps onto the pair. `use_model_adaptation`
does not appear in `CTRL`, so "Off" is also the do-nothing default.
Note `ma_mode`'s switch has no error branch — **any value other than `1` selects
the Kalman Filter** (`:559`), so an out-of-range value is silently KF.

### 1.5 Launch-line options

| Composer choice | Mechanism | Notes |
|---|---|---|
| Robot / sim selector | `sim:=go2` | required by all three launch files; `sim:=unitree` is an accepted synonym |
| Safe-start gate | `safe_start:=false` | *presence* of the exact string disables the pre-flight settle check (`mit_controller.launch.py:73`); see `launch.md` §1.2 before exposing it |

The leg driver (`leg_driver_launch.py`) takes `sim:=go2` and nothing else the
composer controls — but it is still one of the three commands, and the stack does
not run without it (`launch.md` §1.1).

---

## 2. How these mechanisms actually behave

Three properties that the generated output in
[#18](https://github.com/alius-git/kennel/issues/18) must respect. Each was
established by running it, not by reading it.

### 2.1 The YAML wins over the launch argument — do not set both

`mit_controller.launch.py` injects the three MPC choices as `-p` overrides
appended to the node's `arguments=` (`:176-177`), while the stage YAML arrives
via `parameters=` (`:174`). **[runtime]** with a key present in both, the
**YAML value is the effective one**:

```console
# YAML said 1.0, '-p simulator_realtime_rate:=999.0' said otherwise
$ ros2 param get /drake_simulator simulator_realtime_rate
Double value is: 1.0
```

The `mpc_solver:=` family works today only because `mpc_solver`,
`mpc_hpipm_mode` and `mpc_condensed_size` are **absent** from the stock `CTRL`.

> **The rule for #18: pick one route per key and never emit both.** A generator
> that helpfully writes `mpc_solver:` into the composed `CTRL` — a natural thing
> to do, since it *is* a node parameter — silently disables the `mpc_solver:=`
> argument in the very same generated command block. The failure is invisible:
> both artifacts look right and the run uses the YAML value.
>
> Recommendation: **route everything through the YAML.** It is the uniform path,
> it wins, and it reaches all six solvers rather than four. Reserve launch args
> for `sim:=` and `safe_start:=`, which have no YAML equivalent.

### 2.2 Launch-argument parsing is positional and fails quietly

All three launch files parse `sys.argv[4:]` by exact string matching. Consequences,
all **[runtime]**-confirmed:

1. **An unrecognised value is silently ignored.** `mpc_solver:=OSQP` — a
   plausible spelling that is not one of the four — falls through the `else` at
   `:107` to an empty argument list. The launch reports nothing, the stack comes
   up, and the node runs the *default* solver. Meanwhile the node itself does
   validate: an unknown value reaching `mpc_solver` exits with
   `Unknown mpc solver` (`:537-539`). So the strict layer is the node and the
   lax layer is the launch file. **The console must emit exactly the canonical
   strings in §1.3.**

2. **Repeating `mpc_condensed_size:=` crashes the launch.** The `len > 1` branch
   prints an error but never assigns the variable (`:116-118`):

   ```
   Error: Launch param "mpc_condensed_size" specified more than once.
   UnboundLocalError: local variable 'mpc_condensed_size_param' referenced before assignment
   ```

3. **The launch file must be invoked in `<package> <file>` form.** Because the
   slice discards the first four argv entries, invoking by path shortens argv and
   every choice vanishes:

   ```console
   $ ros2 launch /root/ros2_ws/install/.../mit_controller.launch.py sim:=go2 safe_start:=false
   Please specify param 'sim' or 'real' and robot. E.g. 'sim:=ulab' or 'real:=go2'.
   ```

   The generated command block must therefore be
   `ros2 launch controllers mit_controller.launch.py …`, never a path.

### 2.3 Config paths are relative — the working directory is part of the contract

`SIM:3` and `SIM:5` hold paths like `src/common/model/urdf/plane.urdf`, resolved
against the **process working directory**. **[runtime]** launched from `/root`
instead of `/root/ros2_ws`:

```
what():  /root/src/common/model/urdf/go2_description.urdf:0: error: Failed to parse XML file: XML_ERROR_FILE_NOT_FOUND
```

`wbc.arc_opt.model_urdf` (`CTRL:63`) is relative in the same way. Every generated
command block must `cd /root/ros2_ws` first — alongside the source chain that
[`launch.md`](launch.md) §2.1 already requires for non-interactive shells.

---

## 3. Runtime controls (not composer choices, but the same contract)

Dashboard-side surfaces, recorded here so the mapping layer has one home. The
gait and velocity mechanisms are established in [`launch.md`](launch.md) §4 and
are only summarised:

| Control | Mechanism |
|---|---|
| Gait | `ros2 param set /mit_controller_node simple_gait_sequencer.gait <GAIT>` — live (`launch.md` §4.1) |
| Velocity target | `/quad_control_target` (`interfaces/msg/QuadControlTarget`), published continuously; `world_z` is mandatory (`launch.md` §4.2) |
| Sim reset | `/reset_sim` (`interfaces/srv/ResetSimulation`) — `drake_simulator.cpp:479` |
| Manual step | `/step_sim` (`interfaces/srv/StepSimulation`) — served **only when `manually_step_sim: true`** (`drake_simulator.cpp:529-530`) |
| Emergency damping | `/set_emergency_damping_mode` (`std_srvs/Trigger`) |
| Disturbance injection | `/disturb_simulation` (`interfaces/srv/DisturbSim`: `force[3]`, `tau[3]`, `time`) — **needs a fourth process, see §4.6** |

`/step_sim` existing is conditional on a *composer* choice — selecting manual
stepping is what creates the service. The two are one contract.

---

## 4. Gaps — mapping-layer bypasses

Every entry is a composer choice from [`plan/prompts.txt`](../plan/prompts.txt)
with no faithful mechanism at the pin. These are the input to
[#28](https://github.com/alius-git/kennel/issues/28).

### 4.1 The Brick map has no working configuration — `mapping-layer bypass`

**[runtime]** `brick.urdf` cannot be used as `world_urdf` at this pin. Both
candidate values of `world_fix_link` abort the simulator before it starts:

| `world_fix_link` | Result |
|---|---|
| `plane_base_link` | `GetBodyByName(): There is no Body named 'plane_base_link' anywhere in the model` |
| `base_link` | `GetBodyByName(): A Body named 'base_link' appears in multiple model instances (go2_description, dfki-quad-brick)` |

`brick.urdf`'s only link is named `base_link`, which collides with the Go2's own
`base_link`; the lookup at `drake_simulator.cpp:61` is unqualified and throws on
the ambiguity. `plane.urdf` and `terrain.urdf` both start cleanly and were used
as the positive control in the same probe.

Independently: `brick.urdf` is a 4.28 kg 0.47×0.18×0.12 m body, **not a ground
plane**. Even with the naming fixed it is an obstacle to be added *alongside* a
world, and the simulator loads exactly one `world_urdf`.

**Bypass:** the map picker offers two cards (Flat plane, Obstacle terrain) for
the MVP. Brick is not a map.
**Retirement:** upstream renaming brick's link (or the simulator qualifying the
lookup by model instance), plus a multi-body world composition mechanism. Both
are upstream changes, not console work.

### 4.2 No `world:=` launch argument — `mapping-layer bypass`

The second gap design.md §5 anticipates, confirmed at the pin.
`simulator.launch.py:9-17` derives its config file from `sim:=` alone and passes
it wholesale (`:27`); there is no argument for the world, and no argument for any
other simulator key either. Terrain choice is a YAML edit, exactly as
[`prompts.txt`](../plan/prompts.txt)'s open-questions section predicted.

**Bypass:** the map picker writes `world_urdf` **and** `world_fix_link` into the
generated `simulator_params_go2.yaml` (§1.1) rather than emitting a launch
argument. This is the generated-config contract, and it is why a map change is a
Tier 2 relaunch (§5) rather than a launch-line edit.
**Retirement:** upstream adding a `world:=` argument — at which point the map
picker moves from the YAML route to the launch line and the rest of the composer
is unaffected. A small upstream change that would simplify the mapping layer
considerably.

### 4.3 Stage implementations the composer names but the pin lacks — `mapping-layer bypass`

The known upstream gap that design.md §5 and
[`prompts.txt`](../plan/prompts.txt) already anticipate (**no explicit stage
`type:` selection keys**, upstream issue #10 / M2.5) is confirmed: stage choice
is expressed through ordinary scattered parameters, never a per-stage `type:`.
Specifically:

| Composer option | Status at the pin |
|---|---|
| Gait Sequencer → **Bio-inspired** | **Does not exist.** `GetGaitSequencerFromParams` accepts `Simple` and `Adaptive` only; anything else logs `Unknown gait sequencer type` and returns `nullptr` (`:786-788`) |
| Contact Logic → selection | Inline, no key — nothing to map (behind an interface only after upstream M3.1) |
| SLC → alternatives | Single implementation; the "dropdown" has one entry |
| WBC → `wbc.solver` (as named in the spec) | The real key is **`wbc.arc_opt.solver`** — the spec's spelling does not exist |

**Bypass:** the composer renders these dropdowns with the options that exist and
marks the rest unavailable rather than generating a key that does nothing.
Failure modes are asymmetric and worth encoding: an unknown `gait_sequencer` at
**startup** shuts the node down (`:516-521`), while the same value set **live**
leaves the running sequencer untouched (`:491-495`).
**Retirement:** upstream M2.5 lands `type:` keys → the mapping layer is replaced,
not the composer state schema. This swap is exactly what scenario s009.repin
rehearses.

### 4.4 The sensor-noise toggles are inert as configured — `mapping-layer bypass`

`imu_noise` and `joint_noise` perturb `/imu_measurement` and `/joint_states`
only. Upstream's own comments at `SIM:28-29` say so:
`ATTENTION: THIS DOES NOT APPEAR IN QUADSTATE MESSAGE`.

With `publish_quad_state: true` the controller consumes ground-truth
`/quad_state` (`launch.md` §3), and the only consumer of the noisy topics —
state estimation — **has no launch path in sim at all** (`launch.md` §3). So in
the MVP configuration both toggles change nothing observable in the control loop.

**Bypass:** surface them coupled to the ground-truth-state choice and label the
dependency, rather than offering them as free-standing knobs that silently do
nothing. Turning noise into something that matters means turning
`publish_quad_state` off, which at this pin means a stack with no state source.
**Retirement:** a sim-side state-estimation launch path upstream.

### 4.5 `manually_step_sim` is a duplicated YAML key — round-trip hazard

It appears twice in the stock `SIM`, at lines 12 and 25, with different comments
and the same value. The loader takes the last. A generator that emits the key
once produces a file that is *semantically* identical and *textually* different
from stock — which matters because round-trip safety is a byte-comparison
contract (design.md §4).

**Bypass:** #18 defines the generated YAML as the canonical form and byte-compares
generated-against-generated, never against the stock upstream file.

### 4.6 Disturbance injection needs a fourth process — `mapping-layer bypass`

design.md §1 locks the disturbance service as the s003/s004 mechanism. It exists
at the pin — `sim_disturber` is built and installed (**[runtime]** present at
`install/simulator/lib/simulator/sim_disturber`) — but **no launch file starts
it**. It must be run as a fourth command:

```bash
ros2 run simulator sim_disturber
```

It serves `/disturb_simulation`, publishes `/simulation_disturbance`, and the
simulator subscribes (`drake_simulator.cpp:356-358`). Two contract details for
the Interventions toolbar: the force is rotated into the robot's yaw frame
before publication, and **the service call blocks for the full `time` duration**
before returning `success` — it sleeps, then zeroes the force
(`disturbance_node.cpp:60-63`). A UI that awaits the response will appear frozen
for the length of the disturbance.

**Bypass:** the launch surface in [`launch.md`](launch.md) is three commands for
walking; disturbance scenarios need a fourth, so the generated command block is
conditional on the composer enabling disturbances.
**Retirement:** upstream adding `sim_disturber` to `simulator.launch.py`.

**Done within the MVP** ([#68](https://github.com/alius-git/kennel/issues/68),
2026-09-08). The composer has a `disturbances` toggle; with it on, `commands.txt`
carries a fourth block and `run.json` an eighth choice, and
`p21-launch-from-commands.sh` starts that block last and waits for **two**
signals — `/disturbance_node` in the graph and `/disturb_simulation` served. The
upstream retirement above is unchanged: the pin still ships no launch file for
it. Two things the live measurement added to this section:

- **The node is `disturbance_node`**, not `sim_disturber`. The executable's name
  is the CMake target; the graph name is the one the constructor gives it
  (`disturbance_node.cpp:16`). `kennel-verify.sh` tolerates that name under
  `KENNEL_EXPECT_DISTURBER=1`.
- **`time` is a WALL second unless the node is told otherwise.** Measured at
  `simulator_realtime_rate: 0.5`: a 0.2 s request lasts **0.100 sim-s / 0.200
  wall** as a bare `ros2 run`, and **0.200 sim-s / 0.399 wall** with
  `--ros-args -p use_sim_time:=true`. The composed block carries the argument, so
  a push is a sim-second like every other window in this repo
  ([`kennel_console/teleop.md`](../kennel_console/teleop.md) §13).

---

## 5. Change latency

What a composer edit costs. Provisioning builds with `colcon build
--symlink-install` ([`vm/provisioning.md`](../vm/provisioning.md) line 75), and **[runtime]** the
installed configs are symlinks straight back into the source tree:

```console
$ ls -la install/simulator/share/simulator/config/
simulator_params_go2.yaml -> /root/ros2_ws/src/simulator/config/simulator_params_go2.yaml
```

**So no YAML edit ever requires `colcon build`.** The three tiers:

### Tier 1 — Live (`ros2 param set`, no relaunch)

Only parameters handled in the node's parameter-event callback
(`mit_controller_node.cpp:308-476`) take effect; every other name logs
`Changing parameter <name> is not yet suported` *(upstream's spelling)* and is
accepted-but-ignored. **A live set that reports success is not evidence it took
effect** — the console must treat this list as closed:

- everything matching `*gait*` — `gait_sequencer`, `simple_gait_sequencer.*`
  (rebuilds the sequencer), `adaptive_gait_sequencer.gait.*` (individual setters)
- `mpc_state_weights_stand`, `mpc_state_weights_move`, `mpc_alpha`, `mpc_mu`,
  `mpc_fmax`
- `cartesian_joint_control_gains.*`, `cartesian_stiffness_control_gains.*`
- `early_contact_detection`, `late_contact_detection`, `lost_contact_detection`,
  `late_contact_reschedule_swing_phase`, `use_model_adaptation`
- `slc_swing_height`, `slc_world_blend`,
  `maximum_swing_leg_progress_to_update_target`
- `wbc.inverse_dynamics.*` (guarded — no-ops unless `leg_control_mode: 3`)
- `raibert.k`, `raibert.z_on_plane`

Note the asymmetries: `mpc_fmax` and `mpc_mu` are live but **`mpc_fmin` is not**;
`use_model_adaptation` is live but **`ma_mode` is not**. Vector-valued sets are
also validated for length and rejected outright on mismatch (`:281-303`).

### Tier 2 — Relaunch, no rebuild (YAML edit)

Everything else in `SIM` and `CTRL`. Edit the file, restart the affected
component only: the whole of `SIM` needs the simulator restarted; `CTRL`
non-live keys need the controller restarted. Notably here: `mpc_solver`,
`mpc_hpipm_mode`, `mpc_condensed_size`, `mpc_fmin`, `mpc_warm_start`,
`leg_control_mode`, `ma_mode`, all `wbc.arc_opt.*`, `initial_height`,
`gs_shoulder_positions`, `fix_standing_position`.

### Tier 3 — Launch line (per invocation, no file touched)

`sim:=`, `safe_start:=`, and — subject to §2.1 — the three `mpc_*` args.

---

## 6. How this was verified

Sources were read **at the pin**, never from a working tree:

```bash
git -C dfki-quad show dcf53c596339afd45b82f12c54b1e93e8273c2f4:<path>
```

Files inspected: `ws/src/simulator/{launch/simulator.launch.py,
config/simulator_params_go2.yaml, src/drake_simulator.cpp,
src/disturbance_node.cpp, CMakeLists.txt}`,
`ws/src/controllers/{launch/mit_controller.launch.py,
config/mit_controller_sim_go2.yaml, src/mit_controller_node.cpp,
include/mit_controller/mit_controller_params.hpp}`,
`ws/src/drivers/launch/leg_driver_launch.py`,
`ws/src/common/model/urdf/{plane,terrain,brick}.urdf`,
`ws/src/common/model/urdf/go2/urdf/go2_description.urdf`,
`ws/src/interfaces/srv/DisturbSim.srv`.

The **[runtime]** claims were executed on 2026-08-05 in the `dfki_quad` container
on `kennel-vm` (guest clone confirmed at the pin), following the source chain in
[`launch.md`](launch.md) §2:

| Claim | Probe |
|---|---|
| §4.1 Brick unusable | ran `simulator` against all four world/fix-link pairs; plane + terrain alive past 25 s, both brick pairs aborted |
| §2.1 YAML beats `-p` | launch file mimicking `mit_controller.launch.py`'s `parameters=` + `arguments=` shape, then `ros2 param get` |
| §2.2 silent ignore | `mpc_solver:=OSQP` — stack launched, no solver complaint |
| §2.2 duplicate arg | `mpc_condensed_size:=5 mpc_condensed_size:=6` → `UnboundLocalError` |
| §2.2 invocation form | launch by absolute path → `Please specify param 'sim' or 'real'` |
| §2.3 relative paths | launched from `/root` → `XML_ERROR_FILE_NOT_FOUND` |
| §5 symlink-install | `ls -la` on the installed config directories |
| §4.5 `sim_disturber` | present in `install/simulator/lib/simulator/` |

One incidental observation, recorded because the generated command block will
show it and it looks alarming: `mit_controller.launch.py` also starts
`log_cpu_power`, which cannot read RAPL inside the container, logs
`Could not open energy_uj file`, and **exits cleanly**. That is why the healthy
session in [`launch.md`](launch.md) §6 lists six nodes and not seven — the
behaviour is expected, and the evidence is in
[`known-good/01-launch-ctrl.log`](known-good/01-launch-ctrl.log) lines 106-107.
