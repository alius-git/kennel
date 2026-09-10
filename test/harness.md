# The harness — Kennel as a Yuruna project, and the MVP as one sequence

Implementation record for
[#23](https://github.com/alius-git/kennel/issues/23) (a Yuruna-discoverable
`test/`), [#24](https://github.com/alius-git/kennel/issues/24) (the MVP
sequence) and [#25](https://github.com/alius-git/kennel/issues/25) (the cycle
green twice) — steps 17–19 of milestone *Finish the system*. Plan:
[`plan/harness.md`](../plan/harness.md).

The operator page is [`test/README.md`](README.md): the layout, the two host
roles, and how to point a Yuruna host at this repository. This document is the
record of *how it was built and what was measured*.

Builds on [`vm/provisioning.md`](../vm/provisioning.md)
([#10](https://github.com/alius-git/kennel/issues/10)),
[`vm/snapshot.md`](../vm/snapshot.md)
([#51](https://github.com/alius-git/kennel/issues/51)),
[`stack/transfer.md`](../stack/transfer.md)
([#20](https://github.com/alius-git/kennel/issues/20)) and
[`stack/verify.md`](../stack/verify.md)
([#14](https://github.com/alius-git/kennel/issues/14)) — the sequence runs
those tools rather than a second copy of what they do. Everything below was
measured on **2026-09-09/10**, on the host of
[`vm/host-baseline.md`](../vm/host-baseline.md). Transcripts in
[`test/evidence/`](evidence/).

> **Bypass note (tracking-issue [#8](https://github.com/alius-git/kennel/issues/8),
> [#26](https://github.com/alius-git/kennel/issues/26)):** the MVP sequence
> consumes a **checked-in fixture** — a run folder the console exported,
> committed under [`test/fixtures/`](fixtures/) — instead of driving the browser
> UI. *Retirement path:* browser automation in the full POC harness, which is
> what scenario s001 describes. The fixture is never hand-edited; regenerating
> it goes through the console, and `verify-runs.py` group 8 is what keeps that
> true (§3.1).

## 1. What is delivered

| Artifact | Purpose |
|----------|---------|
| [`test/`](.) | the repository **as a Yuruna project** — the six sequences the runner discovers, `test.runner.yml`, and the guest scripts under `test/ubuntu.server.24/` |
| [`test/test.runner.yml`](test.runner.yml) | what a **cycle** runs: the top-level sequence(s) whose `resource:` chains it walks |
| [`test/README.md`](README.md) | the operator page — layout, `test.config.yml`, the two host roles, how the guest gets project files |
| [`test/workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml`](workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml) | **#24** — the MVP as one sequence, 14 steps |
| [`test/ubuntu.server.24/ubuntu.server.24.kennel-mvp-stage.sh`](ubuntu.server.24/ubuntu.server.24.kennel-mvp-stage.sh) | its guest-side staging: the fixture and the four stack tools, fetched from the project clone through the host |
| [`test/fixtures/run-20260910T025021Z/`](fixtures/) | the composition it applies — a console export, unedited |
| [`demo/tools/kennel-demo.sh`](../demo/tools/kennel-demo.sh) | `mvp` and `cycle`; every sequence-running verb now clones the project instead of copying files into the framework |
| [`kennel_console/verify-runs.py`](../kennel_console/verify-runs.py) | group 8, 35 checks: the fixture is still what the console emits, and the sequence still restates it correctly |
| [`test/evidence/`](evidence/) | the transcripts §5 reads |

The chain, with the new link at the end:

```
start.guest.ubuntu.server.24.kennel.ssh                     # create the 8 vCPU / 16 GiB guest
  -> workload.guest.ubuntu.server.24.kennel.ssh             # assert the sizing landed (#9)
    -> workload.guest.ubuntu.server.24.kennel.stack.ssh     # Docker + the pinned stack (#10)
      -> workload.guest.ubuntu.server.24.kennel.baseline.ssh    # clean it, freeze it (#51)
        -> workload.guest.ubuntu.server.24.kennel.reset.ssh     # revert to it, prove it (#51)
          -> workload.guest.ubuntu.server.24.kennel.mvp.ssh     # the demo, asserted (#24)
```

## 2. #23 — what "a Yuruna project" actually is

Read from the framework at `2026.08.04`, then probed. The file:line is the
place to re-read before deviating.

| Piece | Where | Behaviour |
|---|---|---|
| Discovery | `test/modules/Test.SequenceResolve.psm1:162` (`Get-ProjectFlatTestSearchDir`) | **Every directory named `test`** under `<RepoRoot>/project/`, found by recursion. Sequences sit directly in it — there is no `sequences/` level. |
| Resolution | same, `:253` (`Resolve-SequencePath`) | By exact file name, **project first, framework second**. A project file silently overrides a framework file of the same name; two *project* files of one name are a `PlannerFatal`. |
| A cycle's work | `test/modules/Test.SequencePlanner.psm1:56` (`Get-CycleConfigPath`) | `<RepoRoot>/project/test/test.runner.yml`, a `sequences:` list of top-level names (+ optional `testSets:`). Only the *cycle* entry points read it; `Invoke-TestSequence.ps1` takes the name on the command line. |
| The clone | `test/modules/Test.HostGit.psm1:783` (`Update-ProjectClone`) | Every cycle **wipes and re-clones** `project/` from `repositories.projectUrl`, "so previous cycle output cannot leak forward". `Invoke-TestSequence.ps1` does the same unless `-NoProjectClone`. |
| Guest fetch | `automation/fetch-and-execute.sh`; `test/Start-StatusService.ps1:2638` | `sshFetchAndExecute project/<path>` fetches `http://<host>:8080/yuruna-repo/project/<path>` — the framework clone's working tree, project included — behind a deny-list for secrets and `.git`. |
| Digest | `test/modules/Test.SequenceHandler.psm1` (`Get-FetchExecuteEnvPrefix`) | The host hashes the file it serves and types `E_SHA=` ahead of the command; the guest refuses bytes that do not match. A path it cannot hash fails **closed**. The regex is unanchored, so an env prefix of our own in front of the call is fine. |

### 2.1 The move, and what it retires

The five sequences and the two guest scripts moved from `vm/test/` and
`vm/guest/ubuntu.server.24/` into `test/` and `test/ubuntu.server.24/` with
`git mv`. Names and `sequenceGuid`s are unchanged: a file name is a lookup key
(`resource:` chains and `test.runner.yml` name it) and the GUID is what the
perf log joins on across renames. `vm/test/verify-{meshcat,bridge}-host.sh`
stay — they are host-side reachability checks the driver calls by path, not
sequences, and a directory named `test` with no `.yml` in it is inert to
discovery (the probe in §5 shows `project/vm/test` discovered and empty).

Two edits inside the moved files: the `$schema` comment now resolves where the
file actually runs (`project/test/` in the clone), and the two kennel
`fetch-and-execute` paths became project paths —
`project/test/ubuntu.server.24/…`. The framework's own
`guest/ubuntu.server.24/ubuntu.server.24.update.sh` is untouched.

**What retires with it** — [`vm/provisioning.md` §4.2](../vm/provisioning.md)'s
copy-into-the-framework-tree bypass, and the yellow warning it caused on every
healthy run:

```
WARNING: fetch-and-execute fallback: 'guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh'
differs from HEAD, so the GitHub fallback cannot match its digest.
```

It is gone — zero occurrences across two cold cycles (§5.6) — and the mechanism
is worth stating exactly, because the obvious explanation is not the right one.

The host types a digest of the file it is about to serve, and warns when that
working-tree copy differs from what the **GitHub fallback** would fetch. The
test is `git -C <yuruna> status --porcelain --untracked-files=all -- <path>`
(`automation/Yuruna.GitHubSource.psm1:231`), and "cannot tell" is deliberately
reported as "will not match". A kennel file copied into `test/sequences/` was
untracked *there*, so it answered "will not match" on every healthy run. The
same file inside `project/` answers nothing at all: `project/` is **gitignored**
in the framework clone, so `git status` says nothing about it and the check
reads "unmodified".

The nuance underneath is the useful part: for **any** project path the GitHub
fallback is structurally unavailable — it resolves against *yuruna's* repo and
commit, which never contained a project file. So a project's guest scripts can
only ever come from the host, which is the same conclusion §3.3 reaches from
the private-repo direction, arrived at from another.

### 2.2 The driver clones; it no longer copies

`install_kennel_files()` became `install_kennel_project()`: wipe
`$YURUNA_DIR/project` (with `Update-ProjectClone`'s own guard — refuse anything
that is not a `.../project` path) and `git clone` `KENNEL_PROJECT_URL`, whose
default is `file://<this repo>`. Then every `Invoke-TestSequence.ps1` the driver
runs passes **`-NoProjectClone`**, so the tree that runs is the one the verb
just made rather than a re-clone from `test.config.yml`.

The consequence is worth stating plainly, because it is a change in what a verb
*means*: **`provision`, `reset` and `mvp` run the committed HEAD of your
checkout**, not your working tree. An uncommitted edit under `test/` does not
run, and the verb says so:

```
[kennel-demo] WARNING: uncommitted changes are NOT in that clone -- the sequences will run HEAD:
[kennel-demo]         M test/workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml
```

`setup` gained two items. **`retired copies`** deletes the pre-#23 copies from
the framework tree — not tidiness: `Test-Config` parses every sequence under
`test/sequences/` and scans each for logical usernames, so a stale copy there is
a second, older definition of a sequence that has moved. It removed 7 files on
this host. **`projectUrl`** reports which repository a *cycle* would run, and
refuses to guess when the file already exists (an operator who pointed it
elsewhere did so on purpose).

## 3. #24 — the MVP sequence

Fourteen steps, one file, both paths:

| # | Step | Warm | What it proves |
|---|---|---|---|
| 1 | `loadDiskSnapshot` | 1–2 s | both paths start from the same disk |
| 2 | `sshWaitReady` | 11 s | the revert re-DHCPs; nothing may assume the old lease |
| 3 | smoke | 0 s | |
| 4 | baseline record at the pin | 0 s | what came back is the appliance |
| 5 | container running | 1 s | no `--restart` policy, by design |
| 6 | **stage** (`sshFetchAndExecute`) | 1 s | the fixture and the four tools, from the project clone |
| 7 | the fixture's `run.json` is this pin and this solver | 0 s | restatement 1 |
| 8 | **apply** (`guest-apply-config.sh`) | 1 s | restatements 2–4: repo bytes → guest → container |
| 9 | **launch** (`p21-launch-from-commands.sh`) | 32–35 s | three blocking launches, detached, waited on by observing the graph |
| 10 | **verify** (`kennel-verify.sh --expect-solver`) | 41 s | ten checks; exits 0/1/2 |
| 11 | classify | 0 s | *the recipe could look* — anything but 0/1 is infrastructure |
| 12 | assert | 0 s | *healthy and walking on the composed solver* |
| 13 | keep the record | 0 s | the report and the three process logs, on the guest |
| 14 | stop | 0 s | bounded teardown, by exact name |

### 3.1 The fixture, and why it is restated four times

`test/fixtures/run-20260910T025021Z/` is the driver's **default** composition —
flat plane, `simulator_realtime_rate` **0.75**, `PARTIAL_CONDENSING_OSQP`,
`SPEED`, condensed 5, no disturbances — exported by `kennel-demo.sh compose`
driving the real console through `serve.py`. It is non-stock on **two**
observables, which is what makes #24's "assert the composed value, not just
that something runs" a real assertion: the solver, which check 10 reads back
out of the running controller and corroborates against the launch log, and the
rate, which check 2 reports from `/clock` against the wall.

Regenerate with `demo/tools/kennel-demo.sh compose` (no knobs) and copy the
folder in. **Never edit a file in it.**

The sequence restates four things about it — the folder name, the pin, the
expected solver, and the sha256 of each YAML. A fixture regenerated without the
sequence being updated is then a red run at step 7 or 8, naming the mismatch,
rather than a quietly different experiment. That only works while the two
agree, and nothing else in the repo compares them — hence **group 8** of
[`kennel_console/verify-runs.py`](../kennel_console/verify-runs.py), 35 checks,
no VM:

- the fixture is one folder of exactly four files; its pin is `stack/pin.lock`'s
  `commit:`; its composition is the literals above; `commands.txt` splits into
  exactly the canonical three shells under the launcher's own rule and has no
  fourth block;
- it **round-trips**: copied into a real `serve.py`'s run directory it appears
  in the Runs table, `load` puts it back in the composer, and the emitters
  reproduce its two YAMLs byte for byte — then a fresh **send** writes the same
  bytes again, so the fixture is a fixed point of the console rather than an
  export the emitters have drifted away from;
- the sequence's four literals equal the fixture's, and `test.runner.yml`'s
  top-level is the sequence that applies it;
- **every `.yml` under `test/` parses**, which is §6's F12 — the one that
  refused a whole cycle.

### 3.2 The exit-code contract, as three steps

[`stack/verify.md` §1](../stack/verify.md) gives the recipe three codes and two
meanings that call for different things: `1` = it looked and the stack is not
healthy or not walking (a red run, collect the logs), `2` = it could not even
look (a different bug, in a different place). A Yuruna step carries **one**
failure class, and the failing step's `description` is what `status.json` and
the dashboard show. So the recipe runs once, recording its code, and two steps
classify it:

```yaml
  - action: sshExec        # 10
    command: "... /tmp/kennel-verify.sh --expect-solver PARTIAL_CONDENSING_OSQP ...; rc=$?; echo \"$rc\" > \"$HOME/kennel-mvp/verify.rc\"; ...; exit 0"
  - action: sshExec        # 11
    command: "... case \"$rc\" in 0|1) ... ;; *) echo \"INFRASTRUCTURE: ...\"; exit 2 ;; esac"
    description: "Classify: the recipe could look at the stack (any other exit is an infrastructure error, not a stack verdict)"
  - action: sshExec        # 12
    command: "... [ \"$rc\" = 0 ] || { echo \"ASSERT_FAILED: ...\"; <tail the three logs>; exit 1; }"
    description: "Assert healthy and walking on PARTIAL_CONDENSING_OSQP (an assert failed = red run, with the three process logs above)"
```

The classifier asks whether the code is one **the recipe produces**, not whether
it is 2 — §6's F15, and the negative control is what found it.

### 3.3 What the harness cannot do, and what the driver does about it

Three limits of Yuruna `2026.08.04`, none of them worked around in the
sequence:

- **A passing step's output is not kept.** `sshExec` writes it to `Write-Debug`
  and only surfaces it, as a warning, when the step fails
  (`Test.SequenceHandler.psm1:1164`). So the sequence's failing paths tail the
  three process logs into their own output, and its *green* path assembles the
  record into `~/kennel-mvp/<run>/` on the guest instead.
- **There is no host-exec and no file-collection action.** Verbs are `sshExec`,
  `sshFetchAndExecute` and `callExtension` — the same constraint
  [`stack/transfer.md` §2.2](../stack/transfer.md) records. So `kennel-demo.sh
  mvp` and `cycle` scp that directory off, along with the cycle folder,
  `status.json` and the perf rows, into `test/evidence/`
  (`KENNEL_HARNESS_EVIDENCE`). They collect on a **red** run too, which is when
  it matters.
- **`projectUrl` is a clone URL, not a branch selector.** A cycle runs the
  default branch of whatever it clones. Validating a branch means pointing it at
  a checkout with `file://`, which is what §5 did.

## 4. #25 — the cycle

`kennel-demo.sh cycle` wraps **`Invoke-TestProject.ps1`**, which is by its own
`.SYNOPSIS` one cycle "exactly as Invoke-TestRunner would have" run it: it wipes
and re-clones `project/`, runs the `Test-Config` gate, and spawns the same inner
runner every cycle spawns. Not `Invoke-TestRunner.ps1` — that is an eternal loop
whose only stop is a console Ctrl+C (§6, F16), so a script cannot own its
lifetime. Running the loop is an operator step, in
[`test/README.md`](README.md) §5.

Issue #25 calls the single-cycle entry point `Test-Project.ps1`. **That name
does not exist at this release** — the same kind of drift as
`vmCommunication.keystrokeMechanism` in
[`vm/host-baseline.md` §6.1](../vm/host-baseline.md).

### 4.1 The sweep, and the two host roles

The cycle runner has **no warm path**: `requiresSnapshot` is honoured only by
`Invoke-TestSequence.ps1` (`Test.SequenceRunner.psm1:131`, the warm-path probe), never by
`Test.RunnerInnerLoop.psm1`, which always creates
`test-guest.ubuntu.server.24-01` and walks the whole chain. It *does* follow the
mid-chain rename (`Test.SequenceEngine.psm1:1149` `Get-SequenceFinishedVMName`,
read by `Invoke-GuestSequenceList` at `:1175`),
so the later chain entries target `kennel-vm-baseline` exactly as `provision`'s
do.

Its VM sweep runs **at cycle start and again at cycle end**
(`Test.RunnerInnerLoop.psm1:2524`, `:2874`) with the same prefixes:
`test-` plus `vmStart.cleanupVmNamePrefixes` (`Test.Config.psm1:391`,
`Resolve-CleanupVmNamePrefix`). Which
gives the two roles [`test/README.md` §3](README.md) documents:

- **CI host** — set `cleanupVmNamePrefixes: [kennel-vm-baseline]`. Every cycle
  sweeps the baseline before building, and again after, so the host ends each
  cycle with no guest.
- **Dev host** — leave it unset, and let `kennel-demo.sh cycle` sweep both names
  itself before each cycle. The build is just as cold, and the baseline the
  cycle *takes* survives its `test-`-only end sweep, so the next `run` has an
  appliance waiting. That is what this host does and what §5 measured.

Without either, a cold build on a host that still holds `kennel-vm-baseline`
collides at `saveDiskSnapshot`'s rename.

### 4.2 What a cycle is asserted on

`0 FAIL`, never a step count — the chain is 45 steps + this sequence's 14 today
and was 28 before #51. Plus, per #25's "flag and fix flakiness": **zero
`warm_resume` events** in `cycle.events.ndjson`. Yuruna's warm resume is on by
default and re-runs a failed sequence in place on a transient failure; a cycle
that goes green that way is not the same as one that never failed, so `cycle`
counts them and says so.

## 5. Validation — evidence

All of it on the host of [`vm/host-baseline.md`](../vm/host-baseline.md), with
`repositories.projectUrl` pointed at this checkout (`file:///home/thales/kennel`
— a cycle runs a *clone*, so validating a branch means pointing it at one;
§3.3). Transcripts in [`test/evidence/`](evidence/).

### 5.1 The negative control first

The probe of §2 run against a clone of `main` and a clone of this branch, with
no VM involved ([`evidence/probe.txt`](evidence/probe.txt)):

| | `main` | this branch |
|---|---|---|
| directories discovered under `project/` | `project/vm/test` | `project/test` **and** `project/vm/test` |
| `Resolve-SequencePath` for the reset sequence | `project/vm/test/…yml` | `project/test/…yml` |
| the chain | resolves, five links | resolves, five links |
| `Get-CycleConfig` | **`Runner config not found: …/project/test/test.runner.yml`** | `workload.guest.ubuntu.server.24.kennel.mvp.ssh` |

Which is the whole of #23 in one table: a fresh clone of this repository was
*already* discoverable before this PR — Yuruna would find `vm/test/` and walk
the chain — and what was missing was the one file a **cycle** reads. The second
row is why the move still matters: the project copy is what resolves, and it
should live where a reader expects a project's sequences to live.

`project/vm/test` is still discovered, and is inert: it holds the two host-side
reachability checks and no `.yml` at all.

### 5.2 The gate, and what `setup` did to this host

```
[kennel-demo] ok     yuruna tag       2026.08.04
[kennel-demo] ok     test.config      guestSequence: guest.ubuntu.server.24
[kennel-demo] info   projectUrl       file:///home/thales/kennel  (this checkout -- a cycle runs the branch you are on)
[kennel-demo] did    retired copies   removed 7 pre-#23 file(s) from the framework tree
[kennel-demo] did    project clone    cloned file:///home/thales/kennel at 3610981
[kennel-demo] ok     config gate      0 FAIL
```

`Test-Config.ps1 -SkipSend`: **34 PASS / 5 WARN / 0 FAIL**, and no finding names
a kennel file. The sequence scan reads `project/test` and `project/vm/test`
alongside the framework's own directory; the users scan lists both. The fifth
WARN is new and expected — *"projectUrl is a `file://` URL, only the host can
resolve it"* — and §3.3 is why Kennel never needs the guest-side fallback it
warns about. The other four are this host's standing set
([`vm/host-baseline.md` §3](../vm/host-baseline.md)); the host clock is 480 s
slow and still an operator action.

Afterwards `git -C ~/git/yuruna status --short` shows the three patched files
and the operator's config backup — **and nothing else**. The seven copies are
gone.

### 5.3 `reset`, through the project tree

The verb that has run on every host since #51, unchanged except for where its
sequence now comes from ([`evidence/reset.txt`](evidence/reset.txt)):

```
[kennel-demo] project clone    3610981  feat(test): the repo is a Yuruna project — …
requiresSnapshot: snapshot 'kennel-vm-baseline' present on persisted VM 'kennel-vm-baseline' -- skipping baseline chain (warm path).
…
Chain completed successfully (12 step(s) across 5 sequence(s)).
[kennel-demo] reset in 1m20s
```

**12/12, 1m20s** — against 1m21s–1m23s before the move
([`vm/snapshot.md` §5](../vm/snapshot.md)). Nothing about the guest changed;
only the tree the sequence was read from.

### 5.4 The MVP sequence, warm

Three runs of `kennel-demo.sh mvp`, each from a `loadDiskSnapshot` revert
([`evidence/mvp-1.txt`](evidence/mvp-1.txt), [`mvp-2.txt`](evidence/mvp-2.txt)):

| Step | 1 | 2 | 3 |
|---|---|---|---|
| revert + sshd | 13 s | 12 s | 13 s |
| stage + fixture assert + apply | 2 s | 1 s | 2 s |
| **launch** | 32 s | 34 s | 33 s |
| **verify** | 41 s | 41 s | 41 s |
| classify + assert + record + stop | 0 s | 0 s | 0 s |
| **14/14, sequence total** | **89 s** | **91 s** | **90 s** |
| verb total, including the project clone and the collection | 97 s | 99 s | 99 s |

(Seconds, from the transcript's own seconds column — Yuruna's formatted
"completed in" beside it reads a minute long on two of these three, which is
F17.)

And the verdict, from `verify.json` — the file the sequence copied into
`~/kennel-mvp/<run>/` and the verb collected:

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| verdict | `completed` | `completed` | `completed` |
| checks | `pass=10 fail=0` | `pass=10 fail=0` | `pass=10 fail=0` |
| **`active_solver`** (check 10, read back from the running controller) | `PARTIAL_CONDENSING_OSQP` | ditto | ditto |
| **realtime rate** (check 2, `/clock` vs the wall) | **0.7515** | **0.7514** | **0.7498** |
| walking (check 8) | vx 0.2682 m/s, dx 4.02 m | 0.2686 | 0.2683 |
| no-fall (check 9) | belly 0 samples, z median 0.306 m, tilt over 0.5 rad 0.0 % | 0.299 m | 0.295 m |

Both composed values took effect, and both were *measured on the running stack*
rather than read back out of the file that asked for them: the solver from
`ros2 param get` (corroborated by the controller's own launch line, *"Set osqp
linear system solver to qdldl"*), and 0.75 from `/clock` against the monotonic
wall clock. That is #24's "assert the composed value, not just that something
runs", and #21's proof repeated by a machine.

### 5.5 The two failure classes

The negative controls, run as the sequence's **own command strings** — read
verbatim out of the shipped YAML and executed over ssh against a stack crippled
on purpose ([`evidence/negatives.txt`](evidence/negatives.txt)). A split Yuruna
run cannot be used for this; §6's F13 is why.

| | what was done | step 10 | step 11 *classify* | step 12 *assert* |
|---|---|---|---|---|
| **class 1** — a red stack | `pkill -x mitcontrollerno` in the container | records `rc=1` | **exit 0** — the recipe did look | **exit 1**, `ASSERT_FAILED`, the three logs tailed |
| **class 2** — infrastructure | `docker stop dfki_quad` | records `rc=2` | **exit 2**, `INFRASTRUCTURE` | never runs |

In class 1 the report the step printed shows exactly the right thing:
`node-graph … missing: /mit_controller_node`, `controller-alive … 0.00 Hz`, and
checks 5–9 `skipped, liveness gate (checks 2-4) failed` — `pass=2 fail=8`. The
failing step's description is what a reader sees in `status.json`, and the two
are different sentences.

### 5.6 The cycles

`KENNEL_CYCLES=2 kennel-demo.sh cycle --yes`, unattended
([`evidence/cycles.txt`](evidence/cycles.txt), and per cycle
[`cycle-1/`](evidence/cycle-1/), [`cycle-2/`](evidence/cycle-2/)):

```
[kennel-demo] cycle 1 ran for 42m54s        [kennel-demo] cycle 43  pass  2261s
[kennel-demo] cycle 2 ran for 43m19s        [kennel-demo] cycle 44  pass  2286s
[kennel-demo] all 2 cycle(s) green in 86m18s
```

**Two consecutive green cycles from cold** — #25's acceptance. Each destroyed
the guest *and its baseline*, installed Ubuntu from the ISO, built the stack,
froze a new baseline, proved the revert, and ran the MVP sequence to a walking
robot. The cycle time to record in
[#27](https://github.com/alius-git/kennel/issues/27) is **≈ 43 minutes**, of
which Yuruna's own accounting is 2261 s / 2286 s; the driver's extra ~5 minutes
is the pre-cycle sweep, the project clone and the config gate.

Where it goes, per sequence (cycle 1; the seconds column, never the formatted
one — F17):

| Chain link | Steps | Seconds |
|---|---|---|
| `start…kennel.ssh` — create + autoinstall the guest | 9 | 538 |
| `workload…kennel.ssh` — the sizing asserts (#9) | 8 | 2 |
| `workload…kennel.stack.ssh` — Docker + the pinned stack (#10) | 11 | 1449 |
| `workload…kennel.baseline.ssh` — clean it, freeze it (#51) | 5 | 37 |
| `workload…kennel.reset.ssh` — revert it, prove it (#51) | 12 | 71 |
| **`workload…kennel.mvp.ssh` — the demo, asserted (#24)** | **14** | **100** |
| | **59** | **2197** |

So the MVP link costs **100 seconds** on top of a provision that already takes
36 — under 5 %, for the part that actually asserts the product works.

And the verdict, from the cold path, on both cycles:

| | cycle 1 | cycle 2 |
|---|---|---|
| Yuruna | `pass`, 0 FAIL | `pass`, 0 FAIL |
| `warm_resume` events | **0** | **0** |
| verify | `completed`, `pass=10 fail=0` | `completed`, `pass=10 fail=0` |
| solver read back | `PARTIAL_CONDENSING_OSQP` | `PARTIAL_CONDENSING_OSQP` |
| realtime rate | 0.7514 | 0.7527 |
| walking | vx 0.2640 m/s, dx 3.959 m | 0.2646 m/s, 3.968 m |

Three things measured on the way that are worth keeping:

- **`differs from HEAD`: zero occurrences** across both cycles — §2.1's
  retirement, and the reason `provisioning.md` §4.2 is now marked retired.
- **The project reached the guest as a tarball**, never as a clone: the host
  serves `/yuruna-project-archive.tar.gz` (13.7 MB, `200`) and the guest
  extracts it into `~/yuruna/project`. That is why a `file://` `projectUrl`
  works here at all, and it is what makes `Test-Config`'s warning about the
  guest-side fallback benign (§5.2).
- **`status.json` records the *build* VM name**, `test-guest.ubuntu.server.24-01`,
  not the post-rename `kennel-vm-baseline`: the name is captured when the guest
  iteration starts, before `saveDiskSnapshot` renames it mid-chain. Harmless,
  but a reader of the dashboard should not go looking for a VM by that name
  afterwards.

### 5.6.1 The eternal runner — refused, and correctly

Issue #25 also names `Invoke-TestRunner.ps1`. On this host it **will not
start**, and that is the framework working as designed
([`evidence/runner-refused.txt`](evidence/runner-refused.txt)):

```
  RUNNER NOT STARTED -- elevation required
  This host needs passwordless sudo for the commands below. Without
  it a cycle would stop mid-run on a password prompt that nobody is
  present to answer, and the status page would keep reporting the
  last cycle as healthy.
```

The outer runner resolves elevation **once, at startup, while an operator is
still at the console**, because every later cycle runs in a fresh `pwsh` with a
cold sudo timestamp (`Invoke-TestRunner.ps1:325`). It needs
`/etc/systemd/system/yuruna-cacheproxy-p<port>.*` for the caching-proxy
forwarder, tries to install its own `/etc/sudoers.d/yuruna-runner` drop-in, and
refuses when it cannot: *"a host that needs a password typed needs hands on
it, exactly like a host with a broken network."* There is no bypass switch, and
adding one would be wrong.

So this leg is an **operator step**, in the same class as group membership and
the host installer ([`demo/runbook.md` §2](../demo/runbook.md)'s *needs you*
table). One line, then the loop runs:

```bash
echo 'thales ALL=(root) NOPASSWD: /usr/bin/systemctl, /usr/bin/tee, /usr/bin/rm' | sudo tee /etc/sudoers.d/yuruna-runner >/dev/null
sudo chmod 0440 /etc/sudoers.d/yuruna-runner && sudo visudo -cf /etc/sudoers.d/yuruna-runner
pwsh test/Invoke-TestRunner.ps1 -NoGitPull      # Ctrl+C in ITS terminal is the only stop
```

With the drop-in granted, it starts — and parks. **The second attempt sat in
its startup config gate for ninety minutes without creating a VM**, and the
cause is the terminal itself:

```powershell
# Test-Config.ps1:367 -- Invoke-HostClockSyncOffer
$canPrompt = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
if (-not $canPrompt) { return $false }
$ans = Read-Host "Host clock: resynchronize it against NTP now (needs Administrator / sudo)? [y/N]"
```

A pty is the only way to deliver the Ctrl+C that stops this runner (F16) — and
a pty is also what makes `[Environment]::UserInteractive` true with stdin
unredirected. This host's clock is **481 s slow**
([`vm/host-baseline.md` §2](../vm/host-baseline.md), open since #8), so the gate
offers to fix it and then waits for an answer that no one is there to give. Under
`Invoke-TestProject.ps1` the same gate runs with no tty, takes the
`return $false` branch, and passes — which is why §5.6's two cycles never saw it.

So the outer loop on *this* host needs either an operator at the keyboard, or a
clock inside the 120 s limit. Both are the same conclusion the elevation gate
reaches one layer up, and neither is a defect: an unattended runner wants a host
with nothing left to ask about.

What that leg would add over §5.6 is the outer loop's own scaffolding — the
elevation gate, the startup config gate, the backoff, the inter-cycle delay —
around a cycle body that is **the same `Invoke-TestRunnerInnerLoop.ps1` this
PR ran twice**. It is listed in *Still open* rather than claimed, with both
things it is waiting on named.

### 5.7 Nothing else moved

The nine console suites, no VM, on the branch
([`evidence/suites.txt`](evidence/suites.txt)):

```
serve 17   scope 78   generate 57   export 72   send 43
teleop 96  dashboard 85   runs 119   guides 62            629 checks, 9 × exit 0
```

Only `verify-runs` changed — 84 → **119**, all of it appended as group 8 — and
`git diff origin/main -- kennel_console/verify-*.py | grep '^-'` removes
nothing. The other eight suites are byte-identical to `main`.

Also on every commit of this branch: `bash -n` over all 39 tracked shell
scripts, `python3 -m py_compile` over the console and tool scripts, and a
`yaml.safe_load` of every `test/*.yml` — the last one now permanently, as group
8's own check (§3.1).

The framework clone was left as it was found: the three
[`vm/patches/`](../vm/patches/) files modified and the operator's config
backup, and nothing else. `repositories.projectUrl` is the one deliberate
change, and it is `file:///home/thales/kennel` — dev mode, §2 of
[`test/README.md`](README.md).


## 6. Findings

Eight, continuing the F-series of [`demo/dry-run.md` §4](../demo/dry-run.md)
(F11 was the last, in [#73](https://github.com/alius-git/kennel/issues/73)).
Four of them were found by the negative control, which is what it is for.

**F12 — one YAML scalar refused the whole cycle, four seconds in.** The first
`mvp` run died before its first step:

```
[1/1] in section: Sequence files (parse + snippets)
      Sequence '' failed to load: YAML parse error in …/project/test/test.runner.yml:
      "While scanning a plain scalar value, found invalid mapping."
```

The file said `description: The whole demo from a stock guest: the appliance
built and frozen…`. A plain scalar carrying `": "` is invalid YAML, and it reads
perfectly well to a person. What makes it a *cycle* problem rather than a typo
is Yuruna's pre-cycle gate: it parses **every `.yml` in every discovered `test/`
directory**, so one bad file in a project refuses the run before any step
executes. Fixed by quoting; guarded by group 8, which now parses every
`test/*.yml` (§3.1) — and promoted to a house rule in
[`CLAUDE.md`](../CLAUDE.md), because "everything under `test/` is live to
Yuruna" is not obvious from the outside.

**F13 — a sequence cannot be resumed against live state.** `-StartStep N` with
N > 1 **power-cycles the guest** before its first step:

```
Stopping concurrent VM 'kennel-vm-baseline' before the cycle starts.
VM 'kennel-vm-baseline' already exists. Reusing.
Starting VM 'kennel-vm-baseline'...
```

The runner skips that pre-sequence start **only** when the first executed step
is a `loadDiskSnapshot` (which is why a full run of this sequence never sees
it — the transcript says *"skipping pre-sequence start — first step is
loadDiskSnapshot"*). So the obvious way to build a negative control — run steps
1–9, break something, run steps 10–12 — cannot work: the second invocation
reboots the guest and the stack dies with it. §5.5's controls run the
sequence's own command strings over ssh instead, read verbatim out of the
shipped file, which is a closer proof anyway.

**F14 — and a guest boot empties `/tmp`.** `/usr/lib/tmpfiles.d/tmp.conf` on
Ubuntu 24.04 carries `D /tmp 1777 root root 30d`, and the capital `D` removes
the directory's *contents* at boot. So F13's reboot took the staged tools with
it and the recipe exited **127**. `$HOME` survives, which is where the fixture,
the applier and the run record live. Nothing to fix here — the stage step and
the launch are always on the same boot — but anything a sequence leaves in
`/tmp` is valid for that boot only, and the next reader of this repo should not
have to discover that twice.

**F15 — the classifier believed the shell.** That 127 was reported as
`ASSERT_FAILED: the stack is up but not healthy/walking`. It is nothing of the
kind: 127 is the shell saying the recipe does not exist, and blaming the robot
for a missing file is exactly the confusion the two-step classification exists
to prevent. The classify step now asks whether the code is one **the recipe
produces** — `0` or `1` — and treats everything else as infrastructure (§3.2).
On the same path it also labels the report it prints, which on an
infrastructure failure necessarily *predates* the run.

**F16 — `kill -INT` does not stop `Invoke-TestRunner.ps1`.** It registers
`[Console]::CancelKeyPress` (`Test.Prelude.psm1`,
`Register-EntryPointCancelHandler`), which a terminal Ctrl+C raises and a POSIX
signal does not. Probed on a throwaway `pwsh`: after `kill -INT` it was still
running and had to be `TERM`ed. Its own docstring says so — *"Stops only on
Ctrl+C"* — and it is the reason `cycle` wraps the single-cycle entry point
instead (§4).

**F17 — Yuruna's human-readable durations read a minute too long, and it is
exactly reproducible.** `91 s [All 14 steps completed in 2 min and 31 s]` — a
total that exceeds the wall clock of the process containing it. It is not the
measurement that is wrong, only its formatting: **the minutes are rounded and
the remainder is taken separately**, so `round(91/60) = 2` is printed beside
`91 mod 60 = 31`. Every duration whose remainder is ≥ 30 s therefore reads one
minute long, and every one below it happens to read correctly.

Checked against all twelve duration lines in this PR's transcripts — seven of
which are affected — and the rule explains every one:

| seconds | printed | true |
|---|---|---|
| 2 | `0 min and 2 s` | 0m02s ✓ |
| 37 | `1 min and 37 s` | 0m37s ✗ |
| 71 | `1 min and 11 s` | 1m11s ✓ |
| 91 | `2 min and 31 s` | 1m31s ✗ |
| 100 | `2 min and 40 s` | 1m40s ✗ |
| 538 | `9 min and 58 s` | 8m58s ✗ |
| 1449 | `24 min and 9 s` | 24m09s ✓ |

**Every number in §5 is taken from the seconds column**, which is correct, and
never from the formatted one. Filed for
[#28](https://github.com/alius-git/kennel/issues/28)'s upstream-gap backlog:
the fix is `[math]::Floor`, not `[math]::Round`.


**F18 — Yuruna's exec-bit lint now covers this repository.** Its Pester suite
(`Test.ShellScriptExecBit.Tests.ps1`) asserts that every tracked `*.sh` **in the
`project/` clone** is recorded 100755 — and this repo is now that clone. Four
were 100644: `demo/tools/scenario-lib.sh`,
`stack/composed-run/tools/p21-prove-realtime-rate.sh`,
`stack/known-good/tools/prelude.sh` and the moved
`test/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh`. Fixed with
`git update-index --chmod=+x`; sourcing an executable file is unaffected. Its
sibling check for non-`.sh` shebang files covers the framework only, so
`kennel_console/serve.py` and `stack/verify/tools/k14-solve-probe.py` are out of
its scope — recorded rather than changed.


**F19 — the false flakiness alarm, in this repo's own code.** Both cycles
reported `warm_resume events: 0` — as a **WARNING**, with the "this cycle went
green only after resuming a failed sequence" text under it. `grep -c` prints
`0` *and exits 1* when nothing matches, so `wr="$(grep -c … || echo 0)"` made
the count the two-line string `0\n0`, which is not the string `0`. Every clean
cycle was therefore reported as flaky — the one thing #25 asks this counter to
be trustworthy about. Fixed by letting `grep` print its own count and
defaulting only when the file is absent.

## 7. Bypasses

| | Retirement |
|---|---|
| **A checked-in fixture, not a driven browser.** The sequence applies `test/fixtures/run-<stamp>/` rather than composing in the UI, so what #24 automates is everything *after* the composer | browser automation in the full POC harness — scenario s001. Group 8 holds the line in the meantime: the fixture must remain something the console would emit today |
| **The driver runs a clone of *local* HEAD.** `KENNEL_PROJECT_URL` defaults to `file://<this repo>`, and this PR's cycles ran a `file://` URL, because `projectUrl` selects a repository and not a branch | the maintainer's first cycle against `https://github.com/alius-git/kennel` after this merges. The mechanism is identical; only the URL changes |
| **A green run's evidence leaves the guest only through a driver verb.** Yuruna keeps no output from a passing step and has no file-collection action, so `mvp` and `cycle` scp it | a Yuruna artifact action, or the appliance's own run-manifest store (#74/#76) |
| **The MVP asserts one composition.** One fixture, one solver, one rate — not the sweep of `stack/stress.md` | more `testSets` in `test.runner.yml` once there is a reason to spend 40 minutes per composition |


## 8. Still open

- **The eternal runner's own leg of #25** (§5.6.1), which needs **two** things
  this host does not have, both of them by design rather than by accident:
  passwordless sudo for the caching-proxy units (granted during this pass, and
  it cleared the gate), and a host clock inside the 120 s limit — otherwise the
  startup gate asks whether to resynchronize it and waits. The cycle *body* the
  loop would run is the one this PR ran twice; the scaffolding around it is what
  is unproven. `sudo chronyc makestep` and an attended terminal, or a host whose
  clock is already right.
- **A cycle against `https://github.com/alius-git/kennel`.** Everything here
  ran against a `file://` clone of this branch, because `projectUrl` names a
  repository and not a branch. The first cycle against the pushed URL is the
  maintainer's, after this merges.
- **`vm/test/`** still holds the two host-side reachability checks
  (`verify-meshcat-host.sh`, `verify-bridge-host.sh`), which are not sequences.
  A directory named `test` with no `.yml` is inert to discovery, so this costs
  nothing; moving them to where their callers live is housekeeping for another
  pass.
- **Yuruna's `status.json` names the build VM**, not the renamed one (§5.6).
  Cosmetic, and upstream's to fix if it matters.

---

Last review: 2026-09-10
