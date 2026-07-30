# Kennel Verification Scenarios

**Companion documents:** [personas.md](personas.md) — the actors in these sequences · [applications.md](applications.md) — the applications and shared foundations they traverse · [design.md](design.md) — the POC design that implements them, with one sequence diagram per scenario under [design/](design/).

This document is the functional blueprint for the end-to-end automated system demo, executed on the **Yuruna** verification framework. Yuruna asserts that resources are configured to verify components against anticipated workloads; each scenario below is one discoverable test **sequence**, written in structured natural language — the narrative contract a Yuruna sequence implements, not the script itself.

**Conventions**

- **Actors** are the personas defined in [personas.md](personas.md); **applications** and **shared foundations** are as defined in [applications.md](applications.md).
- **Execution environment.** Sequences span the host machine (browser, hypervisor, test runner) and the Kennel VM. Scenarios describe the end-to-end user and system journey only; harness mechanics (VM provisioning, UI automation limits) are design.md's concern, not this document's.
- **Priorities.** `P0` — the five-minute promise and the compose→run→diagnose loop; nothing else matters if these fail. `P1` — the researcher workflow in depth, the mock/live seam, and the classroom. `P2` — lifecycle capstones that consume what the rest produce. Scenarios are ordered by rank; within a rank, by dependency.
- **Target Verification Point.** The desired state Yuruna must assert to declare the sequence successful. Every assertion names observable state — files on disk, console UI state, topic traffic, manifest contents, elapsed time — never internal implementation detail.

---

## s001.firstwalk: Cold Import to Walking Go2 Inside the Time Budget

**Objective & Priority.** Validate the product's non-negotiable promise: a newcomer imports the appliance and reaches a walking, simulated Go2 in about five minutes, following only the first-run checklist. **Priority: P0, ranked first** — this is the PRFAQ's whole argument; if the first session is not the product, Kennel has no product.

**Cross-Refs:** *Personas:* Sofia (Elif's release implicitly) · *Applications:* Kennel/appliance, Kennel/guides, Kennel/stack, Kennel/console · *Foundations:* Version Manifest · *Sequence diagram:* [seq.s001.firstwalk](design/seq.s001.firstwalk.md)

**Step-by-Step Sequence**

1. The harness starts from a clean host: no prior Kennel VM, only the released appliance image and its published checksum.
2. Sofia imports the appliance into the hypervisor and starts it → first boot lands at the first-run checklist; the version manifest is readable and matches the release.
3. The timer starts at first boot. Sofia follows the checklist steps in order, adding nothing: open the console from the host browser, copy the three generated launch commands (simulator, controller, state estimation) into the VM terminal, run them.
4. The console status bar transitions to connected; the dashboard's empty states disappear panel by panel as topics come alive.
5. The stock preset brings the simulated Go2 to standing, then walking (trot) on the flat plane; commanded velocity is reflected in actual velocity on the state plots.
6. Sofia sends a velocity command and a gait change from the interventions toolbar → the robot responds; the gait timeline shows the new pattern.
7. The timer stops when the robot has walked continuously for 10 s under a user-issued command. Elapsed time is recorded.
8. Sofia has consulted nothing but the checklist: the harness records that every executed command string came from the checklist or the console's generated block.

**Target Verification Point.** Desired state: elapsed time from first boot to sustained commanded walking is within the budget (target ≈ 5 minutes; hard ceiling 10 on the reference host); the checklist was sufficient (zero commands executed from outside it); the console status bar shows connected with a live heartbeat; the imported image's checksum and the in-VM version manifest match the release record; and no error state is present in any dashboard panel at timer stop.

---

## s002.compose: Experiment Composition, Generation, and Config Round-Trip

**Objective & Priority.** Validate the experiment builder end to end: map + pipeline + parameter composition, generation of the exact configs and launch commands, a run launched from them, and the round-trip guarantee — a generated config loads back into an identical composer state. **Priority: P0, ranked second** — reproducible composition is the researcher's core loop; without it the console is a viewer, not a lab.

**Cross-Refs:** *Personas:* Alex · *Applications:* Kennel/console, Kennel/stack · *Foundations:* Run Manifests & Config Schema, Version Manifest · *Sequence diagram:* [seq.s002.compose](design/seq.s002.compose.md)

**Step-by-Step Sequence**

1. Alex opens Compose on a connected appliance and selects the obstacle terrain map, adjusting one sim option (real-time rate) from its default.
2. In the pipeline composer, Alex selects the Adaptive gait sequencer and switches the MPC solver from the stock choice to an alternative, modifying two MPC parameters in the drawer → both fields show "modified" badges; the raw-YAML tab reflects the same values.
3. Alex saves the composition as a named preset, then triggers Generate run → the two stack config YAMLs and the three-command launch block are produced, and a run manifest is written capturing map, stage choices, parameters, sim options, and the version-manifest reference.
4. Alex runs the three commands in the VM terminal → the stack launches with the composed configuration; the dashboard's pipeline health strip shows the selected implementations on the blocks.
5. The robot walks on the terrain; Alex stops the run → the manifest is finalized with duration and verdict `completed`.
6. Alex resets the composer to defaults, then loads the generated config back → the composer reproduces the exact prior state: same map, same stage selections, same two modified parameters with badges, same sim options.
7. Alex loads the named preset → identical result by the same comparison.

**Target Verification Point.** Desired state: the generated YAMLs contain exactly the composed values (assert the two modified parameters and the solver selection appear with their set values); the run manifest references the current version manifest and records the full composition; the launched stack's live diagnostics identify the selected solver/stages; and the round-trip comparison — composer state serialized before generation vs. after re-load, and vs. preset load — is byte-identical.

---

## s003.diagnose: Live Degradation, Fall, and Post-Mortem Diagnosis

**Objective & Priority.** Validate the dashboard as a diagnosis instrument: a healthy walk visibly degrades, the console narrates the degradation in plain language as it happens, the fall is detected, and the post-mortem holds the evidence. **Priority: P0, ranked third** — "what is happening and why, in real time" is the console's stated purpose; a dashboard that cannot explain a fall is decoration.

**Cross-Refs:** *Personas:* Alex · *Applications:* Kennel/console, Kennel/stack · *Foundations:* DataSource / Bridge Contract · *Sequence diagram:* [seq.s003.diagnose](design/seq.s003.diagnose.md)

**Step-by-Step Sequence**

1. A run is live and healthy: all pipeline blocks green, gait timeline showing planned and actual contacts aligned, counters flat.
2. The harness induces controller stress (a demanding terrain segment or tightened solver constraints per design.md's fault-injection choice) → MPC solve times climb toward the 10 ms deadline.
3. The MPC block transitions green → amber; the event feed logs the first deadline violation with its measured solve time and iteration count; the overtime counter's sparkline shows a rising rate and the block flashes on each increment.
4. Contact mismatches appear: the gait timeline highlights an early touchdown in amber; the event feed logs it with leg and timing offset.
5. Degradation continues → the robot falls; fall detection triggers on belly contact or attitude/height thresholds.
6. The dashboard raises the red fall banner; the event feed pins the last five seconds of events for post-mortem reading; the run verdict is recorded as `fell`.
7. Alex reads the pinned post-mortem: it contains, in order, the deadline violations, the contact mismatches, and the fall event with its trigger values.
8. Alex resets the simulation from the interventions toolbar → the stack returns to standing; the dashboard clears to healthy; the fallen run's manifest and verdict persist in the Runs view.

**Target Verification Point.** Desired state: every induced signal produced its diagnosis — the event feed contains deadline-violation entries with measured values, at least one contact-mismatch entry with leg and offset, and a fall entry with trigger condition; the pinned post-mortem window covers the five seconds preceding the fall timestamp; the pipeline block tint history follows green → amber → red in step with the counters; and the Runs table shows the run with verdict `fell` and its headline counters.

---

## s004.disturb: Interventions — Commands, Disturbance Injection, and Recovery

**Objective & Priority.** Validate the interventions surface as sim-level interaction, never process control: velocity and gait commands, a disturbance the controller rejects, a disturbance that topples it, sim reset, and manual stepping. **Priority: P1, ranked fourth** — perturb-and-observe is how a controller is actually studied; it is also where the configure+monitor boundary is most tempted.

**Cross-Refs:** *Personas:* Alex · *Applications:* Kennel/console, Kennel/stack · *Foundations:* DataSource / Bridge Contract · *Sequence diagram:* [seq.s004.disturb](design/seq.s004.disturb.md)

**Step-by-Step Sequence**

1. A stock run walks on the flat plane. Alex commands a velocity change via the joystick widget → commanded vs. actual velocity plots converge to the new target.
2. Alex injects a moderate push (force vector, magnitude, duration) via the disturbance service → the robot staggers and recovers; the event feed logs the disturbance and the recovery; the gait timeline shows the transient contact irregularity.
3. Alex injects a severe push → the robot falls; the fall banner and post-mortem behave as in s003.diagnose, with the disturbance event visible in the pinned window immediately before the fall.
4. Alex resets the sim from the toolbar → standing posture restored, plots and counters cleared, previous run's record preserved.
5. Alex enables manual stepping mode and single-steps the simulation → the 3D scene and plots advance in discrete increments matching the step count; real-time factor reads accordingly.
6. Throughout, the harness monitors the VM's process table: the set of stack processes is identical before, during, and after every intervention — the console called services and published topics, and never started or stopped a process.

**Target Verification Point.** Desired state: each intervention corresponds to a recorded service call or topic publish and its observable effect (velocity convergence, logged disturbance with the exact injected parameters, fall after the severe push, restored posture after reset, N scene-advances for N single-steps); the disturbance event appears in the post-mortem window of the induced fall; and the stack's process set observed from the VM is unchanged by any console action.

---

## s005.compare: Solver Benchmark and Run Comparison

**Objective & Priority.** Validate the record-keeping loop: two runs differing in exactly one composed choice, honestly badged verdicts, and a config diff that isolates the one difference. **Priority: P1, ranked fifth** — comparison is what turns runs into findings; the Runs view is the researcher's lab notebook.

**Cross-Refs:** *Personas:* Alex · *Applications:* Kennel/console, Kennel/stack · *Foundations:* Run Manifests & Config Schema · *Sequence diagram:* [seq.s005.compare](design/seq.s005.compare.md)

**Step-by-Step Sequence**

1. Alex composes the "Solver benchmark" preset on the obstacle terrain with solver A, generates, launches, and completes a fixed-duration run → manifest recorded, verdict `completed`, headline counters captured (overtime counts, failure counts).
2. Alex duplicates the preset, changes only the MPC solver to B, and repeats the identical run → second manifest recorded with its own verdict and counters.
3. The harness seeds a third, deliberately failing run (a solver configuration that cannot hold the deadline) → verdict `solver-failed` with its counters.
4. Alex opens the Runs view → all three runs are listed with map, stage summary, duration, verdict badges, and headline counters.
5. Alex selects runs A and B → the side-by-side config diff shows exactly one difference: the MPC solver choice (and its dependent solver-specific fields), with everything else identical.
6. Alex selects run A and the failed run → the diff isolates the failing configuration delta.

**Target Verification Point.** Desired state: three manifests exist with verdicts `completed`, `completed`, `solver-failed`, each with counters consistent with its run's event feed; the A/B diff contains the solver field (plus its dependent fields) and nothing else; both compared manifests reference the same version manifest; and the Runs table's headline counters equal the values in each manifest.

---

## s006.reproduce: Same Manifest, Same Experiment

**Objective & Priority.** Validate the reproducibility contract: a run manifest alone reconstructs the experiment — same composer state, same generated configs, comparable outcome — on the same appliance release. **Priority: P1, ranked sixth** — this is what makes a Kennel result citable and what the hardware handoff (s010.handoff) will lean on.

**Cross-Refs:** *Personas:* Alex, Elif · *Applications:* Kennel/console, Kennel/stack, Kennel/appliance · *Foundations:* Run Manifests & Config Schema, Version Manifest · *Sequence diagram:* [seq.s006.reproduce](design/seq.s006.reproduce.md)

**Step-by-Step Sequence**

1. Alex completes a composed run (from s002.compose or fresh) → manifest M1 exists with configs C1 and verdict `completed`.
2. On a freshly reset appliance of the same release (Elif's baseline; reset per Kennel/appliance), Alex loads manifest M1 into the console → the composer reproduces the full state; regeneration produces configs C2.
3. The harness compares C1 and C2 → byte-identical.
4. Alex launches the regenerated run and completes the same fixed-duration profile → manifest M2 with verdict and counters.
5. The harness compares outcomes: verdicts match; headline counters agree within the tolerance design.md sets for simulation nondeterminism; both manifests reference the same version manifest.
6. As a negative control, the harness loads M1 on an appliance whose environment has been deliberately drifted (a modified stack file) → the drift check reports the deviation, and the console surfaces that the environment does not match the manifest's version reference.

**Target Verification Point.** Desired state: C1 = C2 byte-for-byte; M1 and M2 carry the same version-manifest reference and matching verdicts, with counter deltas inside the declared tolerance; and on the drifted appliance the drift check names the modified component while the reproduction is flagged, not silently run.

---

## s007.bridge: The DataSource Seam — Scripted Demo and Live Swap

**Objective & Priority.** Validate the ecosystem's mock boundary: the full dashboard runs a scripted demo with no stack at all, every panel demonstrating its purpose; swapping to the live bridge changes behavior of nothing but the data; silent topics degrade to empty states naming the missing command. **Priority: P1, ranked seventh** — the seam is what makes demo mode, UI development, and the live lab one application; if it leaks, every earlier scenario's UI evidence is suspect.

**Cross-Refs:** *Personas:* Devon, Alex · *Applications:* Kennel/console · *Foundations:* DataSource / Bridge Contract · *Sequence diagram:* [seq.s007.bridge](design/seq.s007.bridge.md)

**Step-by-Step Sequence**

1. Devon opens the console in mock mode with no VM stack running → the seeded demo plays: ~30 s of stable trot, degrading MPC solve times, then a fall.
2. Every dashboard panel exercises its purpose during the demo: health strip transitions, gait timeline with an induced mismatch, sparkline uptick, state plots, event feed narration, fall banner with pinned post-mortem.
3. The status bar identifies the session as mock/demo — the scripted run is never presentable as live data.
4. Devon switches the data source to the live bridge with the stack down → connection state shows disconnected; every panel presents its empty state naming the specific launch command that would feed it.
5. Alex launches the stack in the VM → panels come alive one by one as their topics appear, with no reload and no panel behaving differently than it did on mock data.
6. The harness compares panel inventory and behavior contracts across the two sources: same panels, same interactions, same event-feed grammar — only the data differs.
7. The harness verifies throttling on the live source: plot update rates stay at or below the design ceiling while windowed statistics remain computed from full-rate data.

**Target Verification Point.** Desired state: the mock demo drives every panel through its demonstrative states without any stack process existing; mode is always visibly labeled; in live-disconnected state every panel's empty state names a launch command; after launch, live panels populate without reload; the panel/interaction inventory is identical between sources; and observed plot update rates on the live source respect the throttling ceiling.

---

## s008.classroom: Fleet Cold Start, Drift, and Reset

**Objective & Priority.** Validate the classroom deployment: multiple seats from one image behave identically, a drifted seat is detected and restored, and the instructor's between-cohort reset holds. **Priority: P1, ranked eighth** — the classroom is the PRFAQ's 12-month adoption metric and the appliance's uniformity promise under real load.

**Cross-Refs:** *Personas:* Marcus, Sofia, Elif · *Applications:* Kennel/appliance, Kennel/guides · *Foundations:* Version Manifest · *Sequence diagram:* [seq.s008.classroom](design/seq.s008.classroom.md)

**Step-by-Step Sequence**

1. From Elif's release image, the harness provisions N seats (design.md fixes N ≥ 2 for the POC) on the host.
2. Marcus verifies each seat: image checksum matches the release; in-VM version manifest identical across seats.
3. Each seat runs the s001.firstwalk checklist (Sofia's flow) → every seat reaches sustained walking inside the same time budget.
4. The harness dirties one seat: modifies a stack file and installs a stray package → the drift check on that seat reports both deviations; clean seats report none.
5. Marcus resets the dirty seat to baseline → the drift check comes back clean; a student-kept run manifest placed in the designated workspace area before reset survives it.
6. The reset seat re-runs the first-walk checklist → same outcome, same budget.
7. Marcus performs the between-cohort routine on all seats: reset all, verify all manifests → the fleet is uniform again by the same assertions as step 2.

**Target Verification Point.** Desired state: all N seats share one image checksum and byte-identical version manifests; every seat (including the reset one) completes first-walk inside the budget; the drift check's report on the dirtied seat names exactly the two injected deviations and nothing on clean seats; and the designated-workspace artifact survives reset while system state returns to baseline.

---

## s009.repin: Upstream Update, Repin, and Regression Gate

**Objective & Priority.** Validate the upstream relationship as a routine operation: a new upstream revision becomes a new pin, the appliance rebuilds, the scenario suite gates the release, and the mapping layer absorbs a contract change without UI changes. **Priority: P2, ranked ninth** — it consumes the suite the earlier scenarios established; it is how Kennel survives the research stack evolving.

**Cross-Refs:** *Personas:* Theo, Elif · *Applications:* Kennel/stack, Kennel/appliance, Kennel/console · *Foundations:* Version Manifest, Run Manifests & Config Schema · *Sequence diagram:* [seq.s009.repin](design/seq.s009.repin.md)

**Step-by-Step Sequence**

1. The harness stages an "upstream update": a new revision of the stack including one contract-relevant change (per design.md's chosen simulation of the known upstream gap closing — e.g., a stage selection key appearing where a launch arg was used).
2. Theo updates the pin and the mapping-layer notes: the affected composer choice now binds to the new mechanism; the UI itself is untouched.
3. Elif rebuilds the appliance image from the new pin → a new version manifest is generated, differing from the previous one in exactly the changed components.
4. The regression gate runs: the P0 scenarios (s001.firstwalk, s002.compose, s003.diagnose) execute against the candidate image.
5. s002.compose's assertions confirm the mapping change: the same composer choice now lands in the new config mechanism, and round-trip still holds.
6. The gate passes → the candidate is recorded as releasable; its manifest supersedes the old one. A run manifest from the previous release, loaded on the new image, is flagged with the version-manifest mismatch (as in s006.reproduce) rather than silently reproduced.
7. As a negative control, the harness stages a breaking upstream change and repeats → the gate fails on a named scenario, and the candidate is recorded as not releasable.

**Target Verification Point.** Desired state: the new version manifest differs from the old in exactly the repinned components; the P0 gate passes on the good candidate and fails with a named failing scenario on the broken one; the composer choice affected by the contract change produces correct configs under the new pin with round-trip intact and zero UI-code change (assert: console version identical across the repin); and cross-release manifest loads are flagged, never silent.

---

## s010.handoff: The Safety-Gated Path Toward Hardware

**Objective & Priority.** Validate Kennel's honesty at its boundary: hardware material is reachable only through the completed, recorded simulation-first checklist; the transfer package carries the validated configs and their evidence; and nothing in the flow claims what the VM cannot promise. **Priority: P2, ranked last by dependency, first by consequence** — it consumes validated runs from the whole suite, and it is the PRFAQ's named risk mitigation made mechanical.

**Cross-Refs:** *Personas:* Noa, Alex · *Applications:* Kennel/guides, Kennel/console · *Foundations:* The Safety Gate, Run Manifests & Config Schema, Version Manifest · *Sequence diagram:* [seq.s010.handoff](design/seq.s010.handoff.md)

**Step-by-Step Sequence**

1. Noa opens the hardware notes without a completed safety gate → the guides present the gate first: the hardware material is structurally behind checklist completion, not merely prefaced by a warning.
2. Noa works the checklist: it requires, among its items, evidence of validated simulation runs — concretely, completed run manifests covering the configuration intended for transfer (drawn from s002–s006 artifacts, including at least one disturbance-recovery run).
3. An attempt to attach an insufficient record (a run with verdict `fell`, or a manifest from a drifted environment) → the gate rejects the item with the stated reason.
4. Noa attaches qualifying manifests and completes the remaining checklist items → gate completion is recorded with a timestamp and the attached evidence list.
5. The transfer package is produced: the validated configs, their run manifests, the version manifest of the validating release, and the completed checklist record.
6. The hardware notes are now presented: they address a dedicated robot computer, and the harness scans the full guide path for scope honesty — no instruction runs robot control from inside the VM, and the VM's non-claims (no hard real-time, no production control) are stated on the path.
7. The package is inspected: it is self-describing — a reader can determine what was validated, on which release, with which evidence, without access to the originating VM.

**Target Verification Point.** Desired state: hardware material is unreachable before gate completion (assert the structural ordering, not a warning banner); the gate's rejection log shows the insufficient-evidence attempts with reasons; the completion record lists the attached manifests, each with verdict `completed` and a version-manifest match; the transfer package contains configs + manifests + version manifest + checklist record and nothing environment-dependent; and the guide-path scan finds zero instructions executing robot control from the VM.

---

## Traceability Assurance

Every persona, application, and shared foundation is exercised by at least one core sequence. No orphan components, no unverified workflows.

### Personas × Scenarios

| Persona | Exercised in |
|---------|--------------|
| Alex — Controls Researcher | s002.compose, s003.diagnose, s004.disturb, s005.compare, s006.reproduce, s007.bridge, s010.handoff |
| Sofia — New Lab Member | s001.firstwalk, s008.classroom |
| Marcus — Course Instructor | s008.classroom |
| Elif — Appliance Steward | s006.reproduce, s008.classroom, s009.repin (release artifacts gate s001.firstwalk) |
| Devon — Demo Presenter | s007.bridge |
| Noa — Hardware-Transition Engineer | s010.handoff |
| Theo — Upstream Stack Maintainer | s009.repin |

### Applications × Scenarios

| Application | Exercised in |
|-------------|--------------|
| Kennel/appliance | s001.firstwalk, s006.reproduce, s008.classroom, s009.repin |
| Kennel/console | s001.firstwalk, s002.compose, s003.diagnose, s004.disturb, s005.compare, s006.reproduce, s007.bridge, s009.repin, s010.handoff |
| Kennel/stack | s001.firstwalk, s002.compose, s003.diagnose, s004.disturb, s005.compare, s006.reproduce, s009.repin |
| Kennel/guides | s001.firstwalk, s008.classroom, s010.handoff |

### Shared Foundations × Scenarios

| Foundation | Exercised in |
|------------|--------------|
| Version Manifest | s001.firstwalk, s002.compose, s005.compare, s006.reproduce, s008.classroom, s009.repin, s010.handoff |
| DataSource / Bridge Contract | s003.diagnose, s004.disturb, s007.bridge |
| Run Manifests & Config Schema | s002.compose, s005.compare, s006.reproduce, s009.repin, s010.handoff |
| The Safety Gate | s010.handoff |

**Coverage statement.** All 7 personas, all 4 applications, and all 4 shared foundations appear in at least one sequence; the three P0 sequences alone encode the PRFAQ's non-negotiable experience (import to walking in ~5 minutes) and the console's core purpose (compose, run, diagnose); and the PRFAQ's three named risks each have a mechanical assertion — hardware overclaiming (s010.handoff), skipping simulation (s010.handoff's structural gate), and environment drift (s006.reproduce, s008.classroom, s009.repin).
