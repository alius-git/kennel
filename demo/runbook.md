# Demo runbook — the whole demo in a handful of commands

The demo that [`dry-run.md`](dry-run.md) performed from the written prose,
reduced to single commands per phase. One driver,
[`demo/tools/kennel-demo.sh`](tools/kennel-demo.sh), wraps the existing
per-phase tools — it adds orchestration (guest discovery, scp, ordering,
timing) and nothing else, so each phase still does exactly what its
implementation record says it does.

Everything below runs **on the host**, from the repo root. The driver reaches
into the guest over SSH by itself.

## 1. The short path

**New here?** [`guides/first-run.md`](../guides/first-run.md) is the checklist —
eight steps, each one command or one click, from a provisioned guest to a robot
walking under your command. This page is the reference behind it.

Five commands, two of which you run once per host and never again:

```bash
demo/tools/kennel-demo.sh setup       # once per host — checks/does the prerequisites of §2
demo/tools/kennel-demo.sh provision   # once per host, ~35 min — builds the guest, ends in a baseline snapshot
demo/tools/kennel-demo.sh import <bundle>  # OR, instead of provision: an exported appliance image, ~1.5 min (vm/image.md)
demo/tools/kennel-demo.sh console     # serves the console and opens it; compose, click "generate run"
demo/tools/kennel-demo.sh run         # the newest run → transfer → launch → verify → walk
demo/tools/kennel-demo.sh teleop      # drive it yourself from the console's joystick
demo/tools/kennel-demo.sh down        # stop the stack (container stays up)
```

`run` ends with the robot trotting and the Meshcat URL printed. Open it, watch
the walk, then `walk stop` returns the gait to STAND and `down` tears the stack
down.

The two halves of that list behave very differently, and it is worth knowing
which is which. `setup` and `provision` are the **once per host** pair: they turn
a machine that has only cloned this repo into one that has a working, frozen
guest. `console`, `run` and `down` are the **every session** loop, and they are
the only three you type after the first day.

`run` is deliberately undemanding about where the run came from. It takes the
newest run it can find — the folder [`compose`](#3-phase-by-phase) unpacked into
`~/kennel-runs`, or the `run-<stamp>.zip` your browser just dropped in
`~/Downloads` — unpacks the archive if that is what won, and applies it. Nothing
to unzip, no path to type, and no way to accidentally launch yesterday's
composition while looking at today's. It says which run it picked and why, on
every run:

```
[kennel-demo] run              /home/you/Downloads/run-20260830T190000Z.zip
[kennel-demo]                  (newest archive in /home/you/Downloads)
```

It is also the verb that copes with a cold host: if the guest is merely powered
off, `run` starts it, waits for the lease and sshd, starts the container, and
carries on. You do not have to notice that the guest was down.

**When something is wrong and you want a clean guest**, you do not re-provision:

```bash
demo/tools/kennel-demo.sh reset         # back to the baseline in ~90 s
```

`provision` ends by freezing the guest as the **baseline snapshot** — stock
configs at the pin, workspace built, nothing running. `reset` returns to exactly
that state and proves it got there: stock, at the pin, container up, simulator
launchable. It is the fastest way out of any mess, and it is 35 minutes cheaper
than the alternative. Full record: [`vm/snapshot.md`](../vm/snapshot.md).

If the guest is merely powered off (after a host reboot, say), you do not need
either — `run` handles it silently, and `up` does it on its own when you want to
watch:

```bash
demo/tools/kennel-demo.sh up            # start the guest, wait for it, start the container
demo/tools/kennel-demo.sh halt          # and the other way, cleanly, before a host reboot
```

### 1.1 The scripted variant

`all` is `run`'s sibling for when nobody is at the keyboard: it *composes* the
run itself by driving the console UI in headless Chrome, then does the same four
phases.

```bash
demo/tools/kennel-demo.sh all           # compose → transfer → launch → verify → walk (~6 min)
```

Use `all` for an unattended demo or a regression check, and `console` + `run`
when a human is composing. They apply the same run folder through the same five
tools; the only difference is whose hands made the composition.

## 2. Prerequisites (once per host)

From a fresh clone of this repo, in order. There are exactly two steps, because
`setup` does the rest:

```bash
# 1. Host baseline (host-baseline.md §2): installs KVM/libvirt + tools and
#    clones the framework to ~/git/yuruna.
bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
# LOG OUT AND BACK IN -- it adds you to the libvirt and kvm groups, and this
# session cannot see groups it did not start with.

# 2. Everything else.
demo/tools/kennel-demo.sh setup
```

`setup` checks — and where it is allowed to, does — the Yuruna release checkout,
the three patches, `test/test.config.yml`, `Enable-TestAutomation.ps1`, the
~3.2 GB guest ISO, the kennel files that go into the clone, and the
`Test-Config.ps1` gate. It prints one line per item with its state and exits 0
only when the host is ready:

```
[kennel-demo] ok     yuruna clone     /home/you/git/yuruna
[kennel-demo] ok     groups           libvirt kvm
[kennel-demo] ok     yuruna tag       2026.08.04
[kennel-demo] did    patch            applied yuruna-ssh-autoinstall-confirm.patch
[kennel-demo] ok     test.config      guestSequence: guest.ubuntu.server.24
[kennel-demo] ok     guest ISO        /home/you/yuruna/image/ubuntu.env/....iso
[kennel-demo] did    kennel files     sequences + guest scripts copied into the clone
[kennel-demo] ok     config gate      0 FAIL
```

The three states mean what they say. **`ok`** — already true, nothing done.
**`did`** — this run changed it. **`needs you`** — `setup` will not do it for
you, and says why: it exits **2** and prints the command. There are only three
things in that category, and each is a deliberate refusal rather than a gap:

| `needs you` | Why a script must not do it |
|---|---|
| Group membership | A process cannot grant itself groups its login did not have. Only a re-login can. |
| The host installer | It is a `curl \| bash` of a third-party script that installs system packages — the operator runs that, having read it. |
| A `Test-Config` FAIL finding, or a modified Yuruna clone | Both mean the host is in a state this driver did not create, and guessing at someone else's edits is how you destroy their work. `setup` prints the paths and changes nothing. |

It is safe to run repeatedly — every item asks the host what state it is in
rather than remembering what a previous run did, so a second `setup` on a ready
host is all `ok` and changes nothing.

The one item worth planning around is the **guest ISO**: ~3.2 GB and ~9 minutes
on a cold cache, and it is *not* counted in `provision`'s 35 minutes. `setup`
asks before fetching it; `setup --yes` takes the questions as answered.

`google-chrome` on the host is needed only for the scripted `compose` (it is the
operator's hands) — §3.2 and §1.1. `setup` reports it and never requires it.

Copying the kennel sequences and guest script into the Yuruna clone
([`provisioning.md` §4.2](../vm/provisioning.md)) is **also done by `provision`
and `reset`** on every run — it is the step whose omission fails twenty minutes
late (dry run F3), so the driver never leaves it to memory or to `setup`.

## 3. Phase by phase

Each verb can be run on its own; `run` chains the last four and `all` chains
those plus `compose`. Timings are the single measured sample from
[`dry-run.md` §2](dry-run.md) unless noted.

| Command | What it wraps | Success looks like | Time |
|---|---|---|---|
| `kennel-demo.sh setup` | the once-per-host prerequisites of §2 — release checkout, the three patches, `test.config.yml` (**and its `projectUrl`**), `Enable-TestAutomation.ps1`, the guest ISO, **the project clone**, the config gate | one line per item, all `ok`/`did`, exit 0 | ~5 s ready; ~9 min if it fetches the ISO |
| `kennel-demo.sh provision` | Yuruna sequence `workload.guest.ubuntu.server.24.kennel.reset.ssh`, cold path — the whole chain, ending in a snapshot ([`vm/provisioning.md` §4.3](../vm/provisioning.md), [`vm/snapshot.md`](../vm/snapshot.md)) | **0 FAIL**, exit 0, and `virsh snapshot-list kennel-vm-baseline` shows one snapshot | ~35 min |
| `kennel-demo.sh up` | `virsh start` + a bounded wait for the DHCP lease and sshd + `docker start` | `guest kennel-vm at 192.168.122.x`, then `status` | ~15 s |
| `kennel-demo.sh halt` | `virsh shutdown` (ACPI, never `destroy`) + a bounded wait for the domain to stop | `shut off after <n>s` | ~20 s |
| `kennel-demo.sh console` | `python3 -m http.server` on [`kennel_console/`](../kennel_console/), backgrounded behind a pidfile, then `xdg-open` | the URL, and the page in your browser | ~1 s |
| `kennel-demo.sh run` | the newest run — folder in `~/kennel-runs` **or** `.zip` in `~/Downloads` — then `transfer` → `launch` → `verify` → `walk`, bringing the guest up first if it is off | the run it picked and why, then `pass=10 fail=0` and the Meshcat URL | ~5 min |
| `kennel-demo.sh teleop` | [`kennel-bridge.sh`](../stack/bridge/kennel-bridge.sh) on the guest + [`verify-bridge-host.sh`](../vm/test/verify-bridge-host.sh), then the console: stops any held trot, starts rosbridge **and the target watchdog**, hands the URL to the page ([`stack/bridge.md`](../stack/bridge.md)) | the `ws://` and Meshcat URLs, a line about the watchdog, then *Dashboard → Interventions → connect bridge* | ~15 s |
| `kennel-demo.sh teleop stop` | zero the target and return to STAND, **then** stop the bridge — in that order | `gait returned to STAND`, `bridge stopped` | ~10 s |
| `kennel-demo.sh reset` | the same sequence, warm path — revert the disk snapshot and re-assert the appliance ([`vm/snapshot.md` §3](../vm/snapshot.md)); its last step is the drift check against the version manifest ([#75](https://github.com/alius-git/kennel/issues/75)) | **13/13 PASS**, then `findings=0` and the version manifest with its `manifest_ref` ([`vm/manifest.md`](../vm/manifest.md)) | ~90 s |
| `kennel-demo.sh snapshot` | [the baseline prep script](../test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh) on the guest — which since #74 also holds the package set still, installs the first-boot key unit and writes the version manifest — then Yuruna's `Save-VMDiskSnapshot` | `this guest is a clean baseline`, the manifest and its `manifest_ref`, then the new snapshot listed | ~40 s |
| `kennel-demo.sh compose` | [`p22-console-demo.sh`](tools/p22-console-demo.sh) — serves the console if nothing else is, makes both choices in the UI, clicks Generate run, unpacks the download | `run folder  ~/kennel-runs/run-<stamp>` | ~1 min |
| `kennel-demo.sh transfer` | [`kennel-transfer.sh apply`](../stack/transfer/kennel-transfer.sh) on the newest run — a folder, or a `.zip` it validates and unpacks first | the run it picked and why, then four matching checksum columns, exit 0 | ~1 min |
| `kennel-demo.sh launch` | [`p21-launch-from-commands.sh`](../stack/composed-run/tools/p21-launch-from-commands.sh) on the guest — the three shells of `commands.txt`, waited on **by observing the stack**, never by sleeping ([F8](dry-run.md)) | `all three are up`, controller reached "Starting controller", **and the six-node graph is complete with no duplicates** ([#52](https://github.com/alius-git/kennel/issues/52)) | ~2 min |
| `kennel-demo.sh verify` | [`kennel-verify.sh`](../stack/verify/kennel-verify.sh) on the guest, with the launch log and `--expect-solver` **taken from the applied run's `run.json`** (§3.3); then files the report in that run's folder as `verify.json` + `verify.txt` ([`verify.md` §7](../stack/verify.md)) | `expect solver <X> (from run-<stamp>/run.json)`, then `pass=10 fail=0`, exit 0, then `verify report  …/verify.json (verdict completed)` | ~1 min |
| `kennel-demo.sh walk` | [`verify-meshcat-host.sh`](../vm/test/verify-meshcat-host.sh) + [`p21-trot-hold.sh start`](../stack/composed-run/tools/p21-trot-hold.sh) | the Meshcat URL, robot trotting until `walk stop` | ~1 min |
| `kennel-demo.sh mvp` | the Yuruna sequence [`workload…kennel.mvp.ssh`](../test/workload.guest.ubuntu.server.24.kennel.mvp.ssh.yml) ([#24](https://github.com/alius-git/kennel/issues/24)) — revert to the baseline, stage the console's committed fixture, apply it, launch, assert walking on the composed solver, keep the logs, stop; then collects the evidence off the guest ([`test/harness.md`](../test/harness.md)) | **14/14 PASS**, then `evidence  test/evidence/mvp-<stamp>` | ~90 s warm |
| `kennel-demo.sh cycle` | one **whole Yuruna cycle** from cold, as the runner runs one ([#25](https://github.com/alius-git/kennel/issues/25)): sweeps the guest *and its baseline*, then `Invoke-TestProject.ps1` — clone the project, gate, build the appliance, run the MVP sequence — then collects | Yuruna's `overallStatus pass`, `warm_resume events: 0`, and a rebuilt baseline left standing | ~40 min |
| `kennel-demo.sh drift` | [`kennel-drift.sh`](../vm/guest/ubuntu.server.24/kennel-drift.sh) on the guest ([#75](https://github.com/alius-git/kennel/issues/75)): tracked files, packages, image, build stamp, pin and kernel against the version manifest; the report is left in `~/kennel-runs/.kennel-drift` for the console ([`vm/drift.md`](../vm/drift.md)) | `findings=0`, exit 0 — or one `DRIFT` line per deviation and exit 1. An applied composed run is two `tracked-file` findings and a note | seconds |
| `kennel-demo.sh export-image [dir]` | refuses unless the guest is its baseline (a manifest, no drift) and the domain matches [`vm/image/kennel-vm.xml.in`](../vm/image/kennel-vm.xml.in); halts it; `qemu-img convert -l snapshot.name=…` converts the **frozen snapshot layer**, compressed; writes the bundle — image, template, manifest envelope, package list, `SHA256SUMS` — under `~/kennel-images/` ([#76](https://github.com/alius-git/kennel/issues/76), [`vm/image.md`](../vm/image.md)) | `converted 25GiB -> 13GiB`, the listing, `image_sha256` and `manifest_ref`; the guest left shut off | ~2.5 min |
| `kennel-demo.sh import <dir>` | verifies the bundle before writing a byte (`SHA256SUMS`, the manifest envelope); refuses an existing `kennel-vm-baseline`, or a running guest answering to `kennel-vm`; copies the image into `~/yuruna/vms/`, builds the KENNELKEY volume from this host's public key, defines the domain from the bundle's own template, boots it, proves its manifest bytes and `drift`, snapshots the **keyed** guest with Yuruna's sidecar, and brings it up. Needs no guest ISO ([#76](https://github.com/alius-git/kennel/issues/76), [`vm/image.md`](../vm/image.md) §4) | `import in 1m23s (verify 12s, copy 24s, first boot …)`, the manifest summary, then `'kennel-vm-baseline' is this host's baseline now` | ~1.5 min |

Also there when needed:

```bash
kennel-demo.sh scenario disturb   # s004 as a test: interventions on the real
                             # robot, and the process set that never changes
                             # (64 checks, ~6 min; demo/scenarios.md)
kennel-demo.sh scenario diagnose  # s003: degradation, fall, post-mortem
                             # (~15 min, up to three attempts)
kennel-demo.sh scenario firstwalk # s001: guides/first-run.md performed and timed
                             # (~2 min; needs the stack DOWN and port 8000 free,
                             # because step 1 of the checklist starts the console)
stack/bridge/verify-teleop-live.sh   # the teleop path, asserted against the real
                             # stack: 90 checks, ~10 min, leaves it in STAND
kennel-demo.sh status        # what run is applied + is Meshcat reachable
kennel-demo.sh walk stop     # STAND, target zeroed
kennel-demo.sh down          # tear the three launches down inside the container
kennel-demo.sh up            # power the guest on and wait for it
kennel-demo.sh halt          # power it off cleanly (before a host reboot)
kennel-demo.sh console stop  # stop the console server this driver started
kennel-demo.sh reset         # revert the whole guest to the baseline (~90 s)
kennel-demo.sh snapshot      # re-freeze the CURRENT guest as the baseline
stack/transfer/kennel-transfer.sh restore-stock    # put the stock YAMLs back
```

`kennel-demo.sh help` prints the same verbs grouped by when you reach for them:
once per host, each session, and the individual pieces.

`restore-stock` and `reset` overlap but are not the same tool. `restore-stock`
puts the two YAMLs back and touches nothing else — cheap, surgical, and it leaves
the running stack, the staged runs and anything else you changed exactly where
they were. `reset` throws the whole guest away and brings back the frozen one.
Reach for `restore-stock` when you know what you changed, and `reset` when you
do not.

### 3.1 What gets composed

The console ships four named presets — **Stock Go2 walk**, **Solver benchmark A
(HPIPM)**, **Solver benchmark B (OSQP)** and **Stress** — and `KENNEL_PRESET`
picks one of them in the UI by name or slug
([`composer-scope.md` §7](../kennel_console/composer-scope.md)). Each is a
measured row of [`stack/stress.md`](../stack/stress.md) §2.

By default, with no preset, the composition proven in [`dry-run.md` §1](dry-run.md): `mpc_solver`
= `PARTIAL_CONDENSING_OSQP` (controller YAML) and `simulator_realtime_rate` =
`0.75` (simulator YAML), map left at stock — obstacle terrain is known not to
walk ([`transfer.md` §6.3](../stack/transfer.md)). Override with knobs (§4).
`verify` expects the same solver it composed, so the two stay consistent
automatically.

### 3.2 Composing by hand instead

The scripted compose is a stand-in for hands, not for the console. To do it
yourself:

```bash
demo/tools/kennel-demo.sh console
```

That serves `kennel_console/` in the background and opens
`http://localhost:8000/Kennel%20Console.dc.html` in your browser. Pick the
solver and the realtime rate, then take either route out of the browser:

- **send to kennel-runs** — the run folder is written straight into
  `~/kennel-runs` by the server, and the strip tells you the path
  ([`kennel_console/send.md`](../kennel_console/send.md));
- **generate run ↓** — the archive lands wherever your browser saves.

Then, either way:

```bash
demo/tools/kennel-demo.sh run
```

No `unzip`, and no path typed. `run` takes whichever is newer: the folder in
`~/kennel-runs` or the archive in `~/Downloads` — and it says which it picked
and why. An archive is validated before anything is written (exactly one
`run-<stamp>/` holding exactly the four files of
[`export.md` §1](../kennel_console/export.md)) and unpacked into `~/kennel-runs`.
If the browser saves somewhere else, set `KENNEL_DOWNLOADS`.

The **send** button appears only when the console is served by
`kennel_console/serve.py`, which is what `console` starts. It is the console
asking the server whether it is there — served any other way the button is
simply absent and nothing else changes.

`console` leaves the server running so you can compose again in the same
session; `console stop` ends it. It refuses to kill a server on that port that it
did not start — if `lsof -i :8000` shows someone else's, that is theirs.

To use a plain server instead, nothing has changed — the console works exactly
as before, minus the send button:

```bash
python3 -m http.server 8000 --directory kennel_console
```

### 3.3 The expected solver comes from the run, not from the knob

`verify` asserts the controller actually loaded the solver the run asked for.
When `run` (or `all`) applied the run in the same invocation, the expected value
is read from that run's own `run.json` — `choices.mpc_solver` — and the phase
says so:

```
[kennel-demo] expect solver    PARTIAL_CONDENSING_HPIPM  (from run-20260830T190000Z/run.json)
```

This matters exactly when you compose by hand. `KENNEL_SOLVER` is the
*composer's* default, `PARTIAL_CONDENSING_OSQP`; a run you built in the browser
with HPIPM would otherwise be checked against OSQP and fail a verification it
should pass. Reading it from the artifact makes the two consistent by
construction, whoever composed it.

Invoked on its own — `kennel-demo.sh verify`, with nothing applied in that
process — the verb falls back to `$KENNEL_SOLVER`, because the only other thing
it could believe is a guess about what the guest is currently running.

## 4. Knobs

All optional, all environment variables — the driver passes them through to the
tools that define them.

| Knob | Default | Meaning |
|---|---|---|
| `KENNEL_SOLVER` | `PARTIAL_CONDENSING_OSQP` | the `mpc_solver` `compose` writes, and the one `verify` expects when nothing was applied in the same command (§3.3) |
| `KENNEL_RATE` | `0.75` | composed `simulator_realtime_rate` |
| `KENNEL_DEMO_OUT` | `~/kennel-runs` | where run folders are unpacked, and the first place `run` looks |
| `KENNEL_DOWNLOADS` | `~/Downloads` | where the browser saves `run-<stamp>.zip`, and the second place `run` looks |
| `KENNEL_CONSOLE_PORT` | `8000` | port `console` and `compose` serve the console on |
| `KENNEL_WATCHDOG` | `1` | start the guest-side target watchdog beside the bridge ([`bridge.md` §11](../stack/bridge.md)). `0` leaves a killed tab's target in force — which is what the watchdog is for |
| `KENNEL_WATCHDOG_STALE` | `1.0` | seconds without a target before the watchdog zeroes it |
| `KENNEL_DISTURBANCES` | `0` | `1` composes the **fourth block**, the disturbance service ([#68](https://github.com/alius-git/kennel/issues/68)) — what `scenario disturb` needs |
| `KENNEL_PRESET` | *(none)* | one of the presets the **console ships**, picked in the UI by its name or its slug: `stock-go2-walk`, `solver-benchmark-a-hpipm`, `solver-benchmark-b-osqp`, `stress` ([`composer-scope.md` §7](../kennel_console/composer-scope.md)). The composition is the page's data, not the driver's; a name the page does not ship is refused **by the page**, which lists the four. It fills in only what you did not choose — an explicit `KENNEL_SOLVER` or `KENNEL_RATE` still wins. A preset *you* saved is not reachable here: the scripted compose drives a throwaway browser profile |
| `KENNEL_S001_BUDGET` / `KENNEL_S001_TARGET` | `600` / `300` | seconds — s001's hard ceiling and its target, for `scenario firstwalk` |
| `KENNEL_S001_VMAX` / `KENNEL_S001_VX_TOL` | `0.5` / `0.2` | what a fully-pushed stick asks for, and the ± band on it |
| `KENNEL_S001_GUIDE` / `KENNEL_S001_EVIDENCE` | `guides/first-run.md` / `demo/evidence/s001-firstwalk` | the page `scenario firstwalk` performs, and where its transcripts land |
| `KENNEL_MAP` | *(untouched)* | `flat_plane` / `obstacle_terrain` — an unset knob leaves the control alone, which is not the same as setting it to stock |
| `KENNEL_HPIPM_MODE` / `KENNEL_CONDENSED` | *(untouched)* | the two solver-dependent MPC fields, for the sweep |
| `KENNEL_PROJECT_URL` | `file://<this repo>` | what `provision`, `reset` and `mvp` clone into `$YURUNA_DIR/project` before running a sequence ([#23](https://github.com/alius-git/kennel/issues/23)). The default is this checkout, so a verb runs the branch you are on — but its **committed** head; an uncommitted edit under `test/` does not run, and the verb says so |
| `KENNEL_CYCLES` | `1` | how many cycles `cycle` runs in a row; it stops at the first red one, because "green twice" is a claim about *consecutive* cycles |
| `KENNEL_HARNESS_EVIDENCE` | `test/evidence` | where `mvp` and `cycle` leave what they collected off the guest and out of the Yuruna cycle folder |
| `KENNEL_IMAGE_DIR` | `~/kennel-images` | where `export-image` writes a bundle, as `<dir>/kennel-vm-<pin7>-<date>/` ([#76](https://github.com/alius-git/kennel/issues/76), [`vm/image.md`](../vm/image.md)) |
| `KENNEL_IMAGE_COMPRESSION` | *(zlib)* | the `qemu-img` `compression_type` `export-image` uses; `zstd` is faster where both hosts' `qemu-img` have it |
| `KENNEL_SSH_PUBKEY` | `$KENNEL_SSH_KEY.pub` | the public key `import` puts on the guest's KENNELKEY volume. Every verb then logs in with `KENNEL_SSH_KEY`, so it must be that key's public half — `import` checks |
| `YURUNA_DIR` | `~/git/yuruna` | framework checkout, for `setup` and `provision` |
| `YURUNA_TAG` | `2026.08.04` | the Yuruna release `setup` checks out and validates against |
| `YURUNA_IMAGE_DIR` | `~/yuruna/image/ubuntu.env` | where `Get-Image.ps1` puts the guest ISO |
| `KENNEL_GUEST_IP` | *(discovered)* | skip the libvirt lease lookup |
| `KENNEL_SSH_KEY` | `~/git/yuruna/test/status/ssh/yuruna_ed25519` | guest SSH key |
| `KENNEL_SNAPSHOT_ID` | `kennel-vm-baseline` | snapshot id **and** the persisted libvirt domain name |
| `KENNEL_VM_DOMAIN` | *(discovered)* | name the domain directly, for `up` / `halt` / `snapshot` |
| `KENNEL_UP_TIMEOUT` | `600` | bound on `up`'s wait for the lease and sshd, and on `halt`'s wait for the shutdown |

## 5. Troubleshooting

| Symptom | What it means |
|---|---|
| `compose` says *"the preset is one the page ships — not offered"* and exits 1 | `KENNEL_PRESET` names something the console does not ship. The message lists the four it does; the composition lives in the page, not in the driver (§4) |
| `scenario firstwalk` exits 2 with *"a stack is already running"* | that verb measures how long a first run takes **from nothing**, so a running stack is the precondition that must not hold. `kennel-demo.sh down` first |
| `scenario firstwalk` exits 2 with *"something is already serving the console"* | step 1 of the checklist starts it, and the verb performs step 1. `kennel-demo.sh console stop` |

Symptoms the dry run already met, plus the driver's own failure modes:

| Symptom | Read this |
|---|---|
| Gate PASS/WARN counts differ from the docs | Expected — read the findings, not the totals ([`provisioning.md` §4.3](../vm/provisioning.md), F1) |
| Yellow `WARNING: fetch-and-execute fallback ... differs from HEAD` during provision | Benign, caused by the doc'd copy step ([`provisioning.md` §4.2](../vm/provisioning.md), F5) |
| `compose` fails asking for google-chrome | Use the by-hand path (§3.2) |
| `transfer` exits 3 (pin mismatch) | The run folder was generated against another pin — re-export, or `--allow-pin-mismatch` via `kennel-transfer.sh` directly |
| `could not discover the guest IP` | The driver already starts a guest that is merely *shut off*. This means it is **running** without a lease — still booting, or the network is broken. `kennel-demo.sh up` waits for it (bounded); `virsh console <domain>` shows why not. Or set `KENNEL_GUEST_IP` |
| `run` picked the wrong run | It prints which one and why, on the line under `run`. It takes the newest by mtime across `$KENNEL_DEMO_OUT/run-*/` and `$KENNEL_DOWNLOADS/run-*.zip`, so an old browser download can win if you composed nothing since. Name it explicitly: `kennel-demo.sh run ~/Downloads/run-<stamp>.zip` |
| `run`/`transfer`: `is missing:` or `carries entries a console export does not` | The archive is not a console export — the four files of [`export.md` §1](../kennel_console/export.md), under one `run-<stamp>/`. Nothing was written. Re-export rather than hand-assembling one |
| `up` exits 3, or `run` hangs on the `guest` phase | The guest never became reachable within `KENNEL_UP_TIMEOUT` (600 s). Watch the boot: `virsh console <domain>` (leave with `Ctrl+]`). Raise the bound on a slow host |
| No **send to kennel-runs** button in the console | The page asks `/api/health` once and renders it only on an answer. Check the server: `curl -s localhost:8000/api/health` should report `"kennel": true`. A plain `python3 -m http.server` has no such endpoint — that is the supported offline path, not a fault ([`send.md` §2.1](../kennel_console/send.md)) |
| **send** says the server refused the run | The message is the server's own. `409` with two pins = composed against another revision, re-export from a console served at the stack pin; `409 … already exists` = a second send inside the same second, compose again ([`send.md` §2.3](../kennel_console/send.md)). Nothing was written either way |
| `console`: `port 8000 answers, but .console.pid does not exist` | Another server is on that port — possibly your own `python3 -m http.server`. The driver will not kill a process it did not start. `lsof -i :8000`, or use `KENNEL_CONSOLE_PORT` |
| `setup` exits 2 | Read the `needs you` lines: each names the command. The three it will not do for you are group membership, the host installer, and anything indicating the clone or the host was changed by someone else (§2) |
| `WARNING: more than one domain could be 'kennel-vm'` | Two guests are asking for the same lease hostname, so discovery is a coin flip. `virsh list --all`, then `virsh undefine --nvram --remove-all-storage <the stale one>` — or pin the good one with `KENNEL_VM_DOMAIN` ([`snapshot.md` §5.2](../vm/snapshot.md)) |
| `reset`: `requiresSnapshot: snapshot 'kennel-vm-baseline' not on host` | There is no baseline yet. Take one from a green guest with `kennel-demo.sh snapshot`, or rebuild with `provision` — which ends in one |
| `reset` reverts, but `status` says Meshcat is not reachable | Correct, not a defect. A baseline has nothing running; the container is started but the stack is not launched ([`snapshot.md` §5.4](../vm/snapshot.md)) |
| `walk` says Meshcat is not reachable | The simulator is not running (`launch` first); exit codes decoded in [`meshcat-exposure.md` §7](../vm/meshcat-exposure.md) |
| Trot tool: `timeout: failed to run command 'ros2'` | Cannot happen since [#45](https://github.com/alius-git/kennel/issues/45): the tool builds its own source chain when the launcher's `/tmp/p21-env.sh` is absent, and says on its first line which of the two it used. If the stack is not launched at all it now exits **2** naming the verb to run ([`composed-run.md` §9.2](../stack/composed-run.md)) |
| `verify` exits 1 vs 2 | 1 = stack up but not healthy/walking (collect logs); 2 = could not even look ([`verify.md` §1](../stack/verify.md)) |
| The robot jitters between two speeds while you drive it | Two publishers on `/quad_control_target`: the controller takes whichever arrived last. Almost always a trot `run` left held. Measured: `[0.3, 0.5]` alternating on the wire, 30 Hz where there should be 20, robot at 0.427 m/s between the two commands. `kennel-demo.sh teleop` stops it for you — run the verb rather than connecting by hand ([`stack/bridge.md` §7](../stack/bridge.md)) |
| The console says `another publisher is holding /quad_control_target` | The same thing, caught before it started: the page listens for a second before it advertises, and refuses rather than joining the fight. `kennel-demo.sh teleop`, then reconnect |
| `connect bridge` fails, or there is no bridge field at all | No field = the console is not served by `serve.py` (use `kennel-demo.sh console`). Field but no connection = the bridge is down: `kennel-demo.sh status` says so, `kennel-demo.sh teleop` starts it. It needs a **launched** stack — the script exits 2 and says so |
| `verify` check 1 says `extra: /rosapi /rosapi_params /rosbridge_websocket /k13_target_watchdog` | A teleop session is running. That is the intended signal, not a defect. `kennel-demo.sh verify` sets `KENNEL_EXPECT_BRIDGE=1` for you when it can reach one; running `kennel-verify.sh` directly on the guest does not ([`stack/bridge.md` §6](../stack/bridge.md)). The entries also linger 10–20 s after a stop |
| `verify` check 1 says `extra: /disturbance_node` | A run composed with disturbances on launches a seventh node ([#68](https://github.com/alius-git/kennel/issues/68)). `kennel-demo.sh verify` sets `KENNEL_EXPECT_DISTURBER=1` from the applied run's `run.json`; running `kennel-verify.sh` directly on the guest does not |
| The console's `inject` says *disturbances off* | The run the guest launched composed no disturber, so `/disturb_simulation` is not being served. `KENNEL_DISTURBANCES=1 kennel-demo.sh compose`, then `run` ([`teleop.md` §13](../kennel_console/teleop.md)) |
| The simulator dies right after a `reset sim`, or a push | Drake's SAP solver aborts (`sap_solver.cc:342`, exit 134) when it is asked to resolve contacts from a degenerate configuration — a robot that has been sitting collapsed, or one pushed while it is. It costs a relaunch: `kennel-demo.sh launch`. Start from a standing robot: `kennel-bridge.sh recover` ([`demo/scenarios.md` §1.3](scenarios.md)) |
| `scenario diagnose` reports *fell 1 of 3* | A red result, and the traces are the answer — not a reason to run it again. Obstacle terrain is measured as failing differently on repeat ([`transfer.md` §6.3](../stack/transfer.md), [`stack/stress.md`](../stack/stress.md)) |
| You closed the browser tab and the robot kept walking | Not any more: the guest-side watchdog zeroes a stale target about a second after the page goes quiet, and the robot stops. Before [#67](https://github.com/alius-git/kennel/issues/67) it walked **13.3 m in 30 sim-s and was still going** — measured ([`bridge.md` §10.6](../stack/bridge.md)). If it does keep walking, the watchdog is off (`KENNEL_WATCHDOG=0`) or was never staged: `kennel-demo.sh status` says whether one is running, and `kennel-demo.sh teleop stop` always ends it |
| The robot coasts a metre or two after the tab dies | Expected. The watchdog commands a hard zero about a second after the page goes silent, and the robot then decelerates at the controller's own rate — two to five sim-seconds from 0.5 m/s. Nothing can shorten that from the target side ([`bridge.md` §11.2](../stack/bridge.md)) |
| `walk stop` and the watchdog log an intervention | Correct, and not a defect. `p21-trot-hold.sh stop` kills its publisher, checks the controller is alive (seconds), and only then publishes its zeros; in between the last target is 0.3 m/s with nobody publishing it ([`bridge.md` §11.4](../stack/bridge.md)) |
| The console says `another publisher is holding` right after a tab was killed | The watchdog is still repeating its zero — about two seconds. Click *connect bridge* again ([`bridge.md` §11.5](../stack/bridge.md)) |
| The Dashboard shows FALL DETECTED while the robot is fine | The status bar says which source the panels are on. `mode · mock (scripted demo)` means you are watching the seeded demo — connect the bridge (`kennel-demo.sh teleop`, then *connect bridge*) to put them on the stack. `mode · live` means the fall is real, by [`verify.md` §4](../stack/verify.md)'s rule; the banner latches for the post-mortem and *unpin feed* releases it ([`dashboard.md`](../kennel_console/dashboard.md)) |
| The 3D pane says *No viewer attached* | The page learns the viewer's URL from `/api/health`, and the driver writes it there. `kennel-demo.sh run`, then `walk` or `teleop`; `kennel-demo.sh status` prints whether Meshcat is reachable ([`dashboard.md` §1.1](../kennel_console/dashboard.md)) |
| The Runs view says `staged` for a run you know was verified | Either `verify` has not run against that run, or the console server predates the upgrade that added the fields — `/api/runs` is served by the process `console` started. `kennel-demo.sh console stop`, then `console` ([`runs.md` §7](../kennel_console/runs.md)) |
| The console is connected and the robot jitters, or the bridge item says `refused` | Two publishers on `/quad_control_target`. `refused` is the console declining to be the second one — the panels stay live and you are watching, not driving. To drive, stop the other publisher: `kennel-demo.sh walk stop` ([`stack/bridge.md` §7](../stack/bridge.md)) |
| `verify` check 1 says `missing: /joy_to_target`, especially right after a `reset` | Known race, [#52](https://github.com/alius-git/kennel/issues/52) — `launch` returns before that node joins the graph, and a cold container widens the window. Run `kennel-demo.sh verify` again without relaunching; if it passes, the stack was always fine |

## 6. Relation to the dry run

[`dry-run.md`](dry-run.md) deliberately did **not** use the automation you are
using now — its job was to test the written instructions, and two of its five
findings exist only because it obeyed the prose. This runbook is the opposite
artifact: the operator-friendly path built on the scripts the dry run vindicated.
The waits that the prose got wrong (F8) are exactly what
`p21-launch-from-commands.sh` does right, which is why `launch` goes through it.

## 7. Implementation record — fewer commands ([#54](https://github.com/alius-git/kennel/issues/54))

This runbook is its own implementation record: the driver exists to make the
runbook short, so what changed in the driver belongs here. §1–§5 above describe
the result; this section is why it has that shape, and what was actually run to
prove it.

Consumes the baseline snapshot of [#51](https://github.com/alius-git/kennel/issues/51)
(`up`, `reset`, and the persisted domain name that `up` has to resolve). Evidence:
[`evidence/b-fewer-commands/`](evidence/b-fewer-commands/).

### 7.1 What the commands were, and where they went

The count that mattered was never the daily loop — `all` was already one line.
It was the **once per host** part, which was nine steps of prose, and the
**by-hand compose**, which was four.

| Was | Now |
|---|---|
| installer, re-login, `git checkout`, `Enable-TestAutomation.ps1`, 3× `git apply`, `Get-Image.ps1`, hand-edit `test.config.yml` | installer, re-login, **`setup`** |
| `python3 -m http.server`, open a URL, `unzip`, `transfer <path>` | **`console`**, compose, **`run`** |
| `virsh start`, wait, `ssh … docker start` after a host reboot | nothing — `run` does it |

Nine commands became one, four became two, and the reboot case became zero.

### 7.2 The four decisions

**`setup` is a checker that also fixes, not a fixer that also checks.** Every
item prints its state — `ok`, `did`, `needs you` — because the operator on a
strange host needs to know what was true before they arrived, and a script that
silently converges tells them nothing. The three `needs you` cases in §2 are
deliberate refusals: a process cannot grant itself groups (only a re-login can),
a `curl | bash` of a third-party installer is the operator's decision to make,
and a modified Yuruna clone means someone else's work is in the tree. That last
one is the one worth stating plainly: `setup` will not `git checkout` over
changes it cannot account for. It knows what it is allowed to see there — the
files the three patches name, the sequences and guest scripts
`install_kennel_files` copies, and the gitignored `test.config.yml` — and
anything else stops it with the paths printed and nothing touched.

`Enable-TestAutomation.ps1` is guarded on `test/status/runtime/host.pre-automation.json`
rather than run every time. That file is the capture of the host's settings
*before* the automation changed them, and it is what `Disable-TestAutomation`
restores from; a second run against an already-modified host would record the
automation's own values as the operator's, which makes the change permanent while
looking correct. (Yuruna's `Save-HostAutomationState` refuses to overwrite for
exactly this reason — the guard here is so the rest of the script does not run
either.)

**`run` finds the run; the operator does not carry it.** The old friction was
not the `transfer` verb, it was the path argument: the console's archive lands
in the browser's download directory, and the operator had to `unzip` it and type
where it went. `run` takes the newest candidate across both places a run can be
— folders in `$KENNEL_DEMO_OUT`, archives in `$KENNEL_DOWNLOADS` — and unpacks
the archive itself if that is the newer one. Two consequences worth knowing:

- It **says what it picked and why**, every time. A driver that silently chooses
  between two run folders can give you a completely green demo of the wrong
  configuration, and that is a failure the operator cannot see.
- The comparison is strictly newer, so a `.zip` and the folder unpacked *from*
  it resolve to the folder. Running `run` twice does not unpack the same bytes
  twice.

The archive is validated before anything is written: exactly one `run-<stamp>/`
prefix, exactly the four files of
[`export.md` §1](../kennel_console/export.md), and nothing else. That strictness
is not pedantry — `~/Downloads` is the one directory on the machine where a
same-shaped `.zip` from somewhere else is genuinely likely.

**The expected solver comes from the artifact, not from the knob.** `verify
--expect-solver` used to be given `$KENNEL_SOLVER`, which is the *composer's*
default. That was invisible while the only composer was `compose`, which writes
that same default. The moment a human composes an HPIPM run in the browser, the
knob and the run disagree, and `verify` fails a run that is perfectly healthy.
It now reads `choices.mpc_solver` from the applied run's own `run.json` — with
`sed`, as `kennel-transfer.sh` reads the pin out of the same file — and prints
which source it used. §3.3 has the detail. `all` is unaffected in behaviour:
it composed the run with the knob, so the two agree by construction.

**`up` happens by itself, but only for the state where that is unambiguous.**
`need_guest` starts the guest when discovery fails *and* the domain is merely
shut off — the state a host reboot leaves behind, where the fix is not a
decision. A domain that is **running** without a lease is a different animal
(still booting, or a broken network) and still gets the diagnosis, because the
alternative is a silent ten-minute wait inside a verb as innocuous as `status`.
The auto-start is attempted once per process, so a second failure is reported
rather than retried.

### 7.3 One fix that was not planned: relaunch was silently a no-op

Proving "`run` twice in a row is green" found a real defect, and it was not in
the new code. `p21-launch-from-commands.sh` opens with

```
say "stopping anything already running"
sudo docker exec "$CONTAINER" bash -c '[ -x /root/k13-stop.sh ] && /root/k13-stop.sh'
```

— and `/root/k13-stop.sh` only ever reached the container through
`kennel-demo.sh down`, which copies it in. On any guest that had not run `down`
since it came up — a fresh `provision`, or anything after a `reset` — that guard
was false and the stop was a **silent no-op**. The second launch then stacked a
second simulator on the first: the sim clock carried on from the previous
session (observed at 84 s instead of restarting at 1 s), the robot was still
lying where the previous controller had dropped it, and the new controller
never reached "Starting controller" through a stream of `early contact` faults.
The phase failed at `launch` with a log full of symptoms and nothing naming the
cause.

The fix is in `do_launch`: stage `k13-stop.sh` into the container before
invoking the launcher, which is the same `docker cp` that `down` already does.
That makes the launcher's own stated behaviour true on every launch instead of
only after one particular verb. After it, the same second run restarts the sim
at 1 s and is green.

This predates #54 and applied equally to `all`; it was invisible because the
demo had never been asked to launch twice without a `down` in between.

### 7.4 Deviations

None. Every verb added here wraps tools that already existed, and no existing
verb changed behaviour: `all` chains the same five phases in the same order,
`compose` still serves and tears down its own server, and
[`p22-console-demo.sh`](tools/p22-console-demo.sh) — the dry run's automation —
was not touched.

`console` runs `python3 -m http.server`, exactly as
[`serve.md` §1](../kennel_console/serve.md) documents, backgrounded behind a
pidfile so it outlives the command that started it. It refuses to stop a server
on its port that it did not start. That one line is where `serve.py` will go
when the console gains its own endpoint; the verb's surface is deliberately
identical so the swap stays a one-line change.

### 7.5 What was validated

All on 2026-08-30, on the host of [`host-baseline.md` §1](../vm/host-baseline.md),
against the guest that `provision` had just built and frozen as
`kennel-vm-baseline`. Transcripts in
[`evidence/b-fewer-commands/`](evidence/b-fewer-commands/).

| # | Claim | Result | Evidence |
|---|---|---|---|
| 1 | `setup` on a host that needed two items | exit 0; `did` for `automation` and `kennel files`, everything else `ok` | `01-setup-first.txt` |
| 2 | `setup` is idempotent | run twice more: every item `ok`, exit 0, and the two runs' item lines are **byte-identical** | `02-setup-idempotent.txt` |
| 3 | `setup` applies a missing patch, and only that | one patch reversed in the clone → exactly one line differs from the all-`ok` run, and it is `did patch applied yuruna-ssh-autoinstall-confirm.patch` | `03-setup-patch-reversed.txt` |
| 4 | `setup` will not check out over foreign changes | a throwaway clone with HEAD past the tag and one operator-edited file → `needs you`, the path named, nothing changed. On the real clone, zero unexpected changes (the 3 patch targets and the copied kennel files are all accounted for) | `04-setup-refuses-foreign-changes.txt` |
| 5 | `help` groups the verbs | once per host / each session / pieces | `05-help-grouped.txt` |
| 6 | **`run` alone, from a shut-off guest** | `halt` → `shut off after 13s`; then `run` with no argument: started the domain, reachable after 12 s, picked the newest folder, `pass=10 fail=0`, Meshcat URL. **1 m 49 s** total (guest 16 s, transfer 2 s, launch 44 s, verify 42 s, walk 5 s) | `06-run-from-cold.txt` |
| 7 | `run` twice in a row | second run relaunches over a running, trotting stack: sim restarts at 1 s, `pass=10 fail=0`, exit 0, 93 s — after the §7.3 fix | `07-run-twice.txt` |
| 8 | **By-hand compose with a non-default solver** | composed `PARTIAL_CONDENSING_HPIPM` at rate `0.5` in the served console, left the `.zip` in `~/Downloads`, ran `run` with no argument: picked the archive (*"newest archive in /home/thales/Downloads"*), unpacked it, and verify expected **HPIPM from `run-…/run.json`** — the case the old `$KENNEL_SOLVER` default would have failed. `pass=10 fail=0` | `08-compose-by-hand-hpipm.txt`, `08-compose-by-hand-render.png` |
| 9 | The session verbs | `walk stop`, `down`, `status`, `console stop` — all exit 0 | `09-session-verbs.txt` |
| 10 | `all` is unchanged | exit 0, `pass=10 fail=0`, 101 s, and its expected solver resolves to the same `$KENNEL_SOLVER` value by construction (compose wrote it into the `run.json` that verify reads) | `10-all-unchanged.txt` |
| 11 | `provision`'s refactored preflight | patches, ISO and kennel-file install all reported, then declined at the confirmation — exit 2, guest and snapshot intact | `11-provision-preflight.txt` |
| 12 | A non-export archive is refused, and nothing is written | four crafted archives — three files, a stray fifth entry, two top-level folders, not-a-zip — each exit 2 with the reason; the run directory untouched | `12-transfer-refusals.txt` |

Two notes on what these transcripts show.

**The `/joy_to_target` race is still there.** The first run in
`07-run-twice.txt` failed verify check 1 with `missing: /joy_to_target` — the
known race of [#52](https://github.com/alius-git/kennel/issues/52), widened by
the cold container of a just-`reset` guest. Everything else passed, walking
included; re-running `verify` without relaunching gave `pass=10 fail=0`, which
is exactly what §5 says to do. This branch does not fix it.

**`provision`'s destructive path was not re-run here.** The 35-minute cold
build is [#51](https://github.com/alius-git/kennel/issues/51)'s acceptance and
its evidence is in [`vm/snapshot.md`](../vm/snapshot.md); one completed on this
host earlier the same day and produced the `kennel-vm-baseline` domain and
snapshot every test above ran against. What this branch changed in `provision` is
its preflight (the patch check became the shared `patch_state`), and that is what
item 11 exercises.
