# Kennel — Plan E: the reliability step (#60 · #52 · #45), one PR

Steps 1–3 of milestone [*Finish the system*](https://github.com/alius-git/kennel/milestone/2),
written like plans A–D (`next-goals.md`, `teleop-joystick.md`) so an agent can
implement them on one branch without re-deriving the repo. Everything in §0 was
checked on **2026-09-06**.

| Step | Issue | One line |
|---|---|---|
| 1 | [#60](https://github.com/alius-git/kennel/issues/60) | house rules into `CLAUDE.md`, the stray files committed, merged branches gone, #27 closed |
| 2 | [#52](https://github.com/alius-git/kennel/issues/52) | the launcher returns when the **six-node graph is complete**, not when one log line appears |
| 3 | [#45](https://github.com/alius-git/kennel/issues/45) | the p21 tools **build their own ROS env** and name what they need, instead of silently requiring the launcher |

**One branch, one PR, closing all three.** That is the maintainer's call for this
step; the milestone's default is one issue per PR, and the PR body says so
(§5.1). The order is fixed: 1 first — `CLAUDE.md` is what steps 2–3 are held to,
and the tree must be clean before the cold-run protocol starts dirtying it; then
2; then 3, whose validation reuses the launched stack that 2 leaves behind.

Budget: roughly one hour of live-guest time (§3.3 + §4.5), the rest is editing.

---

## 0. Ground truth the implementer must know

**Repo.** `main` at `b98aa41`. The working tree is **not** clean:

| Path | State | What it is |
|---|---|---|
| `.gitignore` | modified | three lines ignoring `slides/node_modules/`, `slides/dist/`, `slides/.slidev/` |
| `vm/snapshot/evidence/15-provision-persisted.txt` | modified, +94 lines | the completed transcript PR #53 promised "as a follow-up commit"; its tail reads `conds.: command not found … EXIT=1` |
| `plan/next-goals.md` | untracked | plans A–C, all landed (#51, #54, #56) |
| `slides/` | untracked | Slidev deck: `slides.md`, `package.json`, `package-lock.json`, `public/img/*.png` ×9 — **every PNG is byte-identical to a render already in the repo** (`kennel_console/*-render.png`, `demo/evidence/…`, `stack/bridge/evidence/05-…`), so git stores no new blobs |

`bash -n demo/tools/kennel-demo.sh` passes. Nine local branches, **all merged
into `main`** (asserted with `git branch --merged main`, none in `--no-merged`):
`console/19-export console/56-send-to-host demo/22-dry-run demo/27-runbook
demo/54-fewer-commands stack/20-transfer stack/21-composed-run
teleop/58-virtual-joystick vm/51-baseline-snapshot`; four of them are already
`gone` upstream. No `CLAUDE.md` exists. #27 is open, in the MVP milestone.

**Host.** Yuruna at `~/git/yuruna`, tag `2026.08.04`. `google-chrome`, `python3`,
`virsh` present. The six console suites need only Chrome and Python (no VM);
`verify-generate.sh`'s stock-file group needs the gitignored `dfki-quad/` clone,
which is present.

**Guest.** Domain `kennel-vm-baseline` is **running**, lease `kennel-vm` at
`192.168.122.32` (leases expire; every driver verb rediscovers). The snapshot
`kennel-vm-baseline` (2026-08-30 15:54:23) exists, so `kennel-demo.sh reset`
works — and `reset` is the **cold-container generator** #52's validation needs
(no `--restart` policy, by design: after every revert the container is
`docker start`ed seconds before the stack launches). Whether a stack is up right
now is unknown: `kennel-demo.sh status` first.

**The race (#52), precisely.** `stack/composed-run/tools/p21-launch-from-commands.sh`
starts shell 3 (`start_block 3 ctrl`, line 176), loops until `Starting controller`
appears in `/tmp/p21-ctrl.log` (177–186), and returns 0 (189). `joy_to_target.py`
is launched by that same shell but is a separate `python3` process; nothing waits
for it. `stack/verify/kennel-verify.sh` check 1 (lines 211–259) then samples
`ros2 node list` **once** and wants exactly six nodes:

```
/drake_simulator /joy_linux_node /joy_to_target /leg_driver /mit_controller_node /safe_start_launcher
```

Two cold-container reproductions are on record (`vm/snapshot/evidence/10-all-after-reset.txt`,
`16-all-on-cold-provisioned.txt`); `verify` re-run alone was 10/10 both times
(`11-…`, `17-…`); `vm/snapshot.md` §6 F5 measured *green 2 of 4* after `reset`.
The same file has one more plain wait: `sleep 15` after the leg driver (line 173).

**The coupling (#45), precisely.** `p21-trot-hold.sh:34`:
`in_ctr() { sudo docker exec "$CONTAINER" bash -c "source /tmp/p21-env.sh >/dev/null 2>&1; $1"; }`.
That file is written by the launcher (lines 121–125) as shell 1 of `commands.txt`
minus its `ros2 launch` line — which is `stack/launch.md` §2's chain verbatim, i.e.
`stack/known-good/tools/prelude.sh`. Missing file → silent → `ros2: No such file`.
Who sources `/tmp/p21-env.sh` today:

| Tool | Runs on | Behaviour when the file is absent |
|---|---|---|
| `p21-launch-from-commands.sh` | GUEST | *writes* it |
| `p21-trot-hold.sh` | GUEST | silent failure — **the bug** |
| `p21-prove-realtime-rate.sh:44–50` | GUEST | falls back to a **partial** chain (no unitree overlay, no Drake exports, no `ROS_PACKAGE_PATH`) |
| `stack/bridge/kennel-bridge.sh:63,105` | GUEST | explicit exit 2, but the check *conflates* "no env file" with "no stack launched" |
| `p21-meshcat-shot.sh` | **HOST** | **never sources it** — the issue's "same review" finds *different* undeclared preconditions (§4.3) |

`kennel-verify.sh` carries its own copy of the chain (stage 2, ~lines 146–157)
with the comment "kept identical to `prelude.sh` — change both together": that is
the house precedent for copies, and the one this plan follows.

**Read first.** `plan/next-goals.md` §0 (the house rules), `demo/dry-run.md` §4.1
(F8, the rule this step enforces), `stack/launch.md` §1.1, §2, §7,
`stack/composed-run.md` §2–§3, `vm/snapshot.md` §6 F5, `stack/bridge.md` §3–§4,
and PR #53 / #59's bodies for the PR shape.

---

## 1. Shape of the work

- Branch `stack/60-reliability` from `main`.
- Four commits, in this order, each in the house form `<type>(<area>): <what> (#N)`:
  1. `chore(repo): house rules in CLAUDE.md, the stray files of the last chain committed (#60)` — includes this plan file.
  2. `fix(stack): the launcher waits for the six-node graph, not for one log line (#52)`
  3. `fix(stack): the p21 tools build their own env and name what they need (#45)`
  4. `docs(stack): record the reliability pass — cold-run evidence, corrected preconditions (#52, #45)`
- The non-commit parts of #60 (branch deletion, `git remote prune`, closing #27)
  happen on the host while on the branch; the PR body reports them.
- Every touched script gets its `# Version:` date bumped and its header kept
  truthful (what, where it runs, usage, exit codes).
- **Never sleep to wait.** Poll intervals inside a bounded loop that observes the
  stack are fine (the launcher already does this); a bare `sleep N` is not.

---

## 2. Step 1 — #60, housekeeping

### 2.1 `CLAUDE.md` (repo root, under 120 lines)

Three parts, in this order. Link the records; do not restate them.

**(a) A ten-line map.** `plan/` (corpus + plans A–E) · `kennel_console/`
(single-file console, `serve.py`, six `verify-*.sh` suites) · `stack/`
(`launch.md`, `transfer/`, `verify/`, `composed-run/tools/`, `bridge/`,
`known-good/`) · `vm/` (host baseline, provisioning, snapshot, Yuruna sequences
under `vm/test/`) · `demo/` (`tools/kennel-demo.sh`, the runbook, the dry run) ·
`docs/README.md` (the index) · `dfki-quad/` (the pinned upstream, gitignored, read
via `git show <PIN>:path`). Then the driver verbs from `kennel-demo.sh help`, one
line: once per host `setup provision`; each session `up console run teleop
[stop] walk [stop] down reset`; pieces `all compose transfer launch verify status
snapshot halt`.

**(b) The house rules**, one bullet each, each ending in a link to where the rule
is recorded (all paths verified to exist today):

| Rule | Recorded in |
|---|---|
| Implementation record beside the tool (`vm/*.md`, `stack/*.md`, `kennel_console/*.md`, `demo/*.md`): what was validated, exact commands, measured timings, an evidence dir, every deviation marked *bypass* (with retirement path) or *fix* | `docs/README.md` (opening paragraph); `plan/next-goals.md` §0 |
| Header comment on every script: version date, what it is, HOST / GUEST / container, usage, exit codes | the model: `stack/composed-run/tools/p21-launch-from-commands.sh` lines 1–36; `demo/tools/kennel-demo.sh` 1–100 |
| Knobs are environment variables passed through to the tool that defines them; flags only waive a correctness check (`--yes`, `--quiet`) | `demo/tools/kennel-demo.sh` "Knobs"; `demo/runbook.md` §4 |
| Exit codes `0/1/2` = pass / assert failed / could not even look; a distinct code per failure mode | `stack/verify.md` §1 (the exit table); `vm/snapshot.md` §4.2 |
| **Waits observe the stack, never sleep**; windows in *sim* seconds | `demo/dry-run.md` §4.1 (F8); `stack/composed-run.md` §3.2 |
| `set -uo pipefail` only in scripts that never source a ROS setup file | `stack/launch.md` §7 trap 3; `stack/verify/kennel-verify.sh` lines 25–28 |
| No `${…}` in Yuruna `command:` strings (Yuruna substitutes it); `docker inspect --type container` (the image is also named `dfki_quad`) | `vm/test/workload.guest.ubuntu.server.24.kennel.stack.ssh.yml` line 89 (the NB); `vm/provisioning.md` §5a, table row 2 |
| Never `pkill -f` without the `[x]` bracket trick; `-x` needs the 15-char `comm` | `stack/launch.md` §7 traps 5–6; `stack/known-good/tools/k13-stop.sh` |
| `Test-Config.ps1`: gate on **0 FAIL and no finding naming a kennel file**, never on PASS/WARN totals | `vm/provisioning.md` §4.3; `demo/dry-run.md` F1 |
| Nothing in the console fetches off-host; the suites assert zero non-localhost requests | `kennel_console/serve.md`; `kennel_console/export.md` (verification table, row "7 · Network") |
| Append, never reorder, in the console — the suites click by text order | `kennel_console/send.md` ("contents are not moved or reordered") → `export.md` §5 |
| Read the pin via `git show <PIN>:path`, never the working tree of `dfki-quad/` | `stack/transfer.md` (the backup paragraph); `kennel_console/verify-generate.py:86`; `demo/dry-run.md` F4 |

**(c) One paragraph on the method**: one issue = one branch = one PR, the body
opens with "Step N of 26" and its dependencies, the PR carries the record and the
evidence, and the milestone description is the ordering.

Then prove the file: `wc -l CLAUDE.md` < 120, and every relative path in it
resolves —

```bash
grep -o '`[a-zA-Z0-9_./-]*\.\(md\|sh\|py\|yml\)`' CLAUDE.md | tr -d '`' | sort -u | while read -r p; do [ -e "$p" ] || echo "MISSING $p"; done
```

### 2.2 The stray files

- **`plan/next-goals.md`** — prepend exactly the two lines #60 asks for: all
  three plans landed (#51, #54, #56); `plan/teleop-joystick.md` is plan D (#58).
  A third line naming this file as plan E is welcome but optional. Change nothing
  below the header: it is a historical record ("main is clean…" was true when
  written).
- **`vm/snapshot/evidence/15-provision-persisted.txt`** — keep the appended
  transcript. Add the explanation as a third `=== … ===` line at the top, the
  file's own annotation convention, e.g.
  `=== the five 'command not found' lines after the baseline block are the driver being edited on disk while bash was still reading it (2026-08-30), not a defect: the provision completed (45 steps, 38m44s, snapshot taken); the script as committed passes bash -n ===`.
  `vm/snapshot.md` §5's evidence table (line 243) already cites the file; check
  the sentence still reads true and, if #53's "final numbers land as a follow-up"
  wording is anywhere in `vm/snapshot.md`, replace it with the numbers.
- **`slides/` and the `.gitignore` lines** — commit them. Not in #60's text, but
  #60's acceptance is "`git status` clean on `main`", #78 later "rewrites the
  presentation to what shipped", and the deck is the user's own work of today
  (see §6). Commit `slides.md`, `package.json`, `package-lock.json`,
  `public/img/*.png`; `node_modules/` stays ignored. Do not edit the deck.
- **`plan/reliability.md`** (this file) — commit it in the same commit, as
  `teleop-joystick.md` was in #59.

### 2.3 Branches and #27

```bash
git branch --merged main | grep -v '^\* main'          # must list exactly the nine of §0 — assert, then delete
git branch -d console/19-export console/56-send-to-host demo/22-dry-run demo/27-runbook \
  demo/54-fewer-commands stack/20-transfer stack/21-composed-run teleop/58-virtual-joystick vm/51-baseline-snapshot
git remote prune origin
gh issue close 27 --comment "README.md (#49), docs/README.md (#48) and demo/runbook.md (#47, #55) already do what this asks: prerequisites, the commands, expected results, troubleshooting, timings. Closing as done by those."
```

`-d`, not `-D`: it refuses an unmerged branch, which is the assert.

### 2.4 The verb-parity assert

Checked today: every verb in `README.md` §Quick start and `demo/runbook.md` §1
exists in `kennel-demo.sh help`; the six in `help` but in neither (`compose
launch transfer verify status snapshot`) are the "pieces", documented in
runbook §3. So this item is a proof, not a fix — put the one-liner and its
output in the PR's Verification section:

```bash
help=$(demo/tools/kennel-demo.sh help | grep -o 'kennel-demo.sh [a-z]*' | awk '{print $2}' | sort -u)
readme=$(sed -n '/^## Quick start/,/^## Documentation/p' README.md | grep -o 'kennel-demo.sh [a-z]*' | awk '{print $2}' | sort -u)
runbook=$(sed -n '/^## 1\. /,/^## 2\. /p' demo/runbook.md | grep -o 'kennel-demo.sh [a-z]*' | awk '{print $2}' | sort -u)
comm -13 <(echo "$help") <(printf '%s\n%s\n' "$readme" "$runbook" | sort -u)   # must print nothing
```

### 2.5 Acceptance for step 1

`CLAUDE.md` present, < 120 lines, links resolve · the four stray items committed ·
nine branches gone, remote pruned · #27 closed with the comment ·
`bash -n demo/tools/kennel-demo.sh` · the six suites green (§5.2) — nothing here
touches them, so prove it.

---

## 3. Step 2 — #52, the launcher waits for the node graph

### 3.1 The change, in `p21-launch-from-commands.sh`

After the controller gate (line 187, `say "  controller started"`) and before the
final `say "stack is up…"`, add a fourth wait — the graph — and make exit 0 mean
what the header will now say: *all three are up, the controller reached "Starting
controller", **and the six-node graph is complete with no duplicates***.

```bash
# --- knob, beside the others (line ~45)
GRAPH_TIMEOUT="${KENNEL_GRAPH_TIMEOUT:-120}"     # wall s; on a warm container the six are there in seconds

# The six nodes of a healthy session -- the same list kennel-verify.sh check 1
# asserts and launch.md 6 / known-good/06-healthy-graph.txt record. Change both
# together. joy_to_target is the one that arrives last: it is a separate python3
# process of shell 3 and joins the graph after the controller has logged
# "Starting controller" (#52).
EXPECTED_NODES="/drake_simulator /joy_linux_node /joy_to_target /leg_driver /mit_controller_node /safe_start_launcher"

# Prints what is still wrong with the graph: missing nodes, and DUP:<name> for
# duplicates. Empty output = complete. Uses `ros2 node list` through the ros2
# daemon, exactly as kennel-verify.sh does, so this wait primes and observes the
# same view verify will read a moment later (--no-daemon would watch a different one).
graph_missing() {
    in_ctr "timeout 15 ros2 node list 2>/dev/null" | grep '^/' | sort > "$WORK/nodes"
    for n in $EXPECTED_NODES; do grep -qx "$n" "$WORK/nodes" || printf '%s ' "$n"; done
    uniq -d "$WORK/nodes" | sed 's/^/DUP:/' | tr '\n' ' '
}

t0=$(date +%s); missing=x
for i in $(seq 1 $((GRAPH_TIMEOUT / 2))); do
    missing="$(graph_missing)"; [ -z "$missing" ] && break
    sleep 2                                                  # poll interval, not a wait
done
if [ -n "$missing" ]; then
    fail "the node graph is still incomplete after ${GRAPH_TIMEOUT}s: $missing" \
         "joy_to_target and safe_start_launcher are shell 3's: sudo docker exec $CONTAINER tail -40 /tmp/p21-ctrl.log" \
         "A DUP: entry is a stale copy from a bad teardown (launch.md 7 trap 6) -- run k13-stop.sh and relaunch."
    exit 1
fi
say "  node graph complete: the six healthy-session nodes, no duplicates, $(( $(date +%s) - t0 )) s after 'Starting controller'"
```

Notes the implementer needs:

- **Duplicates are transient after the pre-launch stop.** A just-killed node's
  DDS participant lingers 10–20 s in `ros2 node list` (`stack/bridge.md` §4.1,
  verify check 1's own comment). The loop's criterion "all six present *and* no
  duplicates" converges on its own; do not shorten it to "six present".
- **Extras do not block.** A lingering bridge entry or anything foreign is
  `warn`ed, not failed — `verify` owns that verdict (`KENNEL_EXPECT_BRIDGE`).
- **The measured number is the deliverable.** The `say` line above is what the
  record's table is built from (§3.4): how long after "Starting controller" the
  graph completed, per run, cold vs warm.
- Header: bump `# Version:`, add `KENNEL_GRAPH_TIMEOUT` to the knobs, rewrite
  exit code 0's meaning, and add to the exit-1 line "or the graph never completed
  (the missing node is named)".

### 3.2 The second sleep, same file, same rule

Line 173, `sleep 15` after the leg driver, is a wait that does not observe. The
observable is already on record: `stack/launch.md` §1.1 shows `/joint_cmd` with
`Publisher count: 0` when only the simulator runs, and the leg driver is its
publisher; the controller "proceeds to `Starting controller` the moment
`leg_driver_launch.py` comes up" because it blocks on the leg driver's service.
Replace the sleep with a bounded loop on

```bash
[ "$(in_ctr "timeout 10 ros2 topic info /joint_cmd 2>/dev/null | awk '/Publisher count/{print \$3}'")" -ge 1 ] 2>/dev/null
```

with a `fail … exit 1` naming `/tmp/p21-legdrv.log` on timeout, and a `say` with
the seconds it took. Do this as its own hunk so it can be dropped if the cold
runs of §3.3 show anything odd — in which case keep the `sleep 15`, and record it
in §3.4 as a *bypass* with the observable named as its retirement path. The
`sleep 3` after `k13-stop.sh` (line 141) stays: the stopper's own bounded wait is
the observation, and 3 s is the DDS settle after it, documented there.

### 3.3 Validation protocol — on a cold container, every time

`reset` guarantees a cold container; that is the whole test. Each `reset` + `all`
is ~8 minutes. Capture every transcript with `2>&1 | tee <file>`, opening with an
`=== what ===` line and `date -u +%FT%TZ`, the convention of every evidence file.
Evidence lands in `stack/composed-run/evidence/`, continuing its numbering (the
last is `06-negative-controls.txt`):

| # | Do | File | Must show |
|---|---|---|---|
| 0 | `kennel-demo.sh status`; `down` if a stack is up | — | starting state known |
| 1 | **Before editing the launcher**: `reset`, then `all` — the negative control, up to 2 attempts | `07-52-cold-before.txt` | the `[FAIL] 1 node-graph … [missing: /joy_to_target ]` of the issue; if it does not reproduce in 2 tries, say so in the file and cite `vm/snapshot/evidence/10,16` — do not spend an hour chasing a race that is already on record |
| 2 | edit per §3.1–§3.2; `bash -n` | — | — |
| 3 | `reset`, then `all` — **four times** | `08-52-cold-runs/run-1.txt … run-4.txt` | `launch` prints the graph line; `verify` `pass=10 fail=0`; `all` green, 4 of 4 |
| 4 | `down`, then `run` (warm container) | `09-52-warm-run.txt` | green; the graph line reads a few seconds — the warm path did not get slower |

Also record `all`'s phase timings (it prints a summary) so the record can say
what the two new waits cost on the warm path: expected ≈ nothing, since the graph
is usually already complete and the leg driver is usually up well inside 15 s.

### 3.4 Record

`stack/composed-run.md` gains **§9 "Reliability pass (#52, #45)"** after §8, with
§9.1 for this step: the race in two sentences, the fix, a table of
"graph complete N s after *Starting controller*" for the five runs (cold ×4,
warm ×1) plus the leg-driver wait if §3.2 held, the evidence list, and the
negative control. One sentence appended to `vm/snapshot.md` §6 F5:
"Fixed in #52 — `stack/composed-run.md` §9.1." `demo/runbook.md` §3's `launch`
row (line 168, "what success looks like") adds "and the six-node graph is
complete".

---

## 4. Step 3 — #45, stack tools own their env

### 4.1 One fallback, one shape, in every tool that sources `/tmp/p21-env.sh`

The tools keep using the launcher's `/tmp/p21-env.sh` when it exists — it is the
console's own chain, and the launcher's point is "no second copy to drift". When
it does not exist they source the canonical chain **in-process** (never writing
the file: writing it would mask the coupling for the next tool and leave a stale
prelude behind). The chain is embedded between marker comments so its identity
with `prelude.sh` is checkable (§5.2):

```bash
# --- source chain: identical to stack/known-good/tools/prelude.sh and to shell 1
# of the console's commands.txt (launch.md 2) -- change all of them together.
# Used only when the launcher's /tmp/p21-env.sh is absent, i.e. the stack was
# launched some other way (launch.md 1.1 by hand, k14-stack-up.sh, a Yuruna step).
ENV_FALLBACK='source /opt/ros/humble/setup.bash
[ -f /root/unitree_ros2/install/setup.bash ] && source /root/unitree_ros2/install/setup.bash
source /root/ros2_ws/install/setup.bash
export PATH="/opt/drake/bin:${PATH}"
export PYTHONPATH="/opt/drake/lib/python3.10/site-packages:${PYTHONPATH}"
export LD_LIBRARY_PATH="/opt/drake/lib:${LD_LIBRARY_PATH}"
export ROS_PACKAGE_PATH="/root/ros2_ws/src"
source /root/setup_ulab_workspace.bash
cd /root/ros2_ws'
# --- end source chain

in_ctr() {
    sudo docker exec "$CONTAINER" bash -c \
        "if [ -f /tmp/p21-env.sh ]; then source /tmp/p21-env.sh; else $ENV_FALLBACK; fi >/dev/null 2>&1; $1"
}
```

`${PATH}` and friends are single-quoted in the tool and expand inside the
container, as they do in `commands.txt`; the tool's own `set -uo pipefail` is
untouched because no ROS setup file is sourced in the tool's shell (house rule).
Say once, on the transcript, which path was taken:
`say "env: /tmp/p21-env.sh"` or `say "env: built-in chain (no /tmp/p21-env.sh -- the stack was not launched by p21-launch-from-commands.sh)"`
— the evidence in §4.5 depends on that line.

### 4.2 `p21-trot-hold.sh`

- **Header**: "Runs on the GUEST, against an already-running stack, launched by
  any means" plus how the env is found (§4.1), and an **exit-codes block** it
  never had: `0` commanded / stopped · `1` the parameter set or the publisher
  failed · `2` could not even look (no running container, no `ros2` in the
  container's shell, the controller node not in the graph).
- **Preflight in `start`**, in this order, each with a message naming the cause
  and the fix:
  1. `sudo docker inspect --type container -f '{{.State.Status}}'` = `running`,
     else exit 2 ("Start the stack: `demo/tools/kennel-demo.sh launch`").
  2. `in_ctr "command -v ros2 >/dev/null"`, else exit 2 naming *both* facts:
     `/tmp/p21-env.sh` is absent **and** the built-in chain did not resolve
     `ros2` — "is this the `dfki_quad` image?" with the two setup paths to `ls`.
  3. `in_ctr "timeout 15 ros2 node list | grep -c '^$NODE\$'"` = 1, else exit 2
     ("the stack is not launched: `demo/tools/kennel-demo.sh launch`").
- **`stop` stays tolerant.** Three driver paths call it unconditionally —
  `do_walk stop` (line 1212), `teleop` (1249, 1267) and `do_down` (1314, silenced).
  When there is no running container or no controller node, `stop` says
  "nothing to stop" and exits 0; it fails (2) only on an environment that cannot
  resolve `ros2` with a running stack, which is the one case worth a red line.
- **The `sleep 3` in `start`** (line 49) waits for the detached publisher.
  Observe it instead: loop (bounded, 10 × 0.5 s) until the pidfile exists in the
  container and `kill -0` its pid succeeds, then say "publisher up (pid N)".

### 4.3 `p21-meshcat-shot.sh` — what the "same review" actually finds

Read, not assumed: the script runs on the **host**, drives Chrome over CDP, and
never touches the container or `/tmp/p21-env.sh`. `stack/composed-run.md` §2's
callout, which lumps it with the trot tool, is therefore wrong about it and gets
corrected (§4.6). Its real preconditions, and what to do about each:

| It needs | Today | Fix |
|---|---|---|
| `google-chrome` | checked, exit 2 | keep |
| Meshcat reachable from the host | checked via `vm/test/verify-meshcat-host.sh`, exit 2 | keep |
| **a repo checkout**: `sys.path.insert(0, REPO_ROOT/kennel_console)` then `from cdp import attach` (line 72–73). Copied to `/tmp` and run, it dies as "the capture failed (rc=1)" | unchecked | preflight `[ -f "$REPO_ROOT/kennel_console/cdp.py" ]`, exit 2: "run it from the repository — it imports the console's CDP client" |
| **a held trot**, for the *walking* shot the acceptance evidence is about — a standing robot yields a perfectly valid, non-blank PNG | unchecked | sample `base_link`'s world position twice, 1 s apart, inside the existing JS; if it moved < 1 cm, `say "WARNING: the robot is standing still -- for a walking shot: p21-trot-hold.sh start"`. Warn, still write the PNG, exit 0: a still shot is not an error, an unlabeled one is |
| the scene tree to have arrived | `sleep 6` (line 68) | poll through CDP, bounded (30 × 0.5 s), for `window.viewer && window.viewer.scene.getObjectByName('illustration')`; exit 2 on timeout ("the scene never arrived — is the simulator running?") |
| a rendered frame after re-aiming | `sleep 2.5` (line 125) | keep, and say why in a comment: there is no observable for "the frame was rendered"; note it in §9.2 as the one wait left in these tools that is not an observation |

Header: state all five preconditions; add the new exit-2 cause.

### 4.4 The two siblings, for consistency

- **`p21-prove-realtime-rate.sh`** (lines 44–50): its fallback is a partial chain.
  Replace it with the §4.1 block verbatim, same markers. It measures `/clock` and
  the partial chain happened to suffice — but a partial copy of a chain the
  record says must be identical everywhere is exactly the drift `launch.md` §2.1
  warns silently partitions the graph.
- **`stack/bridge/kennel-bridge.sh`** (`in_ctr` line 63; the file check at
  105–106): same `in_ctr`; turn the file check into a graph check
  (`/mit_controller_node` present, else exit 2 "the stack is not launched") so
  "no env file" and "no stack" stop being the same message. Keep everything else —
  the pidfile, the reaping, the two-signal readiness. Validation is one `teleop`
  / `teleop stop` round trip (§4.5 row 7); #65 owns the bridge's next pass.

### 4.5 Validation protocol — on the stack step 2 left running

The failure condition is "no `/tmp/p21-env.sh`", and the cheapest honest way to
produce it is to remove the file from a stack the launcher started — no second
launch path needed. `EV=stack/composed-run/evidence`; `C="sudo docker exec dfki_quad"`.

| # | Do (on the guest unless said) | File | Must show |
|---|---|---|---|
| 1 | **before editing**: `$C mv /tmp/p21-env.sh /tmp/p21-env.sh.bak`; old `p21-trot-hold.sh start` | `10-45-before.txt` | `timeout: failed to run command 'ros2'` — the issue's symptom |
| 2 | new tool, file still absent: `start`; `$C bash -c 'source …; timeout 10 ros2 topic hz /quad_control_target'` and `ros2 param get /mit_controller_node simple_gait_sequencer.gait`; `stop`; the param reads `STAND` | `11-45-trot-no-envfile.txt` | the "env: built-in chain" line; ~10 Hz on the target; `WALKING_TROT` then `STAND` |
| 3 | `$C mv /tmp/p21-env.sh.bak /tmp/p21-env.sh`; from the host: `kennel-demo.sh walk`, `walk stop` | `12-45-trot-with-envfile.txt` | the "env: /tmp/p21-env.sh" line; the normal path unchanged |
| 4 | `kennel-demo.sh down`; `p21-trot-hold.sh start`; then `stop` | `13-45-trot-not-launched.txt` | `start` exits 2 naming the launch verb; `stop` exits 0 "nothing to stop" |
| 5 | `sudo docker stop dfki_quad`; `start`; `sudo docker start dfki_quad` | (append to 13) | exit 2, container state named |
| 6 | `kennel-demo.sh run` (relaunch — also cold-run #5 for §3.3's table); on the host, `walk`; `p21-meshcat-shot.sh $EV/14-45-meshcat-shot.png`; `walk stop`; the shot again (standing); `cp` the script to `/tmp` and run it from there | `14-45-meshcat-shot.txt` + `.png` | a walking PNG > 20 kB with no warning; the standing warning on the second; exit 2 naming `cdp.py` on the third |
| 7 | `$C mv /tmp/p21-env.sh /tmp/p21-env.sh.bak`; `p21-prove-realtime-rate.sh 0.75` (30 s); `kennel-demo.sh teleop` then `teleop stop`; restore the file | `15-45-rate-and-bridge-no-envfile.txt` | `[PASS] realtime-rate`; bridge up, `verify-bridge-host.sh` green, torn down |

`kennel-demo.sh verify` after row 7 (stack still up, env restored) as the
closing check: `pass=10 fail=0`.

### 4.6 Record and the doc corrections

- `stack/composed-run.md` **§9.2**: the table of §4.3 (what each of the four
  tools needs and how it now says so), the fallback design and why it is
  in-process, the evidence rows of §4.5. **Replace §2's blockquote** (lines
  51–68) with two lines: the trot tool builds its own env since #45, see §9.2;
  the reconstruction recipe is no longer needed.
- `demo/dry-run.md` F9 row (line 103): append "**fixed** in #45".
- `demo/runbook.md` §5 row "Trot tool: `timeout: failed to run command 'ros2'`"
  (line 316): replace with the new behaviour — the tool falls back to the
  canonical chain; when the stack is not launched it exits 2 and says so.
- `stack/bridge.md` §3: one sentence — the bridge finds its env the same way
  since #45; "not launched" is now judged from the graph.
- `plan/next-goals.md` §0 lists #45 as open; it is a historical record — leave it.

---

## 5. The PR

### 5.1 Body skeleton (house style: PRs #53, #59)

```
fix(stack): the reliability step — the launcher waits for the graph, the p21 tools own their env, the house rules in CLAUDE.md

Closes #60, closes #52, closes #45. Plan: plan/reliability.md.
Three issues in one PR at the maintainer's request: they are steps 1–3 of the
milestone, and 2 and 3 share one validation protocol (a cold container).

## What is here            — table: file → what changed (CLAUDE.md, launcher, trot-hold, meshcat-shot, rate, bridge, records)
## Measured on the live guest — the §3.4 table (graph-complete seconds, cold ×4, warm ×1; all → verify pass=10 fail=0, 4 of 4)
## Corrections to the plan, from measurement — only if there were any; say "none" otherwise
## What #45's review found — meshcat-shot never depended on the env file; its real four preconditions, now declared and checked
## Verification            — §5.2, with outputs
## Bypasses                — the 2.5 s render settle in meshcat-shot (no observable); the leg-driver sleep only if §3.2 was dropped
## Housekeeping (#60)      — branches deleted (list), remote pruned, #27 closed (link), the four stray items committed
## Records                 — stack/composed-run.md §9; the one-line touches in vm/snapshot.md, demo/dry-run.md, demo/runbook.md, stack/bridge.md
```

### 5.2 Verification list — every line with its output in the PR

```bash
bash -n demo/tools/kennel-demo.sh stack/composed-run/tools/*.sh stack/bridge/kennel-bridge.sh
for s in serve scope generate export send teleop; do ./kennel_console/verify-$s.sh; echo "verify-$s exit=$?"; done   # six greens
wc -l CLAUDE.md                                                     # < 120
<the link check of §2.1>                                            # prints nothing
<the verb-parity one-liner of §2.4>                                 # prints nothing
# the embedded chain equals prelude.sh, in every tool that carries it:
for t in stack/composed-run/tools/p21-trot-hold.sh stack/composed-run/tools/p21-prove-realtime-rate.sh stack/bridge/kennel-bridge.sh; do
  diff <(sed -n "/^ENV_FALLBACK='/,/^cd \/root\/ros2_ws'/p" "$t" | sed "s/^ENV_FALLBACK='//; s/'$//") \
       <(grep -v '^#' stack/known-good/tools/prelude.sh | grep -v '^$') && echo "chain identical: $t"
done
grep -n 'sleep' stack/composed-run/tools/p21-launch-from-commands.sh   # only poll intervals and the documented /clock fallback remain
git status --porcelain                                              # empty
```

### 5.3 Acceptance, all three

| Issue | Criterion | Proof |
|---|---|---|
| #60 | `git status` clean; `CLAUDE.md` < 120 lines, links resolve; the four stray items committed; nine branches gone; #27 closed; verbs agree; driver `bash -n`; six suites green | §5.2 outputs; the PR's Housekeeping section |
| #52 | `reset` → `all` green **4 of 4**, `verify` `pass=10 fail=0` each time; the launcher names the graph wait and its duration; exit 1 names the missing node on timeout | `08-52-cold-runs/`, `09-52-warm-run.txt`, the §3.4 table |
| #45 | with no `/tmp/p21-env.sh` the trot tool works and says which env it used; with no stack it exits 2 naming the fix; `meshcat-shot` declares and checks its four real preconditions; rate and bridge tools share the chain; `composed-run.md` §2 no longer needs a reconstruction recipe | `10-…15-45-*.txt`, `14-45-meshcat-shot.png`, §9.2 |

---

## 6. Decisions this plan makes that the issues did not

Stated so the implementer knows what is the maintainer's text and what is this
plan's call — revert the call, not the issue, if it turns out wrong.

1. **`slides/` and the `.gitignore` lines are committed under #60.** Reason in
   §2.2. The alternative — leaving them untracked — fails #60's own acceptance.
2. **`kennel-bridge.sh` and `p21-prove-realtime-rate.sh` get the same fallback.**
   #45 names only the two p21 tools; the milestone step is "stack tools own their
   env", the bridge's coupling is the same one, and the rate tool's partial chain
   is a latent drift. The bridge change is bounded to `in_ctr` and one check.
3. **The leg-driver `sleep 15` goes too (§3.2), as a separable hunk.** Same file,
   same rule, observable already on record; dropped-with-a-bypass-note if the
   cold runs say otherwise.
4. **`meshcat-shot` warns, never fails, on a standing robot.** A screenshot is not
   an assert; the warning keeps the "walking" claim honest without breaking any
   caller.
5. **The fallback never writes `/tmp/p21-env.sh`.** In-process only, so the
   launcher stays the single writer and the coupling is visible in each tool's
   `env:` line rather than papered over.

## 7. Don'ts

- Don't `sleep` to wait; don't shorten the graph criterion to "six present".
- Don't run the cold-run protocol with a bridge or a held trot left over from a
  previous session — `down` first, and let `all`'s own `verify` be the judge.
- Don't use `pkill -f` anywhere new; the stopper already reaps `joy_to_target`
  by path with the `[.]` trick.
- Don't touch the console, its suites, or `kennel-verify.sh` — nothing here
  needs them, and the PR proves they are untouched by running them.
- Don't rewrite history in `plan/next-goals.md`, `vm/snapshot.md` §6 or
  `demo/dry-run.md` §4: append the "fixed in" pointers, leave the findings as
  found.
- Don't pass `-WhatIf` to `Remove-TestVMFiles.ps1` (`vm/snapshot.md` §6 F4) —
  irrelevant to this PR unless you decide to re-provision, which you should not.
