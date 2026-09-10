# Kennel — Plan J: the harness (#23 · #24 · #25), one PR

Steps 17–19 of milestone [*Finish the system*](https://github.com/alius-git/kennel/milestone/2),
written like plans A–I (`next-goals.md`, `teleop-joystick.md`, `reliability.md`,
`console-live.md`, `teleop-hardened.md`, `two-scenarios.md`, `user-surface.md`)
so an agent can implement them on one branch without re-deriving the repo.
Everything in §0 was checked on **2026-09-09** with the commands shown; the
probes were read-only or ran against a scratch copy, and the guest was left as
found.

| Step | Issue | One line |
|---|---|---|
| 17 | [#23](https://github.com/alius-git/kennel/issues/23) | the repo becomes a **Yuruna project**: `test/` holds the six sequences, the guest scripts and `test.runner.yml`, in the layout `yuruna-project` uses; the driver **clones the project** into the framework's `project/` instead of copying files into its tree; `setup` writes `repositories.projectUrl`; the copy-into-clone bypass of `vm/provisioning.md` §4.2 retires |
| 18 | [#24](https://github.com/alius-git/kennel/issues/24) | `workload.guest.ubuntu.server.24.kennel.mvp.ssh` — revert to the baseline, stage a **checked-in, console-exported fixture** from the project tree, apply it, launch the three stack processes from its `commands.txt`, assert *healthy and walking on the composed solver* with the #14 recipe, keep the logs, stop the stack; the recipe's `1`/`2` exit split becomes two named steps; a no-VM suite group proves the fixture is what the console emits; `kennel-demo.sh mvp` runs it warm in ~4 min |
| 19 | [#25](https://github.com/alius-git/kennel/issues/25) | `kennel-demo.sh cycle` — one full Yuruna cycle from cold, exactly as the runner runs it (`Invoke-TestProject.ps1`), evidence collected; **two consecutive green cycles** against the kennel repo, then one cycle of the eternal runner; the cycle time recorded; `test/harness.md` is the record |

**One branch, one PR, closing all three.** The maintainer's call for this
step, as for E–I; the milestone's default is one issue per PR and the PR body
says so (§6.1). The three are one thing built in order: a cycle cannot run
until the project tree exists (#23 → `test.runner.yml`), the runner file has
nothing to name until the sequence exists (#24), and "green twice" is only a
statement about the previous two (#25). The order is fixed: the move and the
driver's clone-not-copy first (proven by a `reset` through the project tree),
then the fixture and the suite group that guards it, then the sequence and its
verb, then the cycle verb, then the record. Budget: about **three hours of
guest time** (§4) — two `mvp` runs, the negative controls, two cold cycles of
~40 min, one runner cycle of ~40 min, one `reset` — and the rest is editing.
Branch from **`origin/main` at `b7063b6`** (the #83 merge); local `main` is
seven commits behind it.

---

## 0. Ground truth the implementer must know

**Repo.** `origin/main` is `b7063b6` (*Merge pull request #83*, 2026-09-09).
Local `main` is at `1c9a2ab`; the checked-out branch is `console/72-user-surface`
(merged). **The working tree carries uncommitted deck work** — `M slides/slides.md`
and five untracked files under `slides/` — that is the maintainer's and is not
this PR's: branch from `origin/main`, never `git add -A`, stage files by name.
The repo is **private** (`gh repo view alius-git/kennel` → `PRIVATE`, default
branch `main`); `.git` is 20 MB; the only tracked directory named `test` is
`vm/test/` (five `.yml` sequences and two host-side checks,
`verify-meshcat-host.sh` / `verify-bridge-host.sh`). `dfki-quad/` and
`slides/node_modules/` are gitignored, so a fresh clone carries neither.

**Host.** Yuruna `2026.08.04` (`f0d4d3b1`) at `~/git/yuruna` with the three
`vm/patches/` applied and the five kennel sequences + two guest scripts copied
into its tree (all untracked there, by design — `git status` in the clone shows
exactly those plus `test/test.config.yml*`). `project/` in the clone is the
stock **yuruna-project** at `de988ed9`. `test/test.config.yml` differs from the
template only by `guestSequence: [guest.ubuntu.server.24]`;
`repositories.projectUrl` is `https://github.com/alissonsol/yuruna-project`,
`vmStart.cleanupVmNamePrefixes: []`, `testCycle.stepTimeoutSeconds: 2700`,
`cycleDelaySeconds: 300`, `warmResume.enabled: true`, `logLevel: Information`.
`powershell-yaml 0.4.12` is installed. The status service is up on `:8080`
(`server.pid` in `test/status/runtime/`; `curl localhost:8080/status/` → 200).
`Test-Config.ps1 -SkipSend` today: **34 PASS / 4 WARN / 0 FAIL**, the sequence
scan reading 33 files across 5 dirs (`test/sequences` + four yuruna-project
`test/` dirs). The host clock is **480 s slow** (`chronyc tracking`) — a WARN,
not a gate, and the operator step `sudo chronyc makestep` is the maintainer's
(`vm/host-baseline.md` §2). **The host's git credential works
non-interactively for the private repo**: `GIT_TERMINAL_PROMPT=0 git ls-remote
--exit-code https://github.com/alius-git/kennel.git HEAD` → exit 0, via
`credential.helper = !/usr/bin/gh auth git-credential` (`gh auth status`:
account `thalesasoares`, scope `repo`). Nothing about `ghToken` is needed on
this host; §1.4 says what a host without `gh` needs.

**Guest.** libvirt domain `kennel-vm-baseline` **running** at `192.168.122.32`
(lease hostname `kennel-vm`, user `yuuser24`, key
`~/git/yuruna/test/status/ssh/yuruna_ed25519`), snapshot `kennel-vm-baseline`
of 2026-08-30 with its manifest sidecar; a second, unrelated domain `ub26_guest`
is shut off. `kennel-demo.sh status` (read-only): clone at the pin, container
running, applied run `run-20260909T184456Z` (the all-stock composition
`scenario firstwalk` left behind), **Meshcat reachable** (the stack is up),
bridge down. `/etc/yuruna/host.env` on the guest carries
`YURUNA_STATUS_SERVICE_IP=192.168.122.1`, `PORT=8080`, and the framework's
GitHub repo/ref; `~/yuruna/project` on the guest is a yuruna-project tarball
extract (no `.git`) from provisioning time; `wget` and `curl` are present. Left
exactly as found; §4's first live step reverts the disk anyway, and the last
row puts the guest back at the baseline.

### 0.1 What Yuruna 2026.08.04 does with a project — read from the code, then probed

Every claim here was checked in `~/git/yuruna`; the file:line is the place to
re-read before deviating.

- **Discovery is "every directory named `test` under `<RepoRoot>/project/`".**
  `Test.SequenceResolve.psm1:162–176` (`Get-ProjectFlatTestSearchDir`) recurses
  the project clone for directories *named* `test`; a sequence is found by exact
  file name in any of them, **project first, then `test/sequences/`**
  (`Resolve-SequencePath`, `:231–280`). Two *project* files with the same name
  are a `PlannerFatal`; a project file shadowing a framework file is silent and
  intended. Sequences sit directly in the `test/` dir (flat) — not under a
  `sequences/` subfolder. `_snippets.yml` in a project `test/` dir overrides
  framework snippets by name.
- **A cycle's top-levels come from `<RepoRoot>/project/test/test.runner.yml`**
  (`Test.SequencePlanner.psm1:56–59`, `Get-CycleConfigPath`), a map with a
  `sequences:` list (names, extension optional) and an optional `testSets:`
  list. It is read by the *cycle* entry points (`Invoke-TestRunner.ps1`,
  `Invoke-TestProject.ps1`) — `Invoke-TestSequence.ps1` takes the name on the
  command line and never reads it. The runner walks each top-level's `resource:`
  chain; `start.*` entries run in its Start-GuestOS step, the rest in
  Start-GuestWorkload (`docs/test-harness.md` §Per-cycle dispatch).
  `Read-SequenceFile` on yuruna-project's own `test/test.runner.yml` loads it as
  `sequences,testSets` without error, and `Test-Config`'s per-dir scan
  (`Test-Config.ps1:991`) excludes only `_snippets.yml`/`actions.yml` — so a
  runner file in a discovered `test/` dir is tolerated (it is the stock layout).
- **The project clone is wiped and re-cloned from `repositories.projectUrl` at
  every cycle** (`Test.HostGit.psm1:783`, `Update-ProjectClone`; the docstring:
  "so previous cycle output cannot leak forward"). `Invoke-TestSequence.ps1`
  does the same unless `-NoProjectClone`. `Invoke-TestProject.ps1` always does
  (it refuses an empty `projectUrl`). A `file://` URL is legitimate
  (`CONTRIBUTING.md:115–128`; `Test-Config.ps1:598–612` PASSes it and WARNs
  that only the host can resolve it).
- **The guest fetches project files through the host, never from GitHub.**
  `sshFetchAndExecute` runs `/usr/local/lib/yuruna/fetch-and-execute.sh <path>`
  on the guest; the script resolves `<path>` against
  `http://<status-service>/yuruna-repo/<path>` — the framework's **working
  tree**, which contains `project/` (`automation/fetch-and-execute.sh`,
  `resolve_fetch_source`/`build_fetch_url`; the website example's step is
  literally `fetch-and-execute.sh project/example/website/test/ubuntu.server.24/…sh`).
  The `/yuruna-repo/` route's deny-list (`Start-StatusService.ps1:2638–2670`)
  blocks secrets, `.git/`, and `test/test.config.yml`; everything else under
  the repo root is served, `project/…` included, any file type. The GitHub
  fallback is taken only when the host is unreachable, and **for a private
  project it 404s without a token** (the script says so on stderr) — so the
  status service is the only source, and every entry point that runs a
  sequence starts it. The handler types a digest ahead of the command
  (`Test.SequenceHandler.psm1`, `Get-FetchExecuteEnvPrefix`): it regex-matches
  `fetch-and-execute\.sh\s+(\S+)` anywhere on the line — **an env prefix before
  the script is fine** — hashes `<RepoRoot>/<path>` (so `project/…` paths
  resolve under the clone), and sets `EXEC_REQUIRE_SHA256=1`; a path that does
  not exist under the served root fails **closed**. The yellow *"differs from
  HEAD"* warning (`:931`) is the working-tree-vs-HEAD comparison of that path —
  for a fresh clone the two are identical, which is how the F5 warning of
  `provisioning.md` §4.2 retires.
- **The guest gets the whole project tree once, at provisioning.**
  `guest/ubuntu.server.24/ubuntu.server.24.update.sh:319–349`: it downloads
  `/yuruna-project-archive.tar.gz` from the host (a `git archive` of
  `<RepoRoot>/project` HEAD — no credential involved) and only if that 404s does
  it `git clone $PROJECT_URL` on the guest, **exiting 1 after three failed
  attempts**. With a private `projectUrl` the guest-side clone can only fail, so
  the host tarball must be served during the start sequence — it is, whenever
  `project/` is a git clone. That tree is frozen into the baseline snapshot, so
  the MVP sequence must never read it (§2.2 fetches fresh).
- **`sshExec` keeps output only on failure at `Information` level.**
  `Test.SequenceHandler.psm1:1164–1185`: output goes to `Write-Debug`; on a
  non-zero exit it is `Write-Warning`ed into the transcript (unless
  `allowFailure`). `sshFetchAndExecute` (`:1186–1205`) is the same shape. The
  default per-step timeout is `vmCommunication.timeoutSeconds` = **180 s**.
  The command is passed as one ssh argument (`Test.Ssh.psm1`, `Invoke-GuestSsh`:
  `ssh -i key -o BatchMode=yes … user@ip '<command>'`), so `VAR=x cmd`,
  `$(…)`, `$HOME` and `||` all work — only `${name}` is Yuruna's (the
  CLAUDE.md rule).
- **The cycle runner has no warm path and follows the mid-chain rename.**
  `requiresSnapshot` is honoured only by `Invoke-TestSequence.ps1`
  (`Test.SequenceRunner.psm1:131–201`); `Test.RunnerInnerLoop.psm1` never reads
  it — a cycle always `New-VM`s `test-guest.ubuntu.server.24-01`
  (`Get-TestVMName`, `:624`) and runs the full chain. The rename that
  `saveDiskSnapshot` performs is picked up between chain entries by
  `Invoke-GuestSequenceList` (`Test.SequenceEngine.psm1:1171–1250`,
  `Get-SequenceFinishedVMName`), "one shared mechanism" with the chain runner —
  so a cycle's later entries target `kennel-vm-baseline`, as `provision`'s do.
- **The sweep prefixes are the same at cycle start and cycle end.**
  `Resolve-CleanupVmNamePrefix` (`Test.Config.psm1:395–440`) = `test-` +
  `vmStart.cleanupVmNamePrefixes`; `Remove-CycleStartOrphanVM` (`:2524`) and
  `Remove-CycleTeardownOrphanVM` (`:2874`) both receive it. Consequences, both
  load-bearing for §3: with the key **unset**, a cycle on a host that already
  holds `kennel-vm-baseline` builds `test-guest…-01` beside it and **fails at
  the rename** (a domain of that name exists); with the key **set**, the
  baseline is destroyed at cycle start *and again at cycle end*, so after any
  cycle the host has no guest until the next `provision`. Yuruna's own comment
  on the key names Kennel's case exactly ("a snapshot id becomes the VM name").
- **`Invoke-TestProject.ps1` is one cycle "exactly as Invoke-TestRunner would"**
  (its `.SYNOPSIS`; it calls the same `Update-ProjectClone` and spawns the same
  inner with `-NoProjectClone -NoGitPull`, records a regular cycle in
  `status.json`, and exits with the inner's code — `0`/`1`). It requires a
  non-empty `projectUrl` and refuses if a runner owns `runner.pid`.
  **`Test-Project.ps1`, the name in issue #25, does not exist** at this release
  — the same kind of drift as `keystrokeMechanism` in #8.
- **`Invoke-TestRunner.ps1` cannot be stopped by a signal from a script.**
  Probed: `kill -INT` on a non-interactive `pwsh` left it running (the probe
  process had to be `TERM`ed). The outer registers `[Console]::CancelKeyPress`
  (`Test.Prelude.psm1`, `Register-EntryPointCancelHandler`), which a terminal
  Ctrl+C raises and a `kill -INT` does not. Its own docstring: "Stops only on
  Ctrl+C". `-NoGitPull` skips the outer's `git pull`, which on this clone
  (detached at the tag, three patches applied) would fail or move the tree.
- **A cycle leaves, on the host:** `test/status/log/<NNNNNN.date.time.hostid>/`
  with the HTML transcript, `cycle.events.ndjson` (`cycle_start`, `step_end`…,
  `warm_resume`, `cycle_end`) and `manifest.json`; `test/status/runtime/status.json`
  (`guests[].vmName/topLevel/status/steps`, `history[].totalDurationSeconds`);
  `test/status/perf/cycles/<stamp>__<id>.jsonl` (one row per step, keyed by
  `sequenceGuid`). Cycle 35 on this host (a `reset` via `Invoke-TestSequence`,
  71 s) is the shape to expect.

### 0.2 The probe: a fresh clone of this repo is already a project

Run against a scratch root (`<scratch>/project` = `git clone
file:///home/thales/kennel`, `<scratch>/test/sequences` → the framework's),
read-only:

```
$ pwsh -NoProfile -Command '
    Import-Module ./test/modules/Test.SequenceResolve.psm1 -Force
    Import-Module ./test/modules/Test.SequencePlanner.psm1 -Force
    Get-ProjectFlatTestSearchDir -RepoRoot <scratch>
    Resolve-SequencePath -SequencesDir <scratch>/test/sequences -Name workload.guest.ubuntu.server.24.kennel.reset.ssh -HostType host.ubuntu.kvm -RepoRoot <scratch>
    (Resolve-NamedSequenceChain -SequenceName workload.guest.ubuntu.server.24.kennel.reset.ssh -SequencesDir <scratch>/test/sequences -RepoRoot <scratch> -HostType host.ubuntu.kvm).fullChain
    try { Get-CycleConfig -RepoRoot <scratch> } catch { $_.Exception.Message }'

<scratch>/project/vm/test
<scratch>/project/vm/test/workload.guest.ubuntu.server.24.kennel.reset.ssh.yml
start.guest.ubuntu.server.24.kennel.ssh
workload.guest.ubuntu.server.24.kennel.ssh
workload.guest.ubuntu.server.24.kennel.stack.ssh
workload.guest.ubuntu.server.24.kennel.baseline.ssh
workload.guest.ubuntu.server.24.kennel.reset.ssh
Runner config not found: <scratch>/project/test/test.runner.yml (set test.config.yml's repositories.projectUrl, or place the file under <repo>/project/test/)
```

So: `vm/test/` is discovered as it stands, the project copy wins over the
framework copy, the chain resolves, and the one thing a *cycle* is missing is
`project/test/test.runner.yml`. That last line is §4's **negative control**,
reproducible in seconds with no VM.

### 0.3 The pieces #24 reuses, and what the driver stages for each phase

| Phase (`kennel-demo.sh`) | What goes to the guest | How it is run | Exit codes |
|---|---|---|---|
| `transfer` | `stack/transfer/guest-apply-config.sh` → `~/kennel-staging/`; the run folder → `~/kennel-staging/runs/<run>/` | `KENNEL_MODE=apply KENNEL_RUN=<run> KENNEL_PIN=<pin> [KENNEL_EXPECT_SIM_SHA= KENNEL_EXPECT_CTRL_SHA=] ~/kennel-staging/guest-apply-config.sh` — the contract `stack/transfer.md` §3 wrote *for #24* | `0` placed and checksummed · `1` bytes wrong · `2` could not look · `3` pin mismatch |
| `launch` | `stack/known-good/tools/k13-stop.sh` → `docker cp` to `/root/k13-stop.sh` in the container (else the launcher's "stop anything running" is a silent no-op — `do_launch`'s comment); `stack/composed-run/tools/p21-launch-from-commands.sh` → `/tmp` | `/tmp/p21-launch-from-commands.sh` reads `~/kennel-staging/runs/$(cat ~/kennel-staging/current-run)/commands.txt`, starts three (or four) shells detached, waits on the graph; logs `/tmp/p21-{sim,legdrv,ctrl}.log` **in the container**; measured 35 s | `0` up · `1` a stage never came up (it tails the log) · `2` infra |
| `verify` | `stack/verify/kennel-verify.sh` → `/tmp` | `/tmp/kennel-verify.sh --expect-solver <S> --controller-log /tmp/p21-ctrl.log`; writes `/tmp/kennel-verify/report.{txt,json}` on the guest; measured 33 s | `0` · `1` an assert failed · `2` could not look (`stack/verify.md` §1 — "the 1/2 split is for #24") |
| `down` | `k13-stop.sh` again | `docker exec dfki_quad bash /root/k13-stop.sh` (bounded, reaps by exact name) | — |

`kennel-demo.sh run` from a reset guest measured **77 s** (`demo/evidence/s004-disturb/01-run.txt`:
transfer 2, launch 35, verify 33, walk 7). The cold chain measured **35m25s,
45 steps** (`vm/snapshot.md` §5: start 8m23s, sizing 13 s, stack **25m48s**,
baseline 1m35s, reset 1m11s); `reset` alone **1m21s**, of which the
launchable-simulator proof is 56 s; a revert → sshd is 10–11 s. So the MVP
sequence should run **~4 min warm** (revert + sshd 15 s, stage ~5 s, apply 2 s,
launch 35 s, verify 33 s, record + stop ~15 s, plus a 45-s simulator proof it
does *not* repeat) and a cold cycle **~40 min**. The `testCycle.stepTimeoutSeconds:
2700` watchdog leaves the 26-minute provisioning step ~19 min of headroom; the
sequence's own `timeoutSeconds: 14400` on that step is not what bounds it in a
cycle, and the record should say so.

### 0.4 What the suites assert today, so nothing is reordered

Nine console suites, 594 checks, all no-VM (`PR #83`): serve 17, scope 78,
generate 57, export 72, send 43, teleop 96, dashboard 85, runs 84, guides 62.
`verify-runs.py` is the one this plan appends to: its group 1 composes three
runs through a real `serve.py` into a temporary out dir and files fixture
reports beside them; group 7 (#72) loads each shipped preset, sends, and loads
the written `run.json` back through the Runs table's `load` control
(`__loadRow`), comparing panes byte for byte. Group 8 (§2.1) reuses exactly
those helpers. Nothing existing is modified; the suites click by text order.

---

## 1. #23 — the repo is a Yuruna project

### 1.1 The move

`git mv`, so history follows. Names do not change — a sequence's file name is
its lookup key (`resource:` chains and `test.runner.yml` name it) and its
`sequenceGuid` is its perf identity; only the directory moves.

| From | To |
|---|---|
| `vm/test/start.guest.ubuntu.server.24.kennel.ssh.yml` | `test/start.guest.ubuntu.server.24.kennel.ssh.yml` |
| `vm/test/workload.guest.ubuntu.server.24.kennel.ssh.yml` | `test/workload.guest.ubuntu.server.24.kennel.ssh.yml` |
| `vm/test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml` | `test/…kennel.stack.ssh.yml` |
| `vm/test/workload.guest.ubuntu.server.24.kennel.baseline.ssh.yml` | `test/…kennel.baseline.ssh.yml` |
| `vm/test/workload.guest.ubuntu.server.24.kennel.reset.ssh.yml` | `test/…kennel.reset.ssh.yml` |
| `vm/guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh` | `test/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh` |
| `vm/guest/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh` | `test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh` |

`test/ubuntu.server.24/` is yuruna-project's convention for a project's guest
scripts (`example/website/test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh`).
`vm/test/verify-meshcat-host.sh` and `verify-bridge-host.sh` **stay**: they are
host-side reachability checks the driver, `scenario-lib.sh` and
`verify-teleop-live.sh` call by that path (12 + 2 + 3 references), not
sequences; a directory named `test` with no `.yml` in it is inert to discovery
(§0.1). Moving them is a housekeeping follow-up, not this PR. `vm/` keeps its
records and `vm/patches/`; `vm/guest/` disappears.

Inside the moved files: the `$schema` comment becomes
`# yaml-language-server: $schema=../../yuruna/test/schemas/sequence.schema.yml`
(the sibling-clone convention yuruna-project uses; editor-only), and the two
`sshFetchAndExecute` paths become project paths —
`project/test/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh` (twice, in the
stack sequence) and `project/test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh`
(baseline). The start sequence keeps
`guest/ubuntu.server.24/ubuntu.server.24.update.sh` — that is the framework's
script. `sequenceRevision` is not bumped for a path change (the schema says
bump for steps added/removed/reordered). The comment block at the top of each
moved file that says "copied to `test/sequences/` in the Yuruna clone" is
rewritten to say where the file is now discovered from.

### 1.2 The new files

```
test/
├── README.md                      # the operator page: how to point Yuruna at this repo (§1.3)
├── harness.md                     # the implementation record of #23/#24/#25 (§5)
├── test.runner.yml                # the cycle's top-level(s) (§1.3)
├── start.guest.ubuntu.server.24.kennel.ssh.yml
├── workload.guest.ubuntu.server.24.kennel.ssh.yml
├── workload.guest.ubuntu.server.24.kennel.stack.ssh.yml
├── workload.guest.ubuntu.server.24.kennel.baseline.ssh.yml
├── workload.guest.ubuntu.server.24.kennel.reset.ssh.yml
├── workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml     # #24, §2.3
├── ubuntu.server.24/
│   ├── ubuntu.server.24.dfki-quad.sh
│   ├── ubuntu.server.24.kennel-baseline-prep.sh
│   └── ubuntu.server.24.kennel-mvp-stage.sh               # #24, §2.2
├── fixtures/
│   └── run-<stamp>/                                        # #24, §2.1 — four files, console-exported, never edited
└── evidence/                                               # #25, §3.3
```

`test/test.runner.yml`, in yuruna-project's shape (comments are the point —
that file is read by an operator before it is read by the planner):

```yaml
# Per-cycle runner definition for the kennel repo as a Yuruna project.
# The runner reads this at cycle start (project/test/test.runner.yml in the
# framework clone) to know which top-level sequences to run. Each top-level's
# `resource:` chain is walked: the MVP sequence below pulls in, in order,
# start.guest.ubuntu.server.24.kennel.ssh -> ...kennel.ssh (sizing) ->
# ...kennel.stack.ssh (provision) -> ...kennel.baseline.ssh (snapshot) ->
# ...kennel.reset.ssh (revert + prove) -> ...kennel.mvp.ssh. A cold cycle is
# the whole chain (~40 min); Invoke-TestSequence.ps1 on a host that already
# holds the baseline runs only the top-level (~4 min). See test/README.md.
sequences:
  - workload.guest.ubuntu.server.24.kennel.mvp.ssh

testSets:
  - name: mvp
    displayName: MVP — provision, configure, launch, assert
    description: The full chain from a stock guest to the robot walking on a composed config.
    sequences:
      - workload.guest.ubuntu.server.24.kennel.mvp.ssh
  - name: baseline
    displayName: Baseline only
    description: Provision and freeze the appliance; prove the revert. No stack run.
    sequences:
      - workload.guest.ubuntu.server.24.kennel.reset.ssh
```

### 1.3 `test/README.md` — what an operator needs to point Yuruna here

Short, in the voice of `demo/runbook.md`. It must state, with the exact keys:

- **The layout** above and the rule it follows (every `test/` dir is a
  sequence dir; `test.runner.yml` names the top-levels; guest scripts under
  `test/<guest>/`; project files reach the guest as `project/<path>` through the
  host's status service).
- **`test/test.config.yml` on the host** (the operator's file, gitignored
  upstream — `kennel-demo.sh setup` creates it and sets the first two):

  ```yaml
  guestSequence:
  - guest.ubuntu.server.24
  repositories:
    projectUrl: https://github.com/alius-git/kennel   # or file:///path/to/your/checkout (dev host, §1.5)
  vmStart:
    cleanupVmNamePrefixes: [kennel-vm-baseline]        # CI host ONLY -- see below
  ```

  and the two host roles: a **CI host** sets `cleanupVmNamePrefixes` so every
  cycle rebuilds the baseline from cold and the runner never collides on the
  rename (Yuruna's documented knob for "a snapshot id becomes the VM name");
  it accepts that the baseline is swept at cycle end too. A **dev host** — this
  one — leaves it unset and runs cycles through `kennel-demo.sh cycle`, which
  sweeps the baseline itself before each cycle and leaves the rebuilt one
  standing (§3.1). Both are stated because §0.1 measured what each does.
- **The private repo.** The host needs a non-interactive git credential for
  `projectUrl` — `gh auth login` installs one (`credential.helper = !gh auth
  git-credential`), or `repositories.ghToken` with a fine-grained read-only
  token (Yuruna's own documented path, `docs/definition.md` "Private
  repositories"). The guest needs nothing: it takes the project tree as a
  tarball from the host, and every project file it fetches comes through the
  host's status service. The GitHub fallback of `fetch-and-execute.sh` cannot
  serve a private repo, so a host whose status service is down fails a step
  closed — by design.
- **How to run**: `pwsh test/Test-Config.ps1 -SkipSend` (0 FAIL, no finding
  naming a kennel file), `pwsh test/Invoke-TestProject.ps1` (one cycle),
  `pwsh test/Invoke-TestRunner.ps1 -NoGitPull` (the loop; Ctrl+C from the
  terminal is the only stop), and the two driver verbs `mvp` and `cycle`.
  `Invoke-TestSequence.ps1 -SequenceName <name>` for one sequence with its
  chain. Note that `Test-Project.ps1` in issue #25 is `Invoke-TestProject.ps1`
  at this release.
- **What the fixture is** and how it is regenerated (§2.1) — never edited.

### 1.4 The driver: clone the project, stop copying files

`demo/tools/kennel-demo.sh` (header comment, knobs, `usage`, and the functions
named):

- **New knob** `KENNEL_PROJECT_URL`, default `file://$REPO_ROOT`. What
  `provision`, `reset` and `mvp` run is **the committed HEAD of this checkout**,
  cloned fresh into `$YURUNA_DIR/project` — the same semantics Yuruna gives a
  project (a clone, never a working tree), applied to the branch you are on.
  Uncommitted edits under `test/` do not run; the verb says so.
- `install_kennel_files()` → **`install_kennel_project()`**:
  `rm -rf "$YURUNA_DIR/project"` (refuse unless the path ends in `/project`,
  the same guard `Update-ProjectClone` has), `git clone -q "$PROJECT_URL"
  "$YURUNA_DIR/project"`, print `project  <short sha>  <subject>`; if
  `PROJECT_URL` is the `file://` of `$REPO_ROOT` and `git -C "$REPO_ROOT" status
  --porcelain -- test/` is non-empty, `warn` that those edits are not in the
  clone. Return 2 on a failed clone with the URL in the message. Called where
  `install_kennel_files` was (`provision`, `reset`, `setup` item 8) and by
  `mvp`/`cycle`.
- Every `pwsh test/Invoke-TestSequence.ps1 -SequenceName "$SEQUENCE"` gains
  **`-NoProjectClone`** (`provision`, `reset`, `mvp`): the clone was just made
  from the URL the operator chose; letting Yuruna re-clone from
  `test.config.yml` would silently run *main* instead.
- `yuruna_unexpected_changes()` stops listing `test/sequences/*.kennel*.yml`
  and `guest/ubuntu.server.24/*.sh` as expected — they are retired. `setup`
  item 8 ("kennel files") becomes **"project clone"**: `did` when it removes
  retired copies still present in the clone (they are untracked there; remove
  by the exact names this repo used to ship, nothing else) and/or creates the
  clone; `ok` when the clone already exists and its HEAD is `$REPO_ROOT`'s
  HEAD. **Removing the copies is required, not tidiness**: project-first
  resolution would ignore them, but `Test-Config`'s users scan and sequence
  scan read `test/sequences/` too, and a stale copy there is a second
  definition of a sequence that has moved on.
- `setup` item 5 (`test.config`) — when it **creates** the file from the
  template it now also sets `repositories.projectUrl` to this repo's origin
  URL (`git -C "$REPO_ROOT" remote get-url origin`, `.git` suffix stripped)
  with the same awk-style line replacement it uses for `guestSequence`. When
  the file **exists**: `ok` if `projectUrl` is that URL or `file://$REPO_ROOT`
  (report which — the latter as `info  test.config  projectUrl is this checkout
  (dev mode)`); otherwise `needs you` with the line to set and the two choices.
  Never writes `cleanupVmNamePrefixes` (§1.3: that is the CI-host choice).
- `do_snapshot`: `guest_stage test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh`.
- The header's knob table and `usage` gain `mvp`, `cycle`, `KENNEL_PROJECT_URL`,
  `KENNEL_CYCLES`, `KENNEL_HARNESS_EVIDENCE` (§2.4, §3.1).

`stack/pin.lock`'s "Where this pin is enforced" paragraph names
`vm/guest/…dfki-quad.sh` and `vm/test/…stack.ssh.yml` — update both paths (a
comment in a data file, not a record). `CLAUDE.md`'s rule about Yuruna
`command:` strings cites `vm/test/workload…stack.ssh.yml` line 89 — update the
path; its repo table gains a `test/` row and the `vm/` row loses "the Yuruna
sequences under `vm/test/`".

### 1.5 Acceptance for #23, as it will be measured

1. The planner probe of §0.2 against a clone of the branch: discovery lists
   `project/test` (and `project/vm/test`, inert), the chain resolves from
   `project/test/`, and `Get-CycleConfig` returns `sequences:
   [workload.guest.ubuntu.server.24.kennel.mvp.ssh]`. The same probe against
   `origin/main` is the negative control (§0.2's last line).
2. `pwsh test/Test-Config.ps1 -SkipSend` with `projectUrl` pointing at the
   checkout: 0 FAIL, the sequence scan now reads the six kennel files from
   `project/test`, the users scan lists `project/test`, and **no finding names
   a kennel file**. (The `file://` WARN about guest fallback is expected and
   explained in the record.)
3. `kennel-demo.sh reset` — the existing warm path — runs green **through the
   project tree**: the transcript's `sshFetchAndExecute` lines show
   `project/test/ubuntu.server.24/…` paths, the digest line reads `integrity:
   sha256 verified`, and the F5 warning ("differs from HEAD") is **absent** —
   the retirement `provisioning.md` §4.2 promised. `git -C ~/git/yuruna status
   --short` afterwards shows the three patched files and `test/test.config.yml*`
   only.

---

## 2. #24 — the MVP sequence

### 2.1 The fixture: `test/fixtures/run-<stamp>/`

**What it is.** One run folder — `simulator_params_go2.yaml`,
`mit_controller_sim_go2.yaml`, `commands.txt`, `run.json` — exported by the
console for the driver's **default composition**: flat plane · `simulator_realtime_rate`
**0.75** · `publish_quad_state` on · `PARTIAL_CONDENSING_OSQP` · `SPEED` ·
condensed 5 · disturbances off. That is what every `kennel-demo.sh all` in the
records ran (`vm/snapshot.md` §5 evidence 07/13, `demo/dry-run.md`) — `pass=10
fail=0` each time — and it is non-stock on **two** observables (the solver,
which check 10 asserts, and the rate, which check 2 reports), so "the composed
value took effect" is a real assertion, not a stock read-back. Not a preset,
on purpose: a preset is page data that may change; the fixture must not.

**How it is made** (once, on the branch; the command goes in the record and
in `test/README.md`):

```bash
demo/tools/kennel-demo.sh compose        # no knobs: OSQP / 0.75, through the real console
cp -r ~/kennel-runs/<the folder it printed> test/fixtures/
```

`compose` drives the real page in a throwaway Chrome profile and `send`s the
folder through `serve.py` — the bytes are the emitters' (`export.md` §2.1).
**Never hand-edit a fixture file**; regenerate with the same command. Exactly
one fixture directory exists.

**Restated, so drift is a red run, not a quiet lie.** The MVP sequence carries
four literals: the fixture's directory name, the stack pin, the expected solver,
and the sha256 of each YAML (`KENNEL_EXPECT_SIM_SHA`/`KENNEL_EXPECT_CTRL_SHA` —
the host-side hashes `kennel-transfer.sh` computes, written down instead). The
applier then proves *repo bytes → container bytes* in one checksum chain
(`transfer.md` §2.1), and a fixture regenerated without the sequence being
updated fails at the apply step with the mismatch named.

**The suite keeps the restatement honest** — `verify-runs.py`, appended as
**group 8 "the harness fixture is what the console emits (#24)"**, no VM:

- static: exactly one `test/fixtures/run-*` directory; the four files present
  and nothing else; `run.json.pin` equals `stack/pin.lock`'s `commit:`;
  `choices.mpc_solver == PARTIAL_CONDENSING_OSQP` and
  `choices.simulator_realtime_rate == 0.75` (literals, as group 7 does);
  `commands.txt` has the three blocks and no fourth (read
  `p21-launch-from-commands.sh` for the split marker it uses and assert on
  that); the sequence file's literals — fixture name, pin, solver, the two
  shas — equal the fixture's (parse the YAML with `yaml`, regex the
  `command:` strings; `sha256` from `hashlib`).
- live, with the suite's own `serve.py` and Chrome as group 7: copy the
  fixture directory into the suite's out dir, `goto()`, open Runs, find its
  row, `__loadRow`, read the two panes → **byte-identical** to the fixture's
  YAMLs; `send` from that state → the new folder's `run.json.choices` equal
  the fixture's and its YAMLs equal the fixture's.

Suite count: 84 → 84 + the new checks; nothing before group 8 changes.

### 2.2 The stage script: `test/ubuntu.server.24/ubuntu.server.24.kennel-mvp-stage.sh`

Runs on the **GUEST**, fetched and executed by one `sshFetchAndExecute`. It
does on the guest what `kennel-transfer.sh` + `guest_stage` do from the host —
pull the fixture and the four tools **from the host's serving of the project
clone**, so the bytes under test are the clone's, never the guest's frozen
`~/yuruna/project` (§0.1). House header (`# Version:`, where it runs, usage,
knobs, exit codes); `set -uo pipefail` is fine (it sources nothing).

```bash
# knobs
RUN="${KENNEL_MVP_RUN:?the fixture directory name, e.g. run-20260910T120000Z}"
STAGING="${KENNEL_STAGING:-$HOME/kennel-staging}"
MVP="${KENNEL_MVP_DIR:-$HOME/kennel-mvp}"
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"

# the host is the only source (a private project has no GitHub fallback)
. /etc/yuruna/host.env
BASE="http://${YURUNA_STATUS_SERVICE_IP:?}:${YURUNA_STATUS_SERVICE_PORT:?}/yuruna-repo/project/"
fetch() {   # $1 = repo-relative path, $2 = destination file
    mkdir -p "$(dirname "$2")"
    wget --no-proxy --timeout=20 --tries=2 -qO "$2" "$BASE$1" && [ -s "$2" ] || {
        echo "NONZERO SCRIPT EXIT: could not fetch $BASE$1" >&2
        echo "  the host status service is the only source for a private project; is it up?" >&2
        exit 2; }
    printf '%s  %s\n' "$(sha256sum "$2" | cut -c1-64)" "$1"
}
echo "==== fixture $RUN ===="
for f in simulator_params_go2.yaml mit_controller_sim_go2.yaml commands.txt run.json; do
    fetch "test/fixtures/$RUN/$f" "$STAGING/runs/$RUN/$f"
done
echo "==== tools ===="
fetch stack/transfer/guest-apply-config.sh          "$STAGING/guest-apply-config.sh"
fetch stack/known-good/tools/k13-stop.sh             /tmp/k13-stop.sh
fetch stack/composed-run/tools/p21-launch-from-commands.sh /tmp/p21-launch-from-commands.sh
fetch stack/verify/kennel-verify.sh                  /tmp/kennel-verify.sh
chmod +x "$STAGING/guest-apply-config.sh" /tmp/k13-stop.sh /tmp/p21-launch-from-commands.sh /tmp/kennel-verify.sh
sudo docker cp /tmp/k13-stop.sh "$CONTAINER:/root/k13-stop.sh"   # do_launch's reason, verbatim
mkdir -p "$MVP"; printf '%s\n' "$RUN" > "$MVP/fixture"
echo "==== staged ===="
```

Exit `0` staged, `2` could not fetch (the stack was never touched). The
`==== … ====` banners are the per-phase checkpoints `fetch-and-execute`
records. The sha lines are the transcript's provenance of what ran.

### 2.3 The sequence: `test/workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml`

A draft the implementer adapts; the shape and the decisions are the point.
`sequenceGuid` is generated here so no one invents one:
**`429cd7d3-f996-4df6-ae53-a4ac8ea5dc1e`**. The placeholders `<RUN>`, `<PIN>`,
`<SIM_SHA>`, `<CTRL_SHA>` are the literals of §2.1 (pin =
`dcf53c596339afd45b82f12c54b1e93e8273c2f4`). No `${…}` anywhere in a
`command:` (`$HOME`, `$(…)` and `$r` are the shell's and are fine — the
existing sequences use them); `docker inspect --type container`; never
`pkill -f`.

```yaml
# yaml-language-server: $schema=../../yuruna/test/schemas/sequence.schema.yml

# Kennel -- issue #24: the MVP as one Yuruna sequence.
# Chains onto the reset sequence and, like it, declares the baseline snapshot:
# on a host that holds it, only this sequence runs (revert -> stage -> apply
# -> launch -> assert -> record -> stop, ~4 min); in a cycle the whole chain
# runs first and this is its last link (~40 min). Its first step is its own
# loadDiskSnapshot so that both paths start from the same disk (vm/snapshot.md
# §3: it must be the first EXECUTED step, hence component[0]).
#
# Bypass (tracking-issue #8, #26): the composition is a CHECKED-IN FIXTURE the
# console exported (test/fixtures/<RUN>/), never the browser driven by the
# harness. Retirement path: browser automation in the full POC harness (s001).
# The fixture is never edited; kennel_console/verify-runs.py group 8 proves it
# is what the console emits for its own run.json.
#
# Four literals are restated here on purpose -- the fixture name, the stack
# pin, the expected solver, and the sha256 of each YAML -- so that a fixture
# regenerated without this file being updated is a RED RUN at the apply step,
# not a quietly different experiment. The same idiom stack/pin.lock uses.

sequenceGuid: 429cd7d3-f996-4df6-ae53-a4ac8ea5dc1e
sequenceRevision: 1

description: "Kennel (SSH): the MVP -- revert to the baseline, stage the console-exported fixture from the project tree, apply it, launch the three stack processes from its commands.txt, assert healthy and walking on the composed solver (stack/verify.md), keep the logs, stop the stack."
keystrokeMechanism: ssh
requiresSnapshot:
  id: kennel-vm-baseline
resource:
  ubuntu.server.24:
    - workload.guest.ubuntu.server.24.kennel.reset.ssh
# Restated for the warm path (vm/snapshot.md §3); must equal the start sequence's.
variables:
  username: yuuser24
  hostname: kennel-vm
  memoryStartupBytes: 16GB
  cores: 8

component:
  - action: loadDiskSnapshot
    id: kennel-vm-baseline
    description: "Revert the disk to 'kennel-vm-baseline' and start the guest"

  - action: sshWaitReady
    timeoutSeconds: 600
    description: "Wait for sshd after the revert (fresh boot, new lease)"

  - action: sshExec
    command: "whoami && hostname"
    description: "Smoke test: whoami/hostname"

workload:
  - action: sshExec
    command: "cat \"$HOME/.kennel-baseline\"; grep -qx 'pin=<PIN>' \"$HOME/.kennel-baseline\""
    description: "Assert the restored guest carries the baseline record at the stack pin"

  - action: sshExec
    command: "sudo docker start dfki_quad >/dev/null; s=$(sudo docker inspect --type container -f '{{.State.Status}}' dfki_quad); echo \"container=$s (want running)\"; [ \"$s\" = running ]"
    description: "Start the dfki_quad container and assert it is running"

  - action: sshFetchAndExecute
    command: "KENNEL_MVP_RUN=<RUN> /usr/local/lib/yuruna/fetch-and-execute.sh project/test/ubuntu.server.24/ubuntu.server.24.kennel-mvp-stage.sh"
    timeoutSeconds: 300
    description: "Stage the fixture <RUN> and the four stack tools from the project tree (through the host)"

  - action: sshExec
    command: "r=$(cat \"$HOME/kennel-mvp/fixture\"); j=\"$HOME/kennel-staging/runs/$r/run.json\"; p=$(sed -n 's/.*\"pin\"[[:space:]]*:[[:space:]]*\"\\([0-9a-f]*\\)\".*/\\1/p' \"$j\" | head -1); s=$(sed -n 's/.*\"mpc_solver\"[[:space:]]*:[[:space:]]*\"\\([A-Z_]*\\)\".*/\\1/p' \"$j\" | head -1); echo \"fixture=$r pin=$p solver=$s (want <PIN> / PARTIAL_CONDENSING_OSQP)\"; [ \"$p\" = <PIN> ] && [ \"$s\" = PARTIAL_CONDENSING_OSQP ]"
    description: "Assert the staged fixture's run.json agrees with this sequence's pin and solver"

  - action: sshExec
    command: "r=$(cat \"$HOME/kennel-mvp/fixture\"); KENNEL_MODE=apply KENNEL_RUN=\"$r\" KENNEL_PIN=<PIN> KENNEL_EXPECT_SIM_SHA=<SIM_SHA> KENNEL_EXPECT_CTRL_SHA=<CTRL_SHA> \"$HOME/kennel-staging/guest-apply-config.sh\""
    timeoutSeconds: 120
    description: "Apply the fixture to the container's config paths and prove the bytes landed (repo -> guest -> container)"

  - action: sshExec
    command: "/tmp/p21-launch-from-commands.sh || { rc=$?; echo \"LAUNCH_FAILED rc=$rc\"; for l in sim legdrv ctrl; do echo \"--- /tmp/p21-$l.log (tail) ---\"; sudo docker exec dfki_quad tail -n 60 /tmp/p21-$l.log 2>/dev/null; done; exit $rc; }"
    timeoutSeconds: 600
    description: "Launch the three stack processes from the fixture's commands.txt and wait for the six-node graph"

  # The recipe runs ONCE; its exit code is classified by the two steps that
  # follow, because a Yuruna step has one failure class and verify.md §1 has
  # two: 2 = the recipe could not even look, 1 = it looked and the stack is not
  # healthy/walking. The failing step's description is what status.json and the
  # transcript show, so the class is readable without opening a log.
  - action: sshExec
    command: "mkdir -p \"$HOME/kennel-mvp\"; /tmp/kennel-verify.sh --expect-solver PARTIAL_CONDENSING_OSQP --controller-log /tmp/p21-ctrl.log; rc=$?; echo \"$rc\" > \"$HOME/kennel-mvp/verify.rc\"; echo \"verify_rc=$rc\"; exit 0"
    timeoutSeconds: 600
    description: "Run the verification recipe against the composed solver (its exit code is classified next)"

  - action: sshExec
    command: "rc=$(cat \"$HOME/kennel-mvp/verify.rc\"); [ \"$rc\" != 2 ] || { echo 'INFRASTRUCTURE: kennel-verify.sh exit 2 -- the recipe could not look (no container, source chain, arguments). This is NOT a stack verdict.'; cat /tmp/kennel-verify/report.txt 2>/dev/null; exit 2; }"
    description: "Classify: the recipe could look (exit 2 = infrastructure error, a different failure class)"

  - action: sshExec
    command: "rc=$(cat \"$HOME/kennel-mvp/verify.rc\"); cat /tmp/kennel-verify/report.txt; [ \"$rc\" = 0 ] || { echo \"ASSERT_FAILED: kennel-verify.sh exit $rc -- the stack is up but not healthy/walking\"; for l in sim legdrv ctrl; do echo \"--- /tmp/p21-$l.log (tail) ---\"; sudo docker exec dfki_quad tail -n 60 /tmp/p21-$l.log 2>/dev/null; done; exit 1; }"
    description: "Assert healthy and walking on PARTIAL_CONDENSING_OSQP (exit 1 = an assert failed = red run, logs above)"

  - action: sshExec
    command: "r=$(cat \"$HOME/kennel-mvp/fixture\"); d=\"$HOME/kennel-mvp/$r\"; mkdir -p \"$d\"; cp /tmp/kennel-verify/report.json \"$d/verify.json\"; cp /tmp/kennel-verify/report.txt \"$d/verify.txt\"; for l in sim legdrv ctrl; do sudo docker cp \"dfki_quad:/tmp/p21-$l.log\" \"$d/p21-$l.log\"; done; sudo chown -R \"$(id -un)\" \"$d\"; cp /tmp/yuruna-last-fetch-and-execute.log \"$d/stage.log\" 2>/dev/null || true; cp \"$HOME/kennel-staging/current-run\" \"$d/applied.txt\"; cp \"$HOME/.kennel-baseline\" \"$d/baseline.txt\"; ls -la \"$d\"; grep -o '\"verdict\"[^,]*' \"$d/verify.json\"; grep -E 'sim-clock|composed-config' \"$d/verify.txt\""
    timeoutSeconds: 120
    description: "Keep the run's record on the guest -- the report and the three process logs -- for the host to collect"

  - action: sshExec
    command: "sudo docker exec dfki_quad bash /root/k13-stop.sh; echo 'stack stopped; container up; the run stays applied (reset returns to stock)'"
    timeoutSeconds: 120
    description: "Stop the stack (bounded, by exact name); the container stays up"
```

Notes the implementer needs:

- **Timeouts** are per step and default to 180 s (§0.1); the values above
  are bounds, not expectations — launch measured 35 s and the launcher's own
  knobs (`KENNEL_LEGDRV_TIMEOUT`, `KENNEL_GRAPH_TIMEOUT`, `KENNEL_TOPIC_TIMEOUT`)
  add up to more than 180 s on a bad day, so 600 s. Issue #24's "timeouts per
  step (provisioning is the long pole)" is already true of the stack sequence
  (14400 s) and bounded in a cycle by `stepTimeoutSeconds: 2700` (§0.3).
- **Logs on pass and fail.** On a failing launch or assert, the step tails the
  three logs into its own output, which is what Yuruna keeps (§0.1). On pass,
  the "keep the run's record" step assembles `~/kennel-mvp/<RUN>/` on the guest
  — `verify.json`, `verify.txt`, `p21-{sim,legdrv,ctrl}.log`, `stage.log`,
  `applied.txt`, `baseline.txt` — and the driver's `mvp`/`cycle` verbs scp it
  to the host (§2.4, §3.1). Yuruna has no host-exec, no scp action and no
  output capture on a passing step; that is a limitation of the harness to
  record in `test/harness.md` §"what the harness cannot do", not a bypass.
- **The second revert on the cold path** (reset reverts, then this reverts
  again ~1 min later) costs ~15 s and is accepted: it is what makes one file
  correct on both paths.
- The **realtime rate** is reported by check 2 (`INFO`, never asserted —
  `verify.md` §2); the record quotes it from `verify.txt` as the second
  composed value's proof.
- `sudo docker cp` writes root-owned files; the `chown` is what lets `scp` as
  `yuuser24` read them.

### 2.4 `kennel-demo.sh mvp` — the sequence as a verb

Mirrors `reset` (§0.3 of `vm/snapshot.md`'s `do_reset`): `need_yuruna`,
`install_kennel_project`, `cd $YURUNA_DIR`, wake libvirtd, banner, `pwsh
test/Invoke-TestSequence.ps1 -SequenceName workload.guest.ubuntu.server.24.kennel.mvp.ssh
-NoProjectClone`, measured with `$SECONDS`. On a host with the baseline it is
the warm path (~4 min); without one it is `provision` + the MVP (~40 min), and
the banner says which by asking `virsh snapshot-list "$SNAPSHOT_ID"` first. On
exit 0 **and** on a failed sequence, `harness_collect mvp` (§3.1) tries to scp
`~/kennel-mvp/*` and the newest cycle folder into
`$KENNEL_HARNESS_EVIDENCE/mvp-<stamp>/`, then `do_status`. Exit codes: `0`;
`1` the sequence did not pass; `2` could not even start (no clone, no Yuruna).

---

## 3. #25 — the cycle, green twice

### 3.1 `kennel-demo.sh cycle` — one cold cycle as the runner runs it

`KENNEL_CYCLES=N` (default 1) cycles in a row, stopping at the first red one.
Each cycle:

1. **Preflight** — `need_yuruna`; the three patches applied (`patch_state`, as
   `provision`); the guest ISO present; `repositories.projectUrl` in
   `test/test.config.yml` names this repo (its origin URL or `file://$REPO_ROOT`)
   — else exit 2 with the line to set; no `runner.pid` alive; `virsh list --all`
   to wake libvirtd. Say plainly: *this DESTROYS `kennel-vm` including the
   baseline and rebuilds both from clean (~40 min); the rebuilt baseline is
   left standing.* Prompt unless `--yes` (the one flag: it waives a
   confirmation, as `provision`'s does).
2. **Sweep both names** — exactly `provision`'s line
   (`Remove-TestVMFiles.ps1 -Prefix @('test-','$SNAPSHOT_ID') -Confirm:$false`,
   the `-Command` array form of `snapshot.md` §6 F3). This is what makes a
   cycle **cold** on a dev host without `cleanupVmNamePrefixes` (§0.1), and it
   is why the baseline survives the cycle's own end-sweep (`test-` only).
3. **Run** — `pwsh test/Invoke-TestProject.ps1` (it wipes and re-clones
   `project/` from `projectUrl`, gates on `Test-Config`, runs the cycle exactly
   as the runner would, exits 0/1). Timed with `$SECONDS`.
4. **Collect** — `harness_collect cycle`: the newest
   `test/status/log/<cycle>/` directory (HTML, `cycle.events.ndjson`,
   `manifest.json`), `test/status/runtime/status.json`, the newest
   `test/status/perf/cycles/*.jsonl`, then `need_guest` (the guest re-DHCPs;
   discovery by lease hostname is unchanged) and `scp -r ~/kennel-mvp/` — all
   into `$KENNEL_HARNESS_EVIDENCE/cycle-<stamp>/` (default
   `$REPO_ROOT/test/evidence`). Print the cycle's `totalDurationSeconds` and
   `overallStatus` from `status.json` history, and `grep -c warm_resume` on the
   events file (a green cycle that warm-resumed is **not** flakiness-free —
   §3.2 asserts zero).
5. Exit `0` all N green; `1` a cycle was red (the collected evidence names the
   step); `2` preflight.

After the last cycle the guest is `kennel-vm-baseline`, running, with the MVP's
composed run applied and the stack stopped; `reset` returns it to stock in
90 s. Say so at the end.

**Why not wrap `Invoke-TestRunner.ps1`:** it cannot be stopped from a script
(§0.1's SIGINT probe), and `Invoke-TestProject.ps1` *is* its cycle by that
script's own contract. The runner is an operator step in §3.2.

### 3.2 The protocol for "green twice"

In `test/harness.md` §4 and executed in §4 below. `repositories.projectUrl`
for the PR's own validation is **`file:///home/thales/kennel`** (the branch's
committed HEAD — a branch on GitHub cannot be selected by URL; `Test-Config`
PASSes the path and WARNs about a guest fallback Kennel never takes). The
record states the commit each cycle ran, from `status.json`'s project entry
and the cycle HTML. The first cycle against `https://github.com/alius-git/kennel`
is the maintainer's after merge, and the record says that in "Still open".

`test.config.yml` for the protocol: `projectUrl` as above, `cleanupVmNamePrefixes`
**unset**, `warmResume` left at its default (**on**) so that the evidence shows
what a stock host does — and the assertion is that `cycle.events.ndjson`
carries **no `warm_resume` event** in either green cycle. `logLevel` stays
`Information`.

### 3.3 The evidence and the record

`test/evidence/` holds, committed: `negative-no-runner/` (§4 P0),
`mvp-1/`, `mvp-2/`, `negative-assert/`, `negative-infra/`, `cycle-1/`,
`cycle-2/`, `runner-1/` — each a directory of transcripts named in §4. Cycle
directories keep the HTML transcript, the events file, `status.json`, the perf
rows and `kennel-mvp/<RUN>/` from the guest.

`test/harness.md` is the implementation record of the three issues, in the
shape of `vm/snapshot.md`: what is delivered (table), what Yuruna provides
(§0.1 condensed, with file:lines), the decisions, running it (the verbs, the
knobs, the exit codes), validation (the table of evidence with measured
timings — the cold chain per link, the MVP per step, the cycle totals), the
findings (F-series continues `demo/dry-run.md`'s: F12…), the bypasses with
retirement paths, and "what the harness cannot do" (no output on pass, no
host-exec, no branch selection by URL, a private project has no GitHub
fallback).

---

## 4. Live validation protocol

Negative control first; evidence file names are the contract. Restore the
guest as the last row. The console (`serve.py` on `:8000`) may stay up; no
verb here uses it except `compose` in P1. Run nothing else against the guest
while a cycle runs.

| # | Step | Command | Evidence | Expect |
|---|---|---|---|---|
| P0 | negative control, no VM | the §0.2 planner probe against a clone of `origin/main` | `test/evidence/negative-no-runner/probe.txt` | `Runner config not found: …/project/test/test.runner.yml` |
| P0' | the same probe against the branch | same, `file://` clone of the branch | `…/probe-branch.txt` | discovery lists `project/test`; chain of six; `Get-CycleConfig` → the MVP name |
| P1 | the fixture | `demo/tools/kennel-demo.sh compose`; copy into `test/fixtures/`; fill the four literals into the sequence; `bash kennel_console/verify-runs.sh` | `test/evidence/fixture/compose.txt`, `verify-runs.txt` | group 8 green; 84 + n checks; groups 1–7 unchanged |
| P2 | gate | `pwsh test/Test-Config.ps1 -SkipSend` with `projectUrl: file:///home/thales/kennel` | `test/evidence/gate/test-config.txt` | 0 FAIL; no finding names a kennel file; the sequence scan lists `project/test` |
| P3 | #23's reset through the project tree | `kennel-demo.sh reset` | `test/evidence/reset-project-tree/reset.txt` + `git -C ~/git/yuruna status --short` | 12/12; `project/test/ubuntu.server.24/…` in the `sshFetchAndExecute` lines; `sha256 verified`; **no** "differs from HEAD"; the clone's status shows only the patches and `test.config.yml*` |
| P4 | the MVP warm, twice | `kennel-demo.sh mvp` ×2 | `test/evidence/mvp-1/`, `mvp-2/` (verb transcript + `kennel-mvp/<RUN>/`) | green both; `verify.json` verdict `completed`, check 10 `mpc_solver == PARTIAL_CONDENSING_OSQP`, check 2's rate ≈ 0.75; per-step seconds recorded |
| P5 | negative: assert failed (class 1) | `Invoke-TestSequence.ps1 -SequenceName …mvp.ssh -NoProjectClone -StopStep <launch>`; on the guest `sudo docker exec dfki_quad bash /root/k13-stop.sh`; then `-StartStep <verify> -StopStep <assert>` | `test/evidence/negative-assert/` | the *"Assert healthy and walking"* step fails, the *"Classify"* step passed, the three tails are in the captured output |
| P6 | negative: infrastructure (class 2) | as P5, but `sudo docker stop dfki_quad` before the verify step | `test/evidence/negative-infra/` | the *"Classify"* step fails with `INFRASTRUCTURE`; the assert step never runs |
| P7 | **the two cycles** | `KENNEL_CYCLES=2 demo/tools/kennel-demo.sh cycle --yes` (~80 min, unattended; `sudo chronyc makestep` first is the maintainer's call, advisory) | `test/evidence/cycle-1/`, `cycle-2/` | both `overallStatus: pass`; 0 `warm_resume`; the chain's 6 sequences in each transcript; `totalDurationSeconds` recorded; the project commit in `status.json` |
| P8 | the eternal runner, one cycle, attended | sweep both names (the `Remove-TestVMFiles` line); `pwsh test/Invoke-TestRunner.ps1 -NoGitPull -CycleDelaySeconds 900`; **Ctrl+C in the terminal** after `CYCLE 1 complete -- entering teardown`; note which delay the transcript says is in force | `test/evidence/runner-1/` (`outer.log`, the cycle folder, `status.json`) | one green cycle through the outer loop; the status page reachable during it (`curl -s localhost:8080/status/` → 200, saved) |
| P9 | restore | `kennel-demo.sh reset`; `kennel-demo.sh status` | `test/evidence/restore/` | baseline back, container running, no run applied — as `snapshot.md` §4 |
| P10 | nothing else moved | the nine console suites; `bash -n` on every touched script; `git diff --stat origin/main -- kennel_console/verify-*.py` shows only `verify-runs.py`, and `grep '^-'` on its diff shows nothing removed; `git status --porcelain` shows only `slides/` | `test/evidence/suites.txt` | 9 × exit 0; 594 + n |

If P8's outer loop misbehaves for a reason outside the sequence (a gate, the
pause logic), record it as a finding with the transcript and do not block the
PR on it: the acceptance is P7.

---

## 5. Records and documentation to update

Append, never rewrite, in the existing records; new sections dated.

- **`test/harness.md`** — new (§3.3).
- **`test/README.md`** — new (§1.3).
- **`vm/provisioning.md`** §4.2 — append: the copy step retired by #23 on
  2026-09-xx; the F5 warning gone (with the P3 transcript line); the paths are
  now `test/…`.
- **`vm/snapshot.md`** §2.1 — append the measured sweep semantics (§0.1) and
  the two host roles; §3's file paths.
- **`vm/guest-sizing.md`** §3.2 — append the retirement note; fix paths.
- **`stack/transfer.md`** §2.2/§3 — append: #24's sequence is the consumer
  the contract was written for; the shas are restated in the sequence.
- **`stack/verify.md`** §1 — append: how #24 wired the `1`/`2` split (two
  steps), with the P5/P6 evidence.
- **`stack/pin.lock`** — the two paths in "Where this pin is enforced"; add
  that the MVP sequence is a fourth restatement.
- **`kennel_console/runs.md`** — a new §9 for group 8.
- **`demo/runbook.md`** — §2 (`setup`'s items: `project clone`, `projectUrl`),
  §3 gains `mvp` and `cycle` with what success looks like, §4 the three knobs,
  §7 the verbs table.
- **`docs/README.md`** — a **Harness** section: `test/README.md`,
  `test/harness.md`, the runner file, the fixture.
- **`README.md`** — one line under the quick start: the repo is also a Yuruna
  project (`test/`).
- **`CLAUDE.md`** — the repo table (`test/` row; `vm/` row), the `command:`
  rule's path, the driver verbs list (`mvp`, `cycle`). One new rule, only if
  the maintainer wants it promoted from the record: *`kill -INT` does not stop
  a non-interactive `pwsh`; the runner is stopped from a terminal or not at
  all.*
- **`plan/harness.md`** (this file) — committed in the first commit; the PR
  body's "Corrections to the plan" lists what measurement changed.

---

## 6. The PR

### 6.1 Commit order (each stands on its own)

1. `feat(test): the repo is a Yuruna project — test/ holds the sequences, the guest scripts and test.runner.yml; the driver clones the project instead of copying files into the framework (#23)` — the move, the runner file, `test/README.md`, the driver (`install_kennel_project`, `-NoProjectClone`, `setup`), the path fixes in `pin.lock`/`CLAUDE.md`/records' links, **and `plan/harness.md`**. Green: P0, P0', P2, P3.
2. `feat(test): the MVP fixture — run-<stamp> exported by the console for OSQP / 0.75, and verify-runs.py group 8 that keeps it honest (#24)` — the fixture, the suite group. Green: P1.
3. `feat(test): workload…kennel.mvp.ssh — revert, stage, apply, launch, assert the composed solver, keep the logs, stop; kennel-demo.sh mvp (#24)` — the sequence, the stage script, the verb. Green: P4–P6.
4. `feat(demo): kennel-demo.sh cycle — one Yuruna cycle from cold as the runner runs it, the baseline swept before and kept after, evidence collected (#25)`. Green: P7, P8.
5. `docs: record the harness pass — test/harness.md, the records appended, the runbook and CLAUDE.md, evidence (#23, #24, #25)`.

### 6.2 Body skeleton (house style of #79–#83)

```
Closes #23, closes #24, closes #25. Plan: plan/harness.md.

Three issues in one PR at the maintainer's request: they are steps 17–19 of the
milestone, and a cycle (#25) is a statement about a runner file (#23) naming a
sequence (#24). The milestone's default of one issue per PR is unchanged.

<two paragraphs: what the harness is, and that a fresh clone was already a
project before this PR (§0.2) — what was missing was the runner file, the
sequence, and a driver that stops copying.>

## What is here
| File | |   (test/ layout, runner file, README, fixture, stage script, the sequence,
                 the driver verbs, verify-runs group 8, the record)

## Measured on the live guest
- reset through the project tree: <steps>, <time>, no "differs from HEAD"
- mvp warm: <per-step seconds>, verdict completed, mpc_solver OSQP, rate <x>
- the two cycles: <total seconds each>, per-link table, 0 warm_resume, project commit <sha>
- the runner's cycle: <total>, stopped by Ctrl+C at the banner
- the negative controls: which step failed, with the class in its description

## Findings from the live protocol   (F12…)
## Corrections to the plan, from measurement
## Verification   (the P-table as a block: suites, bash -n, py_compile, greps, git status)
## Bypasses   | the fixture instead of a driven browser → s001 automation |
              | the driver runs a clone of local HEAD, not GitHub main → the maintainer's post-merge cycle |
              | logs on pass leave the guest only through a driver verb → a Yuruna artifact action |
## Still open  — the first cycle against https://github.com/alius-git/kennel after merge;
                 the human friction session (#65) unchanged; vm/test/verify-*-host.sh's home
## Decisions   — §7 of the plan, as built
## Records     — the list in §5
```

---

## 7. Decisions this plan makes that the issues did not

1. **The sequences and the guest scripts move into `test/`** (`git mv`), in
   yuruna-project's layout (`test/*.yml`, `test/<guest>/*.sh`, `test/test.runner.yml`)
   and `design.md` §6's (`test/ # Yuruna sequences`). Discovery would have
   found `vm/test/` as it was (§0.2); the move is for one home, not for the
   planner. The two host-side checks in `vm/test/` stay.
2. **The driver runs the committed HEAD of this checkout**, cloned into
   `project/` (`KENNEL_PROJECT_URL`, default `file://$REPO_ROOT`) and passed
   `-NoProjectClone` — never the working tree, never GitHub `main` while you
   are on a branch. `cycle` is the exception by construction:
   `Invoke-TestProject.ps1` clones from `test.config.yml`, so for the PR's own
   validation `projectUrl` is the `file://` of the checkout.
3. **`cycle` wraps `Invoke-TestProject.ps1`, not the eternal runner**, because
   a script cannot stop the runner (§0.1) and the project runner is its cycle
   by contract. The eternal runner is run once, attended, and stopped with a
   terminal Ctrl+C.
4. **`cycle` sweeps the baseline itself and leaves the rebuilt one standing.**
   `cleanupVmNamePrefixes` is documented as the CI-host setting and never
   written by `setup`, because on this host it would destroy the baseline at
   the end of every cycle (§0.1).
5. **The fixture is the driver's default composition (OSQP / 0.75)**, generated
   through the console by `kennel-demo.sh compose`, not a preset and not a
   copy of an older evidence folder (the emitters have changed since #68).
   Its four literals are restated in the sequence; a suite group proves the
   restatement and the bytes.
6. **The exit-code contract is three steps** — run, classify-2, assert-1 —
   because a Yuruna step has one failure class and the class must be readable
   from the failing step's description.
7. **Logs on pass are kept on the guest and collected by the verb**; on fail
   the failing step tails them. Yuruna keeps `sshExec` output only on failure
   — recorded as a limitation, not worked around with `logLevel: Debug`.
8. **The MVP sequence declares `requiresSnapshot` and starts with its own
   `loadDiskSnapshot`**, so it is warm-runnable in ~4 min and correct at the
   end of a cold chain, at the cost of a second revert there.
9. **The private repo is served by the host's `gh` credential** for the clone
   and by the status service for the guest; `ghToken` is the documented
   alternative; the GitHub fallback is dead for a private project and the
   stage script fails closed with that sentence.
10. `Test-Project.ps1` (the issue) is `Invoke-TestProject.ps1` (the release);
    `sequenceRevision` is untouched for path-only edits; the MVP's GUID is the
    one printed in §2.3; the evidence series continues `dry-run.md`'s F-numbers.

## 8. Don'ts

- Don't `git add -A` — `slides/` is the maintainer's uncommitted deck.
- Don't hand-edit anything under `test/fixtures/`; regenerate with `compose`.
- Don't put `${…}` in a `command:`; don't `pkill -f`; don't `sleep` for
  readiness (the stage script waits on nothing; the launcher and the recipe
  already observe the stack).
- Don't reorder or edit existing suite groups; append group 8 and touch
  nothing before it.
- Don't rename a sequence file — names are lookup keys; don't invent a GUID.
- Don't write `cleanupVmNamePrefixes` into `test.config.yml` from `setup`, and
  don't leave it set on this host after P8.
- Don't rely on `kill -INT` for `pwsh`; don't run `Invoke-TestRunner.ps1`
  without `-NoGitPull` on this clone.
- Don't let a verb re-clone `project/` from `test.config.yml` behind the
  operator's back: every `Invoke-TestSequence.ps1` the driver runs passes
  `-NoProjectClone` after its own clone.
- Don't read the guest's `~/yuruna/project` in any sequence step — it is
  frozen in the snapshot.
- Don't run `scenario *` verbs while validating: they overwrite their committed
  evidence directories.
- Don't end the protocol without P9; the guest must be at the baseline,
  container running, no run applied — and don't stage `bash -n`-untested
  scripts.
