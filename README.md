# kennel

Kennel — 2026 Internship — Thales Andrade Soares

Kennel packages the [DFKI quadruped stack](dfki-quad/) (Go2, ROS 2 + Drake)
into a classroom-ready appliance: a pinned VM that runs the simulation, plus
the **Kennel Console**, a browser UI that composes experiments into exact
configs the stack accepts. Compose a run in the browser, transfer it into the
VM, launch the stack, verify it walks, and watch it in Meshcat — with the
upstream stack wrapped at a pinned revision, never forked. The full picture is
in [`plan/design.md`](plan/design.md).

## Quick start

**New here?** [`guides/first-run.md`](guides/first-run.md) is the checklist —
eight steps to a robot walking under your command, and the console serves it
under **Guides**.

One prerequisite is yours: the [Yuruna host
installer](demo/runbook.md), then a re-login. `setup` does the rest — the
release checkout, the three patches, the config, the guest ISO, the gate
([`demo/runbook.md` §2](demo/runbook.md)). From the repo root:

```bash
demo/tools/kennel-demo.sh setup       # once per host — checks and does the prerequisites
demo/tools/kennel-demo.sh provision   # once per host, ~35 min — creates the kennel-vm guest
demo/tools/kennel-demo.sh console     # compose a run in the browser, click "send to kennel-runs"
demo/tools/kennel-demo.sh run         # the newest run, into the VM and walking — ~5 min
demo/tools/kennel-demo.sh down        # stop the stack (container stays up)
```

The first two are once per host. After that the loop is the last three, and
`run` asks nothing of you: it finds the run you just composed — written straight
into `~/kennel-runs` by the console's **send** button, or the `.zip` still
sitting in `~/Downloads`, whichever is newer — starts the guest if it is powered
off, applies the run, launches the stack, verifies it, and prints the Meshcat URL
with the robot already trotting.

```bash
demo/tools/kennel-demo.sh teleop      # drive it yourself: a joystick in the console
demo/tools/kennel-demo.sh walk stop   # return the gait to STAND
demo/tools/kennel-demo.sh reset       # or: back to a clean guest in ~90 s
demo/tools/kennel-demo.sh all         # the same demo, composing the run for you (unattended)
```

`teleop` turns the console's Interventions joystick into a real one: it starts
the rosbridge that has been sitting unused in the pinned image, hands the
browser its URL, and the stick then publishes `/quad_control_target` at 20 Hz —
gait picker, STAND and E-STOP beside it
([`stack/bridge.md`](stack/bridge.md), [`kennel_console/teleop.md`](kennel_console/teleop.md)).

`provision` ends by freezing the guest as a **baseline snapshot**, so no mistake
ever costs 35 minutes again: `reset` returns to it in about ninety seconds and
proves the guest came back intact ([`vm/snapshot.md`](vm/snapshot.md)). Each
phase, what it wraps, and what success looks like:
[`demo/runbook.md`](demo/runbook.md).

## Documentation

The in-depth documentation is indexed in [`docs/`](docs/README.md):

- [Plan](docs/README.md#plan--what-kennel-is-and-why) — PRFAQ, personas,
  applications, the ten verification scenarios, and the master design.
- [Demo](docs/README.md#demo--running-it-end-to-end) — the runbook, the
  recorded dry run, and its evidence.
- [VM](docs/README.md#vm--host-baseline-and-the-kennel-vm-appliance) — host
  baseline, guest sizing, provisioning, the baseline snapshot, Meshcat exposure.
- [Stack](docs/README.md#stack--running-the-pinned-dfki-quad) — launch,
  mapping, transfer, verify, and the composed run.
- [Console](docs/README.md#console--the-kennel-console-prototype) — serving,
  composer scope, config generation, export, and the send-to-host path.
