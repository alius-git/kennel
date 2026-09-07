# Kennel — house rules

Kennel packages the pinned [DFKI quadruped stack](stack/pin.lock) into a VM
appliance plus a browser console. What it is and why:
[`plan/design.md`](plan/design.md). What to read first:
[`docs/README.md`](docs/README.md).

These are the rules every session works to. They are not new — each one is a
scar from a landed issue, and each links to the record that earned it. Read the
record before deviating from the rule.

## The repo in ten lines

| Path | |
|---|---|
| [`plan/`](plan/) | the corpus — PRFAQ, personas, applications, scenarios, [`plan/design.md`](plan/design.md) and its `design/` diagrams — plus the implementation plans: A–C [`plan/next-goals.md`](plan/next-goals.md), D [`plan/teleop-joystick.md`](plan/teleop-joystick.md), E [`plan/reliability.md`](plan/reliability.md), F [`plan/console-live.md`](plan/console-live.md) |
| [`kennel_console/`](kennel_console/) | the single-file React console, [`kennel_console/serve.py`](kennel_console/serve.py), eight `verify-*.sh` suites (serve, scope, generate, export, send, teleop, dashboard, runs), and the recorded-stack fixtures they replay |
| [`stack/`](stack/) | running the pinned stack: [`stack/launch.md`](stack/launch.md), `transfer/`, `verify/`, `composed-run/tools/` (the `p21-*` tools), `bridge/`, `known-good/` |
| [`vm/`](vm/) | the appliance: [`vm/host-baseline.md`](vm/host-baseline.md), [`vm/provisioning.md`](vm/provisioning.md), [`vm/snapshot.md`](vm/snapshot.md), and the Yuruna sequences under `vm/test/` |
| [`demo/`](demo/) | the driver [`demo/tools/kennel-demo.sh`](demo/tools/kennel-demo.sh), the [runbook](demo/runbook.md), the [dry run](demo/dry-run.md) |
| `dfki-quad/` | the pinned upstream clone — **gitignored, never edited**; read it at the pin with `git show <PIN>:path` |

Driver verbs ([`demo/tools/kennel-demo.sh`](demo/tools/kennel-demo.sh) `help`):

- once per host — `setup`, `provision`
- each session — `up`, `console`, `run`, `teleop [stop]`, `walk [stop]`, `down`, `reset`
- the pieces underneath — `all`, `compose`, `transfer`, `launch`, `verify`, `status`, `snapshot`, `halt`

## The rules

**Records.** Every tool has an implementation record beside it — `vm/*.md`,
`stack/*.md`, `kennel_console/*.md`, `demo/*.md`, indexed by
[`docs/README.md`](docs/README.md). It says what was validated, with the exact
commands, the measured timings, and an `evidence/` directory of transcripts.
Every deviation is marked **bypass** (with its retirement path) or **fix**.
Findings are appended to, never rewritten: see
[`demo/dry-run.md`](demo/dry-run.md) §4 and [`vm/snapshot.md`](vm/snapshot.md) §6.

**Script headers.** Every script opens with a comment block: `# Version:` date,
what it is, **where it runs** (HOST / GUEST / container), usage, and exit codes.
The model is
[`stack/composed-run/tools/p21-launch-from-commands.sh`](stack/composed-run/tools/p21-launch-from-commands.sh)
lines 1–36.

**Knobs are environment variables**, passed through to the tool that defines
them ([`demo/runbook.md`](demo/runbook.md) §4). A flag is only for waiving a
correctness check — `--yes`, `--quiet`.

**Exit codes** `0` / `1` / `2` = passed / an assert failed / could not even
look. A distinct code per failure mode beyond that
([`stack/verify.md`](stack/verify.md) §1, [`vm/snapshot.md`](vm/snapshot.md) §4.2).

**Waits observe the stack, never sleep.** A `sleep N` that stands in for a
readiness check is a defect, not a shortcut — it was wrong at rate 1.0 and wrong
again by 1/rate at any composed rate. Poll a real observable inside a bounded
loop, and measure windows in **sim** seconds, not wall seconds
([`demo/dry-run.md`](demo/dry-run.md) §4.1 "F8 is the finding that justifies the
rule"; [`stack/composed-run.md`](stack/composed-run.md) §3.2, §9.1).

**`set -uo pipefail` only in scripts that never source a ROS setup file.**
`/opt/ros/humble/setup.bash` dereferences `AMENT_TRACE_SETUP_FILES` while unset,
so `set -u` aborts every shell that sources the workspace
([`stack/launch.md`](stack/launch.md) §7 trap 3;
[`stack/verify/kennel-verify.sh`](stack/verify/kennel-verify.sh) lines 25–28 is
the deliberate exception).

**The container source chain is one chain.** Non-interactive `docker exec bash
-c` never reads `.bashrc`, so every container shell must source it explicitly,
and every copy must be identical — a shell that sources
`setup_go2_workspace.bash` instead silently partitions the ROS graph
([`stack/launch.md`](stack/launch.md) §2, §2.1). Canonical copy:
[`stack/known-good/tools/prelude.sh`](stack/known-good/tools/prelude.sh). The
copies that must change with it are named in
[`stack/composed-run.md`](stack/composed-run.md) §9.2.

**Yuruna step `command:` strings** carry no `${…}` — Yuruna substitutes it
first ([`vm/test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml`](vm/test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml)
line 89) — and every `docker inspect` needs `--type container`, because the
image is called `dfki_quad` too and without it the call resolves the image and
exits 0 ([`vm/provisioning.md`](vm/provisioning.md) §5a).

**Never `pkill -f` in the container** without the bracket trick: the pattern
matches the reaping shell's own command line. `pkill -x` needs the name Linux
truncates to 15 chars (`mitcontrollerno`), and does not match `python3`
children at all — match the executable path with a `[.]` in it, as
[`stack/known-good/tools/k13-stop.sh`](stack/known-good/tools/k13-stop.sh) does
([`stack/launch.md`](stack/launch.md) §7 traps 5–6).

**`Test-Config.ps1` gates on 0 FAIL and no finding naming a kennel file** —
never on the PASS/WARN totals, which drift with upstream
([`vm/provisioning.md`](vm/provisioning.md) §4.3;
[`demo/dry-run.md`](demo/dry-run.md) F1).

**The console never fetches off-host.** The suites assert zero non-localhost
requests and would catch a regression ([`kennel_console/serve.md`](kennel_console/serve.md),
[`kennel_console/export.md`](kennel_console/export.md) §4). Its exported bytes
come from the emitters, never from the DOM.

**The console names only commands that exist**, and only topics the pin
publishes. A panel may name a `kennel-demo.sh` verb or one of the three
`ros2 launch` lines its own `commands.txt` generates — nothing else. Five panels
once named four `kennel_*` packages that never existed
([`kennel_console/dashboard.md`](kennel_console/dashboard.md) §1.2;
[`kennel_console/verify-dashboard.sh`](kennel_console/verify-dashboard.sh) group 3 is the check).

**A number a suite cannot read is a number nobody should believe.** Canvas
panels carry a DOM strip with the same values, and every live assertion is made
against what a server recorded — a viewer's access log, a bridge's op log — not
against a variable read back out of the page under test
([`kennel_console/dashboard.md`](kennel_console/dashboard.md) §4).

**Append, never reorder, in the console.** The suites click by text order, so
inserting a control ahead of an existing one breaks them
([`kennel_console/send.md`](kennel_console/send.md) §5 →
[`kennel_console/export.md`](kennel_console/export.md) §5).

**Read the pin with `git show <PIN>:path`**, never from the working tree of
`dfki-quad/` — the clone can be off-pin, and addressing the blob by SHA is what
makes the stock-file comparison trustworthy
([`stack/transfer.md`](stack/transfer.md) §3;
[`kennel_console/verify-generate.py`](kennel_console/verify-generate.py) line 86;
[`demo/dry-run.md`](demo/dry-run.md) F4).

## The method

One issue = one branch = one PR. The issue body opens with "Step N of 26" and
its dependencies; the milestone description is the ordering. A PR lands the
implementation **and** its record and evidence together, and its body carries
what was measured, what deviated, and what is still open — see
[#53](https://github.com/alius-git/kennel/pull/53) and
[#59](https://github.com/alius-git/kennel/pull/59) for the shape. Prove the
things you did not touch are still green rather than asserting it.
