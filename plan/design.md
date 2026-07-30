# Kennel POC — Master Design

**Companion documents:** [personas.md](personas.md) · [applications.md](applications.md) · [scenarios.md](scenarios.md) · diagrams under [design/](design/), indexed in [§9](#9-diagrams)

> One sentence: how the four Kennel applications and four shared foundations become a proof-of-concept — a pinned VM appliance plus the Kennel Console — that executes all ten verification scenarios under Yuruna and grows into the classroom fleet and the documented hardware handoff without contract changes.

---

## 1. Decisions locked

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Console stack | **React + TypeScript + Vite + Tailwind**, single-page app, dark-theme-first | Locked by the console specification in [prompts.txt](prompts.txt) |
| Console data seam | **`DataSource` interface**; `MockDataSource` first, ROS bridge client second | The specification's mock boundary; demo mode, UI development, and live lab are one application (s007.bridge) |
| ROS–web bridge | **rosbridge WebSocket** for the POC; Foxglove WebSocket as a growth-path alternative behind the same `DataSource` | Widest message-type coverage today; the seam makes the choice reversible |
| 3D scene | **Embedded Meshcat iframe** (Drake's own viewer) | Never rebuild 3D rendering; the spec is explicit |
| Appliance base | **Ubuntu LTS + ROS 2 + Drake at the versions the pinned upstream dfki-quad revision supports** — exact versions live in the version manifest, not in this document | Upstream is the source of truth; the manifest, not prose, records versions |
| Hypervisor target | **OVA appliance (VirtualBox-first)**; qcow2/KVM on the growth path | Most common denominator for classroom and personal machines |
| Console serving | **Static assets served from inside the VM**, opened from the host browser via a forwarded port | Nothing to install on the host; the appliance stays the whole product |
| Verification framework | **Yuruna** drives VM provisioning, sequence execution, and asserts | Kennel *is* a VM appliance — Yuruna's home ground; mirrors the AmisAd precedent. *(Flagged assumption — confirm before building `test/`.)* |
| Fault injection (s003/s004) | **Disturbance service + stress preset** (a composed configuration that predictably degrades MPC solve margin), not code-level fault hooks | Uses only surfaces the product already has; nothing test-only leaks into the stack |
| Sim nondeterminism tolerance (s006) | Verdict must match; headline counters within **±20%** initially, tightened empirically | A declared, revisable number beats an undeclared one |
| Classroom fleet size (s008) | **N = 2** seats for the POC | Minimum honest fleet: uniformity and drift assertions need a clean seat and a dirty seat |
| Upstream-gap simulation (s009) | Repin rehearsal stages a revision where a **stage `type:` key** replaces a launch-arg mapping | Exactly the known upstream gap the console spec anticipates |
| Repository layout | `plan/` + `console/` + `appliance/` + `stack/` + `guides/` + `test/` (see §6) | Planning docs and code in one repo; Yuruna discovers `test/` |
| Legacy references in prompts.txt | [prompts.txt](prompts.txt) is kept verbatim as the historical prompt record; its references to `kennel_console_ui_spec.md`, `modularity/stage_contracts.md`, and `PRFAQ.md` are superseded by this corpus ([prompts.txt](prompts.txt) itself, a future `stack/contracts.md`, and [PRFAQ.txt](PRFAQ.txt)) | Don't rewrite history; the plan corpus is the living reference |

## 2. POC topology

Two machines' worth of roles on one physical host, provisioned and driven by Yuruna (see [design/01-overview.md](design/01-overview.md)):

| Node | Role |
|------|------|
| **Host** | Hypervisor, browser (Kennel Console client), Yuruna test runner, release artifacts (image + checksum + version manifest) |
| **kennel-vm** | The appliance: pinned dfki-quad ROS 2 stack, Drake simulator + Meshcat, rosbridge server, console static server, guides, reset/drift tooling |
| **kennel-vm-b** (s008 only) | Second classroom seat from the same image — the minimum honest fleet |

The user's terminal into the VM is part of the product experience: the console generates commands; the user runs them there. The harness automates that terminal over the VM's shell channel, never through hidden orchestration — the same configure+monitor boundary the console honors.

## 3. Application inventory

Every application from [applications.md](applications.md) exists in the POC — s001…s010 assert against all of them, and scenario-driven scope forbids stubbing anything a scenario asserts against.

| Application | POC realization | Surface |
|-------------|-----------------|---------|
| Kennel/appliance | Image build scripts (pinned inputs → OVA), generated version manifest, reset-to-baseline and drift-check scripts | Hypervisor import; in-VM CLI for reset/drift |
| Kennel/console | The SPA per the build prompt in [prompts.txt](prompts.txt): Compose / Dashboard / Runs, status bar, `DataSource` seam, run-manifest store (browser + designated VM workspace dir) | Host browser |
| Kennel/stack | Pinned upstream dfki-quad checkout, pre-built in-image; launch wrappers only where the console's generated commands need them; mapping-layer notes | VM terminal (the three launch commands) |
| Kennel/guides | Markdown shipped in-image and linked from the console shell: first-run checklist, walkthroughs, diagnosis primer, safety gate (structured checklist with evidence attachments), hardware notes behind the gate | Console + VM filesystem |

**Build order note.** The console ships in two phases per its own spec: the **mock phase** (MockDataSource, scripted demo — buildable with no VM at all; validated by s007.bridge's mock half) and the **integration phase** (bridge client; validated by everything else). The mock phase is first deliberately: it is also Devon's demo and the UI's development harness.

## 4. Foundations realization

- **Version Manifest** = a generated file (one per image build) recording OS, ROS 2, Drake, upstream pin, console version, guides version, plus the image checksum. Written by the appliance build, shipped in-image at a fixed path, read by the console status surface, the drift checker, and every Yuruna assert.
- **DataSource / Bridge Contract** = one TypeScript interface in the console; implementations `MockDataSource` (10 Hz simulated streams, scripted demo run: ~30 s trot → degrading solve times → fall) and `RosbridgeDataSource` (subscribe throttled, publish targets, call sim-level services). Message shapes mirror the stack's real definitions (`QuadState`, `GaitState`, `ContactState`, `MPCDiagnostics`, `WBCReturn`, `ControllerInfo`) — including subscribing to the code's `controller_heartbeat` spelling, never the legacy script's.
- **Run Manifests & Config Schema** = JSON manifest (map, stage choices, parameters, sim options, version-manifest reference, duration, verdict, headline counters) + the two generated stack YAMLs, written to the designated workspace directory (the area that survives reset). Round-trip safety is a serialization contract with a byte-comparison test, not a convention.
- **The Safety Gate** = a structured checklist document with recordable completion and evidence attachments (run-manifest references). Its enforcement is structural in the guides: the hardware notes are rendered/reachable only from a completed gate record (s010.handoff asserts the ordering, not a banner).

## 5. Mock boundary

Every mock implements the production interface; swapping it changes no caller.

| Production capability | POC stand-in | Preserved contract |
|-----------------------|--------------|--------------------|
| Live ROS 2 stack telemetry | `MockDataSource` scripted streams + demo run | The `DataSource` interface and the stack's message shapes |
| Explicit stage `type:` selection keys (upstream gap, anticipated) | Console mapping layer → today's launch args (`mpc_solver:=`, `mpc_hpipm_mode:=`, `mpc_condensed_size:=`) and YAML keys | Composer state schema; s009.repin rehearses the swap |
| `world:=` launch argument (upstream gap, anticipated) | Map picker writes `world_urdf` into the generated simulator YAML | The generated-config contract; retired when upstream lands the arg |
| Classroom fleet at scale | Two seats from one image | Image identity: checksum + byte-identical version manifests |
| Real Go2 on a robot computer | Out of the VM by design — represented only by the transfer package (configs + manifests + gate record) | The package format; the VM never claims the robot |

## 6. Repository layout

```
kennel/
  plan/                     # this corpus: PRFAQ.txt, prompts.txt, personas, applications,
                            #  scenarios, design.md, design/
  console/                  # Kennel Console SPA (React+TS+Vite+Tailwind)
    src/datasource/         # DataSource interface, MockDataSource, RosbridgeDataSource
  appliance/
    build/                  # image build scripts, pinned inputs, manifest generator
    tools/                  # reset-to-baseline, drift-check
  stack/
    pin.lock                # the upstream dfki-quad revision + patches (minimal, documented)
    mapping.md              # mapping-layer notes: composer choice → launch arg / YAML key
  guides/                   # first-run checklist, walkthroughs, diagnosis primer,
                            #  safety-gate checklist, hardware notes
  test/                     # Yuruna sequences: baseline (import + boot) + s001…s010
```

## 7. Scenario execution

Yuruna provisions the host artifacts, imports the appliance, and executes [scenarios.md](scenarios.md) as its discovered sequences — s001…s008 in priority order, then the s009/s010 capstones. Each scenario's Target Verification Point maps to asserts against observable state: files (manifests, configs, checklist records, drift reports), console UI state (driven and read via browser automation), topic traffic and service calls (observed at the bridge), the VM process table (the configure+monitor assert in s004.disturb), and wall-clock budgets (s001.firstwalk). The mock half of s007.bridge needs no VM and doubles as the console's CI smoke test.

**Build sequencing** (each step consumes the previous step's artifacts):

1. **Console, mock phase** — execute the build prompt in [prompts.txt](prompts.txt) as written; s007.bridge (mock half) green.
2. **Appliance baseline** — first pinned image + manifest + checklist; s001.firstwalk green.
3. **Bridge integration** — `RosbridgeDataSource`; s002.compose, s003.diagnose, s004.disturb green.
4. **Record & reproduce** — Runs view depth, diff, reset/drift tooling; s005.compare, s006.reproduce, s008.classroom green.
5. **Capstones** — repin rehearsal and the safety gate; s009.repin, s010.handoff green. A release is a full green suite (§ Kennel/appliance, release gate).

Scenario docs and diagrams change only if implementation forces a contract deviation — note it, never drift silently.

## 8. Growth path

| POC | Full system |
|-----|-------------|
| OVA for VirtualBox | Multi-hypervisor artifacts (qcow2/KVM, VMware) from the same build pipeline and manifest |
| rosbridge WebSocket | Foxglove WebSocket behind the same `DataSource` — a new implementation, no panel changes |
| Two classroom seats | Full course fleets; same image-identity assertions at N seats |
| Manual image distribution | Published releases with checksums and manifest history |
| Scripted mock demo | Curated demo library (multiple scripted runs) on the same `MockDataSource` |
| Transfer package + hardware notes | Guided robot-computer deployment tooling — still outside the VM, still behind the gate |
| Yuruna lab sequences | The same sequences as release conformance gates for every appliance version |

## 9. Diagrams

The documents under [design/](design/) visualize this design, they do not restate it. Every diagram holds at most seven boxes; growth-path items use dashed edges.

| # | Document | Diagram type | Shows |
|---|----------|--------------|-------|
| 1 | [POC overview](design/01-overview.md) | flowchart ×2 | The top-level POC blocks; the host + VM deployment topology |
| 2 | [Kennel/appliance](design/02-appliance.md) | flowchart | Image build, manifest, reset/drift, fleet distribution |
| 3 | [Kennel/console](design/03-console.md) | flowchart | Shell, three views, DataSource seam, manifest store |
| 4 | [Kennel/stack](design/04-stack.md) | flowchart | Upstream pin, three launch paths, bridge, mapping layer |
| 5 | [Kennel/guides](design/05-guides.md) | flowchart | Checklist, walkthroughs, safety gate, hardware notes |

One sequence diagram per verification scenario, faithful to the numbered steps in [scenarios.md](scenarios.md); participants are the POC components above, personas as actors, at most 8 lifelines each. Each opens with a Note stating seeded preconditions and closes with a Note stating the Target Verification Point Yuruna asserts.

| Document | Sequence for |
|----------|--------------|
| [seq.s001.firstwalk.md](design/seq.s001.firstwalk.md) | s001.firstwalk — Cold Import to Walking Go2 Inside the Time Budget |
| [seq.s002.compose.md](design/seq.s002.compose.md) | s002.compose — Experiment Composition, Generation, and Config Round-Trip |
| [seq.s003.diagnose.md](design/seq.s003.diagnose.md) | s003.diagnose — Live Degradation, Fall, and Post-Mortem Diagnosis |
| [seq.s004.disturb.md](design/seq.s004.disturb.md) | s004.disturb — Interventions: Commands, Disturbance Injection, and Recovery |
| [seq.s005.compare.md](design/seq.s005.compare.md) | s005.compare — Solver Benchmark and Run Comparison |
| [seq.s006.reproduce.md](design/seq.s006.reproduce.md) | s006.reproduce — Same Manifest, Same Experiment |
| [seq.s007.bridge.md](design/seq.s007.bridge.md) | s007.bridge — The DataSource Seam: Scripted Demo and Live Swap |
| [seq.s008.classroom.md](design/seq.s008.classroom.md) | s008.classroom — Fleet Cold Start, Drift, and Reset |
| [seq.s009.repin.md](design/seq.s009.repin.md) | s009.repin — Upstream Update, Repin, and Regression Gate |
| [seq.s010.handoff.md](design/seq.s010.handoff.md) | s010.handoff — The Safety-Gated Path Toward Hardware |

How the documents relate:

- Doc 1 names the blocks and places them on the host/VM topology; docs 2–5 open one application each.
- Foundations (version manifest, DataSource seam, run manifests, safety gate) appear as external boxes in the application diagrams — they are defined in §4 above and drawn open in doc 1.
- Scenario coverage per application is listed at the bottom of each document, tracing back to [scenarios.md](scenarios.md).
- The seq.\* documents show docs 2–5's components exchanging messages in scenario order, each closing on its Target Verification Point.
