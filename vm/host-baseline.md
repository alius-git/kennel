# Yuruna `ubuntu.kvm` host baseline

Validation record for [issue #8](https://github.com/alius-git/kennel/issues/8) —
proving the **stock** Yuruna baseline on the development host before anything
Kennel-specific is added: the `ubuntu.kvm` host provisions the stock Ubuntu
Server 24.04 guest and the SSH channel works.

Nothing in this document is Kennel-specific. It is the floor that
[#9](https://github.com/alius-git/kennel/issues/9) (guest sizing),
[#10](https://github.com/alius-git/kennel/issues/10) (provisioning script) and
[#11](https://github.com/alius-git/kennel/issues/11) (Meshcat port exposure)
build on.

> **Result: green — but not on stock Yuruna.** A clean cycle boots the guest and
> runs the SSH workload 13/13 in 10 min 9 s (§5.3). Getting there required
> **three patches to Yuruna `2026.08.04`** ([`vm/patches/`](patches/)), because
> the stock `start.guest.ubuntu.server.24.ssh` sequence cannot provision this
> guest on any host. Read [§6](#6-deviations-from-the-issue-text) before relying
> on this. One patch is a real **bypass** with a cost, and the host clock is
> still broken and needs an operator with sudo (§2).

## 1. Validated configuration

| Item | Value |
|------|-------|
| Yuruna release | `2026.08.04` (tag), commit `f0d4d3b` |
| Framework clone | `~/git/yuruna` |
| Yuruna workdir (images + VM disks) | `~/yuruna` |
| Host OS | Ubuntu 24.04.4 LTS, kernel 7.0.0-28-generic, x86_64 |
| CPU / RAM | AMD Ryzen 7 8845HS — 8 cores / 16 threads, 28 GiB RAM |
| Free disk | ~230 GiB on `/` |
| Hypervisor | libvirt 10.0.0 + QEMU 8.2.2 (`qemu:///system`) |
| PowerShell | 7.6.4 |
| Guest | stock `guest.ubuntu.server.24` — Ubuntu 24.04.4 live-server amd64 |
| Guest defaults | 8 GiB RAM, 64 G qcow2, vCPU `min(threads-1, max(2, threads/2))`, libvirt `default` NAT |
| Guest user | `yuuser24` (vault-managed password) |
| Comms | SSH, via the `.ssh.yml` sequence variants (see §4) |

## 2. Host prerequisites

The host was already provisioned from a previous Yuruna session, so the
one-line installer was **not** re-run. For a clean host, run it first:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
```

It installs `qemu-kvm`, `libvirt-daemon-system`, `virtinst`, `swtpm`, `ovmf`,
`genisoimage`, `whois`, `git`, `pwsh`, `tesseract-ocr`; clones the framework to
`~/git/yuruna`; enables `libvirtd` + `virtlogd`; sets the libvirt `default`
network to autostart; and adds `$USER` to the `libvirt` and `kvm` groups.

State verified on this host before the run:

```bash
groups                      # must contain: libvirt kvm   (log out/in after install)
egrep -c '(vmx|svm)' /proc/cpuinfo   # non-zero
virsh net-list --all        # default | active | yes
df -h ~                     # >= ~80 GiB free (3.0 G ISO + 64 G sparse qcow2)
```

### Unattended-run prep

```bash
pwsh ~/git/yuruna/host/ubuntu.kvm/Enable-TestAutomation.ps1
```

Disables display sleep / screen lock so an unattended cycle is not interrupted.
It changes host power settings; reverse with the sibling
`Disable-TestAutomation.ps1`.

### Host clock — operator action required

`Test-Config.ps1` flags host clock skew, and this host is affected:

```
[WARN] Host clock is 270.6s behind real time (limit 120s).
```

`chronyc tracking` confirms it is real, not a probe artifact:

```
System time     : 270.574218750 seconds slow of NTP time
Frequency       : 100027.312 ppm slow
```

`timedatectl` still reports *"System clock synchronized: yes"*, so the defect is
invisible unless you look at `chronyc`. chrony is slewing rather than stepping,
and the standing offset is not closing. Guests inherit the host clock at
power-on and get stepped to real time mid-boot.

Fix before an unattended cycle (needs sudo, so it is an operator step, not an
automated one):

```bash
sudo chronyc makestep
chronyc tracking          # 'System time' should be < 1s
```

This was left **unresolved** for this validation — it is advisory, not a gate,
and the stock Ubuntu guest booted green regardless. It is recorded in §6 as a
deviation because a Kubernetes-bearing guest is the documented failure case, and
the Kennel guest grows toward that.

## 3. Framework and configuration setup

```bash
cd ~/git/yuruna
git fetch --tags
git checkout 2026.08.04                       # release validated here

cp test/test.config.yml test/test.config.yml.bak-2026-06   # keep the old one
cp test/test.config.yml.template test/test.config.yml
```

Then edit `test/test.config.yml` and scope `guestSequence` to the single guest
under validation:

```yaml
guestSequence:
- guest.ubuntu.server.24
```

That is the **only** edit to the template. In particular there is no
`keystrokeMechanism` key to set — see §4.

`Test-Config.ps1` may warn that the project repo is behind upstream. Pulling it
by hand is pointless: `Invoke-TestSequence.ps1` deletes and re-clones
`<RepoRoot>/project` at the start of every run (§6.7).

### Applying the three upstream patches

The stock SSH path cannot provision this guest — see §6.0. Before the first
run, apply the patches from [`vm/patches/`](patches/) to the framework clone:

```bash
cd ~/git/yuruna
git apply /path/to/kennel/vm/patches/yuruna-save-ocrsidecar-export.patch
git apply /path/to/kennel/vm/patches/yuruna-ssh-autoinstall-confirm.patch
git apply /path/to/kennel/vm/patches/yuruna-no-password-expiry.patch
```

### Clearing the config gate

```bash
virsh list --all > /dev/null        # wake socket-activated libvirtd first (§6.2)
pwsh test/Test-Config.ps1 -SkipSend
```

Use `-SkipSend` so the validator does not fire a live notification. Two gates
had to be cleared on this host — both are written up in §6.

Final state: **34 PASS / 4 WARN / 0 FAIL**, exit code 0.

The 4 remaining warnings are all advisory and were accepted:

| Warning | Disposition |
|---------|-------------|
| Host clock 270.6 s behind | Operator action, see §2 |
| `status/extension/notification/transports.yml` missing | Accepted — see §6.3, seeding it makes things *worse* |
| `transports.resend` not configured | Same |
| Skipping live send (`-SkipSend`) | Intentional |

## 4. Communication mechanism — SSH

Issue #8 asks for `vmCommunication.keystrokeMechanism: SSH` in
`test/test.config.yml`. **That key does not exist at Yuruna 2026.08.04.** The
mechanism moved from a global config switch to a per-sequence declaration
between the release this host was last set up with (`2026.06.26`) and the
current one. See §6.1 for the full delta.

The equivalent today is to run the `.ssh.yml` sequence variant, which carries
`keystrokeMechanism: ssh` in its own front matter:

```
test/sequences/start.guest.ubuntu.server.24.ssh.yml
test/sequences/workload.guest.ubuntu.server.24.ssh.yml
```

SSH is keyed off a per-host key at `test/status/ssh/yuruna_ed25519`, generated
on demand and injected into the guest by cloud-init.

## 5. The clean cycle

### 5.1 Fetch the guest image

`Invoke-TestSequence.ps1` deliberately does **no** image download, so the ISO
must be fetched once up front:

```bash
cd ~/git/yuruna/host/ubuntu.kvm/guest.ubuntu.server.24
pwsh ./Get-Image.ps1
```

Resolves the current stable build from `https://releases.ubuntu.com/noble` and
downloads it to `~/yuruna/image/ubuntu.env/`.

### 5.2 Run the sequence chain

```bash
cd ~/git/yuruna
pwsh test/Invoke-TestSequence.ps1 -SequenceName workload.guest.ubuntu.server.24.ssh
```

`Invoke-TestSequence.ps1` walks the `resource:` chain, so this one command runs
both sequences in dependency order — a start-from-nothing clean cycle:

| # | Sequence | Steps |
|---|----------|-------|
| 1 | `start.guest.ubuntu.server.24.ssh` | blind `Enter` ×2 to dismiss GRUB → **`waitForAndEnter` "Continue with autoinstall?" (added, §6.4b)** → `sshWaitReady` (2400 s, fast-fails on subiquity crash patterns) → `sshExec whoami && hostname` → `ubuntu.server.24.update.sh` → `sudo reboot now` |
| 2 | `workload.guest.ubuntu.server.24.ssh` | `sshWaitReady` (300 s) → `sshExec whoami && hostname` → `ubuntu.server.24.code.sh` (VS Code) → `dpkg -l \| grep code` |

The `sshWaitReady` + `sshExec whoami` pair that issue #8 names as the acceptance
criterion appears in **both** sequences.

### 5.3 Result — green

**This cycle is green only with the three patches in §6.4 applied.** It is not a
stock-Yuruna result; see §6 before treating it as one.

```
RUN_START=2026-08-04T21:30:12-03:00
RUN_END  =2026-08-04T21:40:21-03:00
EXIT=0
```

```
--- start.guest.ubuntu.server.24.ssh: local steps 1-9 of 9 (global 1-9) ---
     5 s [1/9] PASS waitForSeconds:     Let the GRUB boot menu render
     0 s [2/9] PASS pressKey:           Blind-dismiss the GRUB boot menu (first attempt)
     8 s [3/9] PASS waitForSeconds:     Pause before retry
     0 s [4/9] PASS pressKey:           Blind-dismiss the GRUB boot menu (retry)
    27 s [5/9] PASS waitForAndEnter:    OCR: Continue with autoinstall?
   354 s [6/9] PASS sshWaitReady:       Wait for SSH after autoinstall
     0 s [7/9] PASS sshExec:            Smoke test: whoami/hostname
    61 s [8/9] PASS sshFetchAndExecute: ubuntu.server.24.update.sh
     0 s [9/9] PASS sshExec:            Reboot the VM
--- workload.guest.ubuntu.server.24.ssh: local steps 1-4 of 4 (global 10-13) ---
    11 s [1/4] PASS sshWaitReady:       Wait for sshd after reboot
     0 s [2/4] PASS sshExec:            Smoke test: whoami/hostname
   129 s [3/4] PASS sshFetchAndExecute: ubuntu.server.24.code.sh
     0 s [4/4] PASS sshExec:            Show installed VS Code package

Chain completed successfully (13 step(s) across 2 sequence(s)).
```

Wall clock, from `virt-install` to VS Code verified: **10 min 9 s**. Useful
component timings for sizing work in #9:

| Phase | Time |
|-------|------|
| GRUB → autoinstall confirmed | ~40 s |
| subiquity install → sshd reachable | 354 s (~6 min) |
| `apt` update script | 61 s |
| reboot → sshd reachable again | 11 s |
| VS Code install | 129 s |

### 5.4 Independent confirmation from the host

Queried over SSH after the cycle, from the host, using the harness key:

```console
$ ssh -i ~/git/yuruna/test/status/ssh/yuruna_ed25519 yuuser24@192.168.122.34 ...
whoami:   yuuser24
hostname: test-guest.ubuntu.server.24-01
os:       Ubuntu 24.04.4 LTS
kernel:   6.8.0-137-generic
uptime:   up 2 minutes
code:     1                       # VS Code present (dpkg ii)
Last password change  : Aug 05, 2026
Password expires      : never     # confirms the §6.4c bypass took effect
```

The guest reaches the host's libvirt `default` NAT network at
`192.168.122.0/24`; its address is discoverable with
`virsh net-dhcp-leases default`. That is the path #11 will extend for Meshcat.



## 6. Deviations from the issue text

Recorded for [#27](https://github.com/alius-git/kennel/issues/27) (README
quickstart), [#26](https://github.com/alius-git/kennel/issues/26) (bypass log)
and [#28](https://github.com/alius-git/kennel/issues/28) (upstream gaps).

### 6.0 Headline

Issue #8 assumed the stock SSH path works and only needed proving on this
machine. **It does not work.** At Yuruna `2026.08.04`,
`start.guest.ubuntu.server.24.ssh.yml` cannot provision this guest — on *any*
host, not just this one: two of the three defects below are in shared,
host-independent files. The SSH variant appears never to have been exercised
for Ubuntu; it was written against assumptions that hold only for
`amazon.linux.2023`.

The baseline is therefore proven **with three local patches**, carried in
[`vm/patches/`](patches/) and applied to the `~/git/yuruna` clone (not to this
repo). Each is a genuine upstream bug with a real fix, not a workaround for a
local misconfiguration.

Failures were found serially — each fix exposed the next — which is why this
took four cycles:

| Run | Outcome |
|-----|---------|
| 1 | Crash at step 5 after 43 s — `Save-OcrSidecar` not found (§6.4a) |
| 2 | Step 5 burns 2400 s — subiquity parked on the autoinstall prompt (§6.4b) |
| 3 | Step 6 burns 2400 s — expired password blocks SSH (§6.4c) |
| 4 | **Green, 13/13, 10 min 9 s** |

### 6.1 The issue's config key no longer exists

Issue #8 says: *set `vmCommunication.keystrokeMechanism: SSH`*. That key was
removed between `2026.06.26` (the release this host was previously set up with)
and `2026.08.04`. `test.config.yml.template` has no such key, and
`Test-Config.ps1 -OnConfigSchemaDrift Fail` treats a leftover one as drift.

The mechanism moved from a global config switch to a per-sequence declaration:

| | 2026.06.26 | 2026.08.04 |
|---|---|---|
| Selected by | `vmCommunication.keystrokeMechanism` in `test.config.yml` | `keystrokeMechanism:` inside each sequence file |
| Sequence layout | `test/sequences/{gui,ssh}/<name>.yml` | flat `test/sequences/`, SSH as `<name>.ssh.yml` |
| Single-sequence runner | `test/Test-Sequence.ps1` | `test/Invoke-TestSequence.ps1` |

**Consequence for #27:** the quickstart must say *"run the `.ssh.yml`
variant"*, never *"set keystrokeMechanism"*. Any doc or issue repeating the old
instruction is stale.

### 6.2 `libvirtd` check is a false negative on Ubuntu 24.04 → #28

`Test-Config.ps1` fails with:

```
[FAIL] libvirtd: inactive. Start with: sudo systemctl enable --now libvirtd
```

but libvirt is working. Ubuntu 24.04 **socket-activates** libvirtd:
`libvirtd.socket` is active and enabled, `virsh` works, and `libvirtd.service`
reads `inactive` until a client connects — then idles back out. The probe
(`Test.HostCondition.Linux.psm1:220` and `Yuruna.Host.psm1:2991`) runs a
point-in-time `systemctl is-active libvirtd`, which is the wrong question.

Following the message's advice (`sudo systemctl enable --now libvirtd`) would
defeat socket activation to satisfy a broken check.

**Workaround used:** issue any libvirt call to wake the daemon immediately
before the gate:

```bash
virsh list --all > /dev/null && pwsh test/Test-Config.ps1 -SkipSend
```

**Upstream fix:** accept `active` on `libvirtd.socket`, or probe by connecting
to `qemu:///system`.

### 6.3 `transports.yml` — do NOT follow the warning

`Test-Config.ps1` warns that
`status/extension/notification/transports.yml` is missing and says to copy it
from the template. **Doing so makes things worse:** the seeded template is
empty, which converts one advisory WARN into two hard FAILs demanding a Resend
API key, and the config gate then refuses the cycle.

Leave the file absent unless email notification is actually wanted. Verified
both ways (34 PASS/0 FAIL absent → 32 PASS/2 FAIL seeded).

### 6.4 Upstream bugs patched → #28

#### a. `Save-OcrSidecar` is not exported — [`yuruna-save-ocrsidecar-export.patch`](patches/yuruna-save-ocrsidecar-export.patch)

```
The term 'Save-OcrSidecar' is not recognized as a name of a cmdlet ...
  at Test.SequenceHandler.psm1: line 1091
```

`Save-OcrSidecar` is defined in `Test.SequenceEngine.psm1:546` but omitted from
that module's `Export-ModuleMember` list, so the `sshWaitReady` handler in the
sibling `Test.SequenceHandler.psm1` cannot resolve it. The call sits on the
installer-crash OCR scan path, which runs on essentially every poll while
subiquity is still installing — so **any** SSH sequence declaring
`installerFailurePatterns` dies within a minute. Both stock Ubuntu SSH
sequences declare them.

Fix: add the function to the export list (one line).

#### b. The SSH sequence never answers the autoinstall prompt — [`yuruna-ssh-autoinstall-confirm.patch`](patches/yuruna-ssh-autoinstall-confirm.patch)

Subiquity parks on `Continue with autoinstall? (yes|no)` and the SSH sequence
has no step that answers it, so sshd never starts and `sshWaitReady` burns its
full 2400 s. Confirmed from the failure screenshot, and by sending `yes` to the
live VM with `virsh send-key` — the installer immediately proceeded into curtin
partitioning.

The prompt is *by design*: `New-VM.ps1` boots the live-server ISO without
`autoinstall` on the kernel command line, and its `.DESCRIPTION` explicitly
rejects the pre-baked cloud image **because** that path skips this prompt. The
GUI sibling has always carried a `waitForAndEnter` step for it; the SSH variant
never did. Its header comment ("Subiquity runs fully hands-off … no
Install-button dance") is simply wrong for this guest.

Fix: add the same `waitForAndEnter` step the GUI sequence uses. This introduces
no new dependency — `sshWaitReady`'s `installerFailurePatterns` already
OCR-scans frames, so the "OCR-free" sequence was using OCR regardless.

#### c. Expired password blocks SSH — [`yuruna-no-password-expiry.patch`](patches/yuruna-no-password-expiry.patch) — **bypass, see #26**

The deepest defect. `host/vmconfig/ubuntu.server.base.user-data:130` runs
`passwd --expire`, so even after publickey auth succeeds:

```
You are required to change your password immediately (administrator enforced).
Password change required but no TTY available.
```

With `UsePAM yes`, `pam_unix` returns `PAM_NEW_AUTHTOK_REQD` during account
management and sshd refuses every non-interactive session. `sshWaitReady` can
never go ready.

`start.guest.amazon.linux.2023.ssh.yml` states the assumption the Ubuntu
variant inherited — *"key auth bypasses the cloud-init forced first-login
password change"* — and **on Ubuntu 24.04 that assumption is false.**

Proven on the live guest: rotating the expired password (and nothing else) made
plain `ssh … 'whoami && hostname'` return `yuuser24` /
`test-guest.ubuntu.server.24-01` / `Ubuntu 24.04.4 LTS` at exit 0.

**This one is a true bypass, not a clean fix, because it has a cost:** the
expiry is load-bearing for the *GUI* sequence — it is what produces the
Current/New/Retype dialog that `start.guest.ubuntu.server.24.yml` drives with
`passwdPrompt` steps. With the line commented out, **the GUI sequence for this
guest will no longer work.** Kennel only needs the SSH path, so the trade is
acceptable for the MVP.

*Retirement path:* upstream should gate the expiry on the sequence's
`keystrokeMechanism` rather than applying it unconditionally, so both paths work
from one image. Until then, restore the line to run the GUI sequence.

### 6.5 ISO checksum verification silently skipped → #28

`Get-Image.ps1` reports:

```
Checksum signature OK (pinned Ubuntu key).
WARNING: Could not find checksum for ubuntu-24.04.4-live-server-amd64.iso. Skipping verification.
```

The GPG signature over `SHA256SUMS` verified, but the ISO's own hash was never
compared — the filename lookup missed. The download is therefore
**unverified**, and the run continues without failing. A supply-chain gap worth
an upstream issue, not just a note.

### 6.6 Host clock — unresolved, operator action

Covered in §2. Advisory only; the stock guest booted green regardless. Left
unfixed because `sudo chronyc makestep` needs a password. **Fix it before any
unattended cycle**, and before #10 builds Kubernetes-adjacent workloads — that
is the documented failure case.

### 6.7 Smaller notes

- **`users.yml` strict mode.** The gate failed on `ch01user1`, `ch02user2`,
  `yt2sqluser` — logical users referenced by the *yuruna-project* repo's
  sequences (`book/`, `example/text-to-sql`), which Kennel never runs;
  `Test-Config.ps1` scans every discoverable sequence. Declared them in
  `test/status/extension/authentication/users.yml` to keep `strict: true`
  rather than dropping the host to lenient mode. `test/status/` is gitignored
  runtime state, so this is host-local.
- **Do not `git pull` the project repo by hand.** `Invoke-TestSequence.ps1`
  deletes and re-clones `<RepoRoot>/project` on every run, discarding local
  state there. (`test/status/` is *not* touched, so the `users.yml` edit
  survives.) Use `-NoProjectRefresh` if that matters.
- **`Invoke-TestRunner.ps1` is not the single-sequence runner** — it is an
  eternal-loop CI runner. Use `Invoke-TestSequence.ps1`.
- **Image download is a separate, manual prerequisite.**
  `Invoke-TestSequence.ps1` does no image fetch; `Get-Image.ps1` must be run
  first (3.4 GB, ~9 min here).
- **Stale VMs.** `Remove-TestVMFiles.ps1 -Prefix test-` only sweeps the
  `test-` prefix, so an unrelated pre-existing domain (`ub26_guest` here) is
  correctly left alone. A VM left running from a failed cycle must be
  `virsh destroy`/`undefine`d before it will fully clean up.


---

Last review: 2026-08-04
