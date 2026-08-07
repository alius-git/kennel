# The demo, run from the written steps alone

Implementation record for
[issue #22](https://github.com/alius-git/kennel/issues/22) — one operator
performs the [tracking issue](https://github.com/alius-git/kennel/issues/1)'s
demo script start to finish, from a clean state, from the written instructions
only, timed, with evidence.

Every other issue built the demo. This one **tests the instructions for it**, so
its product is not a green run — it is the list of places the written steps were
insufficient, and the fixes. Pin:
`dcf53c596339afd45b82f12c54b1e93e8273c2f4` ([`stack/pin.lock`](../stack/pin.lock)).

Run 2026-08-07 on `kennel-vm`. Evidence in [`demo/evidence/`](evidence/).

> **The rule this run was conducted under.** The repo already contains scripts
> that perform the whole demo — [`k14-stack-up.sh`](../stack/verify/tools/k14-stack-up.sh),
> [`p21-launch-from-commands.sh`](../stack/composed-run/tools/p21-launch-from-commands.sh).
> Using them would have tested the automation and told us nothing about the
> docs. **A repo script was used only where the written step *is* "run this
> script"** — the Yuruna sequence, `kennel-transfer.sh`, `verify-meshcat-host.sh`,
> `kennel-verify.sh`. Everything else was performed from the prose. Two of the
> five real findings below exist *only* because of that rule.

## 1. The result

The demo completed. The robot walked on a console-composed config, both composed
values were independently proven in the running stack, and **five written steps
needed fixing** — one of them a case of the console generating advice its own
composer invalidates.

| Demo-script step | Outcome |
|---|---|
| 1 · Yuruna provisions kennel-vm from clean | **28/28 PASS**, exit 0, no manual steps |
| 2–3 · compose + Generate run | clean; both choices took |
| 4 · push YAMLs to the container config paths | **failed on the first attempt** (F6) |
| 5 · run the generated launch commands | **the written wait is wrong** (F8) |
| 6 · Meshcat from the host browser, trot | clean; tooling gap found (F9) |
| 7 · assert over SSH | `pass=10 fail=0` |
| 8 · unattended Yuruna sequence | out of scope — #24/#25 |

The composition, chosen to be provable twice over from independent files:

| Choice | Stock | Composed | Proven by |
|---|---|---|---|
| `mpc_solver` (controller YAML) | `PARTIAL_CONDENSING_HPIPM` | **`PARTIAL_CONDENSING_OSQP`** | check 10 — running param *and* launch log |
| `simulator_realtime_rate` (simulator YAML) | `1.0` | **`0.75`** | measured **0.751**; Drake's HUD reads **76 rtr%** |
| map | flat plane | *(stock)* | [`transfer.md` §6.3](../stack/transfer.md) — obstacle terrain does not walk |

`0.75` rather than #21's `0.5` on purpose: it makes every artifact in
[`evidence/run-20260807T153752Z/`](evidence/run-20260807T153752Z/) provably from
*this* run rather than a copy of #21's.

## 2. Timings

All durations from `CLOCK_MONOTONIC_RAW`. This matters here more than it
usually would — see F2 — and the **ratio column is the evidence that the
numbers are quotable**: the adjusted clock tracked the raw one to 1.000 in every
phase, so the ~10 % understatement [`provisioning.md` §6a](../vm/provisioning.md)
warns about is not present in this run.

| Phase | Duration | What it covers |
|---|---|---|
| provision | **32m39s** | `Remove-TestVMFiles` → 28/28 PASS. Autoinstall 8m53s, sizing asserts 12s, stack build 24m57s (of which the image + colcon step is 22m00s) |
| compose | **43s** | serve the console, make both choices, Generate run, unzip |
| transfer | **1m02s** | `kennel-transfer.sh apply`, including the failed first attempt |
| launch | **2m09s** | three shells from `commands.txt`, to a stack publishing `/clock` |
| walk | **1m22s** | Meshcat URL, commanded trot, screenshot |
| verify | **55s** | `kennel-verify.sh` ten checks |
| **TOTAL** | **38m50s** | |

Raw marks in [`evidence/00-timings.txt`](evidence/00-timings.txt); clock
provenance in [`evidence/00-host-clock.txt`](evidence/00-host-clock.txt).

**Reading these honestly.** One sample, one host, warm ISO already fetched (the
3.2 GB image download is a separate prerequisite and is *not* in the 32m39s).
The provision phase dominates so completely that everything after it — the part
a person actually interacts with — is **6m11s total**. That is the number worth
quoting to #27: once a guest exists, the demo is a six-minute exercise.

## 3. What is delivered

| Artifact | Purpose |
|---|---|
| [`demo/tools/p22-clock.sh`](tools/p22-clock.sh) | Phase timer on `CLOCK_MONOTONIC_RAW`, plus a `ratio` verb that proves the clock before it is trusted |
| [`demo/tools/p22-console-demo.sh`](tools/p22-console-demo.sh) | Operator stand-in for steps 2–3 (deviation D1) |
| [`demo/evidence/`](evidence/) | Transcripts, launch logs, both screenshots, the run folder, the raw friction notes |

## 4. The friction log

The product of this issue. Raw notes as taken during the run:
[`evidence/08-friction.txt`](evidence/08-friction.txt).

| # | Symptom | Where the written step fell short | Disposition |
|---|---|---|---|
| **F1** | Gate returned 33 PASS / 5 WARN | [`provisioning.md` §4.3](../vm/provisioning.md) + [`guest-sizing.md` §3.3](../vm/guest-sizing.md) promise "34 PASS / 4 WARN". The extra WARN is *yuruna-project* drift, which self-clears | **Fixed** — both now state the invariant (0 FAIL, no kennel finding) and say why counts must not be gated on |
| **F2** | Docs say durations here are ~10 % understated | [`provisioning.md` §6a](../vm/provisioning.md) treats one defect where there are two. The **rate** defect has cleared; the **offset** (now 313 s) has not | **Fixed** — new §6a.1 separates them, marks it latent not fixed, and unblocks [`guest-sizing.md` §5.4](../vm/guest-sizing.md)'s two empty rows |
| **F3** | — | §4.2's copy step fails ~20 min late if skipped | Noted for #27 |
| **F5** | Alarming yellow `WARNING: fetch-and-execute fallback ... differs from HEAD`, twice, on a 28/28 PASS run | Caused by §4.2's own copy step; nothing said so | **Fixed** — documented beside the step that causes it |
| **F6** | `kennel-transfer.sh <run-folder>` → `expected a mode` | [`transfer.md` §4](../stack/transfer.md) is titled **"Running it"** and opens on "4.1 Knobs". The invocation is back in §1 | **Fixed** — usage block now opens §4 |
| **F7** | Metrics file describes a 57 s no-op with no peak-RAM line | The sequence runs the script **twice** and the idempotency re-run overwrites the build's metrics. §6 promises numbers the documented sequence destroys | **Fixed** — trap box in §6 with the two ways to re-measure |
| **F8** | At the written 10 s mark the simulator did not exist yet | `commands.txt` says "wait ~10 s"; wrong at rate 1.0 (ignores startup) and wrong again by 1/rate at any composed rate | **Fixed** in [`launch.md` §1](../stack/launch.md); **filed** as [#44](https://github.com/alius-git/kennel/issues/44) |
| **F9** | `p21-trot-hold.sh` → `timeout: failed to run command 'ros2'` | It sources `/tmp/p21-env.sh`, written only by `p21-launch-from-commands.sh`. Header claims it needs only "an already-running stack" | **Fixed** in [`composed-run.md` §2](../stack/composed-run.md) with a reconstruction recipe; **filed** as [#45](https://github.com/alius-git/kennel/issues/45) |
| **F4** | — | *Retracted.* I suspected the off-pin nested clone would corrupt `verify-generate.sh`'s stock comparison. It does not — `verify-generate.py:86` uses `git show <PIN>:path`, addressing the blob by SHA. Kept in the raw notes because it is the obvious worry about bypass #9 and the answer is "already handled" | No action |

### 4.1 F8 is the finding that justifies the rule

Block 3 of the console's generated `commands.txt` carries the comment
`# 3 · MIT controller — wait ~10 s for the robot to settle first`. Followed
literally, at the 10-second mark:

```
--- sim log tail ---
[simulator-1] [INFO] [drake_simulator]: Joint [30]: base_link
--- topics ---            (no /clock, no /quad_state, no /joint_cmd)
--- sim clock ---         (nothing)
```

The simulator was still enumerating joints. Starting the controller there would
have failed outright — not subtly, not "on a robot still falling", but against a
graph with no state source at all.

Two defects, and the repo only knew about one:

- **The advice is wall-clock, and the console lets you compose the rate that
  invalidates it.** At 0.75 the settle costs 13.3 wall seconds; at 0.5, 20.
  [`composed-run.md` §3.2](../stack/composed-run.md) documents exactly this, and
  #21 solved it by waiting in **sim** seconds — but that fix lives in
  `p21-launch-from-commands.sh`, **not in the file the console generates**.
- **Even at rate 1.0 the number is too small**, because it budgets for the
  settle and not for simulator startup.

It survived four issues because every one of them launched through a script that
waits on observation rather than obeying the comment. #13 established the
commands by hand; #14 and #20 drove them through a hand-written copy; #21 ran
the generated file but through a launcher that ignores its advice and waits on
`/clock`. **The comment itself had never been obeyed by anything.** That is what
"run it from the written steps" is for.

## 5. Deviations

### D1 — the operator is an agent, so the clicks are scripted

Steps 2–3 ran through [`p22-console-demo.sh`](tools/p22-console-demo.sh):
headless Chrome over CDP, same controls, same clicks.

| | Human | Here |
|---|---|---|
| Serving the console | `python3 -m http.server` | **identical** — the script refuses to start if the operator has not served it |
| Choosing solver / rate | click, type | scripted events on the same `<select>` / `<input>` |
| Generate run | click | scripted click on the same element |
| The bytes | browser download | **identical** — real download, real archive, unzipped from disk |

Nothing is injected into the config and nothing is read out of a JS variable and
written to disk: [`export.md` §2.1](../kennel_console/export.md) makes "the bytes
come from the emitters" a property of the console, and the only way to keep
testing it is to touch nothing but the UI. Non-localhost DNS was blackholed with
the same flags [`verify-export.sh`](../kennel_console/verify-export.sh) uses, so
the demo cannot quietly depend on the network.

**Where this is weaker than a human.** It cannot report that a control was hard
to find, mislabelled, or visually ambiguous — the class of friction a UI dry run
is best at. [`evidence/02-console-compose.png`](evidence/02-console-compose.png)
is committed so a reader can judge the layout, but #27's "someone who has not
touched the project" validation still needs a person.

Building and debugging the stand-in happened **before** the timed run and is in
no phase. A human's hands do not need debugging, and bugs found while writing it
are not doc friction and are not in the log.

### D2 — the three launch terminals are three SSH sessions

Each block was piped into its own `docker exec -i dfki_quad bash` over its own
connection, logging to its own file — the shape three terminal windows give,
minus the ability to notice something scrolling past.

`p21-launch-from-commands.sh` was deliberately **not** used. It is the right
tool and #21 proved it works, but it asserts the block structure and waits on
the stack in sim time, which is precisely the mistake F8 is about. Running it
would have hidden the finding.

### D3 — one recovery, recorded rather than smoothed over

After F8 the controller could not be started on the written schedule. Rather
than retry blindly I waited for `/clock` and `/quad_state` to appear (the stack
reached sim 39.26 s), then started block 3. The launch phase timing therefore
reflects **the working procedure, not the written one** — the written one does
not produce a running stack at all.

## 6. Evidence

| File | What it proves |
|---|---|
| [`00-host-clock.txt`](evidence/00-host-clock.txt) | The clock was verified sound *before* any timing was taken |
| [`00-timings.txt`](evidence/00-timings.txt) | Raw phase marks, all three clocks per mark |
| [`01-provision.txt`](evidence/01-provision.txt) | 28/28 PASS from a destroyed guest, exit 0 |
| [`01b-provisioning-metrics.txt`](evidence/01b-provisioning-metrics.txt) | F7 — the clobbered metrics, as found |
| [`02-compose.txt`](evidence/02-compose.txt) · [`02-console-compose.png`](evidence/02-console-compose.png) | Both choices taking, in the UI and in the generated panes |
| [`run-20260807T153752Z/`](evidence/run-20260807T153752Z/) | The run folder exactly as downloaded |
| [`04-transfer.txt`](evidence/04-transfer.txt) | F6's failed attempt, then four matching checksum columns |
| [`05-launch-logs/`](evidence/05-launch-logs/) | The three shells' output, including `Set osqp linear system solver to qdldl` |
| [`06-meshcat.txt`](evidence/06-meshcat.txt) · [`07-meshcat-walking.png`](evidence/07-meshcat-walking.png) | Reachable URL from the written recipe; robot upright mid-stride, HUD at 76 rtr% |
| [`09-verify.txt`](evidence/09-verify.txt) | `pass=10 fail=0`, OSQP and 0.751 both measured |
| [`08-friction.txt`](evidence/08-friction.txt) | The notes as taken, including the retraction |

## 7. Limits

- **One run, one host, one operator.** The timings are a single sample. #25 is
  where "green twice consecutively" lives.
- **One composition.** OSQP + 0.75 on the flat plane. Obstacle terrain is still
  known not to walk and was not retried.
- **Step 8 not covered** — the unattended sequence is #24/#25. Said plainly so
  the record is not read as a clean sweep.
- **The UI-friction question is half-answered** — see D1.
- **The 3.2 GB ISO fetch is excluded** from every number here; it is a
  prerequisite ([`host-baseline.md` §6.7](../vm/host-baseline.md)), ~9 min when
  cold.

## 8. What this feeds

- [#27](https://github.com/alius-git/kennel/issues/27) — the quickstart. The
  timings in §2, the F-rows in §4, and the "six minutes once a guest exists"
  framing are its raw material; F3 and F5 are troubleshooting entries.
- [#28](https://github.com/alius-git/kennel/issues/28) — F8 and F9 are filed as [#44](https://github.com/alius-git/kennel/issues/44) and [#45](https://github.com/alius-git/kennel/issues/45).
- [#25](https://github.com/alius-git/kennel/issues/25) — F8 is a live hazard for
  the unattended sequence, which must wait on observation, not on a sleep.
- [#1](https://github.com/alius-git/kennel/issues/1) — exit criteria 1, 2 and 3
  are met by this run; 4 and 5 belong to #25 and #26.
