# kennel-vm guest sizing and definition

Sizing record for [issue #9](https://github.com/alius-git/kennel/issues/9) — a
guest VM definition big enough to build and run dfki-quad (Docker image build +
`colcon build` of MPC/WBC/acados + Drake sim) without thrash, and the recorded
rationale for the numbers.

Builds directly on [`vm/host-baseline.md`](host-baseline.md)
([#8](https://github.com/alius-git/kennel/issues/8)), which is the floor this
document sizes up from. **Read §2 of that document first** — the three Yuruna
patches it carries are a hard prerequisite for anything here.

> **Status: the guest is defined and the sizing is proven to reach the domain**
> (§4.1) — 8 vCPU and 16 GiB are confirmed on the running VM by `virsh dominfo`.
>
> **Boot-to-SSH validation is blocked** (§4.2) by an environment regression that
> appeared on 2026-08-05, *after* #8's green run: subiquity aborts at its final
> postinstall step. **The unmodified stock Yuruna sequence fails identically**,
> so this is not attributable to anything in this document — but it does mean
> the #8 baseline is currently not reproducible on this host, and #10 is blocked
> behind it too.
>
> The *measurement* half of #9 — image size, build peak RAM, workspace disk —
> was always going to be taken during
> [#10](https://github.com/alius-git/kennel/issues/10). §5 carries the
> measurement protocol and an empty results table for #10 to fill in. #9 closes
> when the blocker clears, the guest boots green, that table is populated, and
> #10's provisioning completes without OOM or disk exhaustion.

## 1. The decision

| Resource | #9 hypothesis | **Decided** | Where it is set |
|----------|---------------|-------------|-----------------|
| vCPU | ≥ 4 | **8** | `variables.cores` (explicit) |
| RAM | ≥ 12 GB | **16 GiB** | `variables.memoryStartupBytes: 16GB` |
| Disk | ≥ 50 GB | **64 GB** | stock — hardcoded in `New-VM.ps1`, not settable |

All three clear the hypothesis. Rationale per resource:

### vCPU — 8

The host is an AMD Ryzen 7 8845HS, 8 cores / 16 threads. Yuruna's default
formula (`New-VM.ps1:380`) is
`min(hostCores - 1, max(2, floor(hostCores / 2)))`, which on 16 threads already
yields 8 — so this is **not** a change in value on this host, it is a change in
*guarantee*. Declaring `cores: 8` explicitly means the kennel guest gets 8 vCPU
on any host with ≥ 8 threads instead of silently shrinking with the host, which
matters because `colcon build` wall-clock is close to linear in core count for
this stack and #10 records timings that later issues compare against.

Leaving 8 of 16 threads to the host is deliberate: the harness runs OCR polling
and VM management concurrently with the build, and the #8 baseline notes that a
descheduled installer presents as a frozen console rather than as contention.

Above the ≥ 4 hypothesis. 4 vCPU would work but roughly doubles the colcon
wall-clock, and build time is the MVP's dominant cost.

### RAM — 16 GiB

Host has 28.2 GiB total (`28889 MiB`) and idles at ~6 GiB with no guest running,
so 16 GiB for the guest leaves ~6.4 GiB of headroom plus reclaimable cache. That
is the real constraint — 16 GiB is the largest round size this host can give the
guest while staying safely non-swapping.

Why not the 12 GB hypothesis: the peak is 8 parallel C++ compile jobs (8 vCPU →
colcon's default `--parallel-workers` = core count). acados and the MPC/WBC
translation units are template-heavy; at a conservative 1.5–2 GB per concurrent
job the peak lands at 12–16 GB *before* the Drake sim and the container
runtime. 12 GB is the floor of that range, not headroom above it.

If #10 still hits OOM, **the first lever is capping `colcon build
--parallel-workers`, not raising RAM** — the host cannot give the guest more
than ~20 GiB without swapping, so trading a slower build for a completing build
is the only move available.

### Disk — 64 GB (stock, and not adjustable)

`New-VM.ps1:317` hardcodes the guest disk:

```powershell
& qemu-img create -f qcow2 $diskImg 64G
```

There is **no** cascade variable for disk — unlike RAM and vCPU, it is not a
`New-VM.ps1` parameter at all. 64 GB clears the ≥ 50 GB target, so the MVP needs
no patch here. The qcow2 is sparse, so this costs the host only what the guest
actually writes (7.8 GB after the #8 baseline's install + VS Code).

Budget against the 64 GB: the #8 baseline consumed ~6.6 GiB for a stock install,
leaving ~53 GiB for the Docker image plus the colcon workspace. §5 is where #10
records whether that holds. See §6 for what to do if it does not.

## 2. How the size is set

At Yuruna `2026.08.04` **RAM and vCPU are per-sequence variables**, not host
config. They cascade from a sequence's `variables:` block into the per-guest
`New-VM.ps1`:

| Stage | File |
|-------|------|
| Sequence declares them | `variables.memoryStartupBytes` / `variables.cores` |
| Planner cascades them across the `resource:` chain | `test/modules/Test.SequencePlanner.psm1:243` (`Merge-SequenceVariableCascade`), consumed at `:668` (`Resolve-NamedSequenceChain`) and `:273` (`Add-CyclePlanEntriesForTopLevel`) |
| Runner forwards them to New-VM | `test/Invoke-TestSequence.ps1:635-642` |
| New-VM converts and applies | `New-VM.ps1:398-399` (bytes → MB, default 8192), `:380` (vCPU default + clamp), `:411-412` (`virt-install --memory` / `--vcpus`) |

The cascade walks **top-of-chain → prereqs, first non-empty value wins**. The
kennel guest therefore declares its size in exactly one place — the *start*
sequence, which is the one that creates the VM — and every workload chaining to
it inherits the size without restating it. #10's provisioning sequence gets the
right guest for free by declaring
`resource: {ubuntu.server.24: [start.guest.ubuntu.server.24.kennel.ssh]}`.

### Three things that will bite

1. **The size is applied at VM *creation* only.** `Invoke-TestSequence.ps1:582`
   reuses an existing VM of the same name as-is — an already-provisioned guest
   keeps its old shape and the new `variables:` are silently ignored. Destroy the
   VM before a re-size (§3).
2. **The VM name is derived from the guest key, not from Kennel.**
   `Get-TestVMName` (`test/modules/Test.HostDetection.psm1:254-287`) builds
   `test-<guestKey>-01`, so the libvirt domain is
   `test-guest.ubuntu.server.24-01` — *not* `kennel-vm`. This is deliberate:
   keeping the stock name is what lets `Remove-TestVMFiles.ps1 -Prefix test-`,
   the cycle-start sweep, and `Stop-ConcurrentVM` keep working. **`kennel-vm` is
   the guest's hostname** (`variables.hostname`), which is what the SSH-visible
   asserts and every in-guest path actually see.
3. **`virsh dominfo` reports `Max memory` in KiB.** 16 GiB reads as
   `16777216 KiB`. In-guest `MemTotal` is lower (~15.9 GiB) because firmware and
   kernel reserve claim pages before `/proc/meminfo` exists — the assert in the
   workload sequence uses a 15000 MiB floor for exactly this reason.

## 3. Reproducing this

### 3.1 Prerequisites

Everything in [`vm/host-baseline.md` §2–§3](host-baseline.md), specifically:

```bash
cd ~/git/yuruna && git checkout 2026.08.04
git apply /path/to/kennel/vm/patches/yuruna-save-ocrsidecar-export.patch
git apply /path/to/kennel/vm/patches/yuruna-ssh-autoinstall-confirm.patch
git apply /path/to/kennel/vm/patches/yuruna-no-password-expiry.patch
```

The host clock was stepped before these runs — and **it did not stay fixed**.
See §4.3: `makestep` corrects the offset for roughly twenty minutes, then the
~10 % frequency error pulls it back to the same ~272 s. Do not treat
`sudo chronyc makestep` as having cleared the #8 blocker; it has not.

### 3.2 Install the kennel sequences

The two sequence files live in this repo at [`vm/test/`](test/) and must be
copied into the Yuruna clone, the same way `vm/patches/` is applied there:

```bash
cp /path/to/kennel/vm/test/*.kennel.ssh.yml ~/git/yuruna/test/sequences/
```

`vm/test/` is named `test/` on purpose. Yuruna resolves project sequences by
scanning `<RepoRoot>/project/**/test/` before the framework's own
`test/sequences/` (`Test.SequenceResolve.psm1:162-206`, "project tree wins"), so
when [#23](https://github.com/alius-git/kennel/issues/23) points the harness's
`projectUrl` at the kennel repo these files are discovered where they already
sit, with no move and no copy step. Until then, the copy above is the bypass.

### 3.3 Clear the gate and run

```bash
virsh list --all > /dev/null                     # wake socket-activated libvirtd
cd ~/git/yuruna && pwsh test/Test-Config.ps1 -SkipSend
```

Expect **34 PASS / 4 WARN / 0 FAIL**. The kennel sequences add no findings —
`Test-Config.ps1` schema-validates every discoverable sequence, so this is also
the syntax check for them.

Destroy any existing guest first, or the size will not apply (§2):

```bash
pwsh test/Remove-TestVMFiles.ps1 -Prefix test- -Confirm:$false
```

Then one command walks the whole chain:

```bash
pwsh test/Invoke-TestSequence.ps1 -SequenceName workload.guest.ubuntu.server.24.kennel.ssh
```

To confirm the cascade *before* spending the boot time, resolve the plan
without running it:

```console
$ pwsh -NoProfile -Command '
    Import-Module ./test/modules/Test.SequenceResolve.psm1 -Force
    Import-Module ./test/modules/Test.SequencePlanner.psm1 -Force
    Resolve-NamedSequenceChain -SequenceName workload.guest.ubuntu.server.24.kennel.ssh `
      -SequencesDir ./test/sequences -RepoRoot . -HostType host.ubuntu.kvm |
      Select-Object effectiveHostname, effectiveMemoryStartupBytes, effectiveCores'

effectiveHostname effectiveMemoryStartupBytes effectiveCores
----------------- --------------------------- --------------
kennel-vm         16GB                        8
```

## 4. Validation — evidence

### 4.1 The sizing reaches the guest — confirmed

Proven at all four stages of the cascade described in §2.

**a. The planner resolves the chain and the values** (no VM needed — run this
before spending boot time):

```console
$ pwsh -NoProfile -Command '... Resolve-NamedSequenceChain ...'
guestKey    : guest.ubuntu.server.24
fullChain   : start.guest.ubuntu.server.24.kennel.ssh -> workload.guest.ubuntu.server.24.kennel.ssh
username    : yuuser24
hostname    : kennel-vm
memory      : 16GB
cores       : 8
```

**b. The runner forwards them to `New-VM.ps1`** (`-logLevel Verbose`):

```
VERBOSE: Forwarding -Username 'yuuser24' from ....variables.username.
VERBOSE: Forwarding -Hostname 'kennel-vm' from ....variables.hostname.
VERBOSE: Forwarding -MemoryStartupBytes '16GB' from ....variables.memoryStartupBytes.
VERBOSE: Forwarding -Cores '8' from ....variables.cores.
```

**c. libvirt applies them to the domain** — the decisive check:

```console
$ virsh dominfo test-guest.ubuntu.server.24-01
Name:           test-guest.ubuntu.server.24-01
State:          running
CPU(s):         8
Max memory:     16777216 KiB      # = 16 GiB  (stock default is 8388608 KiB)
Used memory:    16777216 KiB
```

**d. The hostname reaches cloud-init** — `seed.src/user-data` line 25:

```yaml
    hostname: kennel-vm
```

Host headroom while the 16 GiB guest ran: `28889 MiB` total, `13975 MiB` still
available (qemu allocates lazily, so the guest only costs what it touches).
That is the margin the §1 RAM rationale claims, measured rather than assumed.

**To be unambiguous about what is *not* proven here:** the in-guest assertions
in `workload.guest.ubuntu.server.24.kennel.ssh` (`nproc`, `MemTotal`, rootfs
size, hostname) have **never executed** — the chain never reaches the workload
sequence, for the reason in §4.2. Evidence (a)–(d) is host-side and
cloud-init-side only. It shows the size was *configured and applied to the
domain*; it does not yet show the installed guest booting and reporting it.

### 4.2 Boot-to-SSH — BLOCKED by an upstream regression

Three full cycles were run. All three fail at the same place:

| # | Sequence | Result |
|---|----------|--------|
| 1 | `workload.guest.ubuntu.server.24.kennel.ssh` | FAIL step 6 `sshWaitReady` @ 1063 s |
| 2 | `workload.guest.ubuntu.server.24.kennel.ssh` (retry) | FAIL step 6 `sshWaitReady` @ 1267 s |
| 3 | **`workload.guest.ubuntu.server.24.ssh` (STOCK — control)** | **FAIL step 6 `sshWaitReady` @ 374 s** |

Run 3 is the important one. It is the unmodified stock Yuruna sequence — no
kennel sizing, no `kennel-vm` hostname, the exact sequence #8 certified green on
2026-08-04 — and it fails the same way. **The kennel changes are not the
cause**, and the #8 baseline is currently not reproducible on this host.

The proximate failure, identical in all three runs:

```
ERROR finish: subiquity/Install/install/postinstall/restore_apt_config: FAIL
  Running command ['unshare', '--fork', '--pid', '--mount-proc=/target/proc',
    '--', 'chroot', '/target', 'apt-get', 'update']    # -> non-zero
```

Subiquity then drops to `An error occurred. Press enter to start a shell`,
which is one of `sshWaitReady`'s `installerFailurePatterns`, so the step
fast-fails instead of burning its 2400 s. sshd never starts on the installed
system.

The install itself succeeds — partitioning, `openssh-server`, and
`unattended-upgrades` all complete. Only this last step fails.

**What was ruled out, with evidence:**

| Suspect | Verdict |
|---------|---------|
| The kennel sizing / hostname | **Ruled out** — stock fails identically (run 3) |
| Guest OOM at 16 GiB | Ruled out — no OOM; and 8 GiB stock fails too |
| Host disk exhaustion | Ruled out — 221 GiB free, no `dmesg` I/O errors |
| Yuruna caching proxy | Ruled out — the seed's proxy blocks are inert (`if [ -n "" ]`) |
| Network / archive unreachable | **Ruled out** — the *installer's own* `apt-get update` succeeded minutes earlier: `Get:2 http://archive.ubuntu.com/ubuntu noble-updates InRelease [126 kB]`, `Reading package lists...` |
| apt "Release file is not valid yet" (clock) | Ruled out — the `noble-*` Release files are ~6.7 h old, comfortably in the past even against this host's slow clock |

So archive.ubuntu.com is reachable from the guest, and it is specifically the
**in-chroot** `apt-get update` that fails, immediately after
`unattended-upgrades` has run.

**Leading hypothesis (not yet confirmed — flagged as such deliberately).** The
`unattended-upgrades` step immediately preceding the failure installs a fresh
batch that includes `systemd`, `systemd-resolved`, `openssl` and
`ca-certificates` (observed in the journal package list). `noble-updates` is
dated **2026-08-05 10:31 UTC** — *after* #8's green run at 2026-08-05 00:30 UTC.
The most likely mechanism is that upgrading `systemd-resolved` in the target
disturbs the resolver stub that curtin's bind-mounted `/run` exposes to the
chroot, so the next `apt-get update` cannot resolve. That would explain both the
timing (green yesterday, red today) and why only the in-chroot invocation fails.

Confirming it needs apt's stderr, which curtin runs with `capture=False`, so it
goes to the installer's VGA console and is not in any uploaded log. The serial
console cannot reach it either — the live installer boots
`BOOT_IMAGE=/casper/vmlinuz ---` with no `console=` argument, so `virsh console`
sees nothing. **Reading it requires a human at the VNC console** (press Enter for
the shell, then `chroot /target apt-get update`). That is the next diagnostic
step, and it needs an operator, not automation.

**Consequence:** this blocks #10 as hard as it blocks the rest of #9, and it
should be tracked as its own issue rather than buried here. Retirement paths, in
order of preference: pin/skip the `unattended-upgrades` postinstall step in the
autoinstall config, or wait for the upstream batch to settle and re-verify.

### 4.3 Host clock — fixed, then drifted back

`sudo chronyc makestep` corrected the 271.9 s offset #8 left open, verified at
`System time: 0.000810284 seconds slow`. **It did not hold.** Twenty-five
minutes later the harness reported `Host clock is 177.2s behind real time`, and
by the end of the session `chronyc tracking` was back to `272.003387451 seconds
slow` — the original offset.

The underlying `Frequency: 100027 ppm slow` (a ~10 % oscillator error, where
normal is < 100 ppm) is not something `makestep` can fix; chrony re-converges to
the same standing offset. **This host needs a real clock fix — not another
`makestep`** — before any unattended cycle. It is not the cause of §4.2 (see the
ruled-out table), but it remains the open operator action inherited from #8 and
it is exactly the condition Yuruna's own config gate refuses to be quiet about.

## 5. Measurement protocol for #10

The first work item of #9 — *"measure the build's actual footprint (image size,
build peak RAM, workspace disk) during #10"* — executes inside #10, because
there is nothing to measure until the dfki-quad build exists. This section is
the instrument; #10 fills the table.

Add these to the #10 provisioning sequence around the build steps.

### 5.1 Peak RAM

`colcon build` peaks are short and easy to miss with spot checks. Sample
continuously in the background and take the maximum:

```bash
# before the build
( while :; do awk '/MemAvailable/{print systime(), $2}' /proc/meminfo; sleep 5; done ) > /tmp/mem.log &
SAMPLER=$!

/usr/bin/time -v colcon build --symlink-install \
  --cmake-args -DCMAKE_EXPORT_COMPILE_COMMANDS=1 -DROBOT_NAME=go2 2>&1 | tee /tmp/colcon.log

kill $SAMPLER
# peak usage = MemTotal - min(MemAvailable)
awk -v tot="$(awk '/MemTotal/{print $2}' /proc/meminfo)" \
    'NR==1||$2<min{min=$2} END{printf "peak_used=%.1f GiB\n", (tot-min)/1048576}' /tmp/mem.log
grep 'Maximum resident set size' /tmp/colcon.log   # largest single compiler process
```

`MemAvailable` (not `MemFree`) is the right signal — it excludes reclaimable
page cache, which a build inflates without actually needing.

Also capture whether anything was killed, which is the failure this sizing
exists to prevent:

```bash
dmesg -T | grep -i 'out of memory\|oom-kill' || echo "no OOM kills"
```

### 5.2 Disk

```bash
df -h /                       # before build, after image build, after colcon
docker system df              # image + container + build-cache split
docker image ls               # the dfki-quad image specifically
du -sh ~/dfki-quad            # workspace: src + build + install + log
```

### 5.3 Wall clock

Yuruna already stamps per-step durations, so the step log is the source — no
extra instrumentation. Record the image build and the colcon build as separate
steps so they can be read off independently.

### 5.4 Results — to be filled by #10

| Measurement | Command | Result | Fits in the decided size? |
|-------------|---------|--------|---------------------------|
| Docker image size | `docker image ls` | _TBD_ | |
| Docker total (images + cache) | `docker system df` | _TBD_ | |
| Workspace size after colcon | `du -sh ~/dfki-quad` | _TBD_ | |
| **Total disk used** | `df -h /` | _TBD_ | of 64 GB |
| **Peak RAM during colcon** | `MemTotal - min(MemAvailable)` | _TBD_ | of 16 GiB |
| Largest single compiler RSS | `/usr/bin/time -v` | _TBD_ | |
| OOM kills | `dmesg -T \| grep -i oom` | _TBD_ | must be none |
| Image build wall clock | Yuruna step log | _TBD_ | |
| colcon build wall clock | Yuruna step log | _TBD_ | |

When this table is populated and #10's acceptance holds, #9's acceptance
criterion — *"kennel-vm boots at the documented size and completes the full
provisioning of #10 without OOM/disk exhaustion"* — is met and #9 closes. If the
numbers land outside the decided size, §6 is the response.

## 6. Contingencies

### If total disk exceeds ~55 GiB

64 GB is hardcoded, so this needs a fourth Yuruna patch parameterizing the disk
the way RAM and vCPU already are: a `-DiskSizeGb` parameter on `New-VM.ps1`
reading a cascaded `variables.diskSizeGb`, replacing the literal at
`New-VM.ps1:317`. That is a clean upstream feature rather than a workaround —
the sizing cascade already exists for the other two resources and disk is the
obvious gap — so it should be filed on
[#28](https://github.com/alius-git/kennel/issues/28) alongside the other
upstream gaps, and carried in `vm/patches/` in the meantime.

Cheaper first: `docker builder prune` between the image build and colcon, and
`--no-cache` discipline. The build cache is usually the largest disposable term.

### If the build OOMs

In order:

1. Cap parallelism: `colcon build --parallel-workers 4` (and `MAKEFLAGS=-j2` for
   nested make). Costs wall-clock, not correctness.
2. Add guest swap. A build that swaps completes; one that OOMs does not.
3. Only then revisit RAM — and note the host ceiling is ~20 GiB, so there is
   roughly one 4 GiB step available before the host itself starts swapping.

### If the host changes

The numbers here are tied to a 16-thread / 28 GiB host. On a smaller host,
`cores: 8` is clamped down automatically (`New-VM.ps1:388-391`) but
`memoryStartupBytes: 16GB` is **not** clamped — `virt-install` will accept an
over-ask and the guest will thrash. Re-derive both from the new host before
running.

## 7. Notes for the record

- **`Get-Image.ps1` is still a separate manual prerequisite.**
  `Invoke-TestSequence.ps1` does no image fetch (`host-baseline.md` §6.7).
- **The "Forwarding …" verbose line names the wrong file.**
  `Invoke-TestSequence.ps1:636` interpolates the *top-level* sequence name into
  the message regardless of which chain member actually supplied the value, so a
  size cascaded from the start sequence is reported as coming from the workload
  sequence's `variables`. Cosmetic, but it sends an operator editing the size to
  a file that does not declare it. Minor addition for
  [#28](https://github.com/alius-git/kennel/issues/28).
- **`vmStart.testVmNamePrefix`** in `test.config.yml` changes the VM-name prefix;
  if it is ever changed, `Remove-TestVMFiles.ps1 -Prefix` must follow.

---

Last review: 2026-08-05
