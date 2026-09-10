# The appliance image — the baseline on another host in minutes

Implementation record for
[issue #76](https://github.com/alius-git/kennel/issues/76), step 22 of 26 of
[*Finish the system*](https://github.com/alius-git/kennel/milestone/2). The
baseline stops being host-local: `kennel-demo.sh export-image` ships it as a
compressed, checksummed qcow2 bundle with its domain template and version
manifest, and `kennel-demo.sh import` makes that bundle another host's baseline —
defined, keyed for that host, snapshotted, proven — so `reset`, `mvp` and every
other verb work on it unchanged. The PRFAQ's *"import the appliance and be walking
in about five minutes"* is measured here for the first time.

Builds on [`manifest.md`](manifest.md) (#74), whose identity the bundle carries,
and [`drift.md`](drift.md) (#75), which both verbs refuse on. Retires the first
limit of [`snapshot.md`](snapshot.md) §7 (*"the baseline is host-local"*) for
KVM. Plan: [`plan/appliance.md`](../plan/appliance.md) §3.

> **Bypass note ([#26](https://github.com/alius-git/kennel/issues/26), tracker row 1):**
> [`plan/design.md` §1](../plan/design.md) locks an **OVA, VirtualBox-first**, with
> qcow2/KVM on the growth path. The MVP host is KVM, so this ships **qcow2 first**:
> the bypass is retired for KVM and the OVA is still ahead. What an OVA adds is a
> VirtualBox domain description and a VMDK — the manifest, the checksum discipline
> and the key mechanism below carry over unchanged.

## 1. What is delivered

| Artifact | Purpose |
|---|---|
| `kennel-demo.sh export-image [dir]` | refuse unless the guest is its baseline; convert the **snapshot layer**; write the bundle |
| `kennel-demo.sh import <dir>` | verify before writing a byte; place, key, define, boot, prove, snapshot |
| [`vm/image/kennel-vm.xml.in`](image/kennel-vm.xml.in) | the domain template, derived once from the built domain |
| the baseline prep script's *first-boot key unit* phase | `kennel-import-key.service`, its script and a udev rule, installed into every baseline (§3) |
| `yuruna_snapshot_domain` in the driver | `snapshot`'s pwsh block, factored out so `import` takes the same Yuruna snapshot and sidecar |

## 2. What ships

```
~/kennel-images/kennel-vm-<pin7>-<YYYYMMDD>/
├── kennel-vm-<pin7>-<date>.qcow2           the baseline disk, flattened and compressed
├── kennel-vm-<pin7>-<date>.xml             the domain template (§2.2), verbatim
├── kennel-vm-<pin7>-<date>.manifest.json   the version manifest, with the envelope keys
├── kennel-vm-<pin7>-<date>.packages.txt    its package list
└── SHA256SUMS                              the four files, written last
```

The bundle P9 exported from the cycle-built baseline ([`01-export.txt`](image/evidence/01-export.txt)):

```
-rw-rw-r--        1429  kennel-vm-dcf53c5-20260910.manifest.json
-rw-rw-r--       23201  kennel-vm-dcf53c5-20260910.packages.txt
-rw-r--r-- 13767147520  kennel-vm-dcf53c5-20260910.qcow2      qemu-img: virtual 64 GiB, disk size 12.8 GiB, zlib, no snapshots
-rw-rw-r--        8498  kennel-vm-dcf53c5-20260910.xml
-rw-rw-r--         409  SHA256SUMS
image_sha256  d51511800ae242eda70e88e1769b52689e88780f1d89feb4161490579dcc3ca5
manifest_ref  78f09058655ac922ffa7de457db9342100d6d36cbbb269925bd32db00d5cf85c
```

**25 GiB allocated → 12.8 GiB**, not the single digits #76 guessed: the 13 GB
`dfki_quad` image layer is mostly compiled binaries and Drake's shared libraries,
which zlib does little for. The shipped copies of `SHA256SUMS` and the manifest
envelope are kept beside the evidence ([`bundle-SHA256SUMS`](image/evidence/bundle-SHA256SUMS),
[`bundle-manifest.json`](image/evidence/bundle-manifest.json)); the qcow2 is not
committed.

The shipped manifest is the in-image one **plus an envelope**: `image_sha256`
(the qcow2's checksum, which no in-image copy can carry), `image_file`,
`manifest_ref` (the sha256 of the in-image bytes), `exported` and `exported_from`
(the host and the snapshot's creation time). Remove the envelope keys, set
`image_sha256` back to `null`, dump canonically, and you have the in-image bytes
again — `export-image` checks that before it writes `SHA256SUMS`, and `import`
checks it before it writes anything ([`manifest.md`](manifest.md) §2.2).

### 2.1 The snapshot layer, not the disk

`qemu-img convert -W -O qcow2 -c -l snapshot.name=kennel-vm-baseline <disk> <out>`.
`-l` reads the state the libvirt snapshot froze, **not** the active layer the
guest has written to since — probed on a scratch image before building on it
(write A, snapshot, write B: the converted image reads A;
[`plan/appliance.md`](../plan/appliance.md) §0.2 P-a). The output is flattened (no
internal snapshots), compressed (zlib unless `KENNEL_IMAGE_COMPRESSION=zstd`), and
passes `qemu-img check`. `-W` (out-of-order writes) is accepted with `-c` by this
`qemu-img` and is safe on a new target.

So an export of a guest that has run a hundred experiments ships the same bytes as
one that never booted. What the export *does* trust the live guest for is its
manifest: only the prep script writes it, immediately before every freeze, so the
live copy is the snapshot's — and `import` proves that on the far side by
comparing the imported guest's manifest bytes with the bundle's `manifest_ref`.
Before converting, `export-image` refuses a guest with no manifest or with any
drift, asserts the live domain matches the template (§2.2), halts it (`qemu-img`
needs the lock), and leaves it shut off, as `snapshot` does.

### 2.2 The domain template

[`vm/image/kennel-vm.xml.in`](image/kennel-vm.xml.in), derived once from
`virsh dumpxml --inactive kennel-vm-baseline`, with exactly these edits (its
header comment lists them): `<name>` a placeholder; `<uuid>` and the NIC `<mac>`
removed (libvirt generates both; discovery is by lease hostname); the two
installer CD-ROMs and the cdrom `<boot>` removed, one read-only CD-ROM kept for
the key volume (§3); the disk source a placeholder; **`<loader>` and `<nvram>`
removed** with `<os firmware='efi'>` and its `enrolled-keys` / `secure-boot`
features kept. libvirt picks the same `OVMF_*_4M.ms.fd` pair on any Ubuntu 24.04
KVM host and creates a fresh NVRAM from `OVMF_VARS_4M.ms.fd`, which carries no OS
boot entry. The guest boots through its removable-media path `EFI/BOOT/BOOTX64.EFI`,
and shim's fallback writes the `Ubuntu` entry. Measured on the real import after it
had booted: `Boot0002* Ubuntu → \EFI\ubuntu\shimx64.efi` is `BootCurrent` in an
NVRAM that started without it ([`11-efi-boot-entries.txt`](image/evidence/11-efi-boot-entries.txt)).
The builder's NVRAM was never an option: it is `0600 libvirt-qemu`, and this host has
no passwordless sudo.

Kept as built: `pc-q35-noble`, `host-passthrough`, 8 vCPU, 16 GiB, virtio disk
and NIC on `default`, the `tpm-crb` emulator. `export-image` compares machine
type, firmware, vCPU, memory and the disk's bus and format with the live domain
and refuses on a difference.

## 3. The SSH key

The guest trusts exactly one key: the **building** host's Yuruna harness key,
which autoinstall put into `authorized_keys`. The image never contained a private
key — but an imported copy must stop trusting the builder's public key and start
trusting the importer's, and it must do so on a guest where **cloud-init is
disabled** (the installer leaves `/etc/cloud/cloud-init.disabled`; datasource
`None`). Re-enabling it would mean managing cloud-init's seed and instance state
inside the baseline, beside a builder domain that still has its own `seed.iso`
attached — reasoned from what the guest showed, not tried. libguestfs
(`virt-customize --ssh-inject`) is not installed here, and on Ubuntu it has to read a
kernel image only root can read, on a host with no passwordless sudo. A password
would be a credential in the bundle. So the baseline carries its own mechanism:

- **In the baseline** (the prep script's *install the first-boot key unit*
  phase): `/usr/local/lib/kennel/import-key.sh`, `kennel-import-key.service`
  (oneshot, `WantedBy=multi-user.target`) and `90-kennel-import-key.rules` (udev
  starts the unit again whenever a `KENNELKEY` volume appears after its boot-time
  run). With no such volume the script exits 0 silently — every boot of the
  builder, forever. With one, it validates every line with `ssh-keygen -l`,
  **replaces** the user's `authorized_keys` atomically, and on the first import on
  that disk regenerates the SSH host keys and writes `/var/lib/kennel/imported`.
  It never fails a boot; what it did is in `journalctl -t kennel-import-key`.
- **On the importing host**, `import` builds `kennel-key.iso` with the same
  `genisoimage -volid … -joliet -rock` call Yuruna's `New-VM.ps1` builds its seed
  with — the importing host's **public** key and a README, nothing else — from
  `KENNEL_SSH_PUBKEY`, default `$KENNEL_SSH_KEY.pub`: this host's Yuruna key, which
  is what makes every verb and every sequence work on the import unchanged. The
  pair must match (`import` checks with `ssh-keygen -y`), because the verb proves
  the guest by logging in with the private half.
- **The snapshot is taken after that first keyed boot**, not before it. A revert
  then never brings back the builder's key even for the seconds before the unit
  runs, the host keys are regenerated once rather than on every reset, and the
  unit's later runs find `authorized_keys` already right and change nothing.

Measured on the first import, made with a throwaway key
([`04-keys.txt`](image/evidence/04-keys.txt)):

```
--- the throwaway key (the one on the KENNELKEY volume)
accepted: yuuser24@kennel-vm
--- the building host's Yuruna key (the one autoinstall put there)
yuuser24@192.168.122.228: Permission denied (publickey,password).
--- SSH host key: the original baseline, then the import
256 SHA256:2ezxsSdUUDj+JjI9FXam4gu+Qm7Z2rVKlUy8hRgLK+A (ED25519)
256 SHA256:sI7pdEqC72tjHrs54w2NqxiBn5UMrrEaqzkfDpYn3C4 (ED25519)
--- the unit's journal
19:02:13 kennel-import-key[857]: installed 1 key(s) from /dev/disk/by-label/KENNELKEY as the authorized_keys of yuuser24: SHA256:EZCV…
19:02:13 kennel-import-key[901]: regenerated the SSH host keys (the first import on this disk; marker /var/lib/kennel/imported)
-- Boot 3663221c… --
19:02:42 kennel-import-key[835]: authorized_keys of yuuser24 already carries the 1 key(s) on /dev/disk/by-label/KENNELKEY -- unchanged
```

The second boot is the one after the snapshot: the key is already right, the host
keys stay the ones generated once, exactly as §3's last bullet intends. The
domain libvirt defined from the template carries
`<loader … OVMF_CODE_4M.ms.fd>` and a fresh `kennel-vm-imptest_VARS.fd` it
created itself; the guest reached sshd 18 s after `virsh start`, through the
removable-media path and shim's fallback (§2.2).

## 4. `import`

1. **Preflight (exit 2):** the bundle holds exactly one of each file and a
   `SHA256SUMS`; the tools (`virsh`, `qemu-img`, `genisoimage`, `sha256sum`,
   `python3`, `ssh-keygen`); the key pair matches; libvirt's `default` network is
   active — asked up to five times, a second apart, since F25. **No guest ISO is
   needed.**
2. **Verify, before writing a byte (exit 1):** `SHA256SUMS` lists all four files;
   `sha256sum --check --strict`; the manifest's `image_sha256` is the image's line;
   its `manifest_ref` rebuilds from its own contents.
3. **Refuse a collision (exit 1):** a `kennel-vm-baseline` domain or
   `~/yuruna/vms/kennel-vm-baseline/` already present, with the
   `Remove-TestVMFiles.ps1` line to remove it deliberately; or a **running** domain
   already answering to the `kennel-vm` hostname ([`snapshot.md`](snapshot.md) §5.2).
4. **Place:** New-VM's `setfacl u:libvirt-qemu:--x $HOME`; the image copied as
   `~/yuruna/vms/<id>/<id>.qcow2` (Yuruna's layout, which `Remove-VM` and the sweep
   assume); `qemu-img check`; the key volume.
5. **Define** from the bundle's own template (not the checkout's), placeholders
   rendered with `sed`.
6. **First boot** (`up_core`): lease, sshd with the new key, container, manifest.
7. **Prove:** the guest's manifest sha256 equals the bundle's `manifest_ref`;
   the unit's journal; `drift` clean.
8. **Freeze:** halt, `Save-VMDiskSnapshot` in place plus Yuruna's sidecar (so no
   `reset` ever warns *legacy snapshot*), then up again.

## 5. Host requirements

An Ubuntu 24.04 KVM host as `vm/host-baseline.md` leaves it — qemu ≥ 8.2 (the
`pc-q35-noble` machine type), libvirt ≥ 10, `swtpm`, OVMF, `genisoimage`, the
`default` network — plus a Yuruna checkout for the snapshot sidecar and the
sequences. Not needed for `import`: the guest ISO, the three Yuruna patches'
autoinstall path, or 35 minutes. Disk: the bundle (12.8 GiB, almost all of it the qcow2) plus the imported copy of the image (the same 12.8 GiB to start, growing as the guest writes uncompressed clusters over it).

## 6. Running it

```bash
demo/tools/kennel-demo.sh export-image            # -> ~/kennel-images/kennel-vm-<pin7>-<date>/
demo/tools/kennel-demo.sh import <that directory> # on another host (or this one, after a sweep)
```

Knobs: `KENNEL_IMAGE_DIR` (`~/kennel-images`), `KENNEL_IMAGE_COMPRESSION` (empty
= zlib), `KENNEL_SSH_KEY` / `KENNEL_SSH_PUBKEY`, `KENNEL_SNAPSHOT_ID` (the domain
and snapshot name, `kennel-vm-baseline`). Exit codes: `0`; `1` a refusal that is
the bundle's or the guest's fault (a checksum, a drifted guest, a collision, a
manifest that does not match); `2` could not even start (a tool, a directory, a
network, a failed conversion); `3` from `up`/`halt`, a guest that never answered.

## 7. Validation — evidence

[`image/evidence/`](image/evidence/), protocol rows P9–P11 and P13 of
[`plan/appliance.md`](../plan/appliance.md) §4.

| # | File | What it shows |
|---|---|---|
| P9a | [`01-export.txt`](image/evidence/01-export.txt), [`bundle-SHA256SUMS`](image/evidence/bundle-SHA256SUMS), [`bundle-manifest.json`](image/evidence/bundle-manifest.json) | the cycle-built baseline: `drift` `findings=0`; the live domain matches the template on all seven facts; halted in 12 s; **25 GiB → 12.8 GiB in 2m2s**; `qemu-img check` clean, no internal snapshots; hashed in 10 s; `export-image` **2m27s** |
| P9b | [`03-import-throwaway.txt`](image/evidence/03-import-throwaway.txt) | `KENNEL_SNAPSHOT_ID=kennel-vm-imptest KENNEL_SSH_KEY=<throwaway>`, the original baseline defined but shut off: four files `OK` in 10 s and the envelope consistent; copied in 26 s; the key volume; defined; reachable after 18 s; the guest's `manifest_ref` equal to the bundle's; the unit's two journal lines; `findings=0`; halted in 12 s; snapshot and sidecar; up again, reachable after 12 s — **import 1m28s** |
| P9c | [`04-keys.txt`](image/evidence/04-keys.txt) | §3's block: the throwaway key accepted, the builder's refused, a new host key, *unchanged* on the second boot; `OVMF_CODE_4M.ms.fd` and a fresh NVRAM chosen by libvirt; a generated MAC |
| P9d | [`05-run-imported.txt`](image/evidence/05-run-imported.txt) | `run` on the import: *run.json names the same manifest*; `pass=10 fail=0`, `VERDICT: PASS -- healthy and walking`; guest 1 s, transfer 2 s, launch 35 s, verify 43 s, walk 7 s |
| P10a | [`02-sweep.txt`](image/evidence/02-sweep.txt) | `Remove-TestVMFiles.ps1 -Prefix @('kennel-vm-imptest','kennel-vm-baseline')`: both gone, only the unrelated `ub26_guest` left |
| P10b′ | [`06-import-default-refused.txt`](image/evidence/06-import-default-refused.txt), [`06-import-default-refused-journal.txt`](image/evidence/06-import-default-refused-journal.txt) | the first attempt at the real import, refused at preflight with nothing written — F25 |
| P10b | [`06-import-default.txt`](image/evidence/06-import-default.txt) | the real import, with this host's Yuruna key, as `kennel-vm-baseline`: **1m23s** — verify 12 s, copy 24 s, first boot 19 s — with the same manifest proof, `findings=0`, and the keyed guest snapshotted |
| P10c | [`07-reset-imported.txt`](image/evidence/07-reset-imported.txt) | `reset` on the imported appliance — the Yuruna sequence, unchanged, with Yuruna's key: **13/13 in 1m22s**, the drift step PASS, `findings=0`, `manifest_ref 78f09058…` |
| P10d | [`08-mvp-imported.txt`](image/evidence/08-mvp-imported.txt), [`mvp-20260910T191420Z/`](image/evidence/mvp-20260910T191420Z/) | `mvp` on the imported appliance: **14/14 in 1m43s**; the run record's `verify.json` `completed`, `pass=10 fail=0` on `PARTIAL_CONDENSING_OSQP`; its `manifest.json` byte-identical to the bundle's `manifest_ref`: True |
| P11 | [`09-tampered.txt`](image/evidence/09-tampered.txt) | two refusals, on a host that holds the imported baseline. The **good** bundle: four files `OK` in 11 s, then *a 'kennel-vm-baseline' baseline already exists on this host … import never replaces one*, with the `Remove-TestVMFiles.ps1` line, exit 1. A **tampered** bundle — one hex digit of the image's line in `SHA256SUMS` flipped (`d515…` → `0515…`), the image itself a hard link to the good one: `kennel-vm-dcf53c5-20260910.qcow2: FAILED`, *the bundle does not match its SHA256SUMS*, exit 1 — and `~/yuruna/vms`, the libvirt domains and the snapshot sidecars compared before and after: **unchanged** |
| P13 | [`10-restore.txt`](image/evidence/10-restore.txt) | `reset`: **13/13 in 1m21s**, `findings=0`, container running, no run applied. The host ends holding the imported appliance as its baseline |

**Import → walking, measured for the first time:** import **1m28s** + `run` **88 s**
= **2m56s**, against s001's 300 s target and 600 s ceiling — on a host that already
had the bundle on local disk, and not counting the one-time copy of 13 GB to get it
there.

## 8. Findings

**F25 — `import` refused an active network, once, and the first explanation was
wrong.** The throwaway import passed its preflight; the real one, 13 s after
`Remove-TestVMFiles.ps1` had swept both domains, stopped at *libvirt network
'default' is not active* ([`06-import-default-refused.txt`](image/evidence/06-import-default-refused.txt)).
The network was active, with autostart on, and nothing had been written — the
refusal did its job, about the wrong thing.

The first theory was a `virsh net-info | grep -q` under `pipefail`: grep exiting at
its first match, `virsh` taking SIGPIPE on a later write, the pipeline failing.
`virsh` does write that output in seven `write()`s, so it was plausible. It did not
survive measurement: 0 false refusals in 300 tries on an idle host and 300 under
sixteen busy loops; and `grep` on this host is **ugrep 7.8.4**, whose `-q` reads a
pipe to EOF — a producer pausing 2 s after the matching line kept the pipeline
alive 2.0 s, status 0. The journal had the answer, at the refusal's second
([`06-import-default-refused-journal.txt`](image/evidence/06-import-default-refused-journal.txt)):

```
16:04:29 libvirtd[1332996]: libvirt version: 10.0.0, package: 10.0.0-2ubuntu8.16 (Ubuntu)
16:04:29 libvirtd[1332996]: hostname: k8-thales
16:04:29 libvirtd[1332996]: End of file while reading data: Input/output error
```

The first two lines are libvirt's log header, not a start: `systemctl` shows that
`libvirtd` (pid 1332996) had been running since 16:01:19, three minutes earlier —
socket-activated, it had exited while the export converted and was started again by
the throwaway import's first `virsh` call. What the journal does show is its first
logged event since then, at the refusal's second: a client connection ending in an
I/O error. `virsh net-info` returned no `Active:` line, and a one-shot check read
nothing as "not active". The cause of the dropped connection is not established;
that it was transient is — the network answered `Active: yes` on every one of the
600 reads afterwards. The preflight now asks up to five times, a second apart, and
reads the whole answer each time. (A second wrong turn, corrected here: the account
first written from the same journal said a new `libvirtd` was *starting* at that
second; its own `start_time` says otherwise.)

## 9. Bypasses and limits

| | Retirement |
|---|---|
| **qcow2/KVM, not OVA/VirtualBox** — the bypass note | an OVA from the same bundle: VMDK + OVF, same manifest and key volume |
| **One machine-id per image.** Every import carries the builder's `/etc/machine-id`, so two imports on one libvirt network share a DHCP DUID. Observed: the import was handed its source's address, `192.168.122.228`, with a new MAC — harmless one at a time, a collision for two at once | s008's two-seat fleet — regenerate the machine-id in the key unit, or run seats on separate hosts |
| **The bundle is not signed.** `SHA256SUMS` proves the bytes arrived intact, not who made them | a detached signature over `SHA256SUMS` with the release |

- **Export trusts the live guest's manifest** (§2.1); `import` is where that trust
  is checked.
- **The guest ISO and `seed.iso` are not shipped**, so an imported appliance
  cannot reinstall itself — it can only `reset` to its import.

## 10. What this feeds

| Issue | What it takes from here |
|---|---|
| s001.firstwalk | *"elapsed time from import"* has a number |
| s008.classroom | *"all N seats share one image checksum"* — `SHA256SUMS` — with the machine-id limit above |
| [#78](https://github.com/alius-git/kennel/issues/78) | the README's import path, and the deck's numbers slide |

---

Last review: 2026-09-10
