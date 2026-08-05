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

### 4.3 Run

```bash
virsh list --all > /dev/null                     # wake socket-activated libvirtd
cd ~/git/yuruna && pwsh test/Test-Config.ps1 -SkipSend
```

Expect **34 PASS / 4 WARN / 0 FAIL** — the kennel sequences add no findings, and
because `Test-Config.ps1` schema-validates every discoverable sequence this is
also the syntax check for the new one.

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

## 6. Measurements

The script captures guest-sizing.md §5's full protocol as a side effect of
provisioning — peak RAM by continuous `MemAvailable` sampling, disk deltas per
phase, image size, workspace size, OOM check — and writes them to
`$HOME/kennel-provisioning-metrics.txt`. The final sequence step prints that
file into the run log, so the numbers land in the cycle record without a second
instrumented run.

Results are recorded in [`vm/guest-sizing.md` §5.4](guest-sizing.md), which is
where #9's acceptance criterion reads them.

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

**Fix (needs sudo; run when no cycle is in flight):**

```bash
sudo apt install -y adjtimex
sudo systemctl stop chrony
sudo adjtimex --tick 10000 --frequency 0
sudo systemctl start chrony && sudo chronyc makestep
```

Then confirm `chronyc tracking` reports `Frequency` in the tens of ppm rather
than six figures. Deleting `/var/lib/chrony/chrony.drift` alone is **not**
sufficient — it does not reset the kernel `tick`. Switching `clocksource` is
also not a fix; both `tsc` and `hpet` behave identically here, which is
consistent with the hardware being fine.

**Consequence for this issue:** the runs recorded below executed against a clock
running ~10 % slow, so **every wall-clock duration is understated by roughly
10 %**. Disk and memory measurements are unaffected — they are not time-derived.
Timing rows in guest-sizing.md §5.4 are marked accordingly and should be re-taken
once the clock is fixed.

Worth filing on [#28](https://github.com/alius-git/kennel/issues/28): Yuruna's
config gate detects the *offset* but reports it as advisory, and its suggested
remedy (`chronyc makestep`) cannot fix this failure mode.

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

- **The pin is hardcoded in the script.**
  [#12](https://github.com/alius-git/kennel/issues/12) makes `stack/pin.lock`
  the single source of truth; that file does not exist yet, so this literal is
  currently the pin. #12 must reconcile the two — either by having the script
  read `pin.lock`, or by making the assertion in the sequence the enforcement
  point (it already asserts the SHA independently).
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

---

Last review: 2026-08-05
