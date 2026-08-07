# Getting a generated run onto the container's config paths

Implementation record for
[issue #20](https://github.com/alius-git/kennel/issues/20) — a scripted,
repeatable path takes the console's exported files from the host into the
running container at the paths the launch files read.

Consumes [`kennel_console/export.md`](../kennel_console/export.md)
([#19](https://github.com/alius-git/kennel/issues/19)) — an unpacked
`run-<timestamp>/` folder, unmodified — and
[`vm/provisioning.md`](../vm/provisioning.md)
([#10](https://github.com/alius-git/kennel/issues/10)), which delivers the
container, its bind mounts and the built workspace. Pin:
`dcf53c596339afd45b82f12c54b1e93e8273c2f4`
([`stack/pin.lock`](pin.lock)).

Verified 2026-08-06 on `kennel-vm`, end to end, including a launch of the real
stack on the transferred files. Evidence in
[`stack/transfer/evidence/`](transfer/evidence/).

> **Bypass note (tracking-issue [#4](https://github.com/alius-git/kennel/issues/4)).**
> An scp hand-off plus scripted placement stands in for the designated workspace
> directory contract of `design.md`. The console still never runs a process and
> never reaches the guest itself; an operator (or, from
> [#24](https://github.com/alius-git/kennel/issues/24), a Yuruna sequence) runs
> the script. *Retirement path:* the appliance's run-manifest store and workspace
> directory, at which point the console writes where the stack already reads and
> this script has nothing left to do.

## 1. What is delivered

| Artifact | Purpose |
|----------|---------|
| [`stack/transfer/kennel-transfer.sh`](transfer/kennel-transfer.sh) | Host side: validate the run folder, find the guest, scp, invoke the applier |
| [`stack/transfer/guest-apply-config.sh`](transfer/guest-apply-config.sh) | Guest side: back up, place, verify from **inside the container**, restore |
| [`stack/transfer/evidence/`](transfer/evidence/) | The three transcripts §6 reads |

```bash
stack/transfer/kennel-transfer.sh apply ~/runs/run-20260806T170901Z
stack/transfer/kennel-transfer.sh restore-stock
stack/transfer/kennel-transfer.sh status
```

## 2. The four decisions

### 2.1 The container hop is a bind mount, not `docker cp`

Issue #20 asks for one or the other, with a justification. It is the bind mount,
and the reason is that **the hop does not exist**: #10 already starts the
container with

```
-v "$HOME/dfki-quad/ws/src:/root/ros2_ws/src"
```

so `~/dfki-quad/ws/src/simulator/config/simulator_params_go2.yaml` on the guest
and `/root/ros2_ws/src/simulator/config/simulator_params_go2.yaml` in the
container are one file. Writing the guest path *is* writing the container path.
`docker cp` would be a second copy of a file that is already shared.

Three properties follow, and each is a real advantage rather than a tidiness
argument:

- **It works with the container stopped**, and the files survive `docker rm` —
  the same reason #10 chose the mounts. `docker cp` requires a container.
- **No symlink ambiguity.** `--symlink-install` makes the install space point at
  the source path; replacing the source file through the filesystem cannot
  disturb that. `docker cp`'s behaviour when a destination is a symlink is a
  detail worth not depending on.
- **It costs nothing in verifiability**, which is the argument that decides it.
  `docker cp` would still have to be checked with `docker exec sha256sum`, so
  the acceptance criterion is the same either way — and the script performs that
  check regardless (§5). The checksum inside the container is what *proves* the
  mount carried the bytes, rather than assuming it.

### 2.2 Two scripts, because #24 cannot use a host-side one

Yuruna's verbs are `sshExec`, `sshFetchAndExecute` and `callExtension` — there
is no host-exec action (the same constraint
[`vm/meshcat-exposure.md`](../vm/meshcat-exposure.md) records for #11). So
[#24](https://github.com/alius-git/kennel/issues/24)'s sequence cannot call a
wrapper that does discovery and scp from the host.

All the placing and all the verifying therefore live in
`guest-apply-config.sh`, which is env-driven and self-contained. The sequence
stages a fixture into the staging directory and `sshExec`s it; the host wrapper
is for operators. §3 is that contract, and evidence group D exercises it — the
applier runs there over plain SSH with no wrapper in sight.

### 2.3 "Stock" means the pin's blob, not whatever was there first

The backup is materialized with `git show <pin>:<path>` and checked against
`git rev-parse <pin>:<path>`, so the file written is provably the pin's blob.

The obvious alternative — copy the working file aside on first apply — has an
ordering trap: run it once on a guest where a config was already replaced and
the "stock backup" is a composed config, permanently. Deriving from the pin has
no such state. It also means **`restore-stock` works on a guest where `apply`
never ran**, which is not what issue #20's wording assumes but is strictly
better, and is how a `--restore-stock` used as a panic button will actually be
reached for.

The backup is keyed `stock-backup/<pin-sha>/`, so moving the pin invalidates it
with no manual step — the same idiom as #10's `.kennel-built-<sha>` stamp.

A clone whose `HEAD` has drifted off the pin is a **warning, not a failure**:
the backup is correct regardless, and the warning says what `restore-stock`
will actually restore.

### 2.4 Only the two YAMLs are placed; the whole folder is staged

`commands.txt` and `run.json` are read by the operator, by #24 and by
[#27](https://github.com/alius-git/kennel/issues/27) — never by the stack. They
are copied to the guest with the rest of the folder and left in staging, because
a staged run that has lost its provenance is not the artifact #19 exported. Only
the two YAMLs are placed into `ws/src`.

## 3. The staging directory — the contract #24 reuses

Fixed, in the guest's home:

```
~/kennel-staging/
├── guest-apply-config.sh        # the applier (refreshed by every host-side run)
├── runs/<run-name>/             # run folders exactly as exported, four files, unmodified
├── stock-backup/<pin-sha>/      # the two YAMLs at the pin, from git
└── current-run                  # one line: the run currently applied; absent = stock
```

A sequence that wants to apply a checked-in fixture does not need the host
wrapper. It needs the applier on the guest and three environment variables:

```bash
KENNEL_MODE=apply \
KENNEL_RUN=run-20260806T170901Z \
KENNEL_PIN=dcf53c596339afd45b82f12c54b1e93e8273c2f4 \
  ~/kennel-staging/guest-apply-config.sh
```

`current-run` exists so that a failing sequence step can say *which* run was live
without recomputing anything; `status` prints it.

## 4. Running it

From the repository root. **The mode is mandatory** — there is no default:

```bash
stack/transfer/kennel-transfer.sh apply <run-folder> [--allow-pin-mismatch]
stack/transfer/kennel-transfer.sh restore-stock
stack/transfer/kennel-transfer.sh status
```

(Repeated from §1 on purpose: [#22](https://github.com/alius-git/kennel/issues/22)
ran the demo from this section and lost an attempt to `kennel-transfer.sh
<run-folder>`, because the section titled "Running it" opened on the knobs.)

### 4.1 Knobs

Environment variables, matching the idiom of #10 and
[`vm/test/verify-meshcat-host.sh`](../vm/test/verify-meshcat-host.sh):

| Variable | Default | Use |
|----------|---------|-----|
| `KENNEL_GUEST_IP` | *(discovered)* | Skip the libvirt lease lookup |
| `KENNEL_GUEST_HOSTNAME` | `kennel-vm` | The name in the DHCP lease |
| `KENNEL_LIBVIRT_NET` | `default` | Which libvirt network to search |
| `KENNEL_GUEST_USER` | `yuuser24` | SSH user |
| `KENNEL_SSH_KEY` | `~/git/yuruna/test/status/ssh/yuruna_ed25519` | Yuruna's key |
| `KENNEL_STAGING` | `kennel-staging` | Staging dir, relative to the guest's `$HOME` |
| `KENNEL_CONTAINER` | `dfki_quad` | Container to verify inside |
| `KENNEL_CLONE` | `~/dfki-quad` | *(applier only)* the clone to derive stock from |

`--allow-pin-mismatch` is a flag rather than a variable because it waives a
correctness check and should be visible in the shell history that did it.

### 4.2 Exit codes

Distinct per failure mode, because each has a different fix. `0/1/2` deliberately
carry the same meanings as [`stack/verify.md`](verify.md)'s recipe, so #24 can
wire both steps the same way.

| Code | Meaning |
|------|---------|
| 0 | Success; every checksum matched |
| 1 | **Verification failed** — the bytes on the config path are not the bytes asked for |
| 2 | Infrastructure error — bad arguments, unreadable run folder, no clone, no container |
| 3 | Pin mismatch (waivable with `--allow-pin-mismatch`) |
| 4 | Guest unreachable over SSH *(host wrapper only)* |
| 5 | Guest IP could not be discovered *(host wrapper only)* |

### 4.3 The one thing the script will not do for you

The stack reads these YAMLs **at launch**. Applying to a running stack changes
nothing until it is relaunched (`relaunch` latency, every row of
[`stack/mapping.md`](mapping.md) §1). The script says so on every successful
apply rather than leaving it to be discovered.

## 5. What "verified" means here

Issue #20 asks for a checksum match inside the container. The script asserts a
chain, because a single comparison cannot distinguish "the copy worked" from
"both ends are equally wrong":

| # | Compared | Catches |
|---|----------|---------|
| 1 | sha256 on the **host**, taken before the copy | a corrupted or truncated scp |
| 2 | the **staged** copy on the guest | — the reference for everything below |
| 3 | the file on the **guest filesystem** | a failed or partial write |
| 4 | `docker exec sha256sum` on the **container's source path** | the bind mount not carrying the bytes |
| 5 | `docker exec sha256sum` on **the path the launch resolves** | a stale or broken install space |
| 6 | `readlink -f` of that path == the container's source path | see below |

Row 6 is the one that is not a checksum, and it is not decoration. The launch
files resolve their config through `get_package_share_directory()`:

```python
pkg_simulator = get_package_share_directory("simulator")
sim_config_path = os.path.join(pkg_simulator, "config", config_file)
```

which lands on `install/simulator/share/simulator/config/simulator_params_go2.yaml`.
Under `--symlink-install` that is a **symlink to the source file**, which is the
entire reason no rebuild is needed. If something de-links it — a stray
`docker cp`, a `cp --remove-destination`, a colcon invocation without the flag —
every checksum in rows 1-5 still agrees on the day it happens, and the *next*
apply is silently ignored. Only row 6 sees it. Evidence group E provokes exactly
that and confirms the assert bites.

**A detail worth knowing before editing this.** In the install space, `config/`
is a real directory holding **per-file** symlinks, not a symlinked directory:

```
install/simulator/share/simulator/config/
  simulator_params_go2.yaml -> /root/ros2_ws/src/simulator/config/simulator_params_go2.yaml
  ...
```

Replacing an existing config file therefore needs no rebuild, which is what this
issue needs. **Adding a new file** to `src/.../config/` would not appear in the
install space without one. Nothing in the MVP does that; anything that starts to
will not get the free ride.

## 6. Validation — evidence

All of it on `kennel-vm` (8 vCPU / 16 GiB), container `dfki_quad`, 2026-08-06.
The run folders are real console exports, produced by driving the #19 console
headlessly and unpacking the archive — not hand-assembled:

| Run folder | Composition | `simulator_params` | `mit_controller_sim` |
|---|---|---|---|
| `run-20260806T170428Z` | OSQP + **Obstacle terrain** | `d02c62cb` | `3c69d87f` |
| `run-20260806T170901Z` | OSQP + flat plane (stock map) | `f2674ff5` | `3c69d87f` |
| *(stock at the pin)* | — | `eb31c744` | `40683000` |

The controller YAML is byte-identical across two separate export sessions
(`3c69d87f` both times), which is #18's determinism holding across the whole
console→disk→guest path rather than only inside one browser session.

### 6.1 The round trip — [`evidence/01-round-trip.txt`](transfer/evidence/01-round-trip.txt)

`status` → `apply` → `status` → re-`apply` → `apply` the other run →
`restore-stock`. Every apply reports the five-row table with `OK` on both files.
Two results are worth pulling out:

- **Re-applying an already-applied run takes ~1.8 s** and re-verifies rather
  than re-copying — the idempotency #10 established as the house style.
- **After `restore-stock`, `git status` in the guest clone reports no modified
  file at all.** That is a stronger statement than a checksum match against a
  backup: the working tree is byte-identical to the pin, as `git` itself sees it.

### 6.2 The launch reads what was placed — [`evidence/03-launch-readback.txt`](transfer/evidence/03-launch-readback.txt)

The checksums prove the bytes arrived. They do not prove ROS reads them. So the
stack was launched on the transferred files and the **running** controller was
asked what it is using:

```console
$ sudo docker exec dfki_quad /root/k14-stack-up.sh     # NOTE: no EXTRA_ARGS
[k14-up] shell 3: controller
[k14-up] stack is up
$ ~/kennel-verify.sh --expect-solver PARTIAL_CONDENSING_OSQP
[PASS] 10 composed-config -- ros2 param get /mit_controller_node mpc_solver:
       measured PARTIAL_CONDENSING_OSQP, launch log agrees with the running value
       ([mitcontrollernode-1] Set osqp linear system solver to qdldl)
...
pass=10 fail=0
VERDICT: PASS -- healthy and walking
```

**The control that makes this mean anything is the empty `EXTRA_ARGS`.**
[`stack/verify/evidence/02-composed-osqp.txt`](verify/evidence/02-composed-osqp.txt)
reached the same read-back by passing `mpc_solver:=PARTIAL_CONDENSING_OSQP` on
the command line. Here there is no launch argument: the only path from the
console to the running node is the YAML this transfer placed. **And no `colcon
build` was run at any point** — the `--symlink-install` claim of issue #20,
demonstrated rather than asserted.

Then the other half of the acceptance criterion, dynamically:

```console
$ stack/transfer/kennel-transfer.sh restore-stock
$ ~/kennel-verify.sh --expect-solver PARTIAL_CONDENSING_HPIPM
[PASS] 10 composed-config -- measured PARTIAL_CONDENSING_HPIPM
       ([mitcontrollernode-1] Set hpipm mode to SPEED)
pass=10 fail=0
VERDICT: PASS -- healthy and walking
```

The baseline is not merely back on disk; it is back in the running stack.

### 6.3 Finding: the **Obstacle terrain** map does not walk

Recorded because whoever picks
[#21](https://github.com/alius-git/kennel/issues/21)'s composition needs it, and
because it would otherwise look like a transfer defect.

Applying `run-20260806T170428Z` (OSQP **+ terrain**) and launching gives
`[PASS] 10 composed-config` — the transfer worked — but the walking criterion
fails, and fails differently on repeat:

| Run | check 8 walking | check 9 no-fall |
|---|---|---|
| first | `vx_mean=0.003 m/s, dx=0.038 m` — trots in place | PASS, max tilt 0.126 rad |
| second | `vx_mean=-0.129 m/s, dx=-1.935 m` — driven backwards | **FAIL**, max tilt 3.075 rad, 15 % of samples past 0.5 rad |

**It is the map, not the solver, and not the transfer.** The isolating run is
§6.2's: OSQP with the map left at stock walks cleanly, `pass=10 fail=0`. The
only difference is `world_urdf`. It also matches
[`stack/verify/evidence/02-composed-osqp.txt`](verify/evidence/02-composed-osqp.txt),
where OSQP on the stock flat plane walked at `dx=4.037 m`.

Consequences:

- **#21 should not compose Obstacle terrain.** Its own suggestion — OSQP plus
  `simulator_realtime_rate: 0.5` — is unaffected and is the right choice.
- The stock trot controller does not negotiate the 0.12 m stairs / 15° ramps that
  [`stack/mapping.md`](mapping.md) §1.1 describes, and the outcome is not stable
  run to run. Whether that is a controller limitation or a composer offering a
  map the MVP cannot use is worth a line on
  [#28](https://github.com/alius-git/kennel/issues/28); it is not a bypass.
- The transfer is orthogonal to all of it, which is exactly what evidence group C
  is kept to show.

### 6.4 The failure paths — [`evidence/02-failure-paths.txt`](transfer/evidence/02-failure-paths.txt)

A transfer that cannot fail is not a verified transfer. Each case is provoked
deliberately:

| Case | Provoked by | Exit |
|---|---|---|
| A | `run.json` carrying a different pin | 3 |
| B | A run folder missing one YAML | 2 |
| C | The `.zip` handed over instead of an unpacked folder | 2 |
| D | A false host checksum given to the applier | 1 |
| E | The install symlink replaced by a regular file of **identical content** | 1 |

D doubles as the #24 reuse demonstration: the applier runs there over plain SSH,
environment variables only, no host wrapper.

E is the one that justifies row 6 of §5. All four checksums still matched — the
copy was made from the same file — and the transfer was still rejected, on the
resolve check alone.

## 7. Limits

- **Two files, by name.** The composer owns exactly the seven fields of
  [`kennel_console/export.md`](../kennel_console/export.md) §3, which live in
  these two YAMLs. A run folder that grows a third config needs a line here; the
  script will refuse a folder that is missing one of the two rather than guess.
- **No rollback on a failed apply.** If verification fails the guest is left as
  it is, deliberately: the table says which hop disagreed, and rolling back would
  destroy the evidence. `restore-stock` is one command away and always works.
- **Nothing is locked.** Applying while the stack is running is allowed and does
  nothing until relaunch (§4.3). Two operators applying at once will interleave;
  the MVP has one operator.
- **The wrapper assumes libvirt.** Guest discovery is the lease lookup #11
  established. `KENNEL_GUEST_IP` bypasses it for any other host; the applier
  itself knows nothing about libvirt.
- **Wall-clock numbers are the development host's**, which loses ~10 %
  ([`vm/provisioning.md`](../vm/provisioning.md) §6a). The ~1.8 s re-apply is
  quoted as "seconds, not minutes", not as a benchmark.

## 8. Notes for whoever touches this next

- **`set -u` is safe in both of these scripts**, unlike in
  [`stack/verify/kennel-verify.sh`](verify/kennel-verify.sh): neither sources a
  ROS setup file, so neither trips the unbound-variable abort
  [`stack/launch.md`](launch.md) §7 documents. Do not "fix" that inconsistency in
  the other direction.
- **`docker inspect` needs `--type container`.** The image is also called
  `dfki_quad`, so a bare inspect resolves to it and exits 0 with an empty status —
  #10's defect 2, and it would bite here identically.
- **The applier is re-copied to the guest on every run**, so a guest can never be
  running a stale copy. It is a few kilobytes; correctness beats the round trip.
- **The host wrapper reads `stack/pin.lock` directly** rather than carrying a
  derived copy of the SHA. It can, because unlike the provisioning script it runs
  from a checkout of this repo — so #12's three-place reconciliation does not
  grow a fourth place.
- **The run folders in §6 were exported by driving the console headlessly.** A
  naive single-shot click on *generate run* is flaky: the composer re-renders at
  10 Hz from the mock DataSource (export.md §2.4), so a node can be replaced
  between the query and the click. Retry the click. `verify-export.py` does not
  hit this because its earlier steps leave the page settled.

## 9. What this feeds

| Issue | What it takes from here |
|---|---|
| [#21](https://github.com/alius-git/kennel/issues/21) | The transfer half of the PoC, already demonstrated end to end in §6.2 — plus the §6.3 warning about which map to compose |
| [#24](https://github.com/alius-git/kennel/issues/24) | The staging contract (§3) and the applier, `sshExec`-able with three environment variables; the `0/1/2` exit contract already matches `stack/verify.md`'s |
| [#27](https://github.com/alius-git/kennel/issues/27) | The three commands of §1, and §4.3's "relaunch or nothing happens" |

---

Last review: 2026-08-06
