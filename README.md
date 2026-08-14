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

Prerequisites are once per host — Yuruna baseline, three patches, guest ISO —
collected in [`demo/runbook.md` §2](demo/runbook.md). Then, from the repo root:

```bash
demo/tools/kennel-demo.sh provision   # once per host, ~33 min — creates the kennel-vm guest
demo/tools/kennel-demo.sh all         # the demo, ~6 min — ends with the Meshcat URL
```

Open the printed Meshcat URL, watch the robot trot, then:

```bash
demo/tools/kennel-demo.sh walk stop   # return the gait to STAND
demo/tools/kennel-demo.sh down        # stop the stack (container stays up)
```

Once a guest exists, `provision` never needs to run again — `all` is
repeatable on its own. Each phase, what it wraps, and what success looks like:
[`demo/runbook.md`](demo/runbook.md).

## Documentation

The in-depth documentation is indexed in [`docs/`](docs/README.md):

- [Plan](docs/README.md#plan--what-kennel-is-and-why) — PRFAQ, personas,
  applications, the ten verification scenarios, and the master design.
- [Demo](docs/README.md#demo--running-it-end-to-end) — the runbook, the
  recorded dry run, and its evidence.
- [VM](docs/README.md#vm--host-baseline-and-the-kennel-vm-appliance) — host
  baseline, guest sizing, provisioning, Meshcat exposure.
- [Stack](docs/README.md#stack--running-the-pinned-dfki-quad) — launch,
  mapping, transfer, verify, and the composed run.
- [Console](docs/README.md#console--the-kennel-console-prototype) — serving,
  composer scope, config generation, export.
