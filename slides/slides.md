---
theme: default
title: Kennel
titleTemplate: '%s — a ready-to-use virtual lab for a walking Go2'
info: |
  Kennel — final presentation of the 2026 internship, Thales Andrade Soares.
  Demo · problem · previous work · proposal · development · results · learnings.
author: Thales Andrade Soares
colorSchema: dark
transition: slide-left
mdc: true
drawings:
  persist: false
layout: cover
background: /img/meshcat-walking.png
---

# Kennel

## A ready-to-use virtual lab for a walking Go2 quadruped

<div class="mt-8 opacity-80">
Compose an experiment in your browser · run it in a pinned virtual machine · watch the robot walk · drive it yourself
</div>

<div class="mt-16 text-sm opacity-60">
Final presentation — 2026 internship — Thales Andrade Soares
</div>

<!--
⏱ 0:00. One line: "A lab in a box. You open a browser, choose how the robot should be controlled, press one button, and a simulated Go2 walks — on any machine, the same way, every time."

Then the order, in one breath: who I am, a live demo first, then the problem, what existed, what I proposed, what I built, what it measures, what I learned.
-->

---

# Agenda 

<div class="grid grid-cols-2 gap-x-12 gap-y-3 mt-8 text-lg">

<div><span class="opacity-50 mr-3">1</span> Demo</div>
<div><span class="opacity-50 mr-3">5</span> Development</div>
<div><span class="opacity-50 mr-3">2</span> Problem statement</div>
<div><span class="opacity-50 mr-3">6</span> Results</div>
<div><span class="opacity-50 mr-3">3</span> Previous work</div>
<div><span class="opacity-50 mr-3">7</span> Learnings</div>
<div><span class="opacity-50 mr-3">4</span> The proposal</div>
<div></div>

</div>


<!--
Budget: title 0.5 · about me 1 · demo 8 · then 2 · 2 · 2 · 2 · 2 · 1.5 = 21 minutes. The presenter view shows the clock; each section slide's notes carry the cumulative mark.
-->

---
section: ""
---

# About me

<div class="grid grid-cols-5 gap-10 mt-8">

<div class="col-span-2">

## Thales Andrade Soares

<div class="mt-4 opacity-80">

Intern at **Alius LLC**, with **Alisson Sol**

First-year **master's student** in robotics — **PPGEE, UFMG**

</div>

</div>

<div class="col-span-3">

### Research experience

With **real robots** and **simulated environments**:

- Control
- Navigation
- Localization
- Obstacle avoidance
- Fleet management systems

</div>

</div>

<!--
⏱ 0:30 → 1:30. Who I am, in three lines: the internship at Alius LLC with Alisson Sol, the master's at PPGEE UFMG in robotics, and the research so far — real robots and simulation, control, navigation, localization, obstacle avoidance, fleet management. Then straight into the demo.
-->

---
section: "1 · Demo"
---

# Demo — eight minutes

<div class="grid grid-cols-5 gap-6 mt-2">

<div class="col-span-3 text-xs">

| Min | Action | What the audience sees |
|---|---|---|
| 0:00 | **Compose**: flat plane, OSQP, rate 0.75 → **send to kennel-runs →** | the pipeline diagram; the run folder appears |
| 1:00 | `kennel-demo.sh run` | transfer → launch → **`pass=10 fail=0`** → walk |
| 3:00 | open the Meshcat URL it prints | the Go2 trotting on *this* composition |
| 3:30 | `kennel-demo.sh teleop` → Dashboard → **connect bridge** | `mode · live`, the viewer in the 3D pane, panels moving |
| 4:30 | joystick · change gait · **STAND** | the robot obeys; the velocity plot follows the stick |
| 6:00 | Runs view: today's run vs the HPIPM one → **diff** | real verdicts; only the solver keys differ |
| 7:00 | `teleop stop` · `kennel-demo.sh reset` | back to the frozen baseline in ~90 s, self-checked |

</div>

<div class="col-span-2 text-sm">

### Before the talk
```bash
kennel-demo.sh up
kennel-demo.sh console
kennel-demo.sh status      # green
```
One earlier **HPIPM** run with a `verify.json` in `~/kennel-runs`, so the diff has a partner.


</div>

</div>

<!--
⏱ 1:30 → 9:30. Rate 0.75 rather than 0.5: verify drives the robot for 20 sim-seconds, so a slower rate lengthens the wait on stage. While `run` works, narrate: checksummed at every hop, a run for another pin is refused, the launcher waits for the six-node graph, ten checks, one of them proves the controller loaded *your* solver.
-->

---
layout: section
section: "2 · Problem statement"
---

# 2 · Problem statement

Getting a quadruped controller running is a week of setup before the first trot

<!--
⏱ 9:30 → 11:30. Two slides.
-->

---

# Running a research quadruped controller today

<div class="grid grid-cols-2 gap-8 mt-4">

<div>

### The path, as the upstream README writes it

1. Build the Docker image, start a container
2. Build the ROS 2 workspace — **22 min** on 8 vCPU, when everything is right
3. Open **three terminals**: simulator, leg driver, controller — `sim:=go2` on each
4. Wait "a moment", then publish a gait target by hand
5. Open the 3D viewer and **judge by eye** whether it walks

</div>

<div v-click>

### What actually happens

- Versions drift between laptops — one works, the next does not
- Nobody knows *which revision* they are running
- The written wait is wrong: at the 10-second mark the simulator was still enumerating joints
- No pass/fail — "it looks fine" is the verdict
- **Swapping one block** means hunting a scattered parameter, or editing code and rebuilding — some blocks have no switch at all
- Every new lab member wastes a week

</div>

</div>

<div class="mt-6 p-3 rounded bg-red-900/30 border border-red-700/50 text-sm" v-click>
"I used to budget a full week just to get the stack compiling before I could try a single trot in simulation."
</div>

<!--
The stack is good — it is the DFKI underactuated lab's controller, with a published solver benchmark. The barrier is not the controller, it is the environment around it.

The "still enumerating joints" line is a measured finding from the demo dry run (F8) — the written 10 s was wrong at rate 1.0 and wrong again by 1/rate at any slower rate.
-->

---

# The personas — who pays the setup tax

<div class="grid grid-cols-3 gap-6 mt-6">

<div class="card">

### Alex — the researcher
Works on the controller: gait sequencing, MPC solvers, whole-body control. Every hour on installation is an hour off the research.

</div>

<div class="card" v-click>

### Sofia — day one
Has read about quadruped control; has never built a ROS workspace. Her laptop is whatever it is.

</div>

<div class="card" v-click>

### Marcus — the instructor
Thirty seats on Monday. On Wednesday one is hopelessly modified. Support time is the scarce resource.

</div>

</div>

<div class="mt-8 grid grid-cols-2 gap-8" v-click>

<div class="p-3 rounded bg-green-900/30 border border-green-700/50">

**The non-negotiable:** a walking, simulated Go2 within **about five minutes** of starting — on any machine, the same way, every time.

</div>

<div class="card opacity-80">

**Out of scope, on purpose:** controlling a real robot from a VM; hard real-time inside virtualisation; replacing the upstream stack.

</div>

</div>

<!--
Seven personas in the plan corpus; these three carry the problem. The bottom row is the PRFAQ's promise and its explicit non-claims — say them now, so the demo you just saw is judged against the right bar.
-->

---
layout: section
section: "3 · Previous work"
---

# 3 · Previous work

Two proven pieces, a prototype on mock data, and no product between them

<!--
⏱ 11:30 → 13:30. Two slides.
-->

---

# What existed

<div class="grid grid-cols-2 gap-8 mt-8">

<div class="card">

### 🐕 The quadruped stack
<div class="org">German Research Center for Artificial Intelligence (DFKI)</div>

- ROS 2 controller: gait sequencer → **MPC** → **WBC**, four QP solvers
- Drake simulator + Meshcat viewer, in a Docker image
- ICRA 2025: a published QP solver benchmark
- Research code — three terminals, hand-typed commands
- The pipeline is **one node**: stage choice is scattered parameters

</div>

<div class="card" v-click>

### 🧪 Yuruna
- A VM test harness: reproducible host/guest setups, provisioning **sequences** with asserts, written in YAML
- Drives the hypervisor, boots the guest, runs steps over SSH, gates on 0 FAIL
- Already used to validate appliances — the home ground for a *VM-shaped* product

</div>

</div>

<!--
Two pieces, both proven, neither aimed at this problem: a research controller meant to be driven by hand from three terminals, and a harness for testing VM appliances. The third piece — the console prototype — is on the next slide, because it is where the gap is easiest to see.
-->

---

# What was missing between them

<div class="grid grid-cols-5 gap-6 mt-2">

<div class="col-span-2">

- **One lab**, identical everywhere
- **A pipeline you can take apart**, one block at a time
- **A run you can repeat** and check

<div class="note mt-6 text-sm">
The goal: <b>test every block on its own</b> — and again tomorrow.
</div>

</div>

<div class="col-span-3">
<img src="/img/console-prototype.png" class="shot" />
<div class="caption">the prototype's composer — every stage on scripted data</div>
</div>

</div>

<!--
The third piece, and the gap in one picture: the console prototype, scaffolded from the specification in the first week and served on the host. Every panel is fed by a scripted mock — exactly as the spec asked ("MockDataSource first, bridge later") — so it demonstrated every panel's purpose and connected to nothing.

The layout is the same one you saw live in the demo. That is the point of the DataSource seam.

The three bullets are the whole thesis of the internship, and the box is the sentence to say slowly: a component of a control pipeline is only testable if you can swap it *and* trust that nothing else moved. That needs both halves — a modular pipeline, and an environment that is identical every time.

The bullets in full, to say rather than show: not a week of setup per person, and not a different environment on every laptop · swap the gait sequencer, the MPC, the swing or contact logic, one block at a time, without touching the rest · the same choices give the same configuration, and the verdict is read from the robot's own data.
-->

---
layout: section
section: "4 · The proposal"
---

# 4 · The proposal

A stack whose parts can be substituted one at a time — and a lab that makes each test repeatable

<!--
⏱ 13:30 → 15:30. Two slides: what it is, and how it is used. No implementation here — that is the next section.

Say the two moves plainly: first make the stack modular, so a part of the control pipeline can be substituted without disturbing the rest; then wrap it in a lab that is identical every time, so the substitution is the only thing that changed.
-->

---

# Kennel: a virtual lab in a box

<div class="grid grid-cols-3 gap-6 mt-8">

<div class="card">

### 🖥️ The appliance
A virtual machine, **kennel-vm**, built and frozen once. Inside: the DFKI stack at a **pinned revision**, the Drake simulator, the 3D viewer, and a bridge.

</div>

<div class="card" v-click>

### 🎛️ The console
A browser page on your own computer. Compose an experiment, send it, watch every panel on the **running** robot, drive it with a joystick, compare runs.

</div>

<div class="card" v-click>

### 🐕 The stack
A **modular** stack: the parts of the control pipeline can be **substituted one at a time**, so each can be tested on its own. Kennel **pins** one revision of it and never patches it locally.

</div>

</div>

<div class="mt-10 text-center opacity-80" v-click>
One driver, five verbs: <code>setup · provision</code> once per machine — <code>console · run · teleop</code> every session.
</div>

<!--
Written down before building: a PRFAQ, seven personas, ten verification scenarios (s001 firstwalk … s010 handoff), a master design with the decisions locked. The plan corpus is in plan/ and was the first week of the internship.
-->

---

# How the pieces fit

```mermaid {scale: 0.75}
%%{init: {"flowchart": {"rankSpacing": 25, "nodeSpacing": 30}}}%%
flowchart LR
    subgraph Host["Your computer"]
        B["Browser<br/>Kennel Console"]
        D["One command<br/>kennel-demo.sh"]
    end
    subgraph VM["kennel-vm (the appliance)"]
        S["Pinned controller<br/>+ Drake simulator"]
        M["Meshcat 3D viewer"]
        R["rosbridge"]
    end
    B -- "1. compose &<br/>send a run" --> D
    D -- "2. transfer · launch · verify" --> S
    S --> M
    M -- "3. watch it walk" --> B
    B -- "4. drive it ·<br/>every panel live" --> R
    R --> S
```

<!--
Four arrows, four steps of the daily loop. Step 2 is the part the user never types: the driver checksums the run at every hop, launches the three processes, runs ten health checks, and hands back a walking robot.

Say it rather than show it: the VM lives on your computer; the browser talks to it over a private network. No cloud, no account, nothing to install on the host besides the VM tools. The console never fetches off-host — the suites assert it.
-->

---
layout: section
section: "5 · Development"
---

# 5 · Development

The architecture — what the parts are, and where the seams are

<!--
⏱ 15:30 → 17:30. One slide: the chain a single run travels. The stage plugins and Kennel's parts and seams are in the appendix, after the demo backup — go there only if asked.

If anyone asks about volume rather than shape: 82 commits here and 86 on the fork, 26 pull requests, 35 issues closed of 54, ~16k lines of scripts and sequences, ~10k lines of implementation records, 422 evidence transcripts. Every tool has a record beside it and every record has its transcripts — that is why the second number is as large as the first.
-->

---

# A run, end to end

<div class="chain grid grid-cols-6 gap-3 mt-6 text-xs">

<div class="chip"><b>Compose</b><span>in the browser</span></div>
<div class="chip"><b>run folder</b><span>run.json · 2 YAMLs · commands</span></div>
<div class="chip"><b>transfer</b><span>checksummed · pin checked</span></div>
<div class="chip"><b>launch</b><span>waits for the node graph</span></div>
<div class="chip"><b>verify</b><span>10 checks on the robot's topics</span></div>
<div class="chip"><b>verify.json</b><span>verdict · counters → Runs view</span></div>

</div>

<div class="grid grid-cols-3 gap-6 mt-2 text-sm">

<div class="card">

**Same in, same out.** The same choices produce byte-identical configuration files, in any session, on any machine.

</div>

<div class="card">

**Refused, not adapted.** A run composed against another revision of the stack is rejected at the door, never quietly applied.

</div>

<div class="card">

**A verdict, not an impression.** "It walked" is ten checks on the robot's own topics, filed back into the run folder.

</div>

</div>

<!--
This chain is what makes a component test worth anything: the only difference between two runs is the choice you changed, and the answer comes from the robot rather than from an opinion.

Worth naming as it goes past: the transfer checksums every file at every hop; the launcher waits for the six-node graph rather than for a timer; the report is machine-readable, which is why the Runs view can diff two runs at all.
-->

---
layout: section
section: "6 · Results"
---

# 6 · Results

Measured, not estimated

<!--
⏱ 17:30 → 19:30. Two slides. All figures from recorded transcripts on the reference host, 8 vCPU / 16 GiB guest.
-->

---

# The numbers

<div class="hw grid grid-cols-5 gap-4 mt-1 text-xs">
<div class="card col-span-3"><b>Host</b><dl><dt>CPU</dt><dd>AMD Ryzen 7 8845HS · 8 cores / 16 threads</dd><dt>GPU</dt><dd>Radeon 780M, integrated</dd><dt>RAM</dt><dd>32 GB DDR5 (2 × 16 GB) · 5600 MT/s</dd></dl></div>
<div class="card col-span-2"><b>kennel-vm</b><dl><dt>vCPU</dt><dd>8</dd><dt>RAM</dt><dd>16 GiB</dd><dt>Disk</dt><dd>64 GB</dd></dl></div>
</div>

<div class="grid grid-cols-2 gap-8 mt-3">

<div class="text-sm">

| Step | Wall clock |
|---|---|
| `provision` from nothing → frozen lab | 32–39 min, **once** |
| `run` from a powered-off VM → walking | **1m49s** |
| `run` again, over a running stack | 93 s |
| `launch` alone, after the reliability fix | 43–46 s → **29–35 s** |
| `verify` — ten checks, driving the robot 20 sim-s | 42 s |
| `reset` to the baseline | 1m21s – 1m24s |
| `teleop` — bridge up and reachable | ~10 s |

</div>

<div class="text-sm flex flex-col gap-4" v-click>

<div class="p-3 rounded bg-green-900/30 border border-green-700/50">

### First time
From **a week of setup** per person to **one command**: the lab is provisioned once in **~35 min**, and from then on a powered-off VM is **walking in 1m49s**.

</div>

<div class="p-3 rounded bg-green-900/30 border border-green-700/50">

### Back to baseline
A broken lab no longer means a rebuild: **`reset` returns to the frozen, self-checked baseline in ~1m20s** — the revert itself is 1–2 s.

</div>

</div>

</div>

<!--
Say the two green boxes; the table stays for the reader. The provision figure is the one-time cost; everything a person interacts with afterwards is under two minutes. The negative control before the launcher fix did not reproduce the race — the record says "4 of 4 green", not "the race was caught in the act".

Cut for time, if asked: cold containers 4 of 4 green once the launcher waited for the graph instead of a log line (it had been 2 of 4); the `sleep 15` that fix removed stood in for a wait of 2–5 s. Teleop measured 0.47 m/s against 0.50 commanded, 12.5 m in 27 s, stick released → standstill in about a second. Same composition → byte-identical config files; a run for another pin is refused.

The hardware strip: the host's CPU and guest size are in vm/host-baseline.md and vm/guest-sizing.md. The OS reports 28 GiB of the 32 GB; 16 GiB is the largest round size that host can give the guest without the build swapping.
-->

---

# The console, on the live stack

<div class="grid grid-cols-5 gap-6 mt-2">

<div class="col-span-3">
<img src="/img/dashboard.png" class="shot" />
<div class="caption">mode · live — the viewer framed in the 3D pane, every panel on the running robot</div>
</div>

<div class="col-span-2 text-sm">

- **`mode · live`** — every panel reads the running robot over rosbridge
- It **bins into the mock's 10 Hz** cadence — **no drawing code changed**
- `/quad_state` at **49.5 Hz**; the real-time factor reads back **0.50×**
- **Fall detected at 7.9 s** — by the page and by the suite, independently
- **Real verdicts**: OSQP `completed`, HPIPM `completed`, OSQP on terrain **`fell`**
- **Interventions are real**: *inject* → `/disturb_simulation`, *reset sim* → `/reset_sim`
- Two new suites, **85 + 51 checks**, on recorded-bridge fixtures

</div>

</div>

<!--
This is the slide that answers the prototype: same layout, no recording. The post-mortem live: "WBC missed its 2 ms deadline … early contact FL −240 ms … FALL: body height — z median 0.180 m — controller latched to damping mode".
-->

---
layout: section
section: "7 · Learnings"
---

# 7 · Learnings

<!--
⏱ 19:30 → 21:00. One slide — "What the records taught me" is hidden (hide: true); delete that line to show it again.
-->

---
hide: true
---

# What the records taught me

<div class="mt-4">

| | Learned the hard way |
|---|---|
| **Waits observe, never sleep** | the documented "wait ~10 s" was wrong — and no script had ever relied on it |
| **A check can pass and test the wrong thing** | graph presence as liveness — a killed node lingers 10–20 s |
| **Run the docs, not the scripts** | two dry-run findings appeared only by following the written steps |
| **Measure the negative control first** | the launcher race never reproduced — and the record says so |
| **Write for a reader with no context** | the next person — or agent — has only the repo |

</div>

<!--
Pick two to say aloud: the sleep, and the negative control. The table stays for the reader.

The long versions, if asked: the "wait ~10 s" in the generated commands had never been obeyed by anything — every script waited on observation — and it was found only by running the demo from the written steps. Checks that looked right and tested the wrong thing: graph presence as liveness, `topic echo --once` warning on stdout, a fall rule on a 0.2-s window, a counter mistaken for a solve time. Two of the five dry-run findings exist only because a repo script was used solely where the written step is "run this script". The launcher race did not reproduce on the day: the record says "4 of 4 green after", not "caught in the act".

Cut for time: tools must name what they need — a tool that is right about what it does and silent about what it depends on fails three ways, each with a different message.
-->

---

# What I take with me

<div class="grid grid-cols-3 gap-8 mt-6">

<div>

### On virtual machines
- Ship the **whole environment**, the same lab on every machine
- **Pin every version**, so each result names exactly what it ran on
- Build once, **freeze a snapshot**, reuse it — the long build is paid once
- **Snapshots make mistakes cheap**: break the environment, reset fast

</div>

<div v-click>

### On working backwards
- Start from the **press release and FAQ**, before any code
- **Personas and scenarios** decided what to build — and what to leave out
- Say early **what it is not** — no real robot, no hard real-time
- Scenarios became tests: "done" means the scenario runs

</div>

<div v-click>

### On AI-based development
- Use AI to **search faster**, summarise information and write **first drafts**
- Turn repetitive tasks into **reproducible, efficient workflows**
- **Automate the repetitive work** to spend my time on strategy and decisions

</div>

</div>


<!--
This is the personal slide. The third column, AI-based development: the agents searched the pinned upstream and the records, summarised them, and drafted scripts, records and PR bodies; the verify suites and the driver verbs are the repetitive work made into workflows; what stayed mine was choosing what to build and judging the evidence.

Swap any bullet for your own words before presenting. End on the thank-you and go to the last slide.

The long versions. Virtual machines: the barrier was never the controller, it was the environment around it — so the product is the environment. The appliance pins the stack commit, the OS and the tools; the provision takes 32–39 min once, and the frozen snapshot is what every session starts from and every `reset` returns to.

Working backwards: the first week produced a PRFAQ, seven personas, ten verification scenarios and a design with the decisions locked — before a line of Kennel code. The PRFAQ's non-claims (no real robot from a VM, no hard real-time, not replacing the upstream stack) kept the scope honest. Scenarios s001 firstwalk, disturb and diagnose run today as `kennel-demo.sh scenario …`.
-->

---
layout: end
section: ""
---

# Thank you

<div class="opacity-70 mt-4">
Kennel — github.com/alius-git/kennel
</div>


---
layout: image
image: /img/meshcat-walking.png
backgroundSize: contain
section: "Backup · Demo"
---

<!--
Backup 1 — the Drake Meshcat viewer, opened from the host browser: the Go2 trotting on a console-composed run.
-->

---
layout: image
image: /img/dashboard.png
backgroundSize: contain
---

<!--
Backup 2 — the Dashboard on the live stack: mode · live, the viewer framed in the 3D pane, pipeline health, timeline, counters, plots, the event feed.
-->

---
layout: image
image: /img/runs.png
backgroundSize: contain
---

<!--
Backup 3 — the Runs view reading the host's own run folders: real verdicts, headline counters, and the diff of two runs.
-->

---
layout: two-cols
---

# Backup — driving it

```bash
demo/tools/kennel-demo.sh teleop
```

Dashboard → Interventions → **connect bridge**

- **Joystick** — push to walk, twist to turn; release and it stops
- **Gait picker** — trot, walk, pace, bound, gallop…
- **STAND** — stop and stand, immediately
- **E‑STOP** — emergency damping, the robot sits down

<div class="mt-4 text-sm opacity-70">
Measured: 0.47 m/s against a 0.50 m/s command; 12.5 m in 27 s; released stick → standstill in about a second.
</div>

::right::

<img src="/img/teleop.png" class="shot mt-16" />
<div class="caption">the Interventions row over the bridge; the panels below it were still on the mock when this was taken</div>

---
section: "Appendix"
---

# Every stage a plugin

<div class="grid grid-cols-2 gap-8 mt-4 text-sm">

<div>

### Before
The algorithms were compiled into the controller node. A stage was chosen — when it could be chosen at all — through a parameter that looked like any other.

### After
Six stages behind documented interfaces, each one a plugin:

- **`<stage>.type` in the YAML picks the implementation** — one uniform key for `gs` · `mpc` · `slc` · `wbc` · `contact_logic` · `model_adaptation`
- a loader that **fails fast** on a type it cannot resolve
- **per-stage overlays** for parameters, with shipped examples

</div>

<div v-click>

### What it buys
- The contact FSM became a stage of its own; the bio-inspired gait sequencer became a selectable plugin
- An **out-of-package plugin** — a pass-through swing-leg controller — loads through the production loader: a new stage needs no fork of the controller
- `adding_a_stage.md`, so the next person has a path
- Suites for the contract, the loader, the overlays, and the selection every shipped config makes


</div>

</div>

<!--
This is the half of the internship that happens inside the stack, and it is why "test every little component" is a sentence I am allowed to say.

The honest bit, if asked: this landed in the fork on the modular branch. The appliance pins the commit every number in this deck was measured against, which predates it — so the demo composed the MPC, and the other five stages were shown fixed rather than pretended. Repinning is scenario s009, designed for exactly this, and the composer needs no change to gain them: the schema already has an impl per stage.
-->

---

# How Kennel is built

<div class="grid grid-cols-2 gap-8 mt-4 text-sm">

<div>

### The parts

- **On the host** — one HTML file, no build step and no off-host fetch; `serve.py` beside it, which reports the guest's URLs and writes run folders; and `kennel-demo.sh`, the **only** thing in the system that starts a process
- **On the guest** — an appliance built by Yuruna sequences and frozen as a snapshot; the pinned stack in a container; the Drake viewer on `:7000` and rosbridge on `:9090`

</div>

<div v-click>

### The seams

| Seam | What it lets you change |
|---|---|
| `<stage>.type` | one part of the control pipeline |
| the **run folder** | the whole experiment — it is the only contract between browser and stack |
| `DataSource` | where the panels' data comes from: mock or live, same panels |
| `verify.json` | nothing — it is the only thing allowed to say a run worked |

<div class="note mt-3">
The line that never moves: the console <b>configures and observes</b>. It never starts or stops a process.
</div>

</div>

</div>

<!--
Three seams and a rule. Each seam is a place where one thing can be replaced without the rest noticing — which is the whole point of the internship in one slide.

The rule at the bottom is why the driver exists: a browser that could start processes would be a browser you have to trust with the machine.
-->
