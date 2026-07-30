# Kennel Application Ecosystem

**Companion documents:** [personas.md](personas.md) — the people these applications serve · [scenarios.md](scenarios.md) — the end-to-end verification sequences that exercise them · [PRFAQ.txt](PRFAQ.txt) — the product vision · [prompts.txt](prompts.txt) — the Kennel Console specification.

Kennel is a ready-to-use virtual lab for testing a Go2 quadruped walking controller: a portable VM appliance carrying a pinned simulation stack, fronted by **Kennel Console** — a browser control room that composes experiments, generates their configs and launch commands, and diagnoses the running simulation in real time. The product is the first successful test session, delivered in about five minutes instead of a lost week.

This document defines each application required to run that ecosystem: its business objective, its core user-facing functionality, and the architectural paradigms suited to the job. It names the *shape* of each system; the only concrete technology choices repeated here are the ones the console specification already locks.

---

## Design Principles

Every application below inherits six commitments, all traceable to the PRFAQ:

1. **The first successful session is the product.** A cold start must reach a walking, simulated Go2 in about five minutes after the appliance is imported. Anything that lengthens that path is a regression, whatever else it improves.
2. **Simulation first; hardware behind the safety gate.** Kennel makes no real-robot or real-time claims from inside the VM. Hardware notes exist, but only past a completed simulation-first checklist — the sequence is the safety model.
3. **Reproducibility by pinning.** The appliance is an immutable, versioned image; every dependency is recorded in a version manifest, every experiment in a run manifest. Drift is detectable and reversible, never silent.
4. **Configure and monitor, never orchestrate.** The console generates configs and launch commands and observes the running stack over a bridge. It never spawns or kills processes; the user's terminal stays the place where things are run, deliberately.
5. **Upstream is the source of truth.** The dfki-quad research stack is pinned and wrapped, never forked. Known upstream gaps are bridged by a swappable mapping layer that is designed to be deleted.
6. **Resettable and uniform by construction.** Every seat built from the same image behaves the same; any seat returns to baseline without expertise. The classroom is a first-class deployment, not a stretch goal.

---

## Ecosystem at a Glance

| Application | Primary personas | One-line objective |
|-------------|------------------|--------------------|
| Kennel/appliance | Marcus, Elif (Sofia resets it) | Deliver the entire lab as one importable, pinned, resettable VM |
| Kennel/console | Alex, Devon (Sofia on defaults) | Compose experiments, generate runs, and diagnose them live in the browser |
| Kennel/stack | Theo (Alex launches it) | Wrap the pinned upstream controller + simulator as the lab's engine |
| Kennel/guides | Sofia, Noa (Marcus teaches from it) | Walk every user from import to first walk — and gate the path to hardware |

Beneath the applications sit four **shared foundations** — the version manifest, the DataSource/bridge contract, run manifests & config schema, and the safety gate — defined [at the end](#shared-foundations).

---

## Kennel/appliance

**Business objective.** Eliminate the setup tax. Deliver the whole lab — OS, ROS 2, Drake, the pinned controller stack, the console, the guides — as a single portable VM that imports on a standard lab or personal computer and behaves identically on every one of them. The appliance is what makes "the first session is the product" physically true, and what makes a classroom of identical seats possible.

**Core user-facing functionality**

- **One-step import** — a standard appliance image for common desktop hypervisors; import, start, follow the checklist.
- **First-run readiness** — everything pre-installed and pre-configured; the first boot lands the user at the first-run checklist with the console reachable from the host browser.
- **Version manifest** — a readable record of exactly what this appliance release contains: OS, ROS 2, Drake, upstream stack pin, console version, guide version.
- **Reset to baseline** — one action returns the environment to its released state; experiments and manifests the user chose to keep survive in a designated area.
- **Drift check** — compare the running environment against the version manifest and report deviations, so "my seat behaves differently" has a mechanical answer.
- **Fleet distribution** — the same image and manifest serve one researcher or thirty classroom seats; seat verification is a checksum plus a manifest read.

**Architectural paradigms**

- **Immutable appliance image** — the release artifact is the image; fixes ship as new releases, not in-place mutations. User workspace is separated from system state so reset is trivial and keepsakes survive.
- **Manifest-driven build pipeline** — the image is built from pinned, declared inputs; the version manifest is generated from the build, not written by hand.
- **Release gated by the verification suite** — an image becomes a release only when the scenario suite ([scenarios.md](scenarios.md)) passes against it; the P0 set is the non-negotiable gate.
- **Host-portable by conservatism** — modest resource assumptions, no exotic virtualization features, no GPU requirement for the core path; the portability promise beats peak sim performance.

---

## Kennel/console

**Business objective.** Turn the stack from "runnable" into "understandable": a browser-based engineering control room where a researcher composes a simulation experiment (map + controller pipeline + parameters), receives the exact configs and launch commands, and — once the stack runs — watches a live diagnosis of *what is happening and why*. Dark-theme-first, information-dense; per the specification: configure + monitor only.

**Core user-facing functionality**

*Compose view — the experiment builder*

- **Map picker** — card grid of worlds (flat plane, obstacle terrain, brick) with physics summaries, plus sim options: initial pose, sensor-noise toggles, real-time rate, manual stepping, ground-truth-state vs. state estimation.
- **Pipeline composer** — the centerpiece: the real control architecture as a block diagram (Gait Sequencer → MPC → WBC at their true rates, the swing-leg/contact branch, model adaptation broadcasting to all), each block a dropdown of registered implementations with solver sub-choices.
- **Parameter drawers** — per-stage forms generated from the stage's config schema, stock Go2 defaults pre-filled, "modified" badges, raw-YAML mode for researchers.
- **Generate run** — produce the two config YAMLs, the copy-paste three-command launch block (simulator, controller, state estimation), and a run manifest; named presets, save/load/duplicate.

*Dashboard view — diagnosis in time*

- **3D scene** — the simulator's own viewer embedded, never rebuilt.
- **Pipeline health strip** — the composer's block diagram, live: blocks tinted green/amber/red from solve times vs. deadlines (MPC 10 ms, WBC 2 ms), solver failures, topic freshness; click-through to detail plots.
- **Gait/contact timeline** — the four-leg strip chart: planned contact phases as bands, actual contacts overlaid, early/late touchdowns highlighted — the single most informative legged-locomotion diagnostic.
- **Health counters** — failure and overtime counters as rate-of-change sparklines; increases flash the corresponding pipeline block.
- **State plots** — body height and attitude, commanded vs. actual velocity, joint torques — every plot labeled with units and source topic.
- **Event feed** — the diagnosis: raw signals converted to timestamped plain language ("MPC exceeded 10 ms deadline (12.4 ms, 23 iters)", "Early contact FL +40 ms", "FALL: belly contact, pitch −38°"); a fall raises a banner and pins the last five seconds for post-mortem reading.
- **Interventions toolbar** — velocity/gait targets (joystick + fields), disturbance injection (force vector, magnitude, duration), sim reset, and single-step controls — all as service calls and topic publishes against the already-running sim.

*Runs view — the record*

- **Run table** — past manifests: map, stage choices, duration, verdict badge (completed / fell / solver-failed), headline counters.
- **Config diff** — select two runs, see the configuration difference side by side.

**Architectural paradigms**

- **Single-page application** (React + TypeScript + Vite + Tailwind — locked by the specification) with a left nav rail (Compose / Dashboard / Runs) and a persistent status bar: connection state, sim real-time factor, heartbeat age, run ID.
- **The `DataSource` seam** — all live data flows through one interface with two implementations: `MockDataSource` (simulated streams and the scripted demo run) and the ROS bridge client. Swapping them changes no panel; this is the ecosystem's mock boundary (see [Shared Foundations](#shared-foundations)).
- **Configure + monitor only** — the console emits configs and command text and speaks to the running stack over the bridge (topics and sim-level services); process lifecycle belongs to the user's terminal, structurally.
- **Round-trip-safe config generation** — loading a generated YAML reproduces the exact composer state; the config, not the UI session, is the experiment's identity.
- **Swappable stage-mapping layer** — composer choices map to today's launch args and YAML keys behind an interface, so the arrival of upstream's explicit stage selection keys changes the mapping, not the UI.
- **Aggressive telemetry throttling** — high-rate topics downsampled for plots; windowed statistics computed near the source; the browser renders diagnosis, not raw firehose.
- **Meaningful empty states** — every panel with a silent topic names the missing launch command; degraded is a designed state, not an accident.

---

## Kennel/stack

**Business objective.** Provide the lab's engine — the upstream dfki-quad ROS 2 controller and Drake simulation for the Unitree Go2 — pinned, wrapped, and launchable exactly as the console's generated commands expect, while the upstream project remains the source of truth. Kennel's stack is a *distribution* of the research code, never a fork of it.

**Core user-facing functionality**

- **Pinned upstream checkout** — one recorded revision of the research stack, pre-built inside the appliance, launchable immediately.
- **The three launch paths** — simulator, controller, and state estimation, each a single command the console generates with all arguments baked in.
- **Config surface** — the stack's real YAML files and launch arguments, exactly as upstream defines them; what the console's composer writes is what the stack actually reads.
- **Mapping-layer notes** — the maintained record of how composer choices bind to today's mechanisms (solver launch args, terrain YAML edits) and which upstream changes retire each workaround.
- **Repin workflow** — a documented path from "upstream moved" to "new pin validated": update, rebuild, run the scenario suite, record the new manifest.

**Architectural paradigms**

- **Wrap, don't fork** — Kennel-local patches are minimal, documented, and headed upstream; the wrap is launch configuration, pinning, and packaging.
- **Version-pinned distribution** — the stack's identity is its pin in the version manifest; two appliances with the same manifest run the same controller, bit for bit.
- **Contract fidelity** — the console integrates against the stack's actual topics, message definitions, and service names as the code defines them (including its spelling quirks), never against undocumented assumptions.
- **Scenario suite as regression gate** — a repin is valid when the verification scenarios pass against the new pin; upstream evolution becomes routine instead of frightening.

---

## Kennel/guides

**Business objective.** Make the promised experience navigable by a person who has never seen the system: from VM import to first walking robot, through understanding the dashboard, to — for the teams that need it — the documented, safety-gated bridge toward real hardware. The guides are also the classroom's lesson skeleton and the keeper of Kennel's honesty about what the VM is not.

**Core user-facing functionality**

- **First-run checklist** — the short, ordered path: import, boot, open the console, launch the three commands, watch the Go2 stand and walk. The five-minute promise, written down.
- **Guided walkthroughs** — a graded progression: watch it walk → read the dashboard → change a gait → swap a solver → inject a disturbance → compare two runs.
- **Diagnosis primer** — what each dashboard panel means, what healthy looks like, and how to read a fall post-mortem.
- **Preset library documentation** — the shipped presets ("Stock Go2 walk", "Stairs + Adaptive gait", "Solver benchmark") and what each one teaches.
- **The safety gate** — the simulation-first checklist that must be completed and recorded before hardware material applies (see [Shared Foundations](#shared-foundations)).
- **Hardware notes** — the documented handoff from "validated in Kennel" to a dedicated robot computer: what transfers (configs, manifests), what does not (the VM, its timing behavior), and what the VM explicitly does not claim.

**Architectural paradigms**

- **Docs shipped with the appliance, versioned with it** — the guides describe the image they ride in; a guide that references a command is validated against that image's stack, so instructions cannot drift from reality.
- **Checklist as artifact** — the first-run checklist and the safety gate are structured, checkable documents, not prose: completion is recordable, and the verification scenarios execute them literally.
- **Progressive disclosure** — defaults first, parameters later, hardware last and gated; the reading order is the safety model and the lesson plan at once.

---

## Shared Foundations

Four capabilities sit beneath the applications. They are contracts and artifacts, not user-facing products; every application above consumes them.

### Version Manifest
The reproducibility contract of the appliance: a generated record of every pinned component — OS, ROS 2, Drake, upstream stack revision, console version, guides version — identifying an appliance release exactly. Produced by the Kennel/appliance build, referenced by every run manifest, checked by the drift tool, and asserted by every verification scenario ("this ran on manifest X").

### DataSource / Bridge Contract
The console's single seam to live data. One interface; two implementations: **`MockDataSource`** — simulated streams plus the scripted demo run (~30 s stable trot, degrading MPC solve times, then a fall) so every panel demonstrates its purpose with no stack running — and the **ROS bridge client**, speaking to the running stack over a WebSocket bridge (topics in, throttled; sim-level service calls out). The contract carries the stack's real message shapes; swapping implementations changes no consumer. This is the ecosystem's mock boundary: demo mode, UI development, and the live lab are the same application.

### Run Manifests & Config Schema
The identity of an experiment. Generating a run produces the two stack config YAMLs plus a manifest capturing the full composition — map, stage choices, parameters, sim options — and the environment identity (version manifest reference). Round-trip safe by contract: loading a config or manifest back reproduces the exact composer state. The Runs view, config diffs, reproducibility claims, and the hardware transfer package are all built on this artifact.

### The Safety Gate
The recorded, checkable simulation-first checklist standing between simulation work and any hardware material. It encodes the PRFAQ's risk mitigations: no production claims from the VM, no skipping simulation, evidence (run manifests) attached to completion. Kennel/guides presents it; the hardware notes require it; the verification suite proves the ordering is enforced by structure, not by discipline.

---

## Workflow Alignment Matrix

Every persona workflow from [personas.md](personas.md) traced to the capability that serves it:

| Persona workflow | Application capability |
|------------------|------------------------|
| Alex composes a map + pipeline + parameters | Kennel/console — Compose view (map picker, pipeline composer, parameter drawers) |
| Alex generates and launches a run | Kennel/console — generate run · Kennel/stack — the three launch paths |
| Alex reads solver-level diagnostics live | Kennel/console — pipeline health strip, health counters, state plots |
| Alex diagnoses a fall post-mortem | Kennel/console — event feed, fall banner with pinned window |
| Alex injects disturbances and changes targets | Kennel/console — interventions toolbar (bridge service calls) |
| Alex compares runs for a paper | Kennel/console — Runs view, config diff · Run Manifests & Config Schema |
| Sofia goes from import to first walk | Kennel/appliance — one-step import · Kennel/guides — first-run checklist |
| Sofia runs a stock preset | Kennel/console — preset library · Kennel/guides — preset documentation |
| Sofia learns from silent panels | Kennel/console — meaningful empty states naming launch commands |
| Sofia recovers a broken environment | Kennel/appliance — reset to baseline |
| Marcus verifies thirty identical seats | Kennel/appliance — fleet distribution, version manifest check |
| Marcus teaches from the guides | Kennel/guides — walkthroughs, preset progression |
| Marcus resets seats between cohorts | Kennel/appliance — reset to baseline, drift check |
| Elif builds and pins a release | Kennel/appliance — manifest-driven build pipeline |
| Elif gates the release on scenarios | Kennel/appliance — release gated by the verification suite |
| Elif ships drift and reset tooling | Kennel/appliance — drift check, reset to baseline |
| Devon runs the scripted demo | Kennel/console — `MockDataSource` demo run (DataSource contract) |
| Devon switches demo → live | DataSource / Bridge Contract — implementation swap, no UI change |
| Noa completes the safety gate | Kennel/guides — the safety gate (recorded checklist) |
| Noa exports the validated transfer package | Run Manifests & Config Schema · Kennel/guides — hardware notes |
| Theo tracks and repins upstream | Kennel/stack — pinned checkout, repin workflow |
| Theo maintains the mapping layer | Kennel/stack — mapping-layer notes · Kennel/console — swappable stage mapping |
| Theo retires a workaround after upstream lands | Kennel/console — mapping layer swap · Kennel/stack — contract fidelity |

No persona workflow lacks a serving capability, and no application capability exists without a persona who needs it. [scenarios.md](scenarios.md) exercises every row end to end.
