# Kennel — Plan K: the appliance (#74 · #75 · #76), one PR

Steps 20–22 of milestone [*Finish the system*](https://github.com/alius-git/kennel/milestone/2),
written like plans A–J (`next-goals.md`, `teleop-joystick.md`, `reliability.md`,
`console-live.md`, `teleop-hardened.md`, `two-scenarios.md`, `user-surface.md`,
`harness.md`) so an agent can implement them on one branch without re-deriving
the repo. Everything in §0 was checked on **2026-09-10** with the commands
shown; every probe was read-only against the repo, the host and the running
guest, or ran against scratch files, and the guest was left exactly as found.

| Step | Issue | One line |
|---|---|---|
| 20 | [#74](https://github.com/alius-git/kennel/issues/74) | the **version manifest**: the baseline prep script writes `~/kennel-manifest.json` (OS, kernel, Docker, image id, pin, ROS, Drake, the package list, the kennel commit the image was built from, the console and guides versions, `image_sha256: null`); the three sequences assert its pin instead of `~/.kennel-baseline`'s; `up`/`run`/`reset`/`status` fetch and print it; `serve.py /api/health` carries it; the console shows the guest's pin and warns when its own differs; `run.json` gains `manifest_ref`; `kennel-transfer.sh` warns on a mismatch |
| 21 | [#75](https://github.com/alius-git/kennel/issues/75) | the **drift check**: `kennel-drift.sh` on the guest — tracked files, packages, image id, build stamp, pin, kernel — against the manifest, one line per finding, `0/1/2`; `kennel-demo.sh drift`; `reset` ends by asserting clean; the negative control (a modified stack file + `sl`) reports exactly two; the survival question answered honestly — the host's `~/kennel-runs` is the workspace that survives a revert; the console warns *environment drifted* |
| 22 | [#76](https://github.com/alius-git/kennel/issues/76) | the **appliance image**: `export-image` converts the *frozen snapshot layer* to a compressed qcow2 with a domain template, the manifest with `image_sha256` filled, and `SHA256SUMS`; `import` verifies the checksum before writing a byte, defines the domain, takes the libvirt snapshot so `reset` works unchanged, and injects the importing host's SSH key through a `KENNELKEY` ISO read by a first-boot unit baked into the baseline; *import → walking* measured for the first time |

**One branch, one PR, closing all three.** The maintainer's call for this step,
as for E–J; the milestone's default is one issue per PR and the PR body says so
(§6.2). The three are one thing built in order: a drift check diffs *against*
the manifest (#74 → #75), and an image whose identity is a manifest plus a
checksum cannot ship before both exist (#76 depends on #74 and #75, and the
`reset` it promises to keep unchanged is the one #75 ends with a drift assert).
Budget: about **two hours of guest time** (§4) — one cold cycle (~40 min) to
build a baseline that carries the manifest and the first-boot unit through the
real sequence path, the manifest and drift protocol (~10 min), an export
(~5–15 min, unmeasured until now), two imports (~3 min each) with a `run`, a
`reset` and an `mvp` on the imported appliance, the nine suites — and the rest
is editing. Branch from **`origin/main` at `b880567`** (the #84 merge); local
`main` is behind it and the checked-out branch `test/23-harness` is merged.

---

## 0. Ground truth the implementer must know

**Repo.** `origin/main` is `b880567` (*Merge pull request #84*, 2026-09-10).
The checked-out branch is `test/23-harness` at `6c09a8f`, identical to
`origin/test/23-harness` and merged. **The working tree carries uncommitted
deck work** — `M slides/slides.md` and five untracked files under `slides/` —
that is the maintainer's and is not this PR's: branch from `origin/main`,
never `git add -A`, stage files by name. `HEAD:guides` is tree
`d2b5a1c1d691a07b5141318f82daf9690e55b93c` (§0.2 uses it). The nine console
suites total **629 checks** (PR #84: runs 84 → 119 with group 8); the counts
per suite are in each `verify-*.sh` header.

**Host.** Yuruna `2026.08.04` at `~/git/yuruna`, patched, status service up on
`:8080` (`curl -s localhost:8080/status/` → 200); `test/test.config.yml` has
`projectUrl: file:///home/thales/kennel`, `cleanupVmNamePrefixes: []`,
`warmResume` default. Tools: `qemu-img 8.2.2` (Debian 1:8.2.2+ds-0ubuntu1.17),
`virt-install 4.1.0`, `libvirt-daemon-system 10.0.0-2ubuntu8.16`,
`genisoimage`, `xorriso`, `cloud-localds`, `virt-xml`, `virt-clone` present;
**`virtiofsd` absent** (no `/usr/lib/qemu/virtiofsd`, no `/usr/libexec/virtiofsd`),
**libguestfs absent** (no `virt-customize`, no `guestmount`); **no passwordless
sudo** (`sudo -n true` → *a password is required*) — every host-side step in
this plan runs as the user, in the `libvirt`/`kvm` groups. `/` has **101 GB
free** of 717 (86 % used); 16 threads, 28 GB RAM. The host clock is **~480 s
slow** (plan J's finding, still true: the snapshot's host-side creation time
`12:25:59 -0300` = 15:26 Z precedes the guest-stamped `created=…15:33:57Z` of
the same event) — a manifest's `created` is *guest* time, and the record
should say the two clocks disagree by that much.

**The domain.** `kennel-vm-baseline`, **running** (id 2) at lease
`192.168.122.59` (hostname `kennel-vm`, user `yuuser24`, key
`~/git/yuruna/test/status/ssh/yuruna_ed25519`); a second, unrelated domain
`ub26_guest` is shut off. `virsh snapshot-list kennel-vm-baseline`: one
snapshot, `kennel-vm-baseline`, state `shutoff`, created 2026-09-10 (by the
#84 cycle). `virsh domblklist`: `vda` =
`/home/thales/yuruna/vms/kennel-vm-baseline/kennel-vm-baseline.qcow2`, `sda` =
the install ISO under `~/yuruna/image/ubuntu.env/`, `sdb` =
`~/yuruna/vms/kennel-vm-baseline/seed.iso` (its source in `seed.src/`:
`meta-data` with `instance-id: test-guest.ubuntu.server.24-01`,
`local-hostname: kennel-vm`; `user-data` = the subiquity **autoinstall**
config with the harness public key under `ssh.authorized-keys` and a password
hash under `identity`). `qemu-img info -U` on the disk: **virtual 64 GiB,
allocated 24.7 GiB** (file 26,565,017,600 bytes), `compat 1.1`, `compression
type: zlib`, **one internal snapshot** (`ID 1, TAG kennel-vm-baseline, VM SIZE
0 B`). Without `-U` the running domain's write lock refuses `qemu-img`, which
is why §3.1 halts before converting. `virsh dumpxml --inactive`: `machine='pc-q35-noble'`,
`<vcpu>8`, `<memory>16777216 KiB`, `<cpu mode='host-passthrough'>`,
**`<os firmware='efi'>`** with `enrolled-keys` + `secure-boot` features,
`<loader …>/usr/share/OVMF/OVMF_CODE_4M.ms.fd`, **`<nvram>` still named after
the build VM** (`/var/lib/libvirt/qemu/nvram/test-guest.ubuntu.server.24-01_VARS.fd`,
`0600 libvirt-qemu:kvm` — **unreadable to the user**, so it cannot be shipped),
`vda` virtio, one `virtio` NIC on network `default` (`52:54:00:02:5e:0a`),
`tpm-crb` emulator, virtio video, `itco` watchdog, `<uuid>afbd9857-…`. The
Yuruna snapshot sidecar exists:
`~/git/yuruna/test/status/runtime/snapshots/kennel-vm-baseline__kennel-vm-baseline.manifest.json`
(`vmName`, `snapshotId`, `hostType`, `hostName`, `takenAtUtc`, `runId`,
`manifestVersion: 1`) — `import` must write one too (§3.3 reuses the driver's
own pwsh block).

**The guest** (all read-only, over ssh; container **running**, stack down):

| Fact | Value | How read |
|---|---|---|
| `~/.kennel-baseline` | `pin=dcf53c59…`, `image_id=sha256:3f2ce680…`, `created=2026-09-10T15:33:57Z` | `cat` |
| OS | `Ubuntu 24.04.5 LTS`, `VERSION_ID=24.04`, `ID=ubuntu` | `/etc/os-release` |
| kernel | `6.8.0-139-generic` | `uname -r` |
| Docker | server `29.8.0` | `sudo docker version -f '{{.Server.Version}}'` |
| image | `dfki_quad:latest` = `sha256:3f2ce68095033a34d793cc864bed9ed4c3be67782a907681f2fcec576748f65b`, created `2026-09-10T15:25:54Z`, 13.0 GB | `docker image inspect` |
| container | `dfki_quad`, running, image `dfki_quad:latest`, entrypoint `/ros_entrypoint.sh bash`, **no restart policy** | `docker inspect --type container` |
| container OS | `Ubuntu 22.04.5 LTS` (jammy) | `docker exec … /etc/os-release` |
| ROS | `ROS_DISTRO=humble` is in the **image's `Config.Env`** (no shell needed); `ros-humble-ros-base 0.10.0-1jammy.20260804.204550`, `ros-humble-ros-core 0.10.0-1jammy.20260726.123022` | `docker image inspect -f '{{.Config.Env}}'`; `dpkg-query -W` in the container |
| Drake | **not `pydrake`** (`import pydrake` → *ModuleNotFoundError*; the `PYTHONPATH` for it lives only in root's `.bashrc`); **no apt package**; it is the binary tarball `/opt/drake` — `/opt/drake/share/doc/drake/VERSION.TXT` = `20231218181452 9ba8f5d8d4ee6919ec41542d47509549cfa8d919`; the pin's `docker/drake_setup.sh` fetches `drake-1.24.0-jammy.tar.gz` under the misleading local name `drake-latest-jammy.tar.gz` (`git show <PIN>:docker/drake_setup.sh` line 9) | `docker exec … cat VERSION.TXT`; `git show` |
| packages | **706** installed (`dpkg-query -W`), 35 manual; `jq 1.7.1-3ubuntu0.24.04.2` **installed** (a dependency of `ubuntu-server`), `python3 3.12.3`, `efibootmgr`, `ssh-keygen` present; **`apt-get install -s sl` → exactly `Inst sl (5.02-1)`**, no dependencies — the negative control of §2.3 yields exactly one package finding | `dpkg-query`, `apt-mark showmanual`, `apt-get -s` |
| clone | at the pin, `git status --porcelain --untracked-files=no` empty, stamp `ws/.kennel-built-dcf53c59…` present | as the prep script asserts |
| staging | `~/kennel-staging/` present with `guest-apply-config.sh`, `runs/` (empty), `stock-backup/`, **no `current-run`** | `ls` |
| **cloud-init** | **disabled by marker** — `cloud-init status --long` → `status: disabled … Cloud-init disabled by /etc/cloud/cloud-init.disabled`; datasource **`None`** (`/var/lib/cloud/data/instance-id` = `iid-datasource-none`); subiquity's `99-installer.cfg` and `90-installer-network.cfg` in `/etc/cloud/cloud.cfg.d/`; netplan `50-cloud-init.yaml`: `enp1s0: dhcp4: true` (no `dhcp-identifier: mac` → DHCP identity is the **DUID from `/etc/machine-id`**, `afbd9857…`) | `cloud-init status`, `ls`, `cat` |
| SSH | `~/.ssh/authorized_keys` = **one line**, the harness key (`… yuruna-test-harness@`); host keys `ssh_host_{ecdsa,ed25519,rsa}_key`; `ssh` is socket-activated (`is-enabled ssh` → `disabled`, normal on 24.04) | `wc -l`, `ls` |
| EFI | `/boot/efi/EFI/BOOT/{BOOTX64.EFI, fbx64.efi, mmx64.efi}` **and** `/boot/efi/EFI/ubuntu/{shimx64.efi, grubx64.efi, grub.cfg, BOOTX64.CSV}`; `efibootmgr`: `Boot0003* Ubuntu → \EFI\ubuntu\shimx64.efi`, `BootOrder 0003,0002,0001,0000` — so a **fresh NVRAM boots through the removable-media path** and `fbx64.efi` recreates the `Ubuntu` entry; the template of §3.2 can therefore omit the NVRAM file it cannot read anyway | `sudo ls`, `sudo efibootmgr` |
| labels | `/dev/disk/by-label/` has `cidata` (the seed) and the install ISO — a `KENNELKEY` volume will appear there the same way | `ls` |
| 9p / virtiofs | guest modules present (`CONFIG_9P_FS=m`, `CONFIG_NET_9P_VIRTIO=m`, `CONFIG_VIRTIO_FS=m`); the **host** has no `virtiofsd` | `/boot/config-*` |
| the host from the guest | `/etc/yuruna/host.env`: `YURUNA_STATUS_SERVICE_IP=192.168.122.1`, `PORT=8080`, `YURUNA_PROJECT_URL=file:///home/thales/kennel` (a builder path, read by nothing after provisioning); `http://192.168.122.1:8080/yuruna-repo/project/kennel_console/serve.py` → 200 (37,865 B); **`/yuruna-project-archive.tar.gz` → 200 (13,859,044 B)**; `/runtime/status.json` → 200 but carries **no project entry** (`projectUrl`, `project`, `projectCommit` all null) | `curl -s -o /dev/null -w '%{http_code} %{size_download}'` |
| sudo | passwordless for `yuuser24` | `sudo -n true` |
| disk | `/` 60 G, 28 G used, 30 G free (LVM `ubuntu--vg-ubuntu--lv` on `vda3`; `vda1` = ESP, `vda2` = `/boot`) | `df`, `lsblk` |

### 0.1 What the pieces are today, and the file:lines this plan edits

- **The baseline prep script** `test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh`
  (`set -euo pipefail`, sources nothing): knobs at lines 51–66 (`DFKI_QUAD_COMMIT`
  literal, `IMAGE_NAME`, `STAGING`, `BASELINE_FILE`); phase 1 stops the stack
  (the k13 teardown inlined, 96–137); phase 2 asserts the clone stock (tracked
  files only — the F1 rule); phase 3 the build stamp; phase 4 clears staging;
  **phase 5 "record the baseline" (228–247) writes the three-line
  `~/.kennel-baseline`**; phase 6 reclaims. It arrives on the guest **alone** —
  `fetch-and-execute` copies no siblings — so anything it installs (§3.3's unit)
  is a heredoc inside it. It runs both through the baseline sequence
  (`sshFetchAndExecute project/test/ubuntu.server.24/…prep.sh`, with the host's
  status service serving the project clone) and through `kennel-demo.sh
  snapshot` (`guest_stage` + plain ssh, `do_snapshot` 1163–1229).
- **The three sequences** restate the pin against `~/.kennel-baseline`:
  `test/workload…kennel.baseline.ssh.yml:72`, `…kennel.reset.ssh.yml:97` (and
  its evidence block at 163 prints the file), `…kennel.mvp.ssh.yml:84` (and its
  record step at 159 copies it as `baseline.txt`). `reset.yml` is at
  `sequenceRevision: 1`; the schema says bump when steps are added — §2.2 adds
  one there and nowhere else.
- **The driver** `demo/tools/kennel-demo.sh` (`set -uo pipefail`, 169): knob
  table 100–158, exit codes 160; `SSH_OPTS`/`lease_ip`/`need_guest` 267–345;
  `guest_stage` 417; `pin_sha` 548; `install_kennel_project` 580; `up_core`
  1096 (starts the container after the lease/ssh wait); `do_halt` 1137 (ACPI,
  bounded by `UP_TIMEOUT`); `do_snapshot` 1163 — its pwsh block 1193–1218 is
  **the** way a Yuruna snapshot + sidecar is taken from bash (`Save-VMDiskSnapshot`,
  `Write-SnapshotManifest`); `do_reset` 1231 (prints `~/.kennel-baseline` at
  1258, then `do_status`); `harness_collect` 1281; `do_mvp` 1307; `do_cycle`
  1356; `do_status` 1916; `do_run` 1987; dispatch 1997–2021 (the `*)` line
  lists the verbs). The side-channel pattern: `BRIDGE_FILE="$OUT/.kennel-bridge"`,
  `MESHCAT_FILE` (180–181), written by `teleop`/`walk`, read per request by
  `serve.py`.
- **`serve.py`** (`kennel_console/serve.py`, 832 lines, stdlib only): docstring
  1–45 lists the endpoints; `HERE`/`REPO_ROOT`/`PIN_LOCK` 59–61; `BRIDGE_FILE`/`MESHCAT_FILE`
  98–99; `side_channel(out_dir, name)` 127 (first line of a file, or `None`);
  `guide_list` 153; `host_pin` 383; `validate_archive` 409 — it checks the
  archive shape, that `run.json` parses, and **the pin only** (472–479, `409`
  on mismatch); it does **not** pin `run.json` to a key set, so a sixth key
  passes; `list_runs` 553; `Handler` 594, `/api/health` 617–630; `main` 764,
  the startup prints 814–820.
- **The page** `kennel_console/Kennel Console.dc.html` (3,894 lines):
  `const PIN_SHA = '…'` at **1131**; `emitRunJson(cfg, runId, stamp)` at
  **1448** (five keys, `choices` last, `disturbances` spread last inside
  `choices` — the comment explains the key-order contract); `artifacts(cfg,
  runId, stamp)` at **1493**, called at **3034** (send), **3463** (the export
  rows), **3490** (`onGenerate`); `probeKennel()` at 2737 fetches `/api/health`
  once on mount and stores it as `state.kennel`; the export strip's
  `pinDiffers` block at **312–314** (`<sc-if value="{{ pinDiffers }}">`) with
  its props at **3477–3481**; the status bar's run count at 3794 reads
  `st.kennel.out`.
- **`kennel-transfer.sh`** (`stack/transfer/`, `set -uo pipefail`): the pin
  check 118–127 (exit 3 unless `--allow-pin-mismatch`); the guest applier call
  ~203. It already talks to the guest over ssh, which is where §1.6 asks it
  about the manifest.
- **Yuruna, read from the code** (`~/git/yuruna`): `Save-VMDiskSnapshot`
  (`host/ubuntu.kvm/modules/Yuruna.Host.psm1:467`) stops the VM, `Rename-VM`s
  only when `VMName -ne Id`, `snapshot-delete`s any prior one, then
  `snapshot-create-as --domain <id> --name <id> --atomic` — **so with `VMName
  == Id` it is exactly "snapshot this domain in place"**, which is what
  `import` needs (§3.3). `Test-VMDiskSnapshot` (:505) = `snapshot-info`;
  `Restore-VMDiskSnapshot` (:517) = `snapshot-revert`. `Remove-VM` (:238):
  `virsh destroy`, then `undefine --nvram --managed-save --snapshots-metadata
  --checkpoints-metadata`, then deletes `~/yuruna/vms/<name>/` — and
  `test/Remove-TestVMFiles.ps1 -Prefix @('kennel-vm-baseline')` is the sweep
  the driver already uses (`do_provision`, `do_cycle`); the issue's `virsh
  undefine --nvram --remove-all-storage` is a paraphrase of it. `Get-VMIp`
  (:848) reads `virsh domifaddr` — a freshly generated MAC is fine.
  `Write-SnapshotManifest` (`test/modules/Test.SnapshotManifest.psm1:108`)
  writes `<runtime>/snapshots/<vm>__<id>.manifest.json`; a missing sidecar
  makes every `loadDiskSnapshot` warn *legacy snapshot*, a wrong one refuses.
  `New-VM.ps1` (`host/ubuntu.kvm/guest.ubuntu.server.24/`) builds the seed
  with `genisoimage -output <iso> -volid cidata -joliet -rock user-data
  meta-data` (:303) and, before anything, **`setfacl -m u:libvirt-qemu:--x
  $HOME`** (:95–104, "self-heal": libvirt-qemu must traverse `$HOME` to reach
  the qcow2) — `import` copies both. The status service's `Send-GitArchive`
  (`test/Start-StatusService.ps1:~777`) streams **`git archive --format=tar.gz
  HEAD`** of `project/` plus a `.yuruna-origin` file — a `git archive` of a
  commit carries that commit's id in the tar's pax global header (§0.2).

### 0.2 The probes

**P-a. `qemu-img convert -l` exports the snapshot layer, not the active
disk** (scratch, 64 MiB): write `0xAA`, `snapshot -c snapA`, write `0xBB` →
the active layer reads `0xBB`; `qemu-img convert -l snapshot.name=snapA -O
qcow2 -c base.qcow2 out.qcow2` → `out` reads **`0xAA`**, is compressed
(`compression type: zlib`), has **no snapshot list**, passes `qemu-img check`,
and accepts a new internal snapshot (`snapshot -c again` → listed). Plain
`convert` gives `0xBB`. `-o compression_type=zstd` also works on this
`qemu-img`. This is what makes §3.1 correct: the shipped bytes are the frozen
baseline, whatever the guest did since, and no `reset` is needed first.

**P-b. The project archive the host serves carries the commit and reproduces
the guides tree hash** (scratch): `curl localhost:8080/yuruna-project-archive.tar.gz`
(13,859,044 B, ~1 s on `virbr0`); `zcat | git get-tar-commit-id` →
`6c09a8fb7c6e4eaca21080b1de8522edd0bf3f43` = the clone's `HEAD`; `tar -xzf …
guides kennel_console/serve.py`, then in the extracted `guides/`: `git init -q
&& git add -A . && git write-tree` → **`d2b5a1c1d691a07b5141318f82daf9690e55b93c`
= `git rev-parse HEAD:guides`** on the host. So a guest with `git`, `curl`
and `/etc/yuruna/host.env` can attest *which kennel commit built it*, *which
guides tree it was built beside* and *which `KENNEL_CONSOLE_VERSION` literal
`serve.py` carried* — without a `.git` and without any literal restated in a
sequence (§1.2's decision; §7.2 says why the alternatives lose).

**P-c. cloud-init cannot be the key-injection path** (guest, read-only):
disabled by marker, datasource `None`, and the builder's own `seed.iso` stays
attached to the baseline domain. Re-enabling NoCloud in the image would make
the builder's next boot re-read *that* seed under a new instance-id — the
autoinstall config, whose top-level `autoinstall:` key cloud-init ignores
while its default `users` module creates the stock `ubuntu` user — and would
need `cloud-init clean` state baked into the snapshot. §3.3 uses a
40-line first-boot unit instead; §7.8 records the reasoning.

**P-d. `apt-get install -s sl`** on the guest → exactly `Inst sl (5.02-1
Ubuntu:24.04/noble [amd64])` and `Conf sl` — one package, no dependency, so
"exactly two findings" in §2.3 is a real assertion. Note `apt-get update` is
needed first on a reset guest (the prep script `apt-get clean`s, and lists go
stale); it changes no package state.

### 0.3 What the suites assert today, so nothing is reordered

Nine suites, **629 checks**, all no-VM. The ones this plan touches or must
not break:

- **`verify-export.py`** (plain `http.server`, no `/api/health`): group 3
  asserts `list(rj.keys()) == ["run_id", "run", "generated_at", "pin", "choices"]`
  (line 179) — **exactly five keys**. That is why `manifest_ref` is appended
  **only when the page knows a manifest** (§1.5): served by `http.server` the
  page never does, and the export contract stays byte-identical.
- **`verify-send.py`** (a real `serve.py --out <tmp>`, an empty run dir):
  groups 0–6 at lines 160/171/199/222/237/254/277; group 0 asserts health's
  `kennel`, `out`, `pin`; group 2 asserts a sent and a downloaded `run.json`
  differ only in `{run, generated_at, run_id}` — true with or without a
  stable sixth key; group 4 the refusals; group 6 zero non-localhost requests.
  **Group 7 is appended after 6** (§1.7) and ends with its own network check.
- **`verify-runs.py`** group 8 (line 422) parses **every** `test/*.yml`
  (566–577) — the reset sequence's new step must parse — and greps the MVP
  sequence for `KENNEL_MVP_RUN=`, `KENNEL_PIN=`, `--expect-solver`,
  `KENNEL_EXPECT_*_SHA=` (541–560); none of those lines change.
- **`verify-guides.py`** reads the driver's `help` and asserts the checklist's
  verbs exist (317–327); new verbs are additive.
- `verify-serve.sh` asserts the vendored runtime and offline boot; untouched.
- **`Test-Config.ps1 -SkipSend`** parses each `.yml` in the project clone —
  the CLAUDE.md rule: no plain scalar with `": "` in the new step.

---

## 1. #74 — the version manifest

### 1.1 The file: `~/kennel-manifest.json` and its sidecar

Written by the prep script, **by `python3 -c` with `json.dump(…, indent=2,
sort_keys=True)` plus a trailing newline** — canonical bytes, because
`manifest_ref` *is* the sha256 of those bytes (§1.1.1). One key per fact; the
values below are what this host's baseline will say:

```json
{
  "console_version": "2026.09.11",
  "container_os": "Ubuntu 22.04.5 LTS",
  "created": "2026-09-11T14:02:11Z",
  "docker": "29.8.0",
  "drake": "20231218181452 9ba8f5d8d4ee6919ec41542d47509549cfa8d919",
  "drake_source": "/opt/drake/share/doc/drake/VERSION.TXT (binary tarball; the pin's docker/drake_setup.sh names v1.24.0)",
  "guides_version": "d2b5a1c1d691a07b5141318f82daf9690e55b93c",
  "image_id": "sha256:3f2ce68095033a34d793cc864bed9ed4c3be67782a907681f2fcec576748f65b",
  "image_sha256": null,
  "kernel": "6.8.0-139-generic",
  "os": {"id": "ubuntu", "pretty_name": "Ubuntu 24.04.5 LTS", "version_id": "24.04"},
  "packages": {"count": 706, "file": "kennel-manifest.packages.txt", "sha256": "b9364413…"},
  "pin": "dcf53c596339afd45b82f12c54b1e93e8273c2f4",
  "project_commit": "6c09a8fb7c6e4eaca21080b1de8522edd0bf3f43",
  "provenance": "status-service",
  "ros_base": "ros-humble-ros-base 0.10.0-1jammy.20260804.204550",
  "ros_distro": "humble",
  "schema": "kennel-manifest/1"
}
```

- `packages.file` is the sidecar **`~/kennel-manifest.packages.txt`**: `dpkg-query -W
  -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' | awk -F'\t'
  '$3=="installed"{print $1"\t"$2}' | LC_ALL=C sort` — 706 lines today. A
  sidecar rather than 30 KB inline, so the manifest stays readable in a
  transcript and cheap in `/api/health`; `packages.sha256` binds the two, and
  the drift check refuses (exit 2) when they disagree.
- `image_sha256` is **null in-image, always**: an image cannot contain its own
  checksum. `export-image` fills it in the *shipped* copy (§3.1).
- `drake` is `VERSION.TXT` verbatim (build stamp + upstream sha); `drake_source`
  says where it came from, because the issue asked *"record which"* and the
  answer is neither `pydrake.__version__` nor apt (§0 table).
- Everything read **from inside the image** (`container_os`, `ros_distro`,
  `ros_base`, `drake`) is read with **`sudo docker run --rm --entrypoint bash
  "$IMAGE_NAME:latest" -c '…'`**, never `docker exec` — the prep script has
  just *stopped* the container by the time it records (phase 1), the second,
  idempotent run finds it stopped already, and the facts are the image's, not
  the container's. `ROS_DISTRO` could be read from `docker image inspect -f
  '{{.Config.Env}}'` without a process at all; the one `docker run` gets all
  four in ~1 s.
- `os` is an object on purpose (three fields, one source); `kernel` is `uname
  -r` — the running kernel, which the drift check compares (§2.1).

#### 1.1.1 `manifest_ref`

**`manifest_ref` = `sha256sum ~/kennel-manifest.json`**, the in-image bytes.
It is not stored inside the manifest (it cannot be); it is computed by whoever
reads it — the drift check, `serve.py`, `kennel-transfer.sh`, `import` — and
that is the identity `run.json` references (§1.5), the gate (#77) will match,
and s008's *byte-identical manifests across seats* means. The prep script
prints it as its last line: `manifest_ref=<sha>`.

### 1.2 Provenance: `project_commit`, `guides_version`, `console_version`

The guest cannot read the kennel checkout — but it can read what the host's
status service serves (§0.2 P-b). In the prep script, a new phase **"attest
the build inputs"**, before the manifest is written:

```bash
# Knobs win (the driver's `snapshot` passes them from the checkout, §1.4).
# Otherwise the host's project archive is the source: a `git archive HEAD` of
# the project clone, whose pax header names the commit -- the same tree
# fetch-and-execute served this very script from. No .git is needed for
# either the commit id or the guides TREE hash (git write-tree over the
# extracted directory reproduces `git rev-parse <commit>:guides`, §0.2).
PROJECT_COMMIT="${KENNEL_PROJECT_COMMIT:-}"
CONSOLE_VERSION="${KENNEL_CONSOLE_VERSION:-}"
GUIDES_VERSION="${KENNEL_GUIDES_VERSION:-}"
PROVENANCE=knobs
if [ -z "$PROJECT_COMMIT$CONSOLE_VERSION$GUIDES_VERSION" ]; then
    PROVENANCE=unknown
    if [ -r /etc/yuruna/host.env ]; then
        . /etc/yuruna/host.env
        arc="$(mktemp -d)"
        if curl -fsS --max-time 30 -o "$arc/project.tgz" \
              "http://${YURUNA_STATUS_SERVICE_IP:?}:${YURUNA_STATUS_SERVICE_PORT:?}/yuruna-project-archive.tar.gz"; then
            PROJECT_COMMIT="$(zcat "$arc/project.tgz" | git get-tar-commit-id)"
            tar -xzf "$arc/project.tgz" -C "$arc" guides kennel_console/serve.py
            CONSOLE_VERSION="$(sed -n 's/^KENNEL_CONSOLE_VERSION *= *"\([^"]*\)".*/\1/p' "$arc/kennel_console/serve.py" | head -1)"
            GUIDES_VERSION="$(cd "$arc/guides" && git --git-dir="$arc/g" --work-tree=. init -q \
                              && git --git-dir="$arc/g" --work-tree=. add -A -f . \
                              && git --git-dir="$arc/g" --work-tree=. write-tree)"
            PROVENANCE=status-service
        fi
        rm -rf "$arc"
    fi
    [ "$PROVENANCE" = unknown ] && say "WARNING: no build provenance -- neither KENNEL_PROJECT_COMMIT/… nor the host's status service; project_commit, console_version and guides_version will be null"
fi
```

Nulls are recorded as `null` (not `""`), `provenance` says which of the three
paths produced them, and a baseline is still a baseline without them (a
warning, not exit 1): the sequence path always has the service, the driver's
`snapshot` always passes knobs, so `unknown` only happens by hand. Partial
knobs are allowed (each falls through to the archive when empty — adapt the
condition per variable rather than the joined test above if you prefer; the
record says which).

`guides_version` is therefore **the git tree id of `guides/`** (`git rev-parse
<commit>:guides`): content-addressed, identical across commits that do not
touch the guides, computable on both sides, and checkable in the protocol
(§4 P4 asserts the guest's value equals the host's `git rev-parse HEAD:guides`).
The issue said "git hash of `guides/`"; this is the git hash that exists for a
directory. `console_version` is the literal of §1.5, bumped by hand.

### 1.3 The prep script, the sequences, `~/.kennel-baseline`

`test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh`:

- Header: `# Version: 2026.09.xx`, the manifest and the unit (§3.3) in the
  list of claims, the new knobs (`KENNEL_MANIFEST` default
  `$HOME/kennel-manifest.json`, the three `KENNEL_*_VERSION`/`COMMIT` knobs,
  `KENNEL_KEY_USER` default `$(id -un)`), exit code 2 now also for *no
  `python3`/`jq`/`curl`/`git`* (assert them in preconditions — all four are on
  every Yuruna guest, §0).
- Phase 5 becomes **"attest the build inputs"** (§1.2) + **"write the
  manifest"**: the facts above, the sidecar first (so its sha can go in),
  then the JSON via `python3 -c` with the values passed as `sys.argv` (never
  interpolated into Python source), then `manifest_ref` printed. **Still
  write `~/.kennel-baseline`** with its three lines, marked deprecated in the
  header comment (*"kept for one release; nothing reads it after #74; remove
  with the next repin"*).
- The new phase of §3.3 (the first-boot unit) sits **before** the manifest is
  written, and installs files only — the package list is unaffected.
- Idempotency claim in the header updated: a second run rewrites the manifest
  with a fresh `created`, hence a **fresh `manifest_ref`** — say so, it is the
  reason `snapshot` re-takes rather than "refreshes".

The three sequences, **command changes only** except where a step is added:

| File:line | Now | Becomes |
|---|---|---|
| `baseline.ssh.yml:72` | `cat ~/.kennel-baseline; grep -qx 'pin=<PIN>' …` | `cat "$HOME/kennel-manifest.json"; p=$(jq -r .pin "$HOME/kennel-manifest.json"); echo "manifest pin=$p (want <PIN>)"; [ "$p" = <PIN> ]` — description *"Assert the baseline manifest carries the stack pin"* |
| `reset.ssh.yml:97` | same assert | same replacement, description *"Assert the restored guest's manifest carries the stack pin"* |
| `reset.ssh.yml:163` (evidence block) | `cat ~/.kennel-baseline` | `cat "$HOME/kennel-manifest.json"; sha256sum "$HOME/kennel-manifest.json"` |
| `reset.ssh.yml` (end of `workload`) | — | **§2.2's drift step**, and `sequenceRevision: 2` |
| `mvp.ssh.yml:84` | same assert | same replacement |
| `mvp.ssh.yml:159` (record) | `cp ~/.kennel-baseline $d/baseline.txt` | additionally `cp "$HOME/kennel-manifest.json" "$d/manifest.json"; cp "$HOME/kennel-manifest.packages.txt" "$d/manifest.packages.txt"` |

`jq` is asserted present by the prep script, so a baseline that has a
manifest has `jq`. No `${…}` anywhere; the pin stays a literal in each file
(the pin.lock idiom); the YAML strings stay double-quoted as the neighbours
are.

### 1.4 The driver: fetch it, print it, pass the provenance

- **`up_core`** (after the container start): `scp $TARGET:kennel-manifest.json
  "$OUT/.kennel-manifest.json"` and the sidecar to `"$OUT/.kennel-manifest.packages.txt"`,
  best-effort; **when the guest has none, delete the host copy** — a stale
  manifest from a previous guest is worse than none (say so in a comment).
  `MANIFEST_FILE="$OUT/.kennel-manifest.json"` beside `BRIDGE_FILE` (180). `run`
  gets it through `need_guest` → `up_core`.
- **`do_status`**: after `kennel-transfer.sh status`, a *manifest* block —
  ask the **guest** (`ssh … 'cat ~/kennel-manifest.json'`), refresh the copy,
  print one line each for `pin`, `os.pretty_name`, `kernel`, `docker`,
  `ros_distro`, `drake` (first field), `project_commit` (7), `console_version`,
  `guides_version` (7), `created`, and `manifest_ref` (12) — with `jq -r` on
  the host (`jq` is a host prerequisite? it is not today: use `python3 -c`
  on the host, as `serve.py` is the one Python this repo already requires).
  With no manifest: *"no manifest on this guest (baseline predates #74 —
  re-take it: kennel-demo.sh snapshot)"*.
- **`do_reset`** (1258): print the manifest instead of `~/.kennel-baseline`,
  then `do_status`; §2.2 adds the drift fetch after it.
- **`do_snapshot`**: before staging the prep script, `install_kennel_project`
  (cheap, and it makes the served archive this checkout's HEAD); pass the
  knobs on the ssh line — `KENNEL_PROJECT_COMMIT=$(git -C "$REPO_ROOT"
  rev-parse HEAD) KENNEL_CONSOLE_VERSION=$(sed -n '…' kennel_console/serve.py)
  KENNEL_GUIDES_VERSION=$(git -C "$REPO_ROOT" rev-parse HEAD:guides)` — and
  `warn` when `git status --porcelain -- guides/ kennel_console/` is non-empty
  (*"the manifest will name HEAD; your working tree differs"*). After the
  snapshot, print `manifest_ref` from the guest.
- Header/usage/knob table: `KENNEL_MANIFEST` is not a driver knob (the guest
  path is the prep script's); nothing new here beyond the three
  `KENNEL_*` provenance knobs, which are documented as *"passed by `snapshot`;
  set them only when running the prep script by hand"*.

### 1.5 `serve.py`, the page, `run.json`

**`serve.py`:**

- `KENNEL_CONSOLE_VERSION = "2026.09.xx"` (module constant beside `PIN_LOCK`,
  the date of the commit that introduces it, `YYYY.MM.DD`; the docstring says
  *bumped by hand whenever the page or this server changes*). `server_version`
  stays.
- `MANIFEST_FILE = ".kennel-manifest.json"`, `DRIFT_FILE = ".kennel-drift"`
  beside `BRIDGE_FILE`. `manifest_from(out_dir)` → `(dict, sha256)` or
  `(None, None)` — parse errors → `None` with a `log_message` (never a 500:
  the page must still boot). `drift_from(out_dir)` → the parsed JSON of §2.1
  or `None`.
- `/api/health` gains, **after** the existing keys: `"console_version"`,
  `"manifest"` (the dict or `null`), `"manifest_ref"` (or `null`), `"drift"`
  (§2.4, or `null`). Resolved per request like `bridge`/`meshcat`. The
  docstring's endpoint block and the startup prints (`[serve.py] manifest
  <path> (<ref12> | none yet -- kennel-demo.sh up writes it)`) follow.
- `validate_archive`: unchanged refusals. After the pin check, if `run.json`
  carries `manifest_ref` and it differs from the current `manifest_from`
  sha, **`log_message` a warning** and accept — #75's drift finding is the
  gate, not this POST (the issue says so).
- `list_runs`: pass `manifest_ref` through per run when present (one line,
  read from the same `run.json` it already opens). Nothing in `verify-runs`
  asserts the row's key set — check with `grep -n "keys()" kennel_console/verify-runs.py`
  before relying on that, and if it does, leave `list_runs` alone.

**The page:**

- `const KENNEL_CONSOLE_VERSION = '2026.09.xx';` beside `PIN_SHA` (1131) —
  the **same** value as `serve.py`'s; a suite check compares the two files.
- `emitRunJson(cfg, runId, stamp, manifestRef)` and `artifacts(cfg, runId,
  stamp, manifestRef)`: **`...(manifestRef ? {manifest_ref: manifestRef} : {})`
  spread last, after `choices`** — the same idiom `disturbances` uses one
  level down, for the same reason (§0.3). The three call sites (3034, 3463,
  3490) pass `(st.kennel && st.kennel.manifest_ref) || null` (3463 and 3490
  are inside the props builder where `st` is in scope; 3034 is `send`, use
  `this.state`).
- The export strip (312–314), **appended after the `pinDiffers` block**, same
  `sc-if` idiom, props beside 3477:
  - `guestLine` (grey, 9 px mono): `guest <pin7> · <os.pretty_name> · ROS
    <ros_distro> · Drake <drake first 8> · manifest <ref7> · console
    <console_version>` — present when `st.kennel.manifest` is.
  - `guestWarn` (amber `#e0a63c`): `guest pin differs from this console
    (guest <pin12>, console <pin12>)` when `manifest.pin !== PIN_SHA`;
    `server console version differs (server <v>, page <v>)` when
    `st.kennel.console_version !== KENNEL_CONSOLE_VERSION`; **`environment
    drifted: <n> findings (checked <HH:MM:SSZ>)`** when `st.kennel.drift &&
    st.kennel.drift.findings.length` (§2.4). One element, lines joined with
    ` · `, so nothing existing moves.
  - The existing `pinDiffers` (server pin from `pin.lock` vs page) stays as
    it is: it is a different question (*this host's checkout* vs the page)
    from the new one (*the guest* vs the page).

**`run.json`** therefore has **six keys when composed against a known
manifest and five otherwise**, `manifest_ref` last. `export.md` §3 records the
rule and `kennel_console/export.md`'s key table gains the row.

### 1.6 `kennel-transfer.sh`: the warning

After the pin check (118–127), in `apply` mode, when `run.json` carries a
`manifest_ref` (same `sed` idiom as `rj_pin`): ask the guest — it is about to
be sshed anyway — `guest_ref=$(ssh … 'sha256sum ~/kennel-manifest.json 2>/dev/null
| cut -c1-64')`; when the guest has no manifest, `warn "the guest carries no
version manifest (baseline predates #74)"`; when it differs, `warn "this run
was composed against manifest <a12>, the guest carries <b12> -- the environment
is not the one the run was composed for (#75's drift check names what
changed)"`. Never a refusal here: `restore-stock`/`status` untouched.

### 1.7 The suite: `verify-send.py` group 7 — "the manifest reaches the page (#74)"

Appended after group 6, ~18 checks, using the suite's own `serve.py --out
$OUT` and Chrome; **nothing before it changes**:

1. Static: `KENNEL_CONSOLE_VERSION` in `serve.py` equals the page's literal
   (regex both files); health carries `console_version` equal to it; with an
   empty out dir health has `manifest: null`, `manifest_ref: null`, `drift: null`.
2. Write a manifest fixture into `$OUT/.kennel-manifest.json` (a dict in the
   §1.1 shape with `pin = PIN`, built in the test, dumped with the same
   `sort_keys/indent` rule) and its sidecar; health `manifest.pin == PIN`,
   `manifest_ref == sha256(file bytes)`; reload the page; the guest line is
   in the export strip (`__txt()` contains `guest ` + `PIN[:7]`); no
   *differs* warning; a send → the written `run.json` has **six keys**,
   `manifest_ref` **last** and equal to health's; the two YAMLs unchanged
   (byte-equal to a send from group 1's state is not required — assert the
   key list and the value).
3. Overwrite the fixture with `pin = "0"*40` → reload → the strip warns
   *guest pin differs*; server refusal on send is **not** expected (the
   server's own pin is still `pin.lock`'s) — assert the POST still lands.
4. Write `$OUT/.kennel-drift` with two findings (§2.1's shape) → health
   `drift.findings` has 2 → reload → *environment drifted: 2 findings* in the
   strip; delete it → gone.
5. Delete the manifest → health null → reload → a send → **five keys** (the
   offline contract is intact); zero non-localhost requests over the group.

`verify-send.sh`'s header count 32 → 32 + n. The suite total in the PR body.

### 1.8 Record: `vm/manifest.md`

In the shape of `vm/snapshot.md`: what is delivered (the two files, the
fields and their sources — the §0 table becomes its §1), the provenance
decision (§1.2 with the P-b probe), `manifest_ref`, what reads it
(sequences, driver, `serve.py`, page, `run.json`, `kennel-transfer.sh`),
running it, validation (P-table rows), findings, bypasses (the manifest
lives in `$HOME`, not `/etc/kennel/` — growth path; the console version is a
hand-bumped literal), what it feeds (#75, #76, #77's gate, s006/s008/s009).
`vm/manifest/evidence/` holds the transcripts.

---

## 2. #75 — the drift check

### 2.1 `vm/guest/ubuntu.server.24/kennel-drift.sh` (GUEST)

The issue's path; `vm/guest/` returns for the appliance's **in-VM CLI**
(design §6 `appliance/tools/`), while provisioning-time scripts stay under
`test/ubuntu.server.24/` where Yuruna's convention wants them (§7.12). House
header; `set -uo pipefail` (sources nothing); knobs `KENNEL_MANIFEST`
(`$HOME/kennel-manifest.json`), `KENNEL_DRIFT_OUT` (`$HOME/kennel-drift.json`),
`DFKI_QUAD_DIR`, `KENNEL_CONTAINER`, `KENNEL_IMAGE`, `KENNEL_STAGING`. It is
fetched by the reset sequence (`sshFetchAndExecute project/vm/guest/…`) and
staged by the driver (`guest_stage`), so it takes no arguments.

**Exit 2 — could not look:** no manifest / unparsable; the sidecar missing or
its sha256 not the manifest's `packages.sha256`; no docker daemon; no clone.
Each with the sentence that says what to do (*re-take the baseline*).

**Findings, one line each, `DRIFT <class>  <detail>`, in this order:**

| class | what | detail |
|---|---|---|
| `pin` | `git -C clone rev-parse HEAD` ≠ `manifest.pin` | `clone at <sha>, manifest pin <sha>` |
| `tracked-file` | each line of `git status --porcelain --untracked-files=no` (the F1 rule: **tracked only**; the build stamp and `ws/log` are untracked and never findings) | `<status> <path>` |
| `package` | the sidecar vs `dpkg-query` now (same command as the prep script, §1.1): added / removed / version changed | `sl 5.02-1 (added)`, `<pkg> <v> (removed)`, `<pkg> (was <v>, now <v>)` |
| `image` | `docker image inspect -f '{{.Id}}' $IMAGE:latest` ≠ `manifest.image_id`; container `--type container` absent | `image <id12> (manifest <id12>)`, `container dfki_quad absent` |
| `build-stamp` | `ws/.kennel-built-<manifest.pin>` or `ws/install/setup.bash` missing | the path |
| `kernel` | `uname -r` ≠ `manifest.kernel` (a `linux-image` upgrade is also a package finding; this one says what is *running*) | `running <v>, manifest <v>` |

**Notes, not findings** (`note: …` lines): when `~/kennel-staging/current-run`
names a run, *"a composed run is applied (<run>): the tracked YAMLs above are
its configs -- an applied run IS drift; `kennel-demo.sh reset` returns them to
stock"*; `~/kennel-staging` itself is the designated workspace and is never
inspected. The header lists what is **not** checked: untracked files, process
state, the container's own layer, the host.

**Output tail:** `findings=<n> manifest_ref=<sha> checked=<utc>`; then the
JSON at `KENNEL_DRIFT_OUT`:

```json
{"schema": "kennel-drift/1", "checked": "…Z", "manifest_ref": "<sha>",
 "findings": [{"class": "tracked-file", "detail": " M src/…/simulator.launch.py"},
              {"class": "package", "detail": "sl 5.02-1 (added)"}],
 "notes": ["…"]}
```

Exit **0** no findings, **1** one or more, **2** could not look. `python3`
writes the JSON (present on every guest; the manifest is read with `jq`).

### 2.2 `kennel-demo.sh drift`, and `reset` ends clean

- **`do_drift`**: `need_guest`; `guest_stage vm/guest/ubuntu.server.24/kennel-drift.sh`;
  run it; on exit 0/1 `scp $TARGET:kennel-drift.json "$OUT/.kennel-drift"`,
  on 2 delete the host copy; print the guest's output verbatim; exit with the
  script's code. Dispatch entry, `usage`, header (*each session*).
- **The reset sequence's last step** (after the evidence block, `sequenceRevision:
  2`):

  ```yaml
  # The appliance's own drift check, last: a reset that returned anything but
  # the manifest's environment is not a reset. It fetches the tool from the
  # project tree like the prep script; exit 1 = a finding (named in the
  # output Yuruna keeps on failure), exit 2 = could not look.
  - action: sshFetchAndExecute
    command: "/usr/local/lib/yuruna/fetch-and-execute.sh project/vm/guest/ubuntu.server.24/kennel-drift.sh"
    timeoutSeconds: 300
    description: "Assert the drift check finds nothing (the guest is the manifest's environment)"
  ```

  On the cold path this runs right after the baseline was frozen — clean by
  construction, and the first proof that the check is quiet on a clean seat.
- **`do_reset`** then calls `do_drift` (≈2 s: the sequence already asserted
  it; the verb's job is to leave `$OUT/.kennel-drift` for the console).
- `harness_collect` also copies `kennel-drift.json` when present (no `.yml`,
  so it is safe under `test/evidence/`).

### 2.3 The negative control, recorded (§4 P6–P7)

On a reset guest: `kennel-demo.sh drift` → `findings=0`, exit 0 (the clean
seat). Then, over ssh: `echo '# drift control' >> ~/dfki-quad/src/simulator/launch/simulator.launch.py`
(a tracked **stack** file, not a config the composer writes — pick one that
exists at the pin: `git -C dfki-quad show <PIN>:src/simulator/launch/` lists
them), and `sudo apt-get update -qq && sudo apt-get install -y sl`. `drift` →
**exactly two lines**, `DRIFT tracked-file   M src/simulator/launch/simulator.launch.py`
and `DRIFT package  sl 5.02-1 (added)`, exit 1, the JSON with 2 entries, and
the console (P7) reading *environment drifted: 2 findings*. Then `reset` →
the sequence's own last step passes, `drift` → `findings=0`. Separately, a
composed run (`kennel-demo.sh run`, then `down`) → two `tracked-file`
findings on the two YAMLs **plus** the *composed run is applied* note —
that transcript is the *"an applied composed run is drift — say so"* evidence.

### 2.4 The survival question — answered, not designed around

Tested in P8, both directions: a file placed in the **host's** `~/kennel-runs/`
(the console's own run store) before `reset` is there after it; a file placed
in the **guest's** `~/kennel-staging/` before `reset` is **gone** after it — a
qcow2 `snapshot-revert` restores the whole disk. The disposition: **the
designated workspace that survives reset is the host's `~/kennel-runs`**,
which is already where the console writes run folders, where `verify.json` is
filed, and where `.kennel-manifest.json` now lands; the guest's
`~/kennel-staging` is a *staging* area by name and by contract
(`transfer.md` §3) and the prep script deletes it on purpose. A guest-side
share was priced and declined: `virtiofsd` is absent on this host baseline;
a 9p `<filesystem>` device would have to be added to the domain **and to the
snapshot's frozen XML** (libvirt reverts the definition with the disk, so a
device added afterwards disappears on every `reset`), to the export template
with a host-specific path, and to the guest's `fstab` in the baseline. Not
cheap; recorded as the growth path in `vm/drift.md`, with the transcripts.

The console's part of #75 is §1.5's `guestWarn` line reading `health.drift`;
the console cannot run the check — it reads what the driver left, and the
record says so (a stale `.kennel-drift` shows its `checked` time for that
reason).

### 2.5 Record: `vm/drift.md`

Delivered (the script, the verb, the sequence step), the classes and what is
deliberately not a finding, the negative control transcript (`vm/drift/evidence/`),
the survival answer with both transcripts, findings, what it feeds (#76's
`export-image` refuses a drifted guest; #77's gate refuses a drifted
manifest; s006 step 6, s008 steps 4–5).

---

## 3. #76 — the appliance image

### 3.1 `kennel-demo.sh export-image [dir]`

Default `dir` = `${KENNEL_IMAGE_DIR:-$HOME/kennel-images}/<name>/` with
`name=kennel-vm-<pin7>-<YYYYMMDD>` (UTC, host clock — note the 480 s). Steps,
each timed with `$SECONDS` and printed at the end:

1. **Preflight (exit 2):** `virsh`, `qemu-img`, `sha256sum`, `python3` on the
   host; domain `$SNAPSHOT_ID` defined **with** snapshot `$SNAPSHOT_ID`
   (`virsh snapshot-info`); the disk path from `virsh domblklist` (`vda`);
   the template `vm/image/kennel-vm.xml.in` present; `dir` absent or empty.
2. **The guest is the baseline (exit 1):** `need_guest` (up if needed);
   `~/kennel-manifest.json` present (else *"this baseline predates #74 —
   re-take it: `snapshot`"*); `do_drift` → **0 findings** (else *"the guest
   drifted: `reset` first, then export"*). Fetch the manifest and the sidecar
   into `dir` (they are the *snapshot's* bytes: only the prep script writes
   them, and it runs before every freeze). Compute `manifest_ref`.
3. **Assert the domain is what the template says (exit 1):** from `virsh
   dumpxml --inactive`: machine `pc-q35-noble`, `<vcpu>8`, `<memory>16777216`,
   the disk `bus='virtio'`, `firmware='efi'` — the template ships those, and a
   host that built something else must not ship it under this template.
4. **Halt** (`do_halt`'s body: ACPI, bounded) — `qemu-img` needs the lock.
5. **Convert the snapshot layer:**
   `qemu-img convert -p -l snapshot.name="$SNAPSHOT_ID" -O qcow2 -c
   ${KENNEL_IMAGE_COMPRESSION:+-o compression_type=$KENNEL_IMAGE_COMPRESSION}
   "$src" "$dir/$name.qcow2"` (knob default empty = zlib, the portable
   choice; `zstd` documented as faster where both `qemu-img`s support it).
   Record *before* (`qemu-img info -U` disk size of the source: 24.7 GiB
   today) and *after* (`du -h` of the output; expect single digits of GB —
   the 13 GB image layer inside compresses well) and the wall time. Then
   `qemu-img check -q` and `qemu-img info` showing **no snapshots** (flattened,
   §0.2 P-a).
6. **The bundle:** `$name.xml` = the template copied verbatim (placeholders
   intact, §3.2); `$name.manifest.json` = the guest's manifest with
   `image_sha256` (the qcow2's), `image_file`, `manifest_ref`, `exported`
   (UTC), `exported_from` (`hostname`, the snapshot's `creationTime`) added
   by `python3` with the same `sort_keys/indent` rule — **the in-image file
   is the identity; these are the envelope**; `$name.packages.txt`;
   `SHA256SUMS` (`sha256sum` over the four files, relative names, written
   last).
7. Print the listing with sizes, the timings, `manifest_ref`, and *"the guest
   is shut off (as after `snapshot`); bring it back with `up`"*. Exit 0.

The active layer is never exported (P-a): `export-image` on a guest that has
run a hundred experiments ships the same bytes as one that never booted, and
the drift gate in step 2 is there so that what the *guest* says about itself
(the manifest it hands over) is what the snapshot holds.

### 3.2 The domain template: `vm/image/kennel-vm.xml.in`

Committed, derived **once** from today's `virsh dumpxml --inactive
kennel-vm-baseline` (§0) with these edits, and nothing else:

- `<name>` → `@KENNEL_NAME@`; **`<uuid>` removed** (libvirt generates one);
  **`<mac address>` removed** (generated; `Get-VMIp` reads `domifaddr`, the
  driver reads the lease by hostname — neither cares).
- **The two `<disk device='cdrom'>` removed** (install ISO, `seed.iso`) and
  `<boot dev='cdrom'/>` with them; `vda`'s `<source file>` →
  `@KENNEL_DISK@`; **one new cdrom** `sda` on the existing SATA controller:
  `<source file='@KENNEL_KEY_ISO@'/>`, `<readonly/>` — the §3.3 key volume.
- **`<loader>` and `<nvram>` removed; `<os firmware='efi'>` and its two
  `<feature>`s kept** — libvirt's firmware autoselection picks the same
  `OVMF_*_4M.ms.fd` pair on any Ubuntu 24.04 KVM host and creates a fresh
  `/var/lib/libvirt/qemu/nvram/<name>_VARS.fd`; the guest boots through
  `EFI/BOOT/BOOTX64.EFI` and `fbx64.efi` recreates the `Ubuntu` entry (§0).
  The builder's NVRAM is `0600 libvirt-qemu` and cannot be read without
  sudo, so it is not an option even where it would be nice.
- `machine='pc-q35-noble'`, `host-passthrough`, 8 vCPU, 16 GiB, the PCI
  addresses, the `tpm-crb` emulator (needs `swtpm`, in the host baseline),
  virtio NIC on `network='default'`, VNC on `127.0.0.1` — **kept**. The
  machine type is the host requirement the record states: an Ubuntu 24.04
  KVM host (qemu ≥ 8.2, libvirt ≥ 10), i.e. the Yuruna `ubuntu.kvm` baseline.
- The `<metadata>` libosinfo block may go (cosmetic); a comment at the top
  says where the file came from and that `export-image` asserts the live
  domain still matches it.

### 3.3 The SSH key: a `KENNELKEY` volume and a first-boot unit in the baseline

The image must not ship the building host's **private** key — it never did
(only `authorized_keys` is in the image) — but it must stop trusting the
builder's public key and start trusting the importer's, on a guest whose
cloud-init is disabled (P-c). The mechanism, all under Kennel's control:

**In the baseline** (the prep script's new phase *"install the appliance's
first-boot unit"*, idempotent, files only, heredocs, before the manifest is
written): `/usr/local/lib/kennel/import-key.sh` (root, 0755),
`/etc/systemd/system/kennel-import-key.service`, and
`/etc/udev/rules.d/90-kennel-import-key.rules`:

```
# kennel-import-key.service -- installed by ubuntu.server.24.kennel-baseline-prep.sh
[Unit]
Description=Kennel: install the SSH key from a KENNELKEY volume (appliance import)
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/lib/kennel/import-key.sh
[Install]
WantedBy=multi-user.target
```

```
# 90-kennel-import-key.rules -- start the unit whenever a KENNELKEY volume appears
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="KENNELKEY", TAG+="systemd", ENV{SYSTEMD_WANTS}+="kennel-import-key.service"
```

`import-key.sh` (rendered with the prep script's `$(id -un)` as the user,
`yuuser24` today): if `/dev/disk/by-label/KENNELKEY` is absent → exit 0
silently (**the builder's own boots**); mount it read-only on a `mktemp -d`;
read `authorized_keys`; every line must pass `ssh-keygen -l -f` (else log
and exit 0 — never a boot failure); write it **atomically** as
`/home/<user>/.ssh/authorized_keys` (0600, owned by the user; the file is
**replaced**, so the builder's key is gone); if the content changed **and**
`/var/lib/kennel/imported` is absent, regenerate the SSH host keys (`rm -f
/etc/ssh/ssh_host_*_key*; ssh-keygen -A; systemctl restart ssh.socket ssh.service
2>/dev/null || true`) and write the marker with the key fingerprint and the
date; `logger -t kennel-import-key` each step; umount. Runs on every boot
with the volume attached (a no-op when nothing changed), so an operator can
swap the ISO to rotate the key.

**On the importing host** (`import`, §3.4): `KENNEL_SSH_PUBKEY` defaults to
**`${SSH_KEY}.pub`** — the host's own Yuruna key
(`~/git/yuruna/test/status/ssh/yuruna_ed25519.pub`), which is exactly what
makes `reset`, `mvp` and every driver verb work unchanged on the imported
appliance; must exist and pass `ssh-keygen -l -f`. A `mktemp -d` with
`authorized_keys` (the one line) and a `README` (*what this volume is*);
`genisoimage -output "$vmdir/kennel-key.iso" -volid KENNELKEY -joliet -rock
"$tmp"` — the same generator, flags and tool `New-VM.ps1:303` uses for the
seed. The ISO carries a **public** key and nothing else.

**Why not the alternatives** (§7.8): cloud-init is disabled and its seed
semantics would touch the builder's own boots (P-c); `virt-customize
--ssh-inject` needs libguestfs (absent) and a readable kernel (sudo); a
password-based `ssh-copy-id` ships a credential.

### 3.4 `kennel-demo.sh import <dir>`

1. **Preflight (exit 2):** `dir` has `SHA256SUMS` and exactly one each of
   `*.qcow2`, `*.xml`, `*.manifest.json` (+ the `.packages.txt`); `need_yuruna`
   (the sidecar of step 7 needs the modules, and a Kennel host is a Yuruna
   host); `virsh`, `qemu-img`, `genisoimage`, `sha256sum`, `python3`; libvirt
   network `default` active (`virsh net-info default`); `~/yuruna/vms/` exists
   or can be created; the pubkey (§3.3). **`import` does not need the guest
   ISO** — say so in the header (`setup` still checks it for `provision`).
2. **Verify before writing a byte (exit 1):** `(cd "$dir" && sha256sum -c
   --strict SHA256SUMS)` — every file, the failing one named; then
   `manifest.image_sha256` equals the qcow2's line in `SHA256SUMS`. **Nothing
   has been written when this exits**; P11 tampers one byte of `SHA256SUMS`
   and asserts `ls ~/yuruna/vms/` and `virsh list --all` are unchanged.
3. **Refuse a collision (exit 1):** domain `$SNAPSHOT_ID` defined, or
   `~/yuruna/vms/$SNAPSHOT_ID/` present → *"a baseline exists on this host;
   `import` will not replace it. Sweep it deliberately: pwsh
   test/Remove-TestVMFiles.ps1 -Prefix @('kennel-vm-baseline')"* (the `-Command`
   array form of `snapshot.md` F3).
4. **Place:** `setfacl -m u:libvirt-qemu:--x "$HOME"` when `setfacl` and the
   user exist (New-VM's self-heal, verbatim); `mkdir -p vmdir`; `cp` the qcow2
   as `$SNAPSHOT_ID.qcow2` (Yuruna's `<name>/<name>.qcow2` layout, which
   `Rename-VM`/`Remove-VM` assume); `qemu-img check -q` the copy; build
   `kennel-key.iso` (§3.3).
5. **Define:** render the template with `sed` (`@KENNEL_NAME@`, `@KENNEL_DISK@`,
   `@KENNEL_KEY_ISO@` → absolute paths) into a temp file; `virsh define`.
6. **Snapshot + sidecar:** factor `do_snapshot`'s pwsh block (1193–1218) into
   `yuruna_snapshot_domain <vm> <id>` and call it with `<vm> == <id>`
   (`Save-VMDiskSnapshot` then skips the rename and snapshots in place;
   `Write-SnapshotManifest` writes the sidecar); `virsh snapshot-list` printed.
   `reset` now works unchanged on this host.
7. **Up and prove:** `up_core` (start, lease, sshd — the first ssh attempts
   may be refused for a few seconds until the unit has installed the key;
   `wait_for_guest` retries within `UP_TIMEOUT`, record the measured
   boot-to-ssh); `scp` the manifest → `$OUT/.kennel-manifest.json`; **assert
   its sha256 equals the shipped `manifest_ref`** (exit 1: *"the imported
   guest's manifest is not the shipped one"*); `do_drift` → 0 findings (exit
   1 otherwise); `journalctl -t kennel-import-key` tail printed (*installed 1
   key, host keys regenerated*). Print the manifest summary, the timings per
   step, and *"next: kennel-demo.sh console, then run"*.

### 3.5 Timing, on this host (§4 P9–P10)

`export-image` (steps 2–6, halt included) → the sweep → `import` → `run` →
walking, each with `$SECONDS`. `import`'s own number **is the s001 budget
measured from import for the first time**: expect ~1 min of checksum + copy
for a single-digit-GB image, seconds to define and snapshot, ~40 s to ssh,
then `run`'s 77 s — about three to four minutes to a walking robot, against
s001's 300 s target and 600 s ceiling. The export's compression time is the
unknown (5–15 min is the guess; the record replaces it with the measurement).

### 3.6 Records: `vm/image.md`, and the ones it amends

`vm/image.md`: delivered (the two verbs, the template, the unit, the bundle
layout with real sizes), the decisions (§7.7–§7.11), the host requirements
(Ubuntu 24.04 KVM, `swtpm`, `default` network, no ISO), the key mechanism
and its evidence (a throwaway key accepted, the builder's key refused — P9),
the timings, findings, bypasses (qcow2/KVM first, OVA ahead; one machine-id
per image — a second seat on the *same* host collides on the DHCP DUID, s008's
problem, still open), what it feeds. `vm/image/evidence/` holds the
transcripts and the bundle's `SHA256SUMS` + `manifest.json` (not the qcow2).
`vm/snapshot.md` §7 *"The baseline is host-local"* → appended: retired by
#76 on 2026-09-xx (export/import), with the numbers; its bypass note gets
the same line. `README.md` quick start: `import <dir>` as the alternative
to `provision` (*"minutes instead of 35"*, the measured number).

---

## 4. Live validation protocol

Negative controls first; evidence file names are the contract; the guest ends
at a baseline. Implement commits 1–5 (§6.1) **before** P1: the cycle builds
the baseline from the committed branch, and it must carry both the manifest
and the first-boot unit. The console (`serve.py` on `:8000`) may stay up.
Run nothing else against the guest while a cycle runs; no `scenario *` verbs
(they overwrite their evidence).

| # | Step | Command | Evidence | Expect |
|---|---|---|---|---|
| P0 | negative, no VM: the suites before any page change | the nine suites on a clean checkout of the branch base | `vm/manifest/evidence/00-suites-before.txt` | 629, 9 × exit 0 |
| P0' | negative, no VM: a run.json without a manifest | `verify-export.sh` after the page change | in P12 | five keys, group 3 green |
| P1 | **the cycle** (builds the baseline with the manifest and the unit through the sequence path) | `demo/tools/kennel-demo.sh cycle --yes` (~40 min; `projectUrl` is already `file:///home/thales/kennel`) | `test/evidence/cycle-<stamp>/` (the verb's), copied to `vm/manifest/evidence/01-cycle.txt` | `overallStatus: pass`; the baseline sequence's *manifest carries the stack pin* step passed; the reset's *drift check finds nothing* step passed |
| P2 | reset, manifest printed | `kennel-demo.sh reset` | `vm/manifest/evidence/02-reset.txt` | green, 13 steps now; the manifest block on the host transcript; `manifest_ref` printed; `findings=0` |
| P3 | the manifest is what it says | over ssh: `cat ~/kennel-manifest.json`; `sha256sum` it and the sidecar; `wc -l` the sidecar; compare `provenance`, `project_commit` with `git -C ~/git/yuruna/project rev-parse HEAD`, `guides_version` with `git rev-parse HEAD:guides`, `console_version` with `serve.py` | `03-manifest.txt` | all equal; `provenance: status-service`; `image_sha256: null`; 706 ± the branch's own changes |
| P4 | `up`/`status`/console | `kennel-demo.sh status`; `curl -s localhost:8000/api/health`; a screenshot of the export strip's guest line (`dashboard-shot.sh`'s idiom) | `04-status.txt`, `04-health.json`, `04-strip.png` | `.kennel-manifest.json` written; health `manifest.pin` = pin, `manifest_ref` = P3's sha; the strip shows `guest dcf53c5 …`, no warning |
| P5 | `run.json` carries `manifest_ref`; transfer warns on a mismatch | `kennel-demo.sh compose`; inspect the new `run.json`; edit a **copy** of it to another `manifest_ref` and `kennel-transfer.sh apply <copy>` | `05-run-json.txt`, `05-transfer-warn.txt` | six keys, `manifest_ref` last = P3's; the copy applies with the WARNING line; then `reset` |
| P6 | **drift, negative control** (§2.3) | `drift` (clean) → the two injections → `drift` → `reset` → `drift` | `vm/drift/evidence/01-clean.txt`, `02-two-findings.txt`, `03-after-reset.txt` | `findings=0`, then **exactly** the two lines named, exit 1, then 0 |
| P7 | the console warns | with P6's `.kennel-drift` on the host: `curl /api/health`, reload, screenshot | `vm/drift/evidence/04-console-drifted.png` | *environment drifted: 2 findings* |
| P7' | a composed run is drift | `run`, `down`, `drift`; `reset` | `05-composed-run.txt` | two `tracked-file` findings + the *composed run is applied* note |
| P8 | survival, both directions (§2.4) | `touch ~/kennel-runs/keep-me.txt`; over ssh `mkdir -p ~/kennel-staging/keep && touch …/note.txt`; `reset`; `ls` both | `06-survival.txt` | host file present; guest file **gone** |
| P9 | **export, sweep, import with a throwaway key** | `kennel-demo.sh export-image`; `pwsh -NoProfile -Command "& ./test/Remove-TestVMFiles.ps1 -Prefix @('kennel-vm-baseline') -Confirm:\$false"` in `~/git/yuruna`; `ssh-keygen -t ed25519 -N '' -f <scratch>/import-key`; `KENNEL_SSH_PUBKEY=<scratch>/import-key.pub kennel-demo.sh import <dir>`; `ssh -i <scratch>/import-key … true` (accepted) **and** `ssh -i ~/git/yuruna/test/status/ssh/yuruna_ed25519 … true` (refused); `KENNEL_SSH_KEY=<scratch>/import-key kennel-demo.sh run` | `vm/image/evidence/01-export.txt` (sizes, time), `02-sweep.txt`, `03-import-throwaway.txt`, `04-keys.txt`, `05-run-imported.txt` | export green; `qemu-img info` no snapshots; import green with `manifest_ref` equal and `findings=0`; the builder's key **refused**; `run` → `pass=10 fail=0`, timings |
| P10 | **import with the host's key, then the Yuruna path** | sweep again; `kennel-demo.sh import <dir>` (default key); `reset`; `mvp` | `06-import-default.txt`, `07-reset-imported.txt`, `08-mvp-imported.txt` | green, green, green — the harness runs on an imported appliance; *import → walking* = import + `run` from P9 |
| P11 | **tampered checksum, refused before anything is written** | copy the bundle; flip one hex digit in `SHA256SUMS`; `import <copy>` on a host that already has the (P10) baseline → also the collision refusal; then sweep, `import <copy>` → the checksum refusal; `ls ~/yuruna/vms/`, `virsh list --all` unchanged; re-import the good bundle | `09-tampered.txt` | exit 1 naming the file; nothing written; the good import green again |
| P12 | nothing else moved | the nine suites; `bash -n` on the driver, the prep script, the drift script, `kennel-transfer.sh`; `python3 -m py_compile serve.py`; `pwsh test/Test-Config.ps1 -SkipSend`; `git diff --stat origin/main -- kennel_console/verify-*.py` shows only `verify-send.py`, and `grep '^-' ` on its diff shows nothing removed; `git status --porcelain` shows only `slides/` | `vm/manifest/evidence/10-suites.txt`, `10-gate.txt` | 9 × exit 0, 629 + n; 0 FAIL, no finding naming a kennel file |
| P13 | restore | `kennel-demo.sh reset`; `status` | `vm/image/evidence/10-restore.txt` | the imported baseline, container running, no run applied, `findings=0`; the host clock note if `makestep` was not run |

The **end state** is the imported appliance standing as `kennel-vm-baseline`
— the deliverable itself, proven by `reset` and `mvp`. The maintainer can
`provision` at any time; the record says both.

If the imported guest does **not** boot from a fresh NVRAM (P9, unlikely per
§0's EFI evidence), the fallback is `virt-xml`/`virsh edit` to point `<nvram>`
at a copy taken with `sudo` by the maintainer — record it as a finding and
do not block the PR on it; the acceptance is P9–P11.

---

## 5. Records and documentation to update

Append, never rewrite, in the existing records; new sections dated.

- **`vm/manifest.md`**, **`vm/drift.md`**, **`vm/image.md`** — new (§1.8,
  §2.5, §3.6), each with its `evidence/`.
- **`vm/image/kennel-vm.xml.in`** — new (§3.2).
- **`vm/snapshot.md`** — §1: `~/.kennel-baseline` deprecated (one release),
  the manifest is the record now; §7: host-local → retired by #76; the bypass
  note: the OVA bypass is retired for KVM, OVA ahead; §3.1's list of what the
  prep script asserts gains the unit and the manifest.
- **`vm/provisioning.md`** §2 (phase table): the prep script is the baseline
  sequence's; a pointer to `vm/manifest.md`.
- **`stack/pin.lock`** — the bypass note: *"replaced by the manifest for the
  MVP … retirement path: manifest generator"* → appended line: retired by #74
  on 2026-09-xx; `pin.lock` is one field of `~/kennel-manifest.json`, and the
  three sequences now assert the manifest's copy.
- **`stack/transfer.md`** §4.2 (exit codes) / §5: the manifest warning; §3:
  `~/kennel-staging` is *staging*, the surviving workspace is the host's.
- **`kennel_console/serve.md`** — the health fields; **`send.md`** — the guest
  line generalizes the pin check; **`export.md`** §3 — the sixth key and its
  rule; **`runs.md`** §8 — the #74 row is done, `manifest_ref` flows.
- **`test/README.md`** §1/§5 — the reset sequence ends with the drift check;
  the MVP record now carries the manifest; **`test/harness.md`** §7 — the
  bypass row *"a green run's evidence leaves the guest only through a driver
  verb"* gains: the manifest is now in-image, the run-manifest store is still
  ahead.
- **`demo/runbook.md`** — §1 (the short path: `import` as the alternative to
  `provision`), §3 (`drift`, `export-image`, `import` with what success looks
  like and the measured numbers), §4 (knobs: `KENNEL_IMAGE_DIR`,
  `KENNEL_IMAGE_COMPRESSION`, `KENNEL_SSH_PUBKEY`, the three provenance
  knobs), §7 (the verbs table).
- **`README.md`** — quick start gains the import path; the docs index line
  for `vm/`.
- **`docs/README.md`** — the VM section gains the three records.
- **`CLAUDE.md`** — the driver verbs: *once per host — `setup`, `provision`
  or `import`*; *each session* gains `drift`; a new line *the appliance —
  `export-image`, `import`*; the repo table's `vm/` row names the manifest,
  the drift check and the image. A new rule only if the maintainer wants it
  promoted from the record: *"An image cannot carry its own checksum:
  `image_sha256` is null in-image; the identity is `manifest_ref`, the sha256
  of the in-image manifest bytes."*
- **`guides/first-run.md`** — **untouched** (#77 is guides part 2); its
  "starting line is a provisioned guest" sentence is now also true of an
  imported one, and `vm/image.md` says so.
- **The tracker (#1)** — the PR body proposes the two row edits (bypass row 1
  → *retired for KVM (qcow2 export/import, #76); OVA ahead*; row 6 → *retired
  (#74): the manifest exists, `pin.lock` is one of its fields*). Editing the
  issue is the maintainer's.
- **`plan/appliance.md`** (this file) — committed in the first commit; the
  PR body's *Corrections to the plan* lists what measurement changed.

---

## 6. The PR

### 6.1 Commit order (each stands on its own)

1. `feat(vm): the version manifest — the baseline prep script writes ~/kennel-manifest.json and its package sidecar (OS, kernel, Docker, image id, pin, ROS, Drake, build provenance from the host's project archive); the three sequences assert its pin; ~/.kennel-baseline deprecated (#74)` — the prep script, the three sequence edits (reset's drift step waits for commit 4), **and `plan/appliance.md`**.
2. `feat(console): /api/health carries the guest's manifest, manifest_ref, KENNEL_CONSOLE_VERSION and the drift summary; the export strip shows the guest's pin and warns when it differs; run.json gains manifest_ref when a manifest is known; verify-send group 7 (#74)` — `serve.py`, the page, the suite group. Green: verify-send, verify-export (five keys), verify-runs.
3. `feat(demo): up/run/status/reset fetch and print the manifest; snapshot passes the checkout's provenance; kennel-transfer.sh warns on a manifest mismatch (#74)`.
4. `feat(vm): kennel-drift.sh — tracked files, packages, image, build stamp, pin and kernel against the manifest; kennel-demo.sh drift; the reset sequence ends by asserting clean; the console warns on a drifted guest (#75)` — the script, the verb, `reset.yml`'s step and revision bump.
5. `feat(vm): the appliance image — the first-boot key unit in the baseline; kennel-demo.sh export-image converts the frozen snapshot layer to a checksummed qcow2 with the manifest and a domain template; import verifies before writing, defines, snapshots and proves the manifest (#76)` — the prep script's unit phase, the template, the two verbs, the snapshot helper factored out.
6. `docs: record the appliance pass — vm/manifest.md, vm/drift.md, vm/image.md, the records appended, runbook, README and CLAUDE.md, evidence (#74, #75, #76)` — after §4.

### 6.2 Body skeleton (house style of #79–#84)

```
Closes #74, closes #75, closes #76. Plan: plan/appliance.md.

Three issues in one PR at the maintainer's request: they are steps 20–22 of the
milestone, and an image (#76) whose identity is a manifest (#74) plus a checksum
cannot ship before the check that diffs against that manifest (#75) exists. The
milestone's default of one issue per PR is unchanged.

<two paragraphs: what the appliance is now — a manifest in the image, a drift
check against it, an image that imports in minutes — and what it still is not
(an OVA; a run-manifest store; a second seat on the same host).>

## What is here
| File | |   (the prep script's two new phases, the drift script, the two
                 verbs + drift, the template, serve.py/page changes, verify-send
                 group 7, the three records, the sequence edits)

## Measured on the live guest
- the cycle that built the baseline: <total>, the two new asserts green
- the manifest: <the values>, manifest_ref <sha12>, provenance status-service,
  guides_version == HEAD:guides, project_commit == the clone's HEAD
- drift: clean 0; injected → exactly 2 (named); after reset → 0; composed run → 2 + note
- survival: host file kept, guest file gone (the disposition)
- export: <allocated GiB> → <compressed GB> in <m>m<s>s; no snapshots in the output
- import: checksum <s>s, copy <s>s, define+snapshot <s>s, boot→ssh <s>s; manifest_ref equal; 0 findings
- import → walking: <m>m<s>s (import + run), s001's budget from import for the first time
- the builder's key refused on the throwaway-key import; the host's key accepted on the default one
- reset and mvp on the imported appliance: green, <s>/<s>
- tampered SHA256SUMS: refused, nothing written

## Findings from the live protocol   (F-series continues test/harness.md's)
## Corrections to the plan, from measurement
## Verification   (P-table as a block: suites 629 + n, bash -n, py_compile, Test-Config, greps, git status)
## Bypasses   | qcow2/KVM first, OVA ahead (tracker row 1 → retired for KVM) |
              | the manifest lives in $HOME, not /etc/kennel; console_version is a hand-bumped literal |
              | the surviving workspace is the host's ~/kennel-runs, not a guest share |
              | one machine-id per image → a second seat on the same host is s008's, still open |
              | run.json carries manifest_ref only when composed against a known manifest |
## Still open  — the OVA; a cycle on the imported appliance (the sweep semantics
                 are unchanged, but it is a claim nobody has measured); guides part 2 (#77)
                 reads manifest_ref from run.json; the tracker rows to edit
## Decisions   — §7 of the plan, as built
## Records     — the list in §5
```

---

## 7. Decisions this plan makes that the issues did not

1. **The manifest is two files** — a small JSON and a package-list sidecar
   bound by sha256 — and **`manifest_ref` is the sha256 of the in-image JSON
   bytes**, written canonically (`sort_keys`, `indent=2`, trailing newline)
   so that the identity is reproducible by anything that can hash a file.
   `image_sha256` is null in-image by necessity; the shipped copy adds the
   envelope (`image_sha256`, `image_file`, `manifest_ref`, `exported`,
   `exported_from`) and `import` proves the guest's bytes against the
   envelope's `manifest_ref`.
2. **Provenance comes from the host's project archive** (`git archive HEAD`
   served by the status service: the commit from the pax header, the guides
   **tree** hash from `git write-tree` over the extracted directory, the
   console version from `serve.py`'s literal), with knobs as the override the
   driver's `snapshot` uses, and `null` + a warning otherwise. The
   alternatives lose: a literal restated in a sequence goes stale on every
   guides edit (#77 would trip it the same week); `~/yuruna/project` on the
   guest is frozen at provisioning time and plan J forbids reading it;
   `status.json` carries no project entry (§0). "Git hash of `guides/`" is
   the tree id, the hash git has for a directory.
3. **`console_version` is a date literal** (`YYYY.MM.DD`) in `serve.py` and
   the page, equal by a static suite check, bumped by hand — as the issue
   asked, and said out loud in both files.
4. **`run.json` gains `manifest_ref` only when the page knows a manifest**
   (`/api/health` non-null), spread last: the five-key export contract and
   the existing suites stay unmodified, and an offline export is honest about
   not knowing.
5. **Drift is six classes** (pin, tracked files, packages, image/container,
   build stamp, running kernel), tracked files only (F1), `~/kennel-staging`
   excluded and a composed run reported as two findings plus a note. The
   check never judges process state or the host.
6. **The workspace that survives reset is the host's `~/kennel-runs`**,
   tested both ways; no 9p/virtiofs (virtiofsd absent; a device the snapshot
   metadata does not carry; a host path in the export template).
7. **`export-image` converts the frozen snapshot layer** (`-l snapshot.name=`),
   after asserting the guest is drift-clean and halting it; the guest is left
   shut off, like after `snapshot`. It never exports the active disk.
8. **Key injection is a `KENNELKEY` ISO read by a first-boot unit baked into
   the baseline**, which *replaces* `authorized_keys` and regenerates host
   keys once. cloud-init is disabled by the installer and re-enabling it
   would touch the builder's own boots (P-c); libguestfs is absent and needs
   sudo; a password is a credential. `import` defaults to the importing host's
   Yuruna key, so every verb works unchanged.
9. **The domain template is committed** (`vm/image/kennel-vm.xml.in`),
   derived from today's domain minus uuid, MAC, the two installer cdroms, the
   loader/nvram paths; `pc-q35-noble` kept, so the host requirement is an
   Ubuntu 24.04 KVM host — the Yuruna baseline. `export-image` asserts the
   live domain still matches it.
10. **The sweep before `import` is Yuruna's `Remove-TestVMFiles.ps1`**, which
    knows the per-VM directory and the undefine flags — never a hand-rolled
    `virsh undefine`. `import` refuses to run over an existing baseline.
11. **`import` writes the Yuruna snapshot sidecar** through the same pwsh
    block `snapshot` uses (factored into a helper), because a snapshot
    without one makes every `reset` warn *legacy*.
12. **`kennel-drift.sh` lives at `vm/guest/ubuntu.server.24/`** (the issue's
    path): runtime guest tools live beside their record (`stack/bridge/`,
    `stack/verify/`, now `vm/guest/`); provisioning-time scripts stay under
    `test/<guest>/` in Yuruna's layout. The prep script keeps writing the
    manifest because the manifest is a provisioning-time fact.
13. **The manifest path is `~/kennel-manifest.json`** (the issue's);
    `/etc/kennel/` is named as the growth path in the record.
14. **`import` does not need the guest ISO**; `setup` keeps checking it and
    says it is `provision`'s. The record lists what an import-only host needs.
15. **The protocol builds the baseline with a cycle first**, so the exported
    image's manifest was produced by the sequence path (the one a CI host
    runs), and the host ends holding the *imported* appliance.

## 8. Don'ts

- Don't `git add -A` — `slides/` is the maintainer's uncommitted deck.
- Don't change an existing suite group; append group 7 to `verify-send.py`
  and touch nothing before it. Don't make `run.json` six keys unconditionally.
- Don't put `${…}` in a `command:`; don't write a plain YAML scalar with `": "`;
  bump `sequenceRevision` only on `reset.yml` (a step was added); don't rename
  a sequence.
- Don't `docker exec` for the image facts — the container is stopped by then;
  `docker run --rm --entrypoint bash <image>` reads the image.
- Don't `qemu-img convert` a running domain (with or without `-U`): halt, then
  convert **the snapshot layer**.
- Don't ship anything from `test/status/ssh/`; the ISO carries one public key.
  Don't re-enable cloud-init. Don't add keys — replace `authorized_keys`.
- Don't `sudo` on the host (there is no passwordless sudo); the NVRAM file is
  unreadable and the template does not need it.
- Don't let the drift check judge untracked files, `~/kennel-staging`, or
  process state; don't let it exit 1 for a missing manifest (that is 2).
- Don't `virsh undefine` by hand; use `Remove-TestVMFiles.ps1 -Prefix @('kennel-vm-baseline')`.
- Don't run `scenario *` verbs while validating; don't `sleep` for readiness
  (the unit's key install is observed by `wait_for_guest`'s ssh retry, not by
  a pause).
- Don't hand-edit `test/fixtures/`; the fixture's `run.json` keeps five keys
  and that is correct — it was composed with no manifest known.
- Don't end the protocol without P12 and P13: the suites, the gate, and a
  guest at the baseline with `findings=0`.
