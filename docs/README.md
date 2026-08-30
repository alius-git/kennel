# Kennel documentation map

The in-depth documentation lives next to what it describes — the plan corpus in
[`plan/`](../plan/), and an implementation record beside each tool it records in
[`demo/`](../demo/), [`vm/`](../vm/), [`stack/`](../stack/), and
[`kennel_console/`](../kennel_console/). This page is the index.

## Start here

- [`demo/runbook.md`](../demo/runbook.md) — the whole demo in a handful of
  commands: prerequisites, the driver verbs, phase-by-phase expectations.
- [`plan/design.md`](../plan/design.md) — the master design: locked decisions,
  POC topology, application inventory, repository layout.

## Plan — what Kennel is and why

- [`plan/PRFAQ.txt`](../plan/PRFAQ.txt) — the press-release/FAQ vision record.
- [`plan/personas.md`](../plan/personas.md) — who Kennel is for.
- [`plan/applications.md`](../plan/applications.md) — the application ecosystem
  (appliance, console, stack, guides) and shared foundations.
- [`plan/scenarios.md`](../plan/scenarios.md) — the ten verification scenarios
  (s001–s010) the POC must execute.
- [`plan/design.md`](../plan/design.md) — the master design tying it together.
- [`plan/design/`](../plan/design/) — per-application designs
  ([overview](../plan/design/01-overview.md),
  [appliance](../plan/design/02-appliance.md),
  [console](../plan/design/03-console.md),
  [stack](../plan/design/04-stack.md),
  [guides](../plan/design/05-guides.md)) and one sequence design per scenario
  (`seq.s001.firstwalk.md` … `seq.s010.handoff.md`).
- [`plan/prompts.txt`](../plan/prompts.txt) — the verbatim historical prompt
  record, kept as-is.

## Demo — running it end to end

- [`demo/runbook.md`](../demo/runbook.md) — one driver,
  [`demo/tools/kennel-demo.sh`](../demo/tools/kennel-demo.sh), wrapping every
  phase: provision → compose → transfer → launch → verify → walk.
- [`demo/dry-run.md`](../demo/dry-run.md) — the implementation record of the
  by-the-book run: measured timings, frictions found, doc fixes made.
- [`demo/evidence/`](../demo/evidence/) — captured logs, metrics, and
  screenshots from the dry run.

## VM — host baseline and the kennel-vm appliance

- [`vm/host-baseline.md`](../vm/host-baseline.md) — the Yuruna `ubuntu.kvm`
  host baseline: install, pin, patches, unattended-run prep.
- [`vm/guest-sizing.md`](../vm/guest-sizing.md) — the kennel-vm guest sizing
  and definition.
- [`vm/provisioning.md`](../vm/provisioning.md) — provisioning the guest with
  Docker and the pinned dfki-quad stack, via Yuruna sequences.
- [`vm/snapshot.md`](../vm/snapshot.md) — the baseline snapshot: freezing the
  provisioned guest so `reset` returns to it in seconds instead of 35 minutes.
- [`vm/meshcat-exposure.md`](../vm/meshcat-exposure.md) — reaching Meshcat from
  the host browser: the two network hops.

## Stack — running the pinned dfki-quad

- [`stack/launch.md`](../stack/launch.md) — the canonical headless launch
  command set for the go2 sim stack.
- [`stack/mapping.md`](../stack/mapping.md) — how composer choices map onto the
  pin's launch args and YAML keys.
- [`stack/transfer.md`](../stack/transfer.md) — getting a generated run onto
  the container's config paths.
- [`stack/verify.md`](../stack/verify.md) — the CLI walking/health verification
  recipe.
- [`stack/composed-run.md`](../stack/composed-run.md) — the PoC moment: a
  composed config runs the stack and the values take effect.

## Console — the Kennel Console prototype

- [`kennel_console/serve.md`](../kennel_console/serve.md) — serving the
  prototype from the host: one command, no network.
- [`kennel_console/composer-scope.md`](../kennel_console/composer-scope.md) —
  the composer's MVP scope: what is selectable, and why nothing else is.
- [`kennel_console/generate.md`](../kennel_console/generate.md) — generating
  configs the pinned stack accepts.
- [`kennel_console/export.md`](../kennel_console/export.md) — getting the
  generated artifacts out of the browser.

## Upstream

- [`dfki-quad/`](../dfki-quad/) — the vendored upstream DFKI quadruped stack at
  the pinned revision, with [its own README](../dfki-quad/README.md). Kennel
  wraps it; it is never forked.
