# The baseline snapshot — returning the guest to known-good in seconds

Implementation record for
[issue #51](https://github.com/alius-git/kennel/issues/51) — the kennel guest
gains a **baseline**: a Yuruna disk snapshot of the provisioned, stock,
built appliance, and a verb that returns to it.

Before this, the guest was a one-way artifact. Every mistake — a bad config, a
half-applied run, a wedged container, an experiment that changed something
nobody wrote down — cost a **~35-minute re-provision**, because re-provisioning
was the only way back to a known state. After it, the same mistake costs
**about ninety seconds**, of which the revert itself is one.

Builds on [`vm/provisioning.md`](provisioning.md)
([#10](https://github.com/alius-git/kennel/issues/10)) and
[`demo/runbook.md`](../demo/runbook.md)
([#27](https://github.com/alius-git/kennel/issues/27)). Read
[`vm/provisioning.md` §4.3](provisioning.md) first — `provision` is the verb
this changes most.

> **Bypass note (tracking-issue [#7](https://github.com/alius-git/kennel/issues/7),
> [#26](https://github.com/alius-git/kennel/issues/26)):** this snapshot **is**
> the MVP's reset-to-baseline. [`plan/design/02-appliance.md`](../plan/design/02-appliance.md)
> specifies reset against an immutable OVA and its generated version manifest —
> "pinned inputs become an immutable OVA whose … identity … release gating, drift
> checking, reset, and every scenario assert against". There is no OVA yet
> ([`provisioning.md`](provisioning.md)'s own bypass: the MVP builds the stack
> in place instead of shipping an image), so the baseline is a **host-local disk
> snapshot** of the guest that script produced, and `~/.kennel-baseline` is a
> three-line stand-in for the version manifest. What it gives up: the baseline
> is not distributable, not reproducible on another host, and not content-addressed
> — it is *this* host's copy of *this* build. *Retirement path:* the
> `appliance/build` pipeline. When the OVA exists, `reset` re-imports it and
> `~/.kennel-baseline` becomes the manifest the design already describes.

## 1. What is delivered

| Artifact | Purpose |
|----------|---------|
| [`test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh`](../test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh) | Guest-side: make this guest a clean baseline, and **refuse** if it is not one |
| [`test/workload.guest.ubuntu.server.24.kennel.baseline.ssh.yml`](../test/workload.guest.ubuntu.server.24.kennel.baseline.ssh.yml) | Producer sequence: prep, assert, `saveDiskSnapshot` |
| [`test/workload.guest.ubuntu.server.24.kennel.reset.ssh.yml`](../test/workload.guest.ubuntu.server.24.kennel.reset.ssh.yml) | Consumer sequence: `loadDiskSnapshot`, then prove what came back is the appliance |
| [`demo/tools/kennel-demo.sh`](../demo/tools/kennel-demo.sh) | Verbs `up`, `reset`, `snapshot`; `provision` now sweeps both names and ends in the snapshot |

The chain, with the two new links at the end:

```
start.guest.ubuntu.server.24.kennel.ssh                    # create the 8 vCPU / 16 GiB guest
  -> workload.guest.ubuntu.server.24.kennel.ssh            # assert the sizing landed (#9)
    -> workload.guest.ubuntu.server.24.kennel.stack.ssh    # provision the stack (#10)
      -> workload.guest.ubuntu.server.24.kennel.baseline.ssh   # clean it, freeze it (#51)
        -> workload.guest.ubuntu.server.24.kennel.reset.ssh    # revert to it, prove it (#51)
```

`provision` and `reset` **run the same top-level sequence**. What separates a
35-minute build from a 90-second revert is not the command but the host: Yuruna's
`requiresSnapshot` probe looks for the snapshot before doing anything, and takes
the cold path or the warm one accordingly.

## 2. What Yuruna already provided

Yuruna `2026.08.04` has the whole mechanism; Kennel had simply never used it. No
patch was needed, and none was written — a fourth entry in
[`vm/patches/`](patches/) would have been a fourth thing to re-apply on every
host.

| Piece | Where | Behaviour |
|---|---|---|
| `saveDiskSnapshot` (param `id`) | `test/sequences/actions.yml`; handler in `test/modules/Test.SequenceHandler.psm1` | Stops the VM if running, **renames the domain to `id`** and relocates `~/yuruna/vms/<old>` → `<id>` (rewriting disk paths in the XML), then `virsh snapshot-create-as --atomic`, then writes a manifest sidecar. **Leaves the VM stopped.** Overwrites a same-`id` snapshot. |
| `loadDiskSnapshot` (param `id`) | same | Checks the snapshot exists, checks the manifest, `virsh snapshot-revert`, then `Start-VM`. The guest boots fresh → re-DHCP, so downstream steps must gate on `sshWaitReady`. |
| `requiresSnapshot: {id: X}` | top-level sequence key; runner logic in `test/modules/Test.SequenceRunner.psm1` | **Warm:** VM `X` has snapshot `X` → every prereq sequence is skipped and only the top-level runs. **Cold:** absent → the full chain runs and `saveDiskSnapshot` renames mid-chain. |
| KVM driver | `host/ubuntu.kvm/modules/Yuruna.Host.psm1` (`Rename-VM`, `Save-VMDiskSnapshot`, `Test-VMDiskSnapshot`, `Restore-VMDiskSnapshot`) | The rename happens **before** the snapshot, and must. |
| Manifest sidecar | `test/modules/Test.SnapshotManifest.psm1` | `<runtimeDir>/snapshots/<vm>__<id>.manifest.json`. Missing → warn and proceed; **present but mismatched → hard refuse**. |
| Cleanup sweep | `test/Remove-TestVMFiles.ps1 -Prefix ...` | Literal prefix match, `[string[]]`. `test-` no longer matches the renamed VM — that is the point. |

### 2.1 The one decision: the id is also the domain name

`saveDiskSnapshot`'s `id` is not just a snapshot label. It becomes the libvirt
**domain name**, and the runner's warm-path probe looks for *snapshot `id` on VM
`id`*. So the choice of `kennel-vm-baseline` decides three things at once, and
the constraints are:

- it must be valid as a domain name on every host the sequence targets;
- it must **not** start with `test-`, or the next cycle's sweep would delete the
  very thing the snapshot exists to preserve;
- it must not be the guest's *hostname*. `kennel-vm` is the DHCP lease hostname
  every host-side kennel tool discovers by ([`meshcat-exposure.md` §3.1](meshcat-exposure.md)),
  and keeping the two distinct is what makes the rename a non-event (§5.1).

Yuruna's own `test.config.yml` anticipates this exact promotion: `vmStart.cleanupVmNamePrefixes`
exists, in its words, for "a project whose VMs are promoted out of the test-VM
namespace (a snapshot id becomes the VM name)". Kennel passes the prefixes on
the command line instead, so the behaviour travels with the repo rather than
with one host's config — but a host running the **full cycle**
([#25](https://github.com/alius-git/kennel/issues/25)) should set
`cleanupVmNamePrefixes: [kennel-vm-baseline]` there too, because the cycle sweep
does not go through `kennel-demo.sh`.

**Measured, 2026-09-10 ([#25](https://github.com/alius-git/kennel/issues/25),
[`test/harness.md`](../test/harness.md) §4.1):** that setting is right for a
*CI* host and wrong for this one. The sweep runs with the same prefixes at
**cycle start and again at cycle end** (`Test.RunnerInnerLoop.psm1:2524`,
`:2874`), so setting the key means every cycle also destroys the baseline on
its way out and leaves the host with no guest until the next one. A host that
is also a demo machine therefore leaves it **unset** and runs cycles through
`kennel-demo.sh cycle`, which sweeps both names itself before each build: the
build is just as cold, and the baseline the cycle takes survives its
`test-`-only end sweep. Both roles are written up in
[`test/README.md` §3](../test/README.md).

### 2.2 Why the rename must precede the snapshot

Recorded because the upstream documentation says the opposite, and because the
failure it produces is unreadable. `actions.yml` describes the order as "AFTER
the snapshot succeeds, the VM is RENAMED"; the KVM driver does the reverse, and
its own comment explains why:

> libvirt freezes a full copy of the domain XML inside the snapshot metadata,
> and neither `virsh domrename` nor a later `virsh define` rewrites that frozen
> copy. […] when `Restore-VMDiskSnapshot` later runs `snapshot-revert`, libvirt
> tries to reinstate a domain whose disks live at a directory the rename already
> moved away, and fails with the unhelpful "An error occurred, but the cause is
> unknown".

The implementation is right and the prose is stale. This matters to Kennel only
in one way, and it is the reason `kennel-demo.sh snapshot` calls
`Save-VMDiskSnapshot` rather than doing the rename itself: **the ordering is a
property of the host driver, not of this repo**, and re-implementing it would
mean owning that bug.

A second discrepancy, same shape: the schema for `requiresSnapshot` says the VM
name becomes `id` "from the start", making the cold-path rename a no-op. The
runner applies that override **only on the warm path**
(`Invoke-TestSequence.ps1`, `if ($plan.warmPath -and …) { $VMName = … }`), so a
cold build really is created as `test-guest.ubuntu.server.24-01` and really is
renamed mid-chain. Kennel depends on the code's behaviour, not the schema's
description — which is precisely why `provision` sweeps **both** names.

## 3. The two sequences

**Producer** — `workload.guest.ubuntu.server.24.kennel.baseline.ssh`. Chains onto
the #10 stack sequence. `sshWaitReady` → smoke → the prep script → assert the
recorded pin → `saveDiskSnapshot`. Nothing follows the snapshot, because the VM
is stopped when it returns.

**Consumer** — `workload.guest.ubuntu.server.24.kennel.reset.ssh`. Declares
`requiresSnapshot: {id: kennel-vm-baseline}`, chains onto the producer, and
restates `username` / `hostname` / `memoryStartupBytes` / `cores`.

Two constraints on the consumer, both of them things the engine enforces
silently:

- **`loadDiskSnapshot` must be the first executed step.** The runner skips its
  pre-sequence `Start-VM` only when the first step is a `loadDiskSnapshot`
  (the handler starts the VM itself, after the restore). Executed steps are
  `component` ++ `workload`, so it goes at the top of `component`. Put it in
  `workload` and the runner boots the guest first, then reverts a running guest.
- **The variables must be restated.** Sizing is declared once, in the start
  sequence, and cascaded down the chain — which is exactly what the warm path
  does not do. With every prereq skipped there is nothing to cascade from.
  They must stay equal to the start sequence's values, or a *cold* run through
  this file would build a differently-sized guest than the snapshot was taken on.

### 3.1 What the prep script asserts, and why each clause

A snapshot is the one artifact whose defects are invisible: a baseline taken
over a composed run silently returns that composed run for the rest of the
guest's life. So every clause of "clean baseline" is asserted rather than
assumed, and the script **refuses** rather than producing a bad baseline.

| Phase | Assertion | Why it is not optional |
|---|---|---|
| stop the stack | — | A container stopped hard by VM power-off restores in an undefined state |
| assert the clone is stock | no **tracked** file differs from the pin | This is what catches a composed run: `transfer` overwrites the two YAMLs in place |
| assert the workspace is built | build stamp **and** `ws/install/setup.bash` | A baseline without a build freezes the 35 minutes back in |
| clear the staging directory | — | No run is "current" in a baseline |
| record the baseline | writes `pin`, `image_id`, `created` | A revert that cannot say what it returned is not a baseline |
| reclaim | — | Every reclaimed byte is a byte the snapshot carries forever |

The stock assertion runs **before** the staging directory is cleared, which is a
deliberate deviation from the order [`plan/next-goals.md`](../plan/next-goals.md)
sketched. When the assertion fails, `~/kennel-staging/current-run` is the only
thing on the guest that names *which* run dirtied it; deleting it first would
throw away the diagnosis.

## 4. Running it

Three verbs, from the repo root, on the host.

```bash
demo/tools/kennel-demo.sh up         # start the guest and make it reachable
demo/tools/kennel-demo.sh reset      # revert to the baseline  (~1.5 min)
demo/tools/kennel-demo.sh snapshot   # re-take the baseline from a green guest
```

`provision` is unchanged in spirit and different in two ways: it sweeps **both**
VM names before rebuilding, and it runs the *reset* sequence as its top level,
so provisioning now ends in a snapshot and proves the revert on its way out.

| Verb | Wraps | Ends with |
|---|---|---|
| `up` | `virsh start` + lease/SSH poll + `docker start` | the guest reachable, container running, `status` |
| `reset` | `Invoke-TestSequence.ps1 -SequenceName …kennel.reset.ssh` (warm) | the baseline, asserted, container running |
| `snapshot` | the prep script over SSH + `Save-VMDiskSnapshot` | a new `kennel-vm-baseline`, VM **stopped** |
| `provision` | sweep both names + the same sequence (cold) | a rebuilt guest **and** its baseline |

### 4.1 Knobs

| Variable | Default | Meaning |
|---|---|---|
| `KENNEL_SNAPSHOT_ID` | `kennel-vm-baseline` | snapshot id **and** persisted domain name |
| `KENNEL_VM_DOMAIN` | *(discovered)* | name the libvirt domain directly, for `up` / `snapshot` |
| `KENNEL_UP_TIMEOUT` | `600` | bound on `up`'s lease-and-SSH wait |
| `KENNEL_BUILD_DOMAIN` | `test-guest.ubuntu.server.24-01` | what Yuruna calls the guest before the rename |
| `KENNEL_STOP_TIMEOUT` | `30` | seconds `docker stop` gets in the prep script |

### 4.2 Exit codes

The prep script follows [`stack/verify.md` §1](../stack/verify.md): `0` the guest
is a clean baseline, `1` an assertion failed and it says which, `2` it could not
even look (no docker, no clone, no container). `snapshot` propagates them, so a
refusal is distinguishable from a broken host. `up` adds `3` — the guest never
became reachable within the bound.

### 4.3 Why `snapshot` exists beside `provision`

`provision` produces a baseline from clean, which is the one with provenance.
`snapshot` re-takes it from a guest that is *already* green — after a repin, or
after deliberately changing something worth keeping. It is the verb that turns a
35-minute rebuild into an opt-in, and it is why the prep script's refusal matters:
`snapshot` is the path where a human might otherwise freeze a dirty guest.

## 5. Validation — evidence

All measured on 2026-08-30, on the host of [`vm/host-baseline.md`](host-baseline.md).
Transcripts in [`vm/snapshot/evidence/`](snapshot/evidence/).

| Evidence | What it shows |
|---|---|
| [`01-before.txt`](snapshot/evidence/01-before.txt) | The host before any snapshot work: one `test-guest…` domain, no snapshots |
| [`02-up.txt`](snapshot/evidence/02-up.txt) | `up` on a shut-off guest: reachable in **13 s**, container started |
| [`03-negative-dirty.txt`](snapshot/evidence/03-negative-dirty.txt) | **Negative control** — `snapshot` refuses a guest with a composed run applied |
| [`04-snapshot.txt`](snapshot/evidence/04-snapshot.txt) | The prep script's six phases, then the rename + save: **33 s** end to end |
| [`05-after-rename.txt`](snapshot/evidence/05-after-rename.txt) | What the rename did to libvirt (§5.1), and the stale pool it leaves |
| [`06-reset-1.txt`](snapshot/evidence/06-reset-1.txt) | First warm-path `reset`, from a stopped guest |
| [`07-all-before-reset.txt`](snapshot/evidence/07-all-before-reset.txt) | A full `all` against the **renamed** domain: `pass=10 fail=0` |
| [`08-dirty-state.txt`](snapshot/evidence/08-dirty-state.txt) | qcow2 divergence after one dirtying cycle (§5.3) |
| [`09-reset-2-from-dirty.txt`](snapshot/evidence/09-reset-2-from-dirty.txt) | `reset` from a dirty, **running**, trotting guest |
| [`10-all-after-reset.txt`](snapshot/evidence/10-all-after-reset.txt) | The `all` that hit the launcher race — [#52](https://github.com/alius-git/kennel/issues/52) |
| [`11-verify-rerun.txt`](snapshot/evidence/11-verify-rerun.txt) | `verify` alone on that same stack: `pass=10 fail=0`. The stack was fine |
| [`12-reset-twice.txt`](snapshot/evidence/12-reset-twice.txt) | `reset` twice in a row: **1m22s**, **1m21s**, 12/12 both times |
| [`13-all-after-reset-2.txt`](snapshot/evidence/13-all-after-reset-2.txt) | `all` after a reset: `pass=10 fail=0`, **1m38s** |
| [`14-provision-sweep-defect.txt`](snapshot/evidence/14-provision-sweep-defect.txt) | **The F3 defect caught in the act** — the sweep matched nothing and `provision` silently became a `reset` |
| [`14-provision-cold.txt`](snapshot/evidence/14-provision-cold.txt) | `provision` from clean after the fix: the cold chain end to end, ending in the snapshot |
| [`15-provision-persisted.txt`](snapshot/evidence/15-provision-persisted.txt) | A second `provision`, with the persisted VM and its snapshot present beforehand — proves the sweep. Completed **45 steps, 38m44s**, ending in the snapshot; the shell errors in its tail are the driver being edited while bash was reading it, annotated in the file itself |
| [`16-all-on-cold-provisioned.txt`](snapshot/evidence/16-all-on-cold-provisioned.txt) | `all` on the cold-provisioned guest — hit [#52](https://github.com/alius-git/kennel/issues/52) a second time |
| [`17-verify-rerun-2.txt`](snapshot/evidence/17-verify-rerun-2.txt) | …and `verify` alone on that same stack: `pass=10 fail=0` |

### Measured

| Operation | Wall clock |
|---|---|
| `saveDiskSnapshot` — rename, relocate, snapshot | **2–3 s** |
| `loadDiskSnapshot` — the revert itself | **1–2 s** |
| revert → sshd answering | **10–11 s** |
| `reset` end to end | **1m21s – 1m23s** |
| …of which the launchable-simulator smoke | **56 s** — the revert is not the cost, the proof is |
| `up` on a shut-off guest → reachable | **13 s** |
| `snapshot` on a green guest (prep + save) | **33 s** |
| `all` on a freshly reset guest | **1m38s**, `pass=10 fail=0` |

The headline: **35 minutes → ~90 seconds**, and two thirds of the 90 seconds is
the sequence proving the guest works, not the guest coming back.

And what the safety net costs, from the cold-path run
([`14-provision-cold.txt`](snapshot/evidence/14-provision-cold.txt)) — **45 steps
across 5 sequences, 0 FAIL, 35m25s**:

| Chain link | Steps | Wall clock |
|---|---|---|
| `start…kennel.ssh` — create + autoinstall the guest | 9 | 8m23s |
| `workload…kennel.ssh` — the sizing asserts (#9) | 8 | 13s |
| `workload…kennel.stack.ssh` — the stack (#10) | 11 | 25m48s |
| **`workload…kennel.baseline.ssh` — clean it, freeze it** | **5** | **1m35s** |
| **`workload…kennel.reset.ssh` — revert it, prove it** | **12** | **1m11s** |
| | **45** | **35m25s** |

So the baseline costs **2m46s** on top of a provision that already took 33
minutes — under 8% — and buys back 35 minutes on every subsequent mistake. The
mid-chain rename is visible in that transcript exactly where it should be:

```
saveDiskSnapshot: VM renamed 'test-guest.ubuntu.server.24-01' -> 'kennel-vm-baseline';
                  subsequent steps will target 'kennel-vm-baseline'.
VM renamed mid-chain: 'test-guest.ubuntu.server.24-01' -> 'kennel-vm-baseline';
                  subsequent entries will target 'kennel-vm-baseline'.
```

### 5.1 The rename changes nothing that matters — checked, not assumed

After `saveDiskSnapshot` the domain is `kennel-vm-baseline` and its files live in
`~/yuruna/vms/kennel-vm-baseline/`. Observed:

- `virsh domblklist kennel-vm-baseline` lists three devices and **all three paths
  exist**: the relocated and renamed qcow2, the install ISO (which lives in
  `image/`, not in the VM directory, so it was never moved), and the relocated
  `seed.iso`. Both CD attachments survive.
- **Guest discovery is unaffected**, which is the whole reason this is safe:
  every host-side kennel tool finds the guest by DHCP lease *hostname*, never by
  domain name. A full `all` — `kennel-transfer.sh`, `p21-launch-from-commands.sh`,
  `kennel-verify.sh`, `verify-meshcat-host.sh` — ran green against the renamed
  domain without knowing it had been renamed.
- The manifest sidecar is written under the **new** name
  (`kennel-vm-baseline__kennel-vm-baseline.manifest.json`), which is what the
  restore looks for. `kennel-demo.sh snapshot` writes it the same way the step
  handler does, using the host's own `Get-HostType` rather than a literal —
  a missing manifest is only a warning, but a manifest with the *wrong* host
  type is a hard refusal to restore.

**One thing the rename does leave behind.** The per-VM libvirt storage pool is
created implicitly by `virt-install`, not by Yuruna, and nothing renames or
removes it:

```console
$ virsh pool-refresh test-guest.ubuntu.server.24-01
error: Failed to refresh pool test-guest.ubuntu.server.24-01
error: cannot open directory '/home/thales/yuruna/vms/test-guest.ubuntu.server.24-01': No such file or directory
```

The pool stays `active` and `autostart`, pointing at a directory that has moved.
It is inert — libvirt addresses the domain's disks by path from the domain XML,
not through a pool — and a later `provision` re-creates that directory under the
same name, which is why nothing has ever broken. It is recorded because it looks
alarming in `virsh pool-list --all` and because it is genuine untidiness Yuruna
should eventually own: `Remove-VM` asks `undefine` for snapshot, checkpoint,
NVRAM and managed-save metadata, but never touches pools. Filed as part of
[#28](https://github.com/alius-git/kennel/issues/28)'s upstream-gap backlog.

### 5.2 Two guests answering to `kennel-vm`

If a stale `test-guest…` survived beside `kennel-vm-baseline`, both would request
a lease as `kennel-vm` and discovery — which takes `tail -1` — would pick
whichever renewed last. `provision` makes that impossible by sweeping **both**
names before rebuilding; `up` and `snapshot` can only warn, and do:

```
[kennel-demo] WARNING: more than one domain could be 'kennel-vm': …
[kennel-demo] WARNING: using '…'. While both exist, lease discovery is a coin flip --
[kennel-demo] WARNING: destroy the stale one (virsh undefine), or set KENNEL_VM_DOMAIN.
```

### 5.3 Snapshot semantics and what they cost

The snapshot is **internal to the qcow2** and disk-only — the VM is stopped when
it is taken, so there is no RAM state to capture, and `--atomic` rolls back a
partial creation. At save time it costs essentially nothing (`qemu-img info`
reports `VM SIZE 0 B`). Divergence accumulates inside the same file as the guest
is used:

| Moment | qcow2 file length |
|---|---|
| at the snapshot | 26,853,179,904 B |
| after one full `all` cycle | 26,886,340,608 B (**+33 MB**) |

That is the price of one dirtying run. It is not reclaimed by a revert — the
data stays in the file as divergence from the snapshot point — so a guest that
lives through hundreds of cycles will grow. `provision` from clean is the reset
for *that*, and there is no snapshot chain to worry about: there is exactly one
snapshot, overwritten in place by `snapshot`.

### 5.4 The container is stopped after every revert — correct, not a defect

There is no `--restart` policy on `dfki_quad`, by design
([`provisioning.md` §3.2](provisioning.md)), and the prep script stops it
deliberately besides. So the restored guest has a stopped container. `reset`
starts it (step 8) and `up` starts it; `status` and `walk` still do not. A
`status` run between a reset and a launch therefore says:

```
[kennel-demo] Meshcat not reachable (simulator not running, or guest down).
```

which is correct. Nothing is running yet.

### 5.5 The pin is frozen inside the snapshot

Repinning ([s009](../plan/design/seq.s009.repin.md)) is a `provision` from clean,
not a reset — the snapshot carries the old pin's clone, image and build. Three
independent restatements of the SHA catch a mismatch: the prep script's literal,
the producer sequence's assert, and the consumer sequence's assert. That is the
same enforcement-by-assertion [`provisioning.md` §8](provisioning.md) settled on,
extended one link further down the chain.

## 6. Findings

Five defects found by running this. Three are fixed here; one is upstream and is
recorded so nobody else pays for it; one belongs to another tool and is filed
rather than smuggled in.

**F1 — `git status --porcelain` can never be empty on a healthy guest.** The
first version of the stock assertion used it directly, as the plan specified, and
refused every real baseline:

```
     M ws/src/controllers/config/mit_controller_sim_go2.yaml
     M ws/src/simulator/config/simulator_params_go2.yaml
    ?? ws/.kennel-built-dcf53c596339afd45b82f12c54b1e93e8273c2f4
```

The first two lines are the composed run — exactly what the assertion is for. The
third is the **build stamp**, which lives inside the clone's worktree and is not
covered by upstream's `.gitignore` (that file ignores `ws/build`, `ws/install`,
`ws/log`, `ws/data`, but not a dotfile beside them). It is present on every
correctly provisioned guest, by construction. Fixed by asserting on
`--untracked-files=no`: what "stock" means is that no **tracked** file differs
from the pin, and the composed YAMLs are tracked. Untracked entries are build
artifacts; the script lists them and does not judge them.

**F2 — a Yuruna step that only prints leaves no record of a passing run.** The
producer and consumer sequences originally ended with an "evidence block" step in
the style of the #9 and #10 sequences. `sshExec` captures output *only when the
step fails* — it is absent from the HTML log and from `cycle.events.ndjson` — so
on a green run those steps recorded nothing at all. Fixed two ways: the fact
worth having (*no composed run is applied*) became an **assertion**, because
anything worth knowing is worth failing on; and `kennel-demo.sh reset` prints
`~/.kennel-baseline` host-side, so the operator's own transcript carries which
baseline came back.

**F3 — `-Prefix a,b` from bash binds as ONE string, so the sweep matched nothing
and `provision` silently became a `reset`.** The worst defect of the four,
because it failed *quietly and plausibly*. `Remove-TestVMFiles.ps1` declares
`-Prefix` as `[string[]]`, and the plan's instruction was to verify it "accepts
the list form". It does — but you cannot hand it one from a shell:

```console
$ pwsh -File argtest.ps1 -Prefix "test-,kennel-vm-baseline"     # count=1  [test-,kennel-vm-baseline]
$ pwsh -File argtest.ps1 -Prefix test-,kennel-vm-baseline       # count=1  [test-,kennel-vm-baseline]
$ pwsh -Command "& ./argtest.ps1 -Prefix @('test-','kennel-vm-baseline')"
                                                                # count=2  [test-] [kennel-vm-baseline]
```

Comma-as-array is a PowerShell **parser** feature; arguments arriving through a
bash `argv` are bound as the literal strings they are — quoted or not, it makes
no difference. The first `provision` run therefore reported

```
Stopping VMs with prefix 'test-,kennel-vm-baseline'...
  No VMs found matching 'test-,kennel-vm-baseline'.
Removed 0 VM(s); 0 survivor(s).
```

— left the persisted VM and its snapshot in place, and then the `requiresSnapshot`
probe found that snapshot and took the **warm** path. What was meant to be a
35-minute rebuild from clean finished in 1m23s, exit 0, twelve steps PASS, and
looked entirely healthy ([`14-provision-sweep-defect.txt`](snapshot/evidence/14-provision-sweep-defect.txt)).
A `provision` that quietly does not provision is worse than one that fails.

Fixed by invoking through `-Command` with a real array literal. The one-line
tell that it is now working is the sweep's own label, which joins on `', '`:

```
Stopping VMs with prefix 'test-', 'kennel-vm-baseline'...     # two elements — correct
Stopping VMs with prefix 'test-,kennel-vm-baseline'...        # one element  — the defect
```

**F4 — `Remove-TestVMFiles.ps1 -WhatIf` deletes the VM.** Found the direct way,
while trying to dry-run the F3 fix: the "dry run" stopped a running guest,
undefined it, and deleted its 25 GB disk. The script is a plain `param()` script
with no `[CmdletBinding()]`, so `-WhatIf` is not a supported common parameter and
never reaches `$WhatIfPreference`; the internal `Remove-VM -Confirm:$false` calls
then proceed exactly as they would have. Nothing in Kennel depends on `-WhatIf`,
and nothing here was lost — the next step was a destroy-and-rebuild — but a flag
that reads as "show me what you would do" and instead reclaims 25 GB is worth
never learning twice. Recorded for [#28](https://github.com/alius-git/kennel/issues/28)'s
upstream-gap backlog alongside the storage-pool leak of §5.1. **Do not pass
`-WhatIf` to that script.**

**F5 — found here, deliberately *not* fixed here.**
[#52](https://github.com/alius-git/kennel/issues/52):
`p21-launch-from-commands.sh` returns before `/joy_to_target` has joined the ROS
graph, so `verify`'s node-graph check can fail even though the stack is fine.
The launcher gates on the controller reaching `Starting controller` in its log;
`joy_to_target.py` is launched by the same block but is a separate `python3`
process that registers with the graph on its own schedule, and nothing waits for
it.

Reproduced twice, and the two reproductions agree on the cause: both were on a
**cold container** — one freshly reverted, one freshly provisioned — where
`docker start` had run seconds earlier (there is no `--restart` policy, by
design). A container that has been up a while wins the race; a cold one can lose
it. Both times, `verify` re-run alone against the same untouched stack gave
`pass=10 fail=0` ([`11-verify-rerun.txt`](snapshot/evidence/11-verify-rerun.txt),
[`17-verify-rerun-2.txt`](snapshot/evidence/17-verify-rerun-2.txt)).

**This matters to the acceptance of this issue**, and is recorded rather than
hidden: "dirty the guest, `reset`, then `all` is green" is intermittently *not*
green, because `reset` is exactly the workflow that guarantees a cold container.
Measured here: green on 2 of 4 attempts, and healthy on 4 of 4 when `verify` is
allowed to look a second time. The snapshot returns a working guest every time;
the launcher's readiness gate is what is unreliable.

It is left to #52 on purpose. The fix belongs in
`stack/composed-run/tools/p21-launch-from-commands.sh` — wait for the node graph
to carry all six nodes, not just for one log line, which is what
[`dry-run.md` F8](../demo/dry-run.md)'s "waits observe the stack, never sleep"
already asks for. That file is the stack's, with its own record in
[`stack/composed-run.md`](../stack/composed-run.md), and both Plan B's `run` verb
and Plan C build on it; changing it from inside a VM-and-driver issue would be
the wrong seam.

> **Fixed in [#52](https://github.com/alius-git/kennel/issues/52)** —
> [`stack/composed-run.md` §9.1](../stack/composed-run.md). The launcher's last
> gate is now the node graph itself, so the acceptance row this finding qualified
> ("dirty the guest, `reset`, then `all` is green") holds without the re-run:
> measured green on 4 of 4 cold containers after the change.

## 7. Limits

- **The baseline is host-local.** It is a libvirt snapshot on one machine, not a
  distributable image. Another host must `provision`. That is the OVA's job
  (see the bypass note).
- **One baseline, overwritten in place.** There is no history of baselines and no
  snapshot chain. `snapshot` replaces; it does not accumulate. This is
  deliberate — a chain of qcow2 snapshots is a performance and correctness
  liability nobody asked for.
- **`provision` destroys the baseline**, necessarily: it sweeps both names to
  guarantee a clean build. The driver says so before the prompt.
- **Nothing garbage-collects the divergence** inside the qcow2 (§5.3).
- **The reset asserts the appliance, not the experiment.** It proves the guest is
  stock, built and launchable. It does not prove any particular run reproduces —
  that is [s006](../plan/design/seq.s006.reproduce.md)'s job, and it now has
  something to build on.

## 8. What this feeds

- [#24](https://github.com/alius-git/kennel/issues/24) — the unattended MVP
  sequence now has a defined starting state and a way back to it, which is what
  makes an unattended run repeatable rather than merely automated.
- [#25](https://github.com/alius-git/kennel/issues/25) — the green cycle. Note
  the `cleanupVmNamePrefixes` caveat in §2.1: the cycle sweep does not run
  through `kennel-demo.sh`, so it needs the prefix in `test.config.yml`.
- [s006](../plan/design/seq.s006.reproduce.md) (reset baseline, drift negative
  control) and [s008](../plan/design/seq.s008.classroom.md) (fleet, drift, reset)
  — both are written against a reset that did not exist until now.
- [`plan/design/02-appliance.md`](../plan/design/02-appliance.md) — the first
  working piece of "reset-to-baseline + drift check", with the OVA still ahead.

---

Last review: 2026-08-30
