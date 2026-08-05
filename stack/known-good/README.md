# Known-good log — go2 sim stack, healthy session

A single clean run of the canonical command set from
[`stack/launch.md`](../launch.md), captured as the reference for
[issue #14](https://github.com/alius-git/kennel/issues/14) (CLI walking/health
verification) per work item 4 of
[issue #13](https://github.com/alius-git/kennel/issues/13).

## Provenance

| | |
|---|---|
| Stack pin | `dcf53c596339afd45b82f12c54b1e93e8273c2f4` ([`stack/pin.lock`](../pin.lock)) |
| Captured | 2026-08-05 |
| Where | `dfki_quad` container in guest `kennel-vm` (8 vCPU / 16 GiB), over SSH |
| How | [`tools/k13-capture.sh`](tools/) — three components launched detached, headless, no X, no gamepad |
| Commands | `simulator.launch.py sim:=go2` · `leg_driver_launch.py sim:=go2` · `mit_controller.launch.py sim:=go2` |

Wall-clock timestamps inside the guest are subject to the host-clock defect
recorded in [`vm/provisioning.md`](../../vm/provisioning.md) §6a — treat guest
wall-clock as unreliable. Every number below is derived from **simulation** time
or from message counts, so none of it depends on the guest clock.

## Files

| File | What it is |
|------|-----------|
| `01-launch-sim.log` | Simulator launch output — Drake model load, Meshcat URL, joint table |
| `01-launch-legdrv.log` | Leg driver launch — ends at `Switch to OPERATE`, the ready signal |
| `01-launch-ctrl.log` | Controller launch — `safe_start` result, solver dimensions, `Starting controller` |
| `02-stand-baseline.csv` | 10 s standing, gait `STAND`, no target published |
| `03-gait-set.txt` | The gait parameter set, and its `Set parameter successful` |
| `04-trot-in-place.csv` | 15 s of `WALKING_TROT` with no velocity target |
| `05-forward-trot.csv` | 60 s of forward trot at `body_x_dot: 0.3` — **the acceptance run** |
| `06-healthy-graph.txt` | Node list, topic list, rates, `/controller_heartbeat`, gait params |
| `tools/` | The scripts that produced all of the above |

CSV columns: `t_sim,x,y,z,vx,vy,vz,quat_w,foot_contact,belly,n_state,n_gait,n_hb`
— pose and twist from `/quad_state`, `foot_contact` as a 4-bit string in
FL/FR/BL/BR order, `belly` = `belly_contact` (1 = fallen), and running message
counts for `/quad_state`, `/gait_state`, `/controller_heartbeat`.

## The healthy numbers

| Phase | Height | Velocity | Result |
|-------|--------|----------|--------|
| Stand | 0.3138 m | 0.000 m/s | held 10 s, `foot_contact` `1111` |
| Trot in place | 0.3195 m | −0.017 m/s | −0.001 m drift over 15 s |
| Forward trot | 0.3154 m | 0.268 m/s | **16.5 m in 60 s** |

Commanded 0.3 m/s, tracked 0.268 m/s within a 0.267–0.271 band — steady, no
drift or saturation. `foot_contact` alternates `1001` / `0110`: the diagonal
pairs of a trot. `belly_contact` false in every sample of every phase.

Rates under load: `/quad_state` 1000 Hz, `/joint_cmd` 1000 Hz, `/gait_state`
100 Hz, `/controller_heartbeat` 2 Hz. Achieved realtime rate ≈ 1.0 against the
`simulator_realtime_rate: 1.0` target.

Health counters during the trot — the two that matter are the fails:

```
num_mpc_solver_fail: 0
num_wbc_solver_fail: 0
num_mpc_solver_overtime: 0
num_wbc_overtime: 2      # small counts benign
num_early_contacts: 10   # nonzero normal, early_contact_detection is on
```

Exactly six nodes, no duplicates:
`/drake_simulator`, `/leg_driver`, `/mit_controller_node`, `/joy_linux_node`,
`/joy_to_target`, `/safe_start_launcher`.

## Reading this as a reference

Suggested "healthy and walking" signals for #14, cheapest first:

1. `QuadState.belly_contact` is false — did not fall.
2. `num_mpc_solver_fail` and `num_wbc_solver_fail` stay 0.
3. `/controller_heartbeat` arrives at ~2 Hz — the controller is alive at all.
4. `/quad_state` z stays near 0.30–0.32 m — standing, not collapsed.
5. Body x advances monotonically while a forward target is published — walking,
   not just cycling its feet in place.
6. Node list matches the six above — nothing crashed, nothing duplicated.

Regenerate with the recipe in [`stack/launch.md`](../launch.md) §8.
