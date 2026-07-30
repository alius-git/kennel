# Kennel Personas

**Companion documents:** [applications.md](applications.md) — the application ecosystem these personas inhabit · [scenarios.md](scenarios.md) — the end-to-end verification sequences that exercise them · [PRFAQ.txt](PRFAQ.txt) — the product vision.

Kennel makes the first successful controller session the default outcome, not a heroic one. A researcher, student, or team imports a prepared virtual machine and, within about five minutes, is exercising a modern Go2 quadruped walking controller in simulation — changing gaits, sending velocity commands, watching the stack respond — through **Kennel Console**, the browser-based control room that composes experiments and diagnoses runs.

This document defines the people in that loop. Every workflow named here maps to a capability in [applications.md](applications.md); the mapping table at the end makes the alignment explicit.

---

## Persona Roster

| # | Persona | Role | Primary application |
|---|---------|------|---------------------|
| 1 | Alex | The Controls Researcher | Kennel/console |
| 2 | Sofia | The New Lab Member (Student) | Kennel/guides + Kennel/console (defaults) |
| 3 | Marcus | The Course Instructor | Kennel/appliance (fleet) |
| 4 | Elif | The Appliance Steward | Kennel/appliance (build & release) |
| 5 | Devon | The Demo Presenter | Kennel/console (mock demo mode) |
| 6 | Noa | The Hardware-Transition Engineer | Kennel/guides (safety gate → hardware notes) |
| 7 | Theo | The Upstream Stack Maintainer | Kennel/stack |

Personas 1–2 come from the founding console specification (primary and secondary users). Personas 3–4 close the gaps the PRFAQ names explicitly: classroom deployment and environment drift. Personas 5–7 close the adoption-lifecycle gaps identified in the end-to-end review; see [Lifecycle Gap Analysis](#lifecycle-gap-analysis).

---

## 1. Alex — The Controls Researcher

**Application:** Kennel/console

**Who they are.** A graduate researcher in legged robotics — the person the PRFAQ quotes: "I used to budget a full week just to get the stack compiling before I could try a single trot in simulation." Alex's work is the controller: gait sequencing, MPC solver behavior, whole-body control. Every hour spent on installation is an hour taken from research.

**Core motivations**

- Spend time on the controller, not the environment: swap pipeline stages and solvers in minutes.
- See *why*, not just *what*: solver-level diagnostics — solve times against deadlines, iteration counts, failure counters — in real time.
- Reproduce everything: a result that cannot be re-run from its config is not a result.
- Perturb and observe: inject disturbances, change targets mid-run, and read the consequences off the dashboard.

**Responsibilities within the ecosystem**

- Compose experiments: pick a world, assemble the controller pipeline, tune stage parameters.
- Generate and launch runs from the produced configs and command blocks — in a terminal, deliberately, never through hidden orchestration.
- Interpret live diagnostics: pipeline health, gait/contact mismatches, event-feed diagnoses, fall post-mortems.
- Keep run manifests as the durable record for comparisons, lab notes, and papers.
- Report upstream-worthy findings (solver anomalies, contract gaps) toward the maintainer loop (see Theo).

**Primary interaction points**

- The Compose view: map picker, pipeline composer (Gait Sequencer → MPC → WBC, swing/contact branch, model adaptation), parameter drawers with raw-YAML mode.
- Generated artifacts: the two YAML configs, the three-command launch block, the run manifest.
- The Dashboard: pipeline health strip, gait/contact timeline, health-counter sparklines, state plots, event feed, interventions toolbar.
- The Runs view: past manifests, verdict badges, side-by-side config diffs.

**Success looks like.** An afternoon comparing HPIPM against OSQP on the stair terrain: six runs, six manifests, one config diff that explains the difference in solve-time margins — and not one minute spent fighting the environment.

---

## 2. Sofia — The New Lab Member (Student)

**Application:** Kennel/guides + Kennel/console (defaults)

**Who she is.** A new lab member or course student on day one. She has read about quadruped control; she has never built a ROS workspace. Her laptop is whatever it is. The PRFAQ's promise is aimed at her: the first successful test session is the product.

**Core motivations**

- Reach a walking simulated Go2 without reading source code or fighting dependencies.
- Understand what she is looking at: the dashboard should teach the pipeline, not presume it.
- Recover from mistakes: when she breaks something, a reset — not a rebuild — gets her back.
- Keep pace with the lab: her environment behaves exactly like everyone else's.

**Responsibilities within the ecosystem**

- Follow the first-run checklist from VM import to first walk.
- Run stock presets ("Stock Go2 walk") before composing anything custom.
- Learn the control pipeline by observation: which block does what, what healthy looks like, what a fall looks like.
- Reset to baseline when the environment stops matching the guides.

**Primary interaction points**

- The first-run checklist: the short, ordered path from import to walking robot.
- Console defaults and presets: a working experiment without touching a parameter.
- Dashboard empty states: every silent panel names the launch command that feeds it.
- The event feed's plain-language diagnoses: "MPC exceeded 10 ms deadline", "FALL: belly contact".
- Reset-to-baseline control on the appliance.

**Success looks like.** The PRFAQ quote, made routine: she starts after lunch, and by mid-afternoon the simulated Go2 is walking, she can say what the MPC block does, and she can explain why the demo run fell.

---

## 3. Marcus — The Course Instructor

**Application:** Kennel/appliance (fleet)

**Who he is.** He teaches a legged-robotics course or runs lab onboarding. His scarce resource is contact time: every session lost to broken environments is control theory not taught. The PRFAQ's 12-month success metric — Kennel formally integrated into at least one course or lab onboarding path — lands on his desk.

**Core motivations**

- Uniform baseline: thirty seats, one image, identical behavior on every one.
- Spend the session on the subject: labs structured around presets and scenarios, not around setup triage.
- Recover any seat instantly: a broken environment is a reset or re-import, never a debugging session.
- Trust the appliance version: the class runs the release he validated, and drift is detectable.

**Responsibilities within the ecosystem**

- Distribute the appliance image and verify each seat against the version manifest.
- Structure lab sessions around the guides and preset experiments.
- Reset seats between cohorts and confirm baseline state.
- Report classroom-scale friction back to the Appliance Steward.

**Primary interaction points**

- Appliance import and manifest verification: the seat is what the release says it is.
- Reset-to-baseline tooling, per seat, between sessions.
- The guides as lesson skeleton: checklist, walkthroughs, preset progression.
- The preset library: a graded sequence from "watch it walk" to "swap the solver."

**Success looks like.** Thirty students import on Monday; by the end of the first session every seat has a walking Go2. On Wednesday one seat is hopelessly modified — it is re-imported in minutes, and the class never slows down.

---

## 4. Elif — The Appliance Steward

**Application:** Kennel/appliance (build & release)

**Who she is.** The person who turns "works on my machine" into "works on the image." She builds, pins, and releases the Kennel appliance, and owns the PRFAQ's named risk: environment drift. Her product is boring releases.

**Core motivations**

- Make the image the truth: every dependency pinned, every version recorded in the manifest.
- Make releases mechanical: a release is a green run of the verification scenarios, not a judgment call.
- Make drift visible: a modified environment can always be detected against its manifest and restored.
- Keep the appliance importable on ordinary lab and personal machines — the portability promise is hers.

**Responsibilities within the ecosystem**

- Build the appliance image: base OS, ROS 2, Drake, the pinned dfki-quad stack, the console, the guides.
- Maintain the version manifest — the reproducibility contract every scenario and every run manifest references.
- Gate releases on the verification suite: no image ships with a red P0 scenario.
- Provide and maintain reset-to-baseline and drift-detection tooling.
- Coordinate repins with the Upstream Stack Maintainer (see Theo).

**Primary interaction points**

- The image build pipeline and its pinned inputs.
- The version manifest: the single document that says exactly what the appliance contains.
- The verification suite as release gate: scenarios run against every candidate image.
- Drift and reset tooling surfaced to instructors and students.

**Success looks like.** A release is cut by running the suite and watching it pass. Months later, no issue tracker entry reads "it doesn't build" — because nobody builds; they import.

---

## 5. Devon — The Demo Presenter

**Application:** Kennel/console (mock demo mode)

**Who they are.** The person showing Kennel to an audience — a lab open day, a course pitch, a stakeholder meeting. Devon needs every panel of the console to demonstrate its purpose immediately, with zero risk of live-stack flakiness in front of a room.

**Core motivations**

- A compelling, repeatable demonstration: the same scripted story, every time, on any machine.
- Zero live dependencies when it matters: the demo must not hinge on a ROS stack behaving on stage.
- A demo that teaches: the scripted run shows healthy walking, visible degradation, and a diagnosed fall — the product's whole argument in ninety seconds.
- A clean path from demo to real: switching from scripted data to the live stack is a data-source change, not a different application.

**Responsibilities within the ecosystem**

- Run the seeded demo: ~30 s of stable trot, degrading MPC solve times, then a fall — with every dashboard panel exercised.
- Narrate the diagnostics: what the health strip, gait timeline, and event feed are saying and why it matters.
- Switch to the live simulation when the setting allows, using the identical console.

**Primary interaction points**

- The `MockDataSource` scripted demo run, seeded into the console.
- The Dashboard in full: health strip, timeline, sparklines, event feed, fall banner with pinned post-mortem.
- The data-source switch: mock to live bridge, same panels, same behavior.

**Success looks like.** A ten-minute open-day demo with no terminal in sight: the robot walks, degrades, falls, and the console explains the fall before the audience asks — then the same console connects to a live sim for questions.

---

## 6. Noa — The Hardware-Transition Engineer

**Application:** Kennel/guides (safety gate → hardware notes)

**Who they are.** The team member who takes a controller configuration validated in Kennel toward a real Go2 on a dedicated robot computer. The PRFAQ is explicit: Kennel is not a production controller and the VM makes no real-time claims — Noa's job is the *documented bridge* from "validated in Kennel" to "run on dedicated hardware," walked safely.

**Core motivations**

- A bridge, not a leap: a documented, repeatable path from simulation-validated configs to the robot computer.
- Safety as sequence: hardware steps come only after the simulation-first checklist is genuinely complete.
- Evidence in hand: the run manifests that validated the configuration travel with it.
- No overclaims: what the VM cannot promise (hard real-time, production control) stays clearly out of its scope.

**Responsibilities within the ecosystem**

- Complete the simulation-first safety checklist and keep its record.
- Export validated configurations and their run manifests as the transfer package.
- Follow the hardware notes on the dedicated robot computer; the VM stays in its lane.
- Report gaps in the bridge documentation back into the guides.

**Primary interaction points**

- The safety gate: the checklist that precedes any hardware note.
- Run manifests as the evidence of simulation validation.
- The hardware notes in the guides: the documented handoff to the robot computer.

**Success looks like.** A gait configuration proven across the sim scenarios runs on the dedicated robot computer via the documented path — with the completed checklist and its manifests on record, and nobody having pretended the VM was the robot.

---

## 7. Theo — The Upstream Stack Maintainer

**Application:** Kennel/stack

**Who he is.** The engineer who keeps Kennel honest about its most important dependency: the upstream dfki-quad research stack, which remains the source of truth. Kennel wraps and pins it; it does not fork it. Theo owns that relationship — including the known upstream gaps the console must map around.

**Core motivations**

- Track upstream without forking: Kennel's value is the ready front door, not a divergent codebase.
- Make repins routine: a new upstream version becomes a new pin, revalidated by the scenario suite.
- Keep the mapping layer shrinking: today's workarounds (stage selection via launch args, terrain via YAML edit) retire as upstream lands the real contracts.
- Upstream what belongs upstream: fixes and small enabling changes go to the source, not into the wrap.

**Responsibilities within the ecosystem**

- Watch upstream changes; assess impact on the pinned stack and the console's contracts.
- Propose and execute repins with the Appliance Steward; the verification suite is the regression gate.
- Maintain the console's mapping layer notes: which stage choices map to which launch args and YAML keys today, and what changes when upstream's explicit stage `type:` keys land.
- Keep Kennel-local patches minimal, documented, and headed upstream.

**Primary interaction points**

- The pin in the version manifest: exactly which upstream revision the appliance wraps.
- The mapping layer between composer choices and today's launch-arg/YAML mechanisms.
- The scenario suite as the repin regression gate.
- Upstream issue tracking for the gaps Kennel depends on.

**Success looks like.** An upstream release lands; the repin goes through with every scenario green; and one mapping-layer workaround is deleted because upstream now speaks the contract directly.

---

## Lifecycle Gap Analysis

The founding console specification names two users: the Controls Researcher (Alex) and the New Lab Member (Sofia). Two review passes completed the roster.

**Pass one — the PRFAQ's own commitments.** The press release and internal FAQ make promises no founding persona owns:

1. **Classroom deployment was promised but unowned.** The 12-month metric — Kennel in at least one course or onboarding path — needs someone who distributes, verifies, and resets a fleet of identical seats. **Marcus (Course Instructor)** owns it.
2. **Environment drift was named as a primary risk, with no one accountable.** Version pinning and a resettable baseline are mitigations only if someone builds, pins, gates, and releases the image. **Elif (Appliance Steward)** owns the appliance as a product.

**Pass two — the adoption lifecycle.** Walking demo → validation → hardware handoff → upstream evolution exposed three more gaps:

3. **The demo was seeded but nobody presented it.** The mock-data phase ships a scripted demo run precisely so the console can argue for itself; that argument needs a presenter with zero-flakiness requirements. **Devon (Demo Presenter)** owns it — and forces the mock/live seam to stay a pure data-source swap.
4. **The hardware bridge was promised ("a clear path for teams that later want to take validated workflows toward real hardware") but had no traveler.** An undocumented handoff is exactly how the PRFAQ's "skipping simulation to unsafely attempt hardware runs" risk materializes. **Noa (Hardware-Transition Engineer)** makes the safety gate a walked path, not a paragraph.
5. **Upstream was declared the source of truth, with nobody tending the relationship.** The console spec already documents upstream gaps (missing stage `type:` keys, no `world_urdf` launch arg) and demands a swappable mapping layer; that layer needs an owner or it becomes a fork by neglect. **Theo (Upstream Stack Maintainer)** owns the pin, the mapping, and the repin gate.

**No roles remain deferred.** Future additions (e.g., a multi-robot lab coordinator, a CI operator for hosted scenario runs) should be proposed against this baseline.

---

## Persona ↔ Application Map

| Persona | Primary application | Also touches |
|---------|--------------------|--------------|
| Alex — Controls Researcher | Kennel/console | Kennel/stack (launches generated runs); run manifests |
| Sofia — New Lab Member | Kennel/guides + Kennel/console (defaults) | Kennel/appliance (reset-to-baseline) |
| Marcus — Course Instructor | Kennel/appliance (fleet) | Kennel/guides (lesson skeleton); version manifest |
| Elif — Appliance Steward | Kennel/appliance (build & release) | Verification suite as release gate; version manifest |
| Devon — Demo Presenter | Kennel/console (mock demo mode) | DataSource seam (mock ↔ live switch) |
| Noa — Hardware-Transition Engineer | Kennel/guides (safety gate) | Run manifests as validation evidence |
| Theo — Upstream Stack Maintainer | Kennel/stack | Console mapping layer; version manifest; scenario suite |

Every workflow above maps to an application capability defined in [applications.md](applications.md); the alignment matrix there provides the workflow-level trace, and [scenarios.md](scenarios.md) proves each one end to end.
