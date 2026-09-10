# `test/` — Kennel as a Yuruna project

This repository is a **Yuruna project**: point a Yuruna host's
`repositories.projectUrl` at it and the runner clones it, discovers the
sequences in this directory, and runs them. Nothing is copied into the
framework clone by hand any more.

The implementation record is [`test/harness.md`](harness.md); the operator
walkthrough of the demo itself is [`demo/runbook.md`](../demo/runbook.md).

## 1. The layout, and the rule behind it

```
test/
├── README.md                                   this page
├── harness.md                                  the implementation record (#23, #24, #25)
├── test.runner.yml                             which sequences a CYCLE runs
├── start.guest.ubuntu.server.24.kennel.ssh.yml     create the guest (#9)
├── workload.guest.ubuntu.server.24.kennel.ssh.yml           assert its size (#9)
├── workload.guest.ubuntu.server.24.kennel.stack.ssh.yml     provision the stack (#10)
├── workload.guest.ubuntu.server.24.kennel.baseline.ssh.yml  freeze the baseline (#51)
├── workload.guest.ubuntu.server.24.kennel.reset.ssh.yml     revert to it, prove it (#51)
├── workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml       the demo, asserted (#24)
├── ubuntu.server.24/                           guest scripts, by guest key
│   ├── ubuntu.server.24.dfki-quad.sh
│   ├── ubuntu.server.24.kennel-baseline-prep.sh
│   └── ubuntu.server.24.kennel-mvp-stage.sh
├── fixtures/run-<stamp>/                       the composition the MVP applies (§6)
└── evidence/                                   transcripts of the validated runs
```

Four conventions, and each of them is Yuruna's rather than ours:

- **Every directory named `test` under the project clone is a sequence
  directory.** Yuruna recurses `project/` for them and resolves a sequence by
  its exact file name, **project first, framework second** — so a project file
  silently overrides a framework file of the same name, and two *project* files
  of the same name are a fatal ambiguity. Sequences sit directly in the
  directory; there is no `sequences/` level.
- **A sequence's file name is its lookup key.** `resource:` chains and
  `test.runner.yml` name sequences by file name, so renaming one breaks every
  chain that names it. The `sequenceGuid` is what survives a rename, and it is
  what the perf log joins on.
- **Guest scripts live under `test/<guest-key>/`** and reach the guest as
  `project/test/<guest-key>/<script>.sh` — see §4.
- **`test.runner.yml` names only the top-level sequences.** Everything else in
  a cycle is derived by walking `resource:`.

`vm/test/verify-meshcat-host.sh` and `verify-bridge-host.sh` are **not**
sequences — they are host-side reachability checks the driver calls by path,
and they stay where their callers expect them.

## 2. Pointing a host at this repository

`~/git/yuruna/test/test.config.yml` is the operator's file (gitignored
upstream). `demo/tools/kennel-demo.sh setup` creates it from the template and
sets the first two keys; the third is a deliberate choice, described below.

```yaml
guestSequence:
- guest.ubuntu.server.24

repositories:
  projectUrl: https://github.com/alius-git/kennel
  # ...or, to run the branch you are sitting on rather than what is pushed:
  #   projectUrl: file:///home/you/kennel

vmStart:
  cleanupVmNamePrefixes: [kennel-vm-baseline]     # CI HOST ONLY -- see §3
```

`projectUrl` is a clone URL, not a branch selector: a cycle runs whatever the
default branch of that URL holds. To validate a branch, point it at your
checkout with `file://` — Yuruna clones the **committed HEAD** of it, so
uncommitted edits under `test/` do not run. `Test-Config.ps1` accepts a
`file://` URL and warns that only the host can resolve it; that warning is
expected here (§4 explains why the guest never needs to).

## 3. The two host roles, and the one setting that separates them

The kennel guest is renamed to `kennel-vm-baseline` when its baseline snapshot
is taken — that is `saveDiskSnapshot`'s contract, and it is what stops the
cycle's routine `test-` sweep from deleting the appliance
([`vm/snapshot.md`](../vm/snapshot.md) §2.1). Yuruna's own knob for that case
is `vmStart.cleanupVmNamePrefixes`, and it is applied **at cycle start and
again at cycle end**:

| | `cleanupVmNamePrefixes` | What a cycle does |
|---|---|---|
| **CI host** — nothing but cycles run here | `[kennel-vm-baseline]` | Sweeps the baseline before building, so every cycle is genuinely cold; sweeps it again at the end, so the host is left with no guest until the next cycle. |
| **Dev host** — you also demo from this machine | *unset* | The cycle would not sweep the baseline, and a cold build would then collide with it at the rename. Run cycles through **`kennel-demo.sh cycle`**, which sweeps both names itself and leaves the rebuilt baseline standing for the next `run`. |

Set it on a CI host, leave it unset on yours. `setup` never writes it.

## 4. How the guest gets project files

The guest never clones this repository. Two paths, both through the host:

- **At provisioning**, Yuruna's own `ubuntu.server.24.update.sh` downloads
  `/yuruna-project-archive.tar.gz` from the host's status service — a
  `git archive` of the project clone — into `~/yuruna/project` on the guest.
- **Per step**, `sshFetchAndExecute` runs
  `/usr/local/lib/yuruna/fetch-and-execute.sh project/test/<guest-key>/<script>.sh`,
  which fetches that path from `http://<host>:8080/yuruna-repo/project/…` —
  the framework clone's working tree, project included — and pipes it to bash.
  The host types a sha256 of the file it serves ahead of the command and the
  guest refuses bytes that do not match.

Two consequences worth knowing before you debug one of them:

1. **A private project has no GitHub fallback.** `fetch-and-execute.sh` falls
   back to `raw.githubusercontent.com` when the host is unreachable, and for a
   private repository that can only 404. The host's status service is therefore
   the only source, and a step fails *closed* when it is down. Every entry
   point that runs a sequence starts the service, so this is a real failure
   mode only when something else stopped it.
2. **The guest's `~/yuruna/project` is frozen into the baseline snapshot.** It
   is whatever the project was when the guest was provisioned. Nothing in a
   sequence should read it; fetch through the host instead, which is what the
   sequences here do.

**The host** needs a non-interactive git credential for a private `projectUrl`:
`gh auth login` installs one (`credential.helper = !gh auth git-credential`),
or set `repositories.ghToken` to a fine-grained, `Contents: Read-only` token
scoped to this repository — Yuruna's documented path, which also feeds
`GIT_ASKPASS` on the guests.

## 5. Running it

```bash
cd ~/git/yuruna
virsh list --all > /dev/null                       # wake socket-activated libvirtd
pwsh test/Test-Config.ps1 -SkipSend                # the gate: 0 FAIL, and no
                                                   # finding naming a kennel file
pwsh test/Invoke-TestSequence.ps1 -SequenceName workload.guest.ubuntu.server.24.kennel.reset.ssh
pwsh test/Invoke-TestProject.ps1                   # ONE cycle, exactly as the runner runs it
pwsh test/Invoke-TestRunner.ps1 -NoGitPull         # the eternal loop; Ctrl+C is the only stop
```

Read the findings, never the PASS/WARN totals — they drift with upstream
([`vm/provisioning.md`](../vm/provisioning.md) §4.3).

Three things about those commands that are easy to get wrong:

- **`Invoke-TestSequence.ps1` and `Invoke-TestProject.ps1` re-clone `project/`
  from `test.config.yml` before they run**, so a sequence you just edited in
  your checkout is not what runs unless you committed it *and* `projectUrl`
  points at your checkout. `kennel-demo.sh` clones the project itself and then
  passes `-NoProjectClone`, so its verbs always run this checkout's HEAD.
- **`Invoke-TestRunner.ps1` stops only on Ctrl+C from its own terminal.** It
  listens for a console cancel key, not for a signal, so `kill -INT` will not
  stop it. `-NoGitPull` matters too: this framework clone sits detached at a
  release tag with three local patches, and the outer loop's `git pull` has
  nothing useful to do on it.
- **Issue #25 calls the single-cycle entry point `Test-Project.ps1`.** At
  Yuruna 2026.08.04 it is `Invoke-TestProject.ps1`; the older name does not
  exist.

The driver wraps all of it, with preflight and evidence collection:

| | |
|---|---|
| `kennel-demo.sh mvp` | the MVP sequence — warm (~100 s) on a host that holds the baseline, the whole cold chain on one that does not |
| `kennel-demo.sh cycle [--yes]` | one full cycle from cold, sweeping the guest **and its baseline** first; `KENNEL_CYCLES=2` for two in a row |
| `kennel-demo.sh reset` / `provision` | the warm and cold paths of the baseline sequence, unchanged since #51 |

Each of them clones this checkout into `$YURUNA_DIR/project` first and then
runs its sequence with `-NoProjectClone`, so what runs is the branch you are on
— its **committed** head. See [`demo/runbook.md`](../demo/runbook.md) §3.

## 6. The fixture

`test/fixtures/run-<stamp>/` is a run folder the **console exported**: the
composition the MVP sequence applies to the guest (flat plane, realtime rate
0.75, `PARTIAL_CONDENSING_OSQP`). It is a *bypass* — issue #24 wanted the
harness to drive the browser, and driving the browser from a Yuruna sequence is
the full POC harness's job (s001).

Two rules, and the second is the one that bites:

1. **Never edit a file in it.** Regenerate the whole folder:
   `demo/tools/kennel-demo.sh compose` (no knobs), then copy the new
   `~/kennel-runs/run-<stamp>/` in and delete the old one.
2. **The sequence restates it** — the folder name, the pin, the solver and the
   sha256 of each YAML — so a regenerated fixture needs those four updated in
   `workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml` too. Otherwise the run
   goes red at the apply step, which is the intended failure and not a
   mystery. `kennel_console/verify-runs.sh` group 8 checks all of it without a
   VM; run it after any change here.
