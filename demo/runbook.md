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

```bash
# once per host, ~33 min — creates the kennel-vm guest from clean
demo/tools/kennel-demo.sh provision

# the demo itself, ~6 min — compose → transfer → launch → verify → walk
demo/tools/kennel-demo.sh all
```

`all` ends with the robot trotting and the Meshcat URL printed. Open it, watch
the walk, then:

```bash
demo/tools/kennel-demo.sh walk stop     # return the gait to STAND
demo/tools/kennel-demo.sh down          # stop the stack (container stays up)
```

That is the entire demo. Once a guest exists, `provision` never needs to run
again — `all` is repeatable on its own.

## 2. Prerequisites (once per host)

From a fresh clone of this repo, in order. The full context for each step is
[`vm/host-baseline.md`](../vm/host-baseline.md); the commands are collected here
so the runbook stands alone.

```bash
# 1. Host baseline (host-baseline.md §2): installs KVM/libvirt + tools and
#    clones the framework to ~/git/yuruna. Then pin it and prep unattended runs.
bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
# log out/in afterwards -- it adds you to the libvirt and kvm groups
cd ~/git/yuruna && git checkout 2026.08.04
pwsh ~/git/yuruna/host/ubuntu.kvm/Enable-TestAutomation.ps1

# 2. The three Yuruna patches (host-baseline.md §6.4). `provision` refuses to
#    run without them -- it checks in seconds rather than failing 20 min in.
git -C ~/git/yuruna apply /path/to/kennel/vm/patches/yuruna-save-ocrsidecar-export.patch
git -C ~/git/yuruna apply /path/to/kennel/vm/patches/yuruna-ssh-autoinstall-confirm.patch
git -C ~/git/yuruna apply /path/to/kennel/vm/patches/yuruna-no-password-expiry.patch

# 3. The ~3.2 GB guest ISO, once (~9 min cold; NOT counted in provision's 33 min).
cd ~/git/yuruna/host/ubuntu.kvm/guest.ubuntu.server.24 && pwsh ./Get-Image.ps1
```

`google-chrome` on the host is needed only for the scripted compose (it is the
operator's hands) — §3.2 shows the by-hand alternative.

Copying the kennel sequences and guest script into the Yuruna clone
([`provisioning.md` §4.2](../vm/provisioning.md)) is **done by `provision`
itself** on every run — it is the step whose omission fails twenty minutes late
(dry run F3), so the driver never leaves it to memory.

## 3. Phase by phase

Each verb can be run on its own; `all` chains the last five. Timings are the
single measured sample from [`dry-run.md` §2](dry-run.md).

| Command | What it wraps | Success looks like | Time |
|---|---|---|---|
| `kennel-demo.sh provision` | Yuruna sequence `workload.guest.ubuntu.server.24.kennel.stack.ssh` ([`vm/provisioning.md` §4.3](../vm/provisioning.md)) | **28/28 PASS**, exit 0 | ~33 min |
| `kennel-demo.sh compose` | [`p22-console-demo.sh`](tools/p22-console-demo.sh) — serves the console if nothing else is, makes both choices in the UI, clicks Generate run, unpacks the download | `run folder  ~/kennel-runs/run-<stamp>` | ~1 min |
| `kennel-demo.sh transfer` | [`kennel-transfer.sh apply`](../stack/transfer/kennel-transfer.sh) on the newest run folder | four matching checksum columns, exit 0 | ~1 min |
| `kennel-demo.sh launch` | [`p21-launch-from-commands.sh`](../stack/composed-run/tools/p21-launch-from-commands.sh) on the guest — the three shells of `commands.txt`, waited on **by observing the stack**, never by sleeping ([F8](dry-run.md)) | `all three are up`, controller reached "Starting controller" | ~2 min |
| `kennel-demo.sh verify` | [`kennel-verify.sh`](../stack/verify/kennel-verify.sh) on the guest, with `--expect-solver` and the launch log wired in | `pass=10 fail=0`, exit 0 | ~1 min |
| `kennel-demo.sh walk` | [`verify-meshcat-host.sh`](../vm/test/verify-meshcat-host.sh) + [`p21-trot-hold.sh start`](../stack/composed-run/tools/p21-trot-hold.sh) | the Meshcat URL, robot trotting until `walk stop` | ~1 min |

Also there when needed:

```bash
kennel-demo.sh status        # what run is applied + is Meshcat reachable
kennel-demo.sh walk stop     # STAND, target zeroed
kennel-demo.sh down          # tear the three launches down inside the container
stack/transfer/kennel-transfer.sh restore-stock    # put the stock YAMLs back
```

### 3.1 What gets composed

By default the composition proven in [`dry-run.md` §1](dry-run.md): `mpc_solver`
= `PARTIAL_CONDENSING_OSQP` (controller YAML) and `simulator_realtime_rate` =
`0.75` (simulator YAML), map left at stock — obstacle terrain is known not to
walk ([`transfer.md` §6.3](../stack/transfer.md)). Override with knobs (§4).
`verify` expects the same solver it composed, so the two stay consistent
automatically.

### 3.2 Composing by hand instead

The scripted compose is a stand-in for hands, not for the console. To do it
yourself:

```bash
python3 -m http.server 8000 --directory kennel_console
```

Open `http://localhost:8000/Kennel%20Console.dc.html`, pick the solver and the
realtime rate, click **Generate run**, unzip the download, then:

```bash
demo/tools/kennel-demo.sh transfer ~/Downloads/run-<stamp>
```

## 4. Knobs

All optional, all environment variables — the driver passes them through to the
tools that define them.

| Knob | Default | Meaning |
|---|---|---|
| `KENNEL_SOLVER` | `PARTIAL_CONDENSING_OSQP` | composed **and** expected `mpc_solver` |
| `KENNEL_RATE` | `0.75` | composed `simulator_realtime_rate` |
| `KENNEL_DEMO_OUT` | `~/kennel-runs` | where compose unpacks run folders |
| `KENNEL_CONSOLE_PORT` | `8000` | port compose serves the console on |
| `YURUNA_DIR` | `~/git/yuruna` | framework checkout, for `provision` |
| `KENNEL_GUEST_IP` | *(discovered)* | skip the libvirt lease lookup |
| `KENNEL_SSH_KEY` | `~/git/yuruna/test/status/ssh/yuruna_ed25519` | guest SSH key |

## 5. Troubleshooting

Symptoms the dry run already met, plus the driver's own failure modes:

| Symptom | Read this |
|---|---|
| Gate PASS/WARN counts differ from the docs | Expected — read the findings, not the totals ([`provisioning.md` §4.3](../vm/provisioning.md), F1) |
| Yellow `WARNING: fetch-and-execute fallback ... differs from HEAD` during provision | Benign, caused by the doc'd copy step ([`provisioning.md` §4.2](../vm/provisioning.md), F5) |
| `compose` fails asking for google-chrome | Use the by-hand path (§3.2) |
| `transfer` exits 3 (pin mismatch) | The run folder was generated against another pin — re-export, or `--allow-pin-mismatch` via `kennel-transfer.sh` directly |
| `could not discover the guest IP` | `virsh list --all` — is the guest running? Or set `KENNEL_GUEST_IP` |
| `walk` says Meshcat is not reachable | The simulator is not running (`launch` first); exit codes decoded in [`meshcat-exposure.md` §7](../vm/meshcat-exposure.md) |
| Trot tool: `timeout: failed to run command 'ros2'` | The stack was launched without the launcher, so `/tmp/p21-env.sh` is missing — recipe in [`composed-run.md` §2](../stack/composed-run.md) (F9) |
| `verify` exits 1 vs 2 | 1 = stack up but not healthy/walking (collect logs); 2 = could not even look ([`verify.md` §1](../stack/verify.md)) |

## 6. Relation to the dry run

[`dry-run.md`](dry-run.md) deliberately did **not** use the automation you are
using now — its job was to test the written instructions, and two of its five
findings exist only because it obeyed the prose. This runbook is the opposite
artifact: the operator-friendly path built on the scripts the dry run vindicated.
The waits that the prose got wrong (F8) are exactly what
`p21-launch-from-commands.sh` does right, which is why `launch` goes through it.
