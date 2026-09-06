# Kennel — the next three goals, as implementation plans

> **Historical record — all three landed.** Plan A shipped as
> [#51](https://github.com/alius-git/kennel/issues/51), plan B as
> [#54](https://github.com/alius-git/kennel/issues/54), plan C as
> [#56](https://github.com/alius-git/kennel/issues/56). Plan D is
> [`teleop-joystick.md`](teleop-joystick.md) ([#58](https://github.com/alius-git/kennel/issues/58)),
> plan E is [`reliability.md`](reliability.md) (#60, #52, #45).
>
> Kept as written on 2026-08-30, including its §0 ground truth — the house rules
> it states first now live in [`CLAUDE.md`](../CLAUDE.md), and the open issues it
> lists are the state of that day, not of today.

Three plans, one per goal, written so an agent can implement each one on its
own branch without re-deriving the repo. They are ordered by the recommended
execution order, which is **not** the order the goals were stated in:

| Plan | Goal as stated | Why this position |
|---|---|---|
| [A](#plan-a--baseline-snapshot-with-yuruna) | 3 — save a snapshot with Yuruna so the VM is always ready and there is a baseline to return to | Cheapest (Yuruna already has the verbs), and it turns every mistake in B and C from a 33-minute re-provision into a seconds-long revert. Build the safety net before the work that needs it. Also seeds open issues #24/#25. |
| [B](#plan-b--fewer-commands) | 2 — fewer commands, so the thing is actually usable | Small shell work in the existing driver. Fixes the state the host is in right now (guest shut off, no verb can start it). `run` is the verb Plan C's console button calls, so it exists first. |
| [C](#plan-c--connect-the-console-to-the-pipeline) | 1 — connect the console to the ROS 2 pipeline: launch from the console, or at least stop moving the `.zip` by hand | The only plan that touches the 129 KB single-file console and its four verify suites, and the only one with a design-contract decision attached (see C §0). Last, so it is built on a stable `run` verb and a resettable guest. |

Each plan is one GitHub issue, one branch, one PR, landing with its
implementation record beside the tool it records — the method every closed
issue in this repo followed (`plan/prompts.txt`, "POC scope cut").

---

## 0. Ground truth the implementer must know

Read before any plan. All of it was checked on 2026-08-30.

**Repo.** `main` is clean. Epics #2–#5 are closed; the PoC chain is complete and
wrapped by `demo/tools/kennel-demo.sh` (verbs: `provision compose transfer launch
verify walk down status all`). Open issues: #23 (Yuruna-discoverable `test/`),
#24 (unattended MVP sequence), #25 (green cycle), #26 (bypass log), #28
(backlog), #44 (`commands.txt` says "wait ~10 s" and that is wrong), #45
(`p21-trot-hold.sh` silently needs `p21-launch-from-commands.sh`). Read
`demo/runbook.md`, `demo/dry-run.md` §4 (the friction log), `stack/transfer.md`
§3 (the staging contract) and `vm/provisioning.md` §2–§5 first.

**Host.** Yuruna clone at `~/git/yuruna`, tag `2026.08.04`, with the three
`vm/patches/*.patch` applied and the kennel sequences + guest script copied in
(both uncommitted there, by design). Guest ISO fetched at
`~/yuruna/image/ubuntu.env/`. `google-chrome` present.

**Guest.** libvirt domain `test-guest.ubuntu.server.24-01` (hostname
`kennel-vm`, user `yuuser24`, 8 vCPU / 16 GiB, disk
`~/yuruna/vms/test-guest.ubuntu.server.24-01/*.qcow2`, plus `sda` = the
install ISO and `sdb` = `seed.iso` still attached). It is **shut off**, has
**no snapshots**, and holds **no DHCP lease** — so `kennel-demo.sh all` fails
today at "could not discover the guest IP", and no verb can start it. A
per-VM libvirt storage pool of the same name exists. `~/yuruna/vms` is 31 GB;
113 GB free on `/`.

**Discovery.** Every host-side kennel script finds the guest by the DHCP lease
*hostname* (`kennel-vm`) on libvirt net `default`, never by domain name
(`vm/meshcat-exposure.md` §3.1). `KENNEL_GUEST_IP` bypasses discovery;
`KENNEL_VM_DOMAIN` is a secondary lookup in `stack/transfer/kennel-transfer.sh`.
Renaming the domain therefore breaks nothing — Plan A relies on this.

**Container.** `dfki_quad`, started with `--network host`, five `ws/` bind
mounts, **no `--restart` policy** (`vm/provisioning.md` §3.2): after any guest
boot it is stopped until `sudo docker start dfki_quad`. The guest applier
(`stack/transfer/guest-apply-config.sh:92-103`) and the launcher
(`stack/composed-run/tools/p21-launch-from-commands.sh`) both start it if
needed; `status`/`walk` do not.

**Console.** `kennel_console/Kennel Console.dc.html` is a single-file React
prototype served by `python3 -m http.server 8000 --directory kennel_console`.
Export is `onGenerate` (line ~1880): `stampNow()` → `artifacts()` →
`buildZip()` → `save()` which is an `a.download` anchor click (line ~1655).
The bytes must always come from the emitters, never the DOM
(`kennel_console/export.md` §2.1). Four verify suites must stay green:
`verify-serve.sh`, `verify-scope.sh`, `verify-generate.sh`, `verify-export.sh`.

**House rules** (from the existing tools; the implementer must match them):
- Implementation record beside the tool (`vm/*.md`, `stack/*.md`,
  `kennel_console/*.md`, `demo/*.md`): what was validated, exact commands,
  measured timings, evidence directory, every deviation marked *bypass* (with
  retirement path) or *fix*. Header comment on every script: version date,
  what it is, where it runs (HOST / GUEST / container), usage, exit codes.
- Knobs are environment variables passed through to the tool that defines
  them; flags only for things that waive a correctness check.
- Distinct exit codes per failure mode; `0/1/2` mean success / assert failed /
  could not even look, as in `stack/verify.md`.
- **Waits observe the stack, never sleep** (`demo/dry-run.md` F8).
- `set -uo pipefail` is fine in scripts that never source a ROS setup file;
  never in ones that do (`stack/launch.md` §7).
- In Yuruna step `command:` strings, no `${...}` (Yuruna substitutes it), and
  `docker inspect --type container` (the image is also called `dfki_quad`).
- Never `pkill -f` inside the container (matches the calling shell); `pkill -x`.
- `Test-Config.ps1`: gate on **0 FAIL and no finding naming a kennel file**,
  never on the PASS/WARN totals.
- Nothing in the console may fetch off-host; the suites assert zero
  non-localhost requests.

---

## Plan A — Baseline snapshot with Yuruna

*Goal 3. Estimated: half a day plus one unattended ~33-minute provision.*

### A.0 What Yuruna already provides

Yuruna `2026.08.04` has disk-snapshot verbs; Kennel has not used them yet.

| Piece | Where | Behaviour |
|---|---|---|
| `saveDiskSnapshot` (params: `id`) | `~/git/yuruna/test/sequences/actions.yml:130` | Stops the VM if running, **renames the domain to `id`** and relocates `~/yuruna/vms/<old>` → `<id>` (rewriting disk paths in the XML), then `virsh snapshot-create-as --atomic`. **Leaves the VM stopped.** Overwrites a same-id snapshot. |
| `loadDiskSnapshot` (params: `id`) | `actions.yml:154` | Stops if running, `virsh snapshot-revert`, then the engine calls `Start-VM`. Guest boots fresh → re-DHCP; gate the next step on `sshWaitReady`. |
| `requiresSnapshot: {id: X}` (top-level key) | `~/git/yuruna/docs/test-sequences.md` "requiresSnapshot"; runner logic `test/modules/Test.SequenceRunner.psm1:131-201` | **Warm path:** VM `X` exists with snapshot `X` → every prereq sequence is skipped, the top-level runs against `X`. **Cold path:** snapshot absent → full chain runs, `saveDiskSnapshot` renames mid-chain, later entries follow the rename. `id` must equal both the snapshot name and the persisted VM name. |
| KVM driver | `~/git/yuruna/host/ubuntu.kvm/modules/Yuruna.Host.psm1:367-555` (`Rename-VM`, `Save-VMDiskSnapshot`, `Test-VMDiskSnapshot`, `Restore-VMDiskSnapshot`) | The rename must happen before the snapshot (libvirt freezes disk paths into snapshot metadata — comment at line ~443). |
| Cleanup sweep | `test/Remove-TestVMFiles.ps1 -Prefix ...` | Literal prefix match. `test-` no longer matches the renamed VM — that is the point — so a *clean* rebuild must sweep the persisted name explicitly. |

Warm-path caveat from the docs: prereqs do not run, so the consumer sequence
must itself declare every variable baked into the disk (`username`,
`hostname`) — it cannot inherit them from `start.guest...kennel.ssh`.

### A.1 Deliverables

1. **`vm/guest/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh`** —
   guest-side "make this guest a clean baseline", run over `sshFetchAndExecute`
   (it lands in the Yuruna clone via the copy `provision` already does for
   `vm/guest/ubuntu.server.24/*.sh`). Idempotent. Phases with `==== name ====`
   banners like the provisioning script:
   - stop anything running in the container (the `k13-stop.sh` pattern, by
     exact name), then `sudo docker stop dfki_quad` (bounded);
   - `rm -rf ~/kennel-staging` (no composed run is "current" in a baseline);
   - assert the clone is stock: `git -C ~/dfki-quad rev-parse HEAD` == pin
     **and** `git status --porcelain` empty — fail (exit 1) otherwise, and say
     `stack/transfer/kennel-transfer.sh restore-stock` is the fix;
   - assert the build stamp `~/dfki-quad/ws/.kennel-built-<pin>` and
     `ws/install/setup.bash` exist (a baseline without a build is worthless);
   - write `~/.kennel-baseline` — one line per fact: `pin`, `image_id`
     (`docker image inspect -f '{{.Id}}' dfki_quad:latest`), `created` (UTC);
   - `sudo apt-get clean`, `sudo journalctl --vacuum-time=1d`, `sync`.
   The pin is a literal here, exactly as in the provisioning script, and the
   sequence's assert step re-states it (`vm/provisioning.md` §8).

2. **`vm/test/workload.guest.ubuntu.server.24.kennel.baseline.ssh.yml`** —
   resource chain: `workload.guest.ubuntu.server.24.kennel.stack.ssh`. Steps:
   `sshWaitReady` → `sshFetchAndExecute` the prep script → `sshExec` assert
   `~/.kennel-baseline` carries the pin → `saveDiskSnapshot id:
   kennel-vm-baseline`. Nothing after it (the VM is stopped; that is the
   documented contract).

3. **`vm/test/workload.guest.ubuntu.server.24.kennel.reset.ssh.yml`** — the
   consumer. `requiresSnapshot: {id: kennel-vm-baseline}`; resource chain:
   the baseline sequence (so a cold run builds everything); `variables:`
   restating `username: yuuser24`, `hostname: kennel-vm`,
   `memoryStartupBytes: 16GB`, `cores: 8` (warm-path caveat above). Steps:
   `loadDiskSnapshot id: kennel-vm-baseline` → `sshWaitReady 600` → assert
   hostname → assert `~/.kennel-baseline` pin == pin → `sudo docker start
   dfki_quad` → assert container running (`--type container`) → assert
   `install/setup.bash` → the launchable-simulator smoke, copied verbatim from
   the stack sequence (it carries five hard-won teardown fixes — do not
   rewrite it).

4. **`demo/tools/kennel-demo.sh`** verbs:
   - `snapshot` — for a guest that is *already* provisioned and green: run the
     prep script over SSH (same `guest_stage` pattern), then call Yuruna's own
     driver directly rather than re-implementing the rename:
     `pwsh -NoProfile -Command 'Import-Module ~/git/yuruna/host/ubuntu.kvm/modules/Yuruna.Host.psm1; exit ([int](-not (Save-VMDiskSnapshot -VMName test-guest.ubuntu.server.24-01 -Id kennel-vm-baseline -Confirm:$false)))'`.
     Domain name from `KENNEL_VM_DOMAIN`, else the first domain whose lease
     hostname is `kennel-vm`, else the Yuruna default name. Refuse if the
     prep script failed (a dirty baseline is worse than none).
   - `reset` — `pwsh test/Invoke-TestSequence.ps1 -SequenceName
     workload.guest.ubuntu.server.24.kennel.reset.ssh` (warm path; expect
     ~1–3 min: revert in seconds, boot, docker start, smoke). Prints what it
     did and ends with `status`.
   - `provision` — sweep **both** names before a clean rebuild
     (`Remove-TestVMFiles.ps1 -Prefix test-,kennel-vm-baseline`; verify the
     cmdlet accepts the list form and removes the relocated directory — it
     enumerates through the host contract's `Get-VMName`, so it should), and
     run the **reset** sequence as top-level: cold path = start → sizing →
     stack → baseline → reset, i.e. provisioning now *ends* in a snapshot.
     Expect the step count to change from 28; update the runbook's
     "28/28 PASS" wording to the new invariant (0 FAIL).
   - `up` (if Plan B has not landed yet, add the minimal form here): `virsh
     start` the domain when shut off, wait for the lease + SSH, `docker
     start dfki_quad`.

5. **`vm/snapshot.md`** — the implementation record: what Yuruna provides,
   the id/rename decision, the two sequences, the caveats below with what was
   actually observed, measured revert and boot times, evidence in
   `vm/snapshot/evidence/` (`virsh snapshot-list`, `virsh domblklist`,
   `pool-list` before/after the rename, the reset transcript, a green `all`
   or `run` after reset, the second clean `provision`).

6. Docs: `demo/runbook.md` (short path gains `reset`; phase table; two
   troubleshooting rows: "two guests answer to kennel-vm", "reset says no
   snapshot"), `README.md` quick start, `docs/README.md` index, `vm/provisioning.md`
   §4.3 (sweep both names), the bypass note in `vm/provisioning.md` (this is a
   step toward the appliance image: the snapshot *is* the MVP's reset-to-baseline
   of `plan/design/02-appliance.md`; say so, with the OVA build as the
   retirement path).

### A.2 Caveats to test, not to reason about

1. **The rename.** After `saveDiskSnapshot` the domain is `kennel-vm-baseline`
   and its files live in `~/yuruna/vms/kennel-vm-baseline/`. Check: `virsh
   domblklist kennel-vm-baseline` paths exist; the old per-VM storage pool
   `test-guest.ubuntu.server.24-01` now points at a moved directory — record
   whether it needs `virsh pool-destroy/undefine`; the `seed.iso` and the
   install ISO attachments survive (the ISO lives in `image/`, not in the VM
   dir). `verify-meshcat-host.sh` and `kennel-transfer.sh` still discover the
   guest (by hostname) — assert it.
2. **Two guests named kennel-vm.** If a stale `test-guest...` survives beside
   `kennel-vm-baseline`, both request a lease for hostname `kennel-vm` and
   discovery takes `tail -1`. `provision` must make that impossible (sweep
   both); `up`/`status` should warn when `virsh list --all` shows more than
   one candidate.
3. **Internal qcow2 snapshot semantics.** Shut-off VM → disk-only, atomic;
   revert is seconds; divergence accumulates inside the same qcow2. Record
   `qemu-img info` before/after and after a dirtying `run`.
4. **The container is stopped after every revert** (no restart policy).
   `reset` starts it; `status` before any launch will still say "Meshcat not
   reachable" — that is correct, not a defect.
5. **The pin is frozen in the snapshot.** Repinning (s009) means `provision`
   from clean. The reset sequence's pin assert is what catches a snapshot
   taken at another pin.
6. **Provenance of the first baseline.** The current guest has had composed
   runs applied. For today's convenience `restore-stock` + `down` + a green
   `all` + `snapshot` is fine; the *committed* record should show a baseline
   produced by `provision` from clean.

### A.3 Acceptance

- `provision` from clean: exit 0, 0 FAIL, ends with `virsh snapshot-list
  kennel-vm-baseline` showing one snapshot and no `test-guest...` domain.
- Dirty the guest (`all`, which applies OSQP + 0.75 and launches), then
  `reset`: `kennel-transfer.sh status` reports stock, `git status` in the
  clone is clean, container running, `~/.kennel-baseline` pin matches, and a
  following `all` is green (`pass=10 fail=0`). Time the revert-to-SSH.
- `reset` twice in a row works (idempotent warm path).
- A second `provision` from clean succeeds with the persisted VM present
  beforehand (proves the sweep).
- `Test-Config.ps1 -SkipSend`: 0 FAIL, no finding naming a kennel file.
- The four console suites are untouched by this plan and still green.

---

## Plan B — Fewer commands

*Goal 2. Estimated: one day.*

### B.0 Where the commands are today

From a fresh clone: 1 installer (`ubuntu.kvm.sh`) + log out/in, `git checkout
2026.08.04`, `Enable-TestAutomation.ps1`, 3× `git apply`, `Get-Image.ps1`,
`test.config.yml` from the template with `guestSequence` scoped
(`vm/host-baseline.md` §3), then `provision`, then per session `all` /
`walk stop` / `down`. Composing by hand adds `python3 -m http.server`, a
browser, `unzip`, and `transfer <folder>`. The daily loop is fine; the
once-per-host part and the by-hand compose are where the commands are.

Target after this plan:

```bash
demo/tools/kennel-demo.sh setup       # once per host (after the installer + re-login)
demo/tools/kennel-demo.sh provision   # once per host, ~33 min, ends in the baseline snapshot (Plan A)
demo/tools/kennel-demo.sh console     # serves the console and opens it; compose, click Generate run
demo/tools/kennel-demo.sh run         # newest run (folder OR .zip) -> transfer -> launch -> verify -> walk
demo/tools/kennel-demo.sh down        # or: reset (Plan A)
```

### B.1 Deliverables — all in `demo/tools/kennel-demo.sh`

1. **`setup [--yes]`** — idempotent, prints one line per item with its state
   (`ok` / `did` / `needs you`), exit 2 on anything it cannot do:
   - Yuruna clone present at `$YURUNA_DIR`; else print the installer line
     from `demo/runbook.md` §2 and the re-login note, exit 2 (group
     membership cannot be automated from inside the same session).
   - `groups` contains `libvirt` and `kvm`; else "log out and in", exit 2.
   - Clone at tag `2026.08.04` (compare `git rev-parse HEAD` with `git
     rev-parse 2026.08.04^{commit}`); check it out if not. Refuse if the
     working tree has modifications *other than* the three patches and the
     copied kennel files (`git status --porcelain` filtered) — never discard
     someone's edits.
   - The three patches: reuse `provision`'s preflight loop verbatim — factor
     it into `patch_state <patch>` returning applied / missing / unknown —
     and apply the missing ones.
   - `test/test.config.yml`: create from the template if absent and scope
     `guestSequence` to `guest.ubuntu.server.24`; if present, only check
     the scope and warn.
   - `Enable-TestAutomation.ps1`: run only if
     `test/status/runtime/host.pre-automation.json` is absent (re-running
     would snapshot already-modified host settings as "pre").
   - Guest ISO under `$YURUNA_IMAGE_DIR`; else `Get-Image.ps1` (~9 min,
     say so, honour `--yes`).
   - Install the kennel files into the clone (the `cp` lines `provision`
     already has — move them into `install_kennel_files` and call it from
     both).
   - `Test-Config.ps1 -SkipSend` gate; print the host-clock WARN as
     advisory (`vm/provisioning.md` §6a.1).
   - `google-chrome` present: informational only (needed for scripted
     `compose`, not for `run`).

2. **`up`** — make the guest reachable: pick the domain (`KENNEL_VM_DOMAIN`,
   else `kennel-vm-baseline` if defined, else `test-guest.ubuntu.server.24-01`;
   warn if more than one candidate exists), `virsh start` if `shut off`, poll
   `virsh net-dhcp-leases` for the hostname and then SSH (bounded, `ConnectTimeout`
   loop — no fixed sleeps), `sudo docker start dfki_quad` if not running, then
   `status`. Exit codes: 0 reachable, 2 no such domain, 3 lease/SSH never came
   up within the bound (print `virsh console` hint). **`need_guest` calls `up`
   automatically** when discovery fails and the domain is merely shut off, so
   `run` on a cold host just works.
   Optional sibling `halt`: `virsh shutdown` after `down` (clean state for a
   host reboot).

3. **`transfer` accepts a `.zip`.** If the argument (or the auto-picked
   newest) ends in `.zip`: `unzip -q -o` into `$KENNEL_DEMO_OUT`, verify the
   archive contained exactly one `run-<stamp>/` with the four files
   (`kennel_console/export.md` §1), then apply that folder. Auto-pick = the
   newest by mtime among `$KENNEL_DEMO_OUT/run-*/` and
   `$KENNEL_DOWNLOADS/run-*.zip` (new knob, default `~/Downloads`). Say which
   one was picked and why. A `.zip` newer than the newest folder wins.

4. **`run [run-folder|zip]`** — `up` if needed → `transfer` (as above) →
   `launch` → `verify` → `walk`, with the same phase timing `all` prints.
   `all` stays as the scripted-compose variant (`compose` + the rest) so the
   dry run's automation keeps its meaning; `run` is the by-hand sibling.
   `verify --expect-solver` must come from the **applied run's `run.json`**
   (`choices.mpc_solver`), not from `$KENNEL_SOLVER`, or a by-hand HPIPM run
   fails verify against the OSQP default. Read it with `sed`, as
   `kennel-transfer.sh` does.

5. **`console`** — serve `kennel_console/` on `$KENNEL_CONSOLE_PORT` in the
   background (pidfile `$KENNEL_DEMO_OUT/.console.pid`; reuse if already
   answering), print the URL, `xdg-open` it unless `--no-open`. `console
   stop` kills it. Plan C swaps the server for `serve.py`; keep the verb's
   surface identical so that swap is one line.

6. **`help`** groups the verbs: *once per host* (`setup`, `provision`),
   *each session* (`up`, `console`, `run`, `walk stop`, `down`, `reset`),
   *pieces* (`compose transfer launch verify walk status snapshot all`).

7. Docs: `demo/runbook.md` — §1 becomes the five lines above, §2 shrinks to
   the installer + `setup`, §3 phase table gains `setup`/`up`/`run`/`console`,
   §4 gains `KENNEL_DOWNLOADS`, §5 gains "run picked the wrong run" and "up
   timed out". `README.md` quick start mirrors §1. Record the change in
   `demo/runbook.md` itself (it is the runbook's own implementation record),
   with a new evidence folder `demo/evidence/b-fewer-commands/`.

### B.2 Acceptance

- `setup` on this host: every item `ok`, no changes, exit 0; run twice,
  identical output. On a copy of the clone with one patch reversed:
  `did` for that patch and nothing else.
- From the guest **shut off**: `run` alone brings it up, finds the newest
  run, and ends with `pass=10 fail=0` and the Meshcat URL. Time it.
- Compose by hand in the served console with a **non-default** solver
  (`PARTIAL_CONDENSING_HPIPM` + rate `0.5`), leave the `.zip` in
  `~/Downloads`, `run` with no argument: it picks the zip, verify expects
  HPIPM (from `run.json`), green.
- `run` twice in a row (relaunch over a running stack) is green.
- `demo/runbook.md` §1 is ≤ 5 commands and every command in it was executed
  as written for the evidence.
- All existing verbs behave exactly as before (`all` unchanged; the dry-run
  automation `p22-console-demo.sh` untouched).

---

## Plan C — Connect the console to the pipeline

*Goal 1. Estimated: one to two days for Tier A; Tier B is a separate decision.*

### C.0 The design constraint — decide before coding

`plan/design.md` §2 and `plan/design/03-console.md` lock *configure + monitor,
never orchestrate*: "the console generates commands; the user runs them …
never through hidden orchestration"; "no process control anywhere".

- Getting the run folder from the browser to the host's run directory is
  **inside** the design — it is the run-manifest store / designated workspace
  directory, and `stack/transfer.md`'s bypass note names exactly this as the
  retirement path for the scp hand-off. **Tier A** below does that.
- A *Launch* button in the console is **outside** the design, and unlike the
  other MVP bypasses it has no retirement path: the design's end state is
  still "the user's terminal runs the commands". **Tier B** is therefore not a
  bypass but a deviation. Implement Tier A first; do Tier B only if the user
  confirms it after reading this paragraph, and then off by default and
  recorded as a deviation in the record and in #26's log.

### C.1 Tier A — the console writes where the driver reads

1. **`kennel_console/serve.py`** — stdlib only (`http.server`, `zipfile`,
   `json`, `hashlib`; the "no dependencies beyond Python 3" rule of
   `serve.md` §1). Serves `kennel_console/` exactly as `http.server` does —
   same URLs, same directory listing, so the four suites and `serve.md`'s
   `%20` note are unchanged — bound to `localhost` only, plus:
   - `GET /api/health` → `{"kennel": true, "out": "<abs run dir>", "pin": "<sha>"}`.
     Pin read from `stack/pin.lock` (`commit:` line), the same way
     `kennel-transfer.sh` does.
   - `POST /api/runs` with body = the archive bytes (`Content-Type:
     application/zip`). Validate before writing anything: every entry
     STORED, exactly four entries under one `run-<stamp>/` prefix with the
     names in `ARTIFACT_NAMES`, `run.json` parses and its `pin` equals the
     host pin (else `409` with the same message shape as transfer exit 3),
     target folder does not exist (else `409`). Then write
     `$KENNEL_DEMO_OUT/run-<stamp>/` **and** keep the archive beside it as
     `run-<stamp>.zip` (provenance: the artifact #19 exported, unmodified).
     Respond `201 {"run": ..., "path": ..., "sha256": {name: hex}}`.
   - `GET /api/runs` → the folders present, newest first (for `status` and a
     later Runs view).
   - Args: `--port` (default 8000), `--out` (default `$KENNEL_DEMO_OUT` or
     `~/kennel-runs`), `--dir` (default the script's own directory). One log
     line per request to stdout.

2. **Console change** (`Kennel Console.dc.html`), minimal and feature-detected:
   - On mount, `fetch('/api/health')` once; on `ok` store `{out, pin}` in
     state; on any failure (404 from `http.server`, network error) do
     nothing. Must never throw, delay render, or touch the 10 Hz mock loop.
     It is a localhost request, so the suites' "zero non-localhost
     requests" assertion holds.
   - When health succeeded, render a second button **`send to kennel-runs →`**
     beside `generate run ↓` (line ~252). Handler: the **same three lines as
     `onGenerate`** — `stampNow()`, `artifacts()`, `buildZip()` — then `fetch`
     `POST /api/runs` with the `Uint8Array` body; on `201` set the same
     `runs`/`lastExport` state `onGenerate` sets and show `saved
     <out>/run-<stamp>` in the strip; on error show the server's message.
     `generate run ↓` is untouched.
   - Do **not** move or reorder the export strip (`export.md` §5:
     `verify-generate.py` clicks tabs by text in document order). Append the
     button at the end of the existing row.
   - If the console's pin literal differs from the server's, show it in the
     strip ("server pin differs — export will be refused") rather than
     discovering it at send time.

3. **Driver** (`demo/tools/kennel-demo.sh`): `console` uses `serve.py`
   (`python3 kennel_console/serve.py --port $PORT --out $OUT`); `run` already
   picks the newest folder in `$OUT`, so the loop is: click *send*, then
   `kennel-demo.sh run`. `status` lists `GET /api/runs` when the server is
   up. `compose` (scripted) keeps using whichever server answers.

4. **Fold in #44** while the generator is open: the block-3 label in
   `COMMAND_BLOCKS` (`# 3 · MIT controller — wait ~10 s ...`) becomes advice
   that is true at any rate: wait until `/clock` advances and `/quad_state`
   exists, then ~10 **sim** seconds (`stack/launch.md` §1). `commands.txt` is
   emitted from the same list, so both change together. Re-run
   `verify-generate.sh` and `verify-export.sh` — group 4 compares the file
   against the UI blocks, so they should stay green; if either asserts the
   literal string, update the assertion and say so in the record.

5. **Verification** — `kennel_console/verify-send.sh` + `verify-send.py`, in
   the style of `verify-export.py` (CDP, headless Chrome, DNS blackhole
   except localhost, throwaway profile and out dir):
   - served by `serve.py`: the button is present; served by `http.server`:
     it is absent and the page still renders with zero mustaches;
   - click *send* → folder on disk with four files; the two YAMLs are
     byte-identical to the rendered panes **and** to a `generate run ↓`
     download made in the same session (same composition → same bytes, by
     `export.md` §6 determinism);
   - the kept `.zip` is STORED, CRCs valid, entries == the folder;
   - server refusals via `curl` with crafted archives: wrong pin → 409, a
     three-entry archive → 400, an existing folder → 409, a deflated entry →
     400; nothing written in any refused case;
   - `verify-serve.sh` run against `serve.py` (add a knob for the server
     command) — every asset 200, zero off-host requests;
   - the other three suites unchanged and green.

6. **Record: `kennel_console/send.md`** — decisions (feature detection over a
   build flag; STORED-zip validation as the fidelity check; keeping the zip;
   why `localhost` only), what was verified, evidence (`send-render.png`,
   transcripts). Update `serve.md` §1 (the command is now `serve.py`;
   `http.server` still works and is what the offline claim was proven on),
   `export.md` §6 ("unpacking is a manual step" — no longer, when served by
   `serve.py`), `stack/transfer.md`'s bypass note (the scp hand-off now
   starts from a folder the console wrote — the host→guest hop remains),
   `demo/runbook.md` §3.2 (by-hand compose is now: `console`, compose,
   *send*, `run`), `README.md`, `docs/README.md`.

### C.2 Tier B — launch from the console (only if confirmed; separate PR)

- `serve.py --allow-launch` (default off) enables `POST /api/runs/<run>/launch`
  → spawns `demo/tools/kennel-demo.sh run <path>` with stdout+stderr to
  `<run>/launch.log`, single-flight (409 while one is running), and
  `GET /api/runs/<run>/launch` → `{state: idle|running|done|failed, exit,
  meshcat_url, log_tail}` (URL parsed from the driver's `Watch it here:` line).
- Console: a **`launch in kennel-vm`** button that appears only when health
  reports `launch: true`, a log pane polling the status endpoint at 1 Hz, and
  the Meshcat URL as a link when it appears. No other panel changes; the
  Dashboard stays on `MockDataSource`.
- Record it in `send.md` as a **deviation** from `design.md` §2 (quote the
  sentence), off by default, with the reason it exists (a single-operator
  demo host), and add the row to #26's bypass log so it is not mistaken for
  the product's shape.

### C.3 Acceptance (Tier A)

- Compose by hand, click *send*: the folder is in `~/kennel-runs`, and
  `kennel-demo.sh run` with no arguments launches it and is green — no
  Downloads folder, no `unzip`, no path typed.
- `verify-send.sh` green; `verify-serve.sh`, `verify-scope.sh`,
  `verify-generate.sh`, `verify-export.sh` green and unmodified except for
  the #44 label if they asserted it.
- Serving with plain `python3 -m http.server` still boots the console
  offline with no *send* button and no console errors.
- `serve.py` refuses a run generated against another pin with a message
  that names both pins, and writes nothing.
- `commands.txt` no longer says "wait ~10 s"; #44 can be closed from this PR.

---

## Suggested issue titles

- **A** — "Baseline snapshot: `provision` ends in a Yuruna disk snapshot; `reset` returns the guest to it in seconds" (`area:vm`, `area:harness`; feeds #24, #25)
- **B** — "Reduce the demo to setup → provision → console → run: `setup`, `up`, `run`, zip-accepting `transfer`" (`area:docs`, `area:config-path`)
- **C** — "Console writes run folders to the host via `serve.py`; *send to kennel-runs* button; fix #44" (`area:console`, `area:config-path`; closes #44)
