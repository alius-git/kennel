# Guest provisioning — Docker + the pinned dfki-quad stack

Implementation record for
[issue #10](https://github.com/alius-git/kennel/issues/10) — one idempotent
script that takes a fresh Ubuntu 24.04 kennel guest to **"stack ready"**: Docker
CE installed, the pinned dfki-quad fork cloned, upstream's Docker image built,
the container running headless, and the go2 workspace compiled.

Builds on [`vm/host-baseline.md`](host-baseline.md)
([#8](https://github.com/alius-git/kennel/issues/8)) and
[`vm/guest-sizing.md`](guest-sizing.md)
([#9](https://github.com/alius-git/kennel/issues/9)). **Read guest-sizing.md §2
and §3 first** — the three Yuruna patches and the sizing cascade are hard
prerequisites for anything here.

> **Bypass note (tracking-issue [#7](https://github.com/alius-git/kennel/issues/7),
> [#26](https://github.com/alius-git/kennel/issues/26)):** this script **is** the
> MVP's appliance. It replaces the pinned OVA image build of `design.md` §1 —
> instead of shipping a pre-baked image, the MVP builds the stack in-place on a
> stock guest, every time. *Retirement path:* the `appliance/build` pipeline,
> which bakes exactly this result into a distributable image.

## 1. What is delivered

| Artifact | Purpose |
|----------|---------|
| [`vm/guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh`](guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh) | The provisioning script — the actual work |
| [`vm/test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml`](test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml) | Yuruna sequence: runs the script, then asserts acceptance |

The sequence chains onto #9's sizing sequence, so one command walks the whole
thing from nothing:

```
start.guest.ubuntu.server.24.kennel.ssh      # create + install the 8 vCPU / 16 GiB guest
  -> workload.guest.ubuntu.server.24.kennel.ssh        # assert the size actually landed (#9)
    -> workload.guest.ubuntu.server.24.kennel.stack.ssh  # provision the stack (#10)
```

Putting #9's asserts in the chain is deliberate: a wrong-sized guest fails in
seconds on the `nproc`/`MemTotal` checks instead of hours later, inside a colcon
build that was never going to fit.

## 2. The script, phase by phase

Each phase is guarded, so a re-run on an already-provisioned guest is a no-op or
a cheap refresh (issue #10, work item 4). Each phase also emits a
`==== name ====` banner — Yuruna's `fetch-and-execute` captures those as
per-phase timing checkpoints, so **the banners are the wall-clock
instrumentation**, not decoration.

| # | Phase | Guard (what makes it idempotent) |
|---|-------|----------------------------------|
| 1 | `Docker CE` | `docker info` answers → skip install |
| 2 | `dfki-quad clone at pin` | `git rev-parse HEAD` == pin → no-op; wrong rev → fetch + detach; absent → clone |
| 3 | `dfki-quad image build` | `docker image inspect dfki_quad:latest` → skip |
| 4 | `dfki-quad container` | container running → reuse; stopped → `docker start`; absent → `docker run` |
| 5 | `colcon build go2` | build stamp for **this pin** + `install/setup.bash` → skip |
| 6 | `verify sim launchable` | always runs — it is the acceptance criterion |

**Docker CE** is installed from Docker's official apt repository, with the
signing key's fingerprint verified against `9DC858229FC7DD38854AE2D88D81803C0EBFCD88`
before it is trusted into apt — reusing the `_yuruna_verify_key_fpr` helper
verbatim from the stock `ubuntu.server.24.code.sh`, so the kennel script trusts
apt keys on exactly the same terms the framework's own scripts do. The suite is
taken from the guest's `/etc/os-release` `VERSION_CODENAME` rather than
hardcoded to `noble`, so the script survives the guest image moving forward.

`yuuser24` is added to the `docker` group for an operator's later interactive
session, but **every docker call in the script uses `sudo`** — group membership
does not apply to the SSH session that is already open.

**The colcon line is verbatim from issue #10:**

```bash
colcon build --symlink-install --cmake-args -DCMAKE_EXPORT_COMPILE_COMMANDS=1 -DROBOT_NAME=go2
```

Note that the pin predates upstream's own `ws/src/build_go2_sim.sh` helper
(added in a later commit), which restricts the build to
`--packages-up-to simulator drivers state_estimation controllers`. At this pin
the whole workspace is built. If a package outside that set proves to be the
thing that breaks or dominates the build, restricting the package set is the
first thing to try — see §7.

## 3. Deviations from upstream dfki-quad

These are the substantive findings of #10 and the reason the script does not
simply call upstream's own two scripts. Recorded for
[#26](https://github.com/alius-git/kennel/issues/26) (bypass log) and
[#28](https://github.com/alius-git/kennel/issues/28) (upstream gaps).

### 3.1 `build_new_image.sh` cannot run unattended

It opens with an interactive prompt:

```bash
echo "Press ENTER, if you want to continue:"
read -s -n 1 key
if [[ $key != "" ]]; then echo "Aborted."; exit 0; fi
```

Under `sshFetchAndExecute` there is no TTY, so this can never complete. Worse,
it `exit 0`s on a non-empty key — a **silent success that builds nothing**.

The script therefore runs the command `build_new_image.sh` derives for x86_64,
directly:

```bash
sudo docker build -t dfki_quad "$HOME/dfki-quad/docker" \
  --build-arg HW_ARCH=x86_64 --build-arg GO2_NETWORK_INTERFACE=enp0s31f6
```

Only the prompt and the destructive container-sweep are dropped; the build
arguments are exactly what upstream computes.

*Retirement path:* upstream should gate the prompt on `[ -t 0 ]` or accept a
`--yes` flag.

### 3.2 `run_docker.sh` is headless-hostile three ways

| Line | Problem headless |
|------|------------------|
| `xhost +local:` | No X server on a server guest |
| `docker attach dfki_quad` | Blocks forever, wants a TTY |
| `docker-compose.yml` → `devices: [/dev/ttyACM0]` | That device does not exist in the guest, so `docker compose up` **fails outright** |

The third is the decisive one: a compose *override* file can add or change
values, but it **cannot remove** a `devices:` entry, so compose cannot be
salvaged from the outside. The script therefore starts the container with a
direct `docker run` that reproduces the compose service minus the
headless-breakers:

```bash
sudo docker run -d -it --name dfki_quad --label dfki_quad \
  --network host --privileged -w /root/ros2_ws \
  -v "$HOME/dfki-quad/ws/src:/root/ros2_ws/src" \
  -v "$HOME/dfki-quad/ws/build:/root/ros2_ws/build" \
  -v "$HOME/dfki-quad/ws/install:/root/ros2_ws/install" \
  -v "$HOME/dfki-quad/ws/log:/root/ros2_ws/log" \
  -v "$HOME/dfki-quad/ws/data:/root/ros2_ws/data" \
  dfki_quad:latest
```

**Dropped vs. upstream compose:** `DISPLAY` / `QT_X11_NO_MITSHM`, the
`/tmp/.X11-unix` mount, `/dev/input`, the `/dev/ttyACM0` device, and the
bash-history mount — all X11-, joystick- or real-robot-only, none of them
reachable or relevant in a headless sim run.

**Kept deliberately:** `--network host` (this is what will let
[#11](https://github.com/alius-git/kennel/issues/11) reach Meshcat from the
host — the container publishes on the guest's own interfaces), `--privileged`,
the working directory, and all five `ws/` bind mounts (so the build artifacts
live on the guest filesystem and survive `docker rm`).

**No `--restart` policy**, matching upstream. After a guest reboot the container
is restarted explicitly:

```bash
sudo docker start dfki_quad
```

That matters for #11's "survives a guest reboot" acceptance criterion.

*Retirement path:* upstream could split the device/X11 bindings into a
`docker-compose.hardware.yml` overlay so the base compose file is headless-clean.

### 3.4 Issue #10's colcon command cannot succeed at this pin — `-DWITH_VICON=OFF` is required

**This is the most substantive finding of #10.** The colcon line the issue
specifies:

```bash
colcon build --symlink-install --cmake-args -DCMAKE_EXPORT_COMPILE_COMMANDS=1 -DROBOT_NAME=go2
```

fails at configure time, in 92 s, with:

```
CMake Error at CMakeLists.txt:23 (find_package):
  Could not find a package configuration file provided by "vicon_receiver"
Failed   <<< state_estimation [0.88s, exited with code 1]
Aborted  <<< drivers, simulator
```

Two facts at the pin combine to make this unavoidable:

| Where | What |
|-------|------|
| `ws/src/state_estimation/CMakeLists.txt:11` | `option(WITH_VICON "Use Vicon" ON)` — **defaults ON** |
| `ws/src/state_estimation/CMakeLists.txt:23` | `find_package(vicon_receiver REQUIRED)` under `if(WITH_VICON)` |
| `docker/Dockerfile:154-158` | the entire Vicon driver install is **commented out** |

So the image is built without `vicon_receiver`, while the workspace requires it
by default. The stack cannot build with the command as written, and this is a
property of the pin, not of the harness or the guest.

The script therefore adds `-DWITH_VICON=OFF`. That is also the *semantically*
correct value: Vicon is lab motion-capture hardware for the `ulab` robot and has
no role in the go2 simulation the MVP runs. With it, `state_estimation`
configures and builds cleanly (verified in 23.5 s, warnings only).

Corroboration that this is upstream's own conclusion: the later
`ws/src/build_go2_sim.sh` helper (which post-dates the pin) exists precisely to
carry a `--no-vicon` switch and pass `-DWITH_VICON=$WITH_VICON` explicitly.

*Override:* `KENNEL_WITH_VICON=ON` restores the issue's literal command, for
anyone re-testing once the image ships Vicon.

**Action:** #10's acceptance text should be amended to include
`-DWITH_VICON=OFF`, and the mismatch filed on
[#28](https://github.com/alius-git/kennel/issues/28) — either the Dockerfile's
Vicon install is restored, or `state_estimation` should default the option OFF.

### 3.5 The unitree_ros2 overlay must be sourced explicitly

Upstream expects you to work **interactively** inside the container, where
`/root/.bashrc` sets the environment up for you:

```bash
source /root/ros2_ws/install/setup.bash
source /root/unitree_ros2/install/setup.bash     # supplies unitree_go / unitree_api
```

`docker exec ... bash -c` is **not** an interactive shell, so `.bashrc` is never
read. Without the second line, `ROBOT_NAME=go2` fails its configure:

```
CMake Error at CMakeLists.txt:67 (find_package):
  Could not find a package configuration file provided by "unitree_go"
Failed   <<< drivers
```

The image is fine — `unitree_go`, `unitree_api` and `unitree_ros2_example` are
all present under `/root/unitree_ros2/install/`. Only the environment was
missing. Every in-container command in the script therefore sources a shared
`CONTAINER_ENV` block (guarded with `-f`), and the sequence's launch assertion
does the same.

This is a headless-execution consequence rather than an upstream defect, but it
is invisible when testing by hand — an operator who `docker exec -it`s in gets a
working environment and never sees it. Worth stating in the #27 quickstart.

Incidental confirmation of §3.4: `/root/.bashrc` also sources
`/root/ros2-vicon-receiver/vicon_receiver/install/setup.bash`, which **does not
exist** in the image, so even an interactive shell reports an error on that line.

### 3.3 `time` is installed into the container

`/usr/bin/time -v` is not in the ROS base image, and guest-sizing.md §5.1 needs
it for the largest-single-compiler-RSS measurement. The script installs it into
the container (not the guest) before the build. Harmless, but it is a
modification to the image's running state and is noted for completeness.

## 4. Running it

### 4.1 Prerequisites

Everything in [`vm/guest-sizing.md` §3.1](guest-sizing.md) — the three Yuruna
patches, the fetched guest ISO, and the host clock caveat (§4.3 there: the clock
defect is **not** fixed by `chronyc makestep`, it re-converges to the same
offset; it remains an open operator action).

### 4.2 Install the kennel files into the Yuruna clone

Both the sequence **and the guest script** must be copied into the framework
clone. This is the same bypass guest-sizing.md §3.2 describes, extended to the
`guest/` tree:

```bash
cp /path/to/kennel/vm/test/*.kennel*.yml     ~/git/yuruna/test/sequences/
cp /path/to/kennel/vm/guest/ubuntu.server.24/*.sh ~/git/yuruna/guest/ubuntu.server.24/
```

`sshFetchAndExecute` resolves its path against the **framework working tree**,
which the host status service serves at `/yuruna-repo/`. Once
[#23](https://github.com/alius-git/kennel/issues/23) points
`repositories.projectUrl` at the kennel repo, the fetch path in the sequence
becomes a project-tree path and this copy step retires.

`vm/guest/` mirrors the `vm/test/` naming for exactly that reason — the layout
already matches where the files will eventually be discovered.

**Expect this warning, twice, in yellow, on a completely healthy cycle:**

```
WARNING: fetch-and-execute fallback: 'guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh'
differs from HEAD, so the GitHub fallback cannot match its digest. Harmless while
the host status service is reachable (the guest fetches the working tree); if it
is not, commit and push -- or bring the status service back up.
```

It is caused by the copy above: the script now in the framework clone is
Kennel's working-tree copy, which by construction differs from *yuruna's*
committed HEAD, so the GitHub-fallback digest cannot match. The guest fetches
from the host status service, so nothing is degraded. It fires at both
`sshFetchAndExecute` steps and retires with the copy step itself
([#23](https://github.com/alius-git/kennel/issues/23)). Recorded because
[#22](https://github.com/alius-git/kennel/issues/22) hit it on a 28/28 PASS run
and it reads like a failure.

### 4.3 Run

```bash
virsh list --all > /dev/null                     # wake socket-activated libvirtd
cd ~/git/yuruna && pwsh test/Test-Config.ps1 -SkipSend
```

Expect **0 FAIL, and no finding naming a kennel sequence or the guest script** —
that is the invariant. Because `Test-Config.ps1` schema-validates every
discoverable sequence, this is also the syntax check for the new one.

**Do not gate on the PASS/WARN counts.** They were 34 PASS / 4 WARN when this
was written and 33 PASS / 5 WARN on 2026-08-07, with no Kennel change in
between: the gate scans the *yuruna-project* repo too, and its "project N
commits behind upstream" check flips to WARN whenever upstream commits. That
warning is self-clearing — `Invoke-TestSequence.ps1` re-clones `project/` on
every run (host-baseline.md §6.7) — so the count drifts on its own. Read the
findings, not the totals ([#22](https://github.com/alius-git/kennel/issues/22)).

Destroy any existing guest first — sizing applies at VM *creation* only
(guest-sizing.md §2):

```bash
pwsh test/Remove-TestVMFiles.ps1 -Prefix test- -Confirm:$false
pwsh test/Invoke-TestSequence.ps1 -SequenceName workload.guest.ubuntu.server.24.kennel.stack.ssh
```

To confirm the chain and the cascade before spending the boot time:

```console
$ pwsh -NoProfile -Command '
    Import-Module ./test/modules/Test.SequenceResolve.psm1 -Force
    Import-Module ./test/modules/Test.SequencePlanner.psm1 -Force
    Resolve-NamedSequenceChain -SequenceName workload.guest.ubuntu.server.24.kennel.stack.ssh `
      -SequencesDir ./test/sequences -RepoRoot . -HostType host.ubuntu.kvm |
      Select-Object fullChain, effectiveHostname, effectiveMemoryStartupBytes, effectiveCores'

fullChain                   : {start.guest.ubuntu.server.24.kennel.ssh,
                              workload.guest.ubuntu.server.24.kennel.ssh,
                              workload.guest.ubuntu.server.24.kennel.stack.ssh}
effectiveHostname           : kennel-vm
effectiveMemoryStartupBytes : 16GB
effectiveCores              : 8
```

### 4.4 Iterating on the script alone

Once a guest is up, the script can be re-run directly over SSH without a full
cycle — useful when debugging a single phase:

```bash
ssh -i ~/git/yuruna/test/status/ssh/yuruna_ed25519 yuuser24@<guest-ip> \
  '/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh'
```

### 4.5 Knobs

`fetch-and-execute` passes **no arguments** to the fetched script, so every knob
is an environment variable set ahead of the call:

| Variable | Default | Use |
|----------|---------|-----|
| `KENNEL_COLCON_JOBS` | *(empty = colcon default)* | Cap build parallelism — the **first** OOM lever (guest-sizing.md §6) |
| `KENNEL_FORCE_IMAGE_REBUILD` | `0` | Rebuild the Docker image even if it exists |
| `KENNEL_SIM_SMOKE_SECONDS` | `45` | How long the acceptance smoke lets the simulator run |
| `DFKI_QUAD_COMMIT` | the pin | Override the stack revision (for #12 reconciliation / bisecting) |
| `KENNEL_METRICS_FILE` | `$HOME/kennel-provisioning-metrics.txt` | Where the measurement block is written |

```bash
KENNEL_COLCON_JOBS=4 /usr/local/lib/yuruna/fetch-and-execute.sh \
  guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh
```

## 5. Idempotency

Issue #10 asks that re-running on an already-provisioned guest be "a no-op or
clean refresh". The sequence **asserts** this rather than asserting it in prose:
the provisioning step runs twice, and the second invocation carries a
deliberately short `timeoutSeconds: 1800`. If any guard failed to hold, the
second run would rebuild and blow that bound — which is exactly the failure
worth surfacing, instead of a silently slow re-run.

What a second run actually does: confirms Docker answers, confirms the clone is
at the pin, finds the image and the running container, finds the build stamp,
and re-runs only the bounded simulator smoke. Minutes, not hours.

**Manual refresh knobs** (deliberately not automatic — each discards real work):

| To force | Do |
|----------|-----|
| Image rebuild | `KENNEL_FORCE_IMAGE_REBUILD=1`, or `sudo docker image rm dfki_quad` |
| Workspace rebuild | `rm $HOME/dfki-quad/ws/.kennel-built-<sha>` (colcon is then incremental) |
| Clean workspace rebuild | also `rm -rf $HOME/dfki-quad/ws/{build,install,log}` |
| Container recreate | `sudo docker rm -f dfki_quad` (build artifacts survive — they are bind mounts) |

The build stamp is keyed on the **pin SHA** (`.kennel-built-<sha>`), so moving
the pin automatically invalidates it without any manual step.

## 5a. Validation — evidence

Run on the kennel guest (8 vCPU / 16 GiB, hostname `kennel-vm`) on 2026-08-05.

**Functional acceptance: met.** Issue #10's criterion is *"fresh guest → script →
`ros2 launch simulator simulator.launch.py sim:=go2` is launchable inside the
container with no manual step in between."*

| Stage | Result |
|-------|--------|
| Guest boot (the #9 §4.2 blocker) | **PASS** — `sshWaitReady` at 442 s; the blocker had cleared |
| #9 sizing asserts (8 vCPU, ≥15 GiB, ≥50 GiB, hostname) | **PASS**, all four |
| Docker CE install | **PASS** |
| Clone at pin `dcf53c5` | **PASS** |
| Docker image build | **PASS** — 3.69 GB content / 13 GB disk |
| Container start (headless `docker run`) | **PASS** |
| `colcon build` (7 packages) | **PASS** — exit status 0 |
| `ros2 launch simulator ... sim:=go2` | **PASS** — alive past the smoke window; `drake_simulator` enumerates the go2 model's 30 joints |

Measurements are in [`vm/guest-sizing.md` §5.4](guest-sizing.md): peak RAM
7.2 GiB of 16, largest compiler RSS 2.46 GiB, 28 GiB disk used of ~60 usable,
**no OOM kills**.

**Five defects were found and fixed by this validation**, which is the argument
for running it rather than reasoning about it. Recorded because four of the five
are traps any similar harness work will hit:

| # | Defect | Where |
|---|--------|-------|
| 1 | `docker inspect … \|\| echo absent` yields `"\nabsent"` — docker writes a newline to **stdout** before failing, so the `case` fell through and tried to start a container that never existed | this script |
| 2 | `docker inspect NAME` also resolves **images**; the image is named `dfki_quad` too, so it exited 0 with an empty `.State.Status`. Needs `--type container` | this script + the sequence assert |
| 3 | `WITH_VICON` defaults ON but the image omits `vicon_receiver` | **upstream / the issue text** — see §3.4 |
| 4 | The unitree_ros2 overlay is only sourced by `.bashrc`, which `docker exec bash -c` never reads | this script — see §3.5 |
| 5 | `wait $LP` after `kill -INT` hung a run for **83 minutes**: the Drake simulator ignores SIGINT to the launcher | this script + the sequence assert |

Defect 5 is worth extra care by anyone editing the teardown. Two obvious fixes
are both wrong:

- `setsid` + `kill -$LP` (negative = process group) killed the **calling shell's
  own group** — `$!` is the `setsid` PID, which is not dependably the new group
  leader.
- `pkill -f 'ros2 launch simulator'` also killed the calling shell, because that
  shell's *command line contains that very string*.

The working form signals the launcher PID, waits a bounded interval, hard-kills
it, then reaps survivors by **exact process name** (`pkill -x simulator`,
`pkill -x ros2`) — a name match cannot hit a shell called `bash`. Verified live:
zero leftovers, bounded at ~32 s.

**The clean pass has since been demonstrated** (2026-08-05, later the same
day): one uninterrupted `Invoke-TestSequence` cycle from guest creation through
all 27 steps — full provisioning in step 3, the idempotency re-run inside its
1800 s bound in step 4, every assert green. The literal "no manual step in
between" wording now holds. Wall-clock numbers from that run are still
untrustworthy (§6a — the host clock defect stands), so the §5.4 timing rows
remain unfilled; everything else is final.

## 6. Measurements

The script captures guest-sizing.md §5's full protocol as a side effect of
provisioning — peak RAM by continuous `MemAvailable` sampling, disk deltas per
phase, image size, workspace size, OOM check — and writes them to
`$HOME/kennel-provisioning-metrics.txt`. The final sequence step prints that
file into the run log, so the numbers land in the cycle record without a second
instrumented run.

Results are recorded in [`vm/guest-sizing.md` §5.4](guest-sizing.md), which is
where #9's acceptance criterion reads them.

> **Trap: the idempotency step overwrites the build's metrics.** The stack
> sequence runs this script **twice** — step 20 builds, step 21 re-runs it to
> prove idempotency — and both write `$KENNEL_METRICS_FILE`. The second run does
> no build, so it records no peak RAM and no OOM check, and what survives on the
> guest describes the **57-second no-op**, not the 22-minute build:
>
> ```
> run.started  2026-08-07T15:40:34Z
> run.ended    2026-08-07T15:41:30Z      <- the idempotency re-run
> (no peak-RAM line, no OOM line)
> ```
>
> Consequence: §5.4's peak-RAM figure **cannot be reproduced by running the
> documented sequence**, which is why it is cited to #10's original run. To
> re-measure, either read the file between steps 20 and 21, or run the script
> directly over SSH (§4.4) with `KENNEL_METRICS_FILE` pointed somewhere the
> re-run will not reach. Found by
> [#22](https://github.com/alius-git/kennel/issues/22).

## 6a. Host clock — wall-clock timings from these runs are understated

Recorded here because it changes how §6's numbers must be read, and because it
resolves the open operator action inherited from
[`vm/host-baseline.md`](host-baseline.md) §6.6 and
[`vm/guest-sizing.md`](guest-sizing.md) §4.3.

Both of those documents describe the host clock as a ~272 s standing offset with
a "~10 % oscillator error" that `chronyc makestep` cannot fix. **The oscillator
is not the problem.** Measured against an external reference:

| Clock | Elapsed over a 67.00 s true interval | |
|-------|--------------------------------------|---|
| `CLOCK_MONOTONIC_RAW` (no NTP adjustment) | 67.16 s | **100.2 % — hardware is correct** |
| `CLOCK_MONOTONIC` (NTP-adjusted) | 60.48 s | 90.3 % |
| `CLOCK_REALTIME` (NTP-adjusted) | 60.48 s | 90.3 % |

The raw counter tracks true time exactly; time is lost only *after* NTP
adjustment. The cause is visible in `adjtimex`:

```
kernel freq : 0.0 ppm       (fine adjustment: zero)
kernel tick : 9000 us       <-- should be 10000; exactly the 10 % being lost
```

chrony saturated the fine-grained `freq` field, drove the coarse `tick` to its
lower rail, and cannot recover: on restart it measures a clock that is already
10 % slow *because* `tick=9000`, re-derives "the oscillator is 10 % slow", and
reproduces the same state. That is why `makestep` appears to work and then
reverts, and why `Frequency` returns to exactly `100000.000 ppm` — the rail, not
a measurement.

**What was tried, and the outcome.** Resetting the tick does work, briefly:

```bash
sudo systemctl stop chrony
sudo rm -f /var/lib/chrony/chrony.drift
sudo adjtimex --tick 10000 --frequency 0     # rate returns to 100.00 %
```

but it does not hold. With chrony running it is re-railed to 9000 within
seconds — chrony's frequency estimate is derived from measuring a clock it
itself broke, so on every start it "confirms" a 10 % error and reapplies it.
**And it reverts even with chrony stopped, masked, and no `chronyd` process
alive**, so chrony is not the whole story on this host.

Ruled out along the way: deleting the drift file alone (does not reset the
kernel `tick`); switching `clocksource` (`tsc` and `hpet` behave identically,
consistent with the hardware being sound); and a competing time daemon
(`systemd-timesyncd` is not even installed here).

**Descoped.** This is a property of the development host, not of Kennel, and no
MVP acceptance criterion depends on wall-clock duration. Chasing it further has
no payoff for the project. Practical guidance:

- Leave `chrony` **enabled**. It cannot fix the rate, but it keeps absolute time
  near zero. Masked, the clock free-runs ~6 min/hour off, which trips Yuruna's
  120 s config gate mid-cycle and can make the guest's `apt` reject repository
  metadata as "not valid yet".
- Treat any Yuruna step duration measured here as ~10 % low.
- Take real timings on a host with a sound clock before quoting them.

**Consequence for this issue:** the two wall-clock rows in guest-sizing.md §5.4
are intentionally left unfilled. Everything else — functional acceptance, peak
RAM, disk, OOM — is unaffected, because none of it is time-derived.

Worth filing on [#28](https://github.com/alius-git/kennel/issues/28): Yuruna's
config gate detects the *offset* but reports it as advisory, and its suggested
remedy (`chronyc makestep`) cannot fix this failure mode — it addresses the
offset while the rate is what is actually wrong.

### 6a.1 Update 2026-08-07 — the rate defect is gone, the offset is not

Re-measured at the start of [#22](https://github.com/alius-git/kennel/issues/22)'s
demo dry run, because that issue's deliverable *is* a set of timings and the
paragraphs above say they cannot be taken here. They can now:

| Clock | Elapsed over a 60.00 s true interval | |
|-------|--------------------------------------|---|
| `CLOCK_MONOTONIC_RAW` | 60.004 s | 100.0 % — reference |
| `CLOCK_MONOTONIC` | 60.002 s | **100.0 %** |
| `CLOCK_REALTIME` | 60.002 s | **100.0 %** |

```
kernel tick : 10000 us      <-- the default; was railed at 9000
kernel freq : -39.4 ppm     <-- an ordinary discipline value, not a rail
```

The tick is off its rail and chrony is disciplining normally. Nothing in this
repo did that; the host was rebooted between 2026-08-06 and 2026-08-07, which is
the only change. Note what this costs the paragraphs above: the claim that the
state "reverts even with chrony stopped, masked, and no `chronyd` process alive"
described a **running** kernel that could not be talked down, not a persistent
one. A reboot clears it. The mechanism was never identified, so treat this as
*latent* rather than fixed — re-run `demo/tools/p22-clock.sh ratio 60` before
quoting any duration, which takes a minute and is the whole check.

**The two defects are separate, and only one is gone:**

| | Then (2026-08-06) | Now (2026-08-07) | Affects |
|---|---|---|---|
| **Rate** — tick railed at 9000 µs | ~10 % slow | **sound** | durations |
| **Offset** — clock behind real time | 270.6 s | 313.2 s (still WARNs) | absolute timestamps |

So **durations measured on this host are now quotable**, and §5.4's two empty
rows are filled by #22's run ([`demo/dry-run.md`](../demo/dry-run.md) §2).
**Absolute timestamps are still ~5 min behind reality** — which is why
`run.json`'s `generated_at` and the `run-<timestamp>/` folder name from a
console export taken here read about five minutes early. That is cosmetic for
the MVP (nothing joins on those stamps) but it is not nothing, and it is the
part the config gate still flags.

Consequence for the guidance above: "treat any Yuruna step duration measured
here as ~10 % low" **no longer holds unconditionally**. Check the rate, then
decide.

## 7. Contingencies

### The build OOMs

In the order guest-sizing.md §6 sets out — **cap parallelism first**, because
the host cannot give the guest much more than 16 GiB without swapping:

```bash
KENNEL_COLCON_JOBS=4 /usr/local/lib/yuruna/fetch-and-execute.sh \
  guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh
```

The script prints exactly this line on a failed build, and records the measured
peak and any OOM kills either way — so a failed run still explains itself.

### Disk runs out

`docker builder prune` between the image build and colcon is the cheapest first
move; the build cache is usually the largest disposable term. Beyond that, the
64 GB guest disk is hardcoded in `New-VM.ps1` and needs the fourth Yuruna patch
described in guest-sizing.md §6.

### A package outside the sim set breaks the build

The pin builds the whole workspace. Upstream's later `build_go2_sim.sh`
restricts to `--packages-up-to simulator drivers state_estimation controllers`;
applying the same restriction is the first thing to try, and it is also faster.
That is a change to the colcon line in phase 5.

### The simulator smoke fails

The smoke asserts the launch is still alive after 45 s — a stack that failed to
build, or whose environment is wrong, exits within seconds. The full output is
kept at `/tmp/kennel-sim-smoke.log` (guest) and `/tmp/sim-smoke.log`
(container). Deeper launch and walking verification is
[#13](https://github.com/alius-git/kennel/issues/13) and
[#14](https://github.com/alius-git/kennel/issues/14), not this issue.

## 8. Notes for the record

- **The pin lives in [`stack/pin.lock`](../stack/pin.lock); the script's literal
  is a derived copy.** [#12](https://github.com/alius-git/kennel/issues/12)
  landed that file and resolved the reconciliation this note used to leave open,
  in favour of *assertion-as-enforcement*: the script cannot read `pin.lock`
  (fetch-and-execute drops it into the guest alone, with no checkout of the
  kennel repo), so `DFKI_QUAD_COMMIT` stays a literal, and the sequence's
  "Assert the clone sits at the stack pin" step — which re-states the SHA
  independently — is what catches drift between the three. Repinning means
  changing all three and re-running the sequence. No SHA changed: `pin.lock`
  records the `dcf53c5` this document validated.
- **The container's `~/.bashrc` sources `/root/ros2_ws/install/setup.bash`**,
  which does not exist before the first build. Every command the script runs in
  the container sources what it needs explicitly, rather than relying on the
  interactive shell's environment.
- **`--network host` means the container has no network isolation from the
  guest.** That is upstream's choice, kept deliberately for #11, and acceptable
  for an MVP appliance on a NAT'd guest — but it is a real property worth
  stating rather than inheriting silently.
- **Meshcat's URL is captured** from the smoke output into the metrics file, so
  #11 starts from an observed value rather than an assumed `localhost:7000`.
  [#11](https://github.com/alius-git/kennel/issues/11) is now closed out in
  [`vm/meshcat-exposure.md`](meshcat-exposure.md): `--network host` did indeed
  carry the container→guest hop, and the guest→host hop needs no port forward —
  the host routes to the guest's NAT address over `virbr0`.

---

Last review: 2026-08-05
