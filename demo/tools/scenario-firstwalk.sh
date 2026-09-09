#!/bin/bash
# Version: 2026.09.09
# Kennel -- issue #73: scenario s001.firstwalk, as a verb.
#
#   demo/tools/kennel-demo.sh scenario firstwalk
#
# Runs on the HOST, against a PROVISIONED guest whose stack is DOWN. It performs
# guides/first-run.md exactly as written, on a stopwatch, and asserts that
# everything it executed came from that page.
#
# WHAT THIS IS
#
# s001.firstwalk asks whether a newcomer following only the first-run checklist
# reaches a walking robot inside a time budget, and whether the checklist was
# sufficient -- "the harness records that every executed command string came
# from the checklist or the console's generated block" (plan/scenarios.md s001
# step 8). This verb makes both mechanical:
#
#   * every step is read OUT OF THE FILE. A ```bash fence is run in this shell;
#     a ```click fence is driven through scenario-page.py. Nothing else is run,
#     and the trace assertion at the end proves it as a set difference.
#   * every step's SUCCESS TEXT is read out of the file too -- the first
#     backticked literal on its `**Success looks like:**` line -- and must
#     appear in that step's transcript or in the page. If the prose promises a
#     line the tool does not print, this FAILS. That is the point: the failure
#     is a defect in the checklist, not in this script, and it is fixed in the
#     prose (demo/dry-run.md's method, one level along).
#   * the clock is CLOCK_MONOTONIC_RAW via p22-clock.sh, because this host's
#     adjusted clocks run ~10 % slow (vm/provisioning.md §6a) and a budget
#     number is exactly the kind of number that must not be quietly wrong.
#
# The timer starts at the first fence and stops when the robot has walked -- not
# when the script ends. Importing an appliance image and booting into the
# checklist is #76; until then the starting line is a provisioned guest.
#
# DEVIATION D1, as in demo/dry-run.md: an agent has no hands, so the clicks are
# scripted. It cannot report that a control was hard to find or mislabelled --
# a person should still perform this page once, and that session is still open.
#
# IT LEAVES THE STACK UP, unlike the other two verbs: the checklist ends with a
# walking robot, and `walkthrough.md` is what a newcomer reads next. The trap
# still releases the stick, stops teleop (zero, STAND, bridge down) and stops
# the console server this verb started through step 1.
#
# Knobs (environment variables):
#   KENNEL_S001_BUDGET     600    ceiling in seconds -- s001's hard ceiling of
#                          10 minutes on the reference host
#   KENNEL_S001_TARGET     300    the target it reports against (~5 min)
#   KENNEL_S001_VMAX       0.5    what a fully-pushed stick asks for (TELEOP_VMAX)
#   KENNEL_S001_VX_TOL     0.2    the +/- band on that, as a fraction
#   KENNEL_S001_GUIDE      guides/first-run.md   the page to perform
#   KENNEL_S001_EVIDENCE   demo/evidence/s001-firstwalk
#   KENNEL_CONSOLE_PORT    8000   the console the CHECKLIST starts -- this verb
#                          drives that one, not a server of its own, because
#                          step 1 of the page is what brings it up
#   plus the guest knobs of verify-bridge-host.sh, passed through untouched.
#
# Exit codes:
#   0  every check passed, and the walk was inside the budget
#   1  a check failed
#   2  could not run the checks (no chrome, no guest, a stack already up, the
#      console port busy, no guide to perform, not run from a checkout)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DEMO="$HERE/kennel-demo.sh"
OUT_DIR="${KENNEL_S001_EVIDENCE:-$REPO_ROOT/demo/evidence/s001-firstwalk}"
GUIDE="${KENNEL_S001_GUIDE:-$REPO_ROOT/guides/first-run.md}"

# The console the checklist itself starts, on the port the checklist's own
# command uses. The other scenario verbs run a serve.py of their own; this one
# must not, because "does step 1 bring up a console?" is one of the things under
# test.
export KENNEL_SCENARIO_PORT="${KENNEL_CONSOLE_PORT:-8000}"
# shellcheck source=scenario-lib.sh
. "$HERE/scenario-lib.sh"

BUDGET="${KENNEL_S001_BUDGET:-600}"
TARGET_S="${KENNEL_S001_TARGET:-300}"
VMAX="${KENNEL_S001_VMAX:-0.5}"
VX_TOL="${KENNEL_S001_VX_TOL:-0.2}"
CLOCK="$HERE/p22-clock.sh"

mkdir -p "$OUT_DIR/04-traces" "$OUT_DIR/05-renders"
tmp="$(mktemp -d)"
results="$tmp/checks.psv"
: > "$results"
serve=""; chrome=""; chromes=""; browsers=0
WALK_TRACE=""
CMDLOG="$OUT_DIR/01-commands.txt"
: > "$CMDLOG"
export KENNEL_TIMINGS="$OUT_DIR/00-timings.txt"
: > "$KENNEL_TIMINGS"

cleanup() {
    echo
    say "leaving the stack UP and standing -- the checklist ends with a walking robot"
    page release >/dev/null 2>&1
    page disconnect >/dev/null 2>&1
    "$DEMO" teleop stop >"$tmp/teardown.log" 2>&1
    sed 's/^/[scenario]   /' "$tmp/teardown.log" 2>/dev/null | tail -3
    for p in $chromes; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    for p in $chromes; do wait "$p" 2>/dev/null; done
    # The console server belongs to the checklist's step 1, so this verb stops
    # what that step started -- and says so, because an operator who ran the
    # checklist by hand would have one running.
    "$DEMO" console stop >"$tmp/console-stop.log" 2>&1
    sed 's/^/[scenario]   /' "$tmp/console-stop.log" 2>/dev/null | tail -2
    rm -rf "$tmp" 2>/dev/null || true
}

echo "=== scenario s001.firstwalk -- guides/first-run.md, performed and timed (#73) ==="
date -u +%FT%TZ
# `nostack`: every other verb needs a stack up; this one starts one itself and
# measures how long that takes, so a stack already running is the precondition
# that must NOT hold.
scenario_preflight firstwalk nostack

[ -f "$GUIDE" ] || { fail "no checklist to perform at $GUIDE." \
    "This verb performs guides/first-run.md; without it there is nothing to do."; exit 2; }
[ -x "$CLOCK" ] || { fail "no timer at $CLOCK."; exit 2; }
if curl -sf -o /dev/null "http://localhost:$PORT/$PAGE" 2>/dev/null; then
    fail "something is already serving the console on port $PORT." \
         "Step 1 of the checklist starts it, and this verb performs step 1." \
         "Stop it:  $DEMO console stop"
    exit 2
fi

trap cleanup EXIT

echo "guest        $GUEST_HOSTNAME at $GUEST_IP"
echo "checklist    ${GUIDE#$REPO_ROOT/}"
echo "evidence     $OUT_DIR"
echo "budget       ${BUDGET}s ceiling, ${TARGET_S}s target -- s001's own numbers"

# --- REGION: read the checklist
#
# The file is the program. Each step is a `### N · title` heading, one fenced
# block, and a `**Success looks like:**` line whose FIRST backticked literal is
# what must appear. Parsed here rather than restated, so that this verb cannot
# drift from the page a person reads.
python3 - "$GUIDE" > "$tmp/steps.tsv" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# Split on the step headings, keeping each heading with its body.
parts = re.split(r"^### ", text, flags=re.M)[1:]
n = 0
for part in parts:
    head, _, body = part.partition("\n")
    fences = re.findall(r"```(\w*)\n(.*?)```", body, re.S)
    if not fences:
        continue          # a prose section (the vocabulary footer) is not a step
    lang, fence = fences[0]
    if lang not in ("bash", "click"):
        continue
    m = re.search(r"\*\*Success looks like:\*\*(.*?)(?:\n\n|\Z)", body, re.S)
    want = ""
    if m:
        lit = re.search(r"`([^`]+)`", m.group(1))
        if lit:
            want = lit.group(1)
    n += 1
    print("%d\t%s\t%s\t%s\t%s" % (n, lang, head.strip(),
                                  fence.strip().replace("\n", "\\n"), want))
PY
nsteps=$(wc -l < "$tmp/steps.tsv")
[ "$nsteps" -ge 1 ] || { fail "no steps parsed out of $GUIDE." \
    "A step is a '### N · title' heading with a ```bash or ```click fence."; exit 2; }
echo
echo "the checklist, as this verb reads it:"
while IFS=$'\t' read -r n kind head fence want; do
    printf '  %s  %-6s %-28s %-42s want %s\n' "$n" "$kind" "$head" \
           "$(echo "$fence" | cut -c1-42)" "${want:-<none>}"
done < "$tmp/steps.tsv"

# --- REGION: the clock. Prove it before trusting it (demo/dry-run.md §2).
echo
"$CLOCK" ratio 5 > "$OUT_DIR/00-host-clock.txt" 2>&1
sed 's/^/[clock] /' "$OUT_DIR/00-host-clock.txt"
"$CLOCK" mark start >/dev/null

walked=0
# The steps are read into an ARRAY first, and the loop iterates over that.
#
# A `while read ... done < steps.tsv` loop looks equivalent and is not: the
# steps RUN SSH (through `kennel-demo.sh run`, and through `observe`), ssh reads
# stdin, and it eats the rest of the file. Measured here on the first audit run:
# step 4 ran and steps 5-8 silently did not, and the transcript looked green
# because everything that DID run passed. Same species as the sweep's
# swallowed points.txt (stack/stress.md, PR #82's first correction), which is
# the second time this has been paid for.
mapfile -t STEPS < "$tmp/steps.tsv"
for row in "${STEPS[@]}"; do
    IFS=$'\t' read -r n kind head fence want <<< "$row"
    banner "step $n · $head"
    "$CLOCK" mark "step-$n" >/dev/null
    log="$OUT_DIR/02-step-$n.txt"
    if [ "$kind" = bash ]; then
        line="$(echo "$fence" | sed 's/\\n/\n/g' | head -1)"
        echo "CMD: $line" >> "$CMDLOG"
        say "\$ $line"
        ( cd "$REPO_ROOT" && bash -c "$line" ) >"$log" 2>&1
        rc=$?
        tail -6 "$log" | sed 's/^/[scenario]   /'
        check "$rc" "step $n ran: $line" "exit $rc"
        # The console the checklist just started is the one this verb drives.
        # A person opens the tab that command opened for them; an agent starts
        # its own headless one against the same URL (deviation D1).
        if echo "$line" | grep -q ' console'; then
            start_chrome
        fi
        # After `teleop`, /api/health carries the bridge URL -- and the page has
        # to be re-read to see it. A person's tab picks it up when they click;
        # this reload is the verb's equivalent, and it is logged as its own,
        # NOT as a checklist step.
        if echo "$line" | grep -q ' teleop'; then
            echo "PAGE: boot" >> "$CMDLOG"
            say "reloading the page so it sees the bridge URL teleop just published"
            page boot
        fi
        if [ -n "$want" ]; then
            if grep -qF -- "$want" "$log"; then
                check 0 "  and said what the checklist promises" "found: $want"
            else
                check 1 "  the checklist promises a line this step did not print" \
                      "wanted: $want"
                say "  ^ that is a friction in the PROSE, not in this script (see demo/scenarios.md §6)"
            fi
        fi
    else
        : > "$log"
        mapfile -t CLICKS <<< "$(echo "$fence" | sed 's/\\n/\n/g')"
        for step in "${CLICKS[@]}"; do
            [ -z "$step" ] && continue
            echo "PAGE: $step" >> "$CMDLOG"
            set -- $step
            if [ "$1" = hold ]; then
                # A measured window, in SIM seconds, from the guest's own
                # monitor -- never a sleep, and never the page's own idea of
                # what the robot did (dashboard.md §4).
                secs="${2:-10}"
                say "holding the stick for $secs sim-s, measured on the guest"
                f="$(observe walk "$secs" --rows)"
                cp "$f" "$OUT_DIR/04-traces/walk.csv" 2>/dev/null
                WALK_TRACE="$f"
                walked=1
            else
                page $step 2>&1 | tee -a "$log" | sed 's/^/[scenario]   /'
            fi
        done
        if [ -n "$want" ]; then
            dom="$(page_quiet dom 2>/dev/null)"
            if grep -qF -- "$want" "$log" || echo "$dom" | grep -qF -- "$want"; then
                check 0 "  the page says what the checklist promises" "found: $want"
            else
                check 1 "  the checklist promises something the page did not say" \
                      "wanted: $want"
                say "  ^ that is a friction in the PROSE, not in this script (see demo/scenarios.md §6)"
            fi
        fi
    fi
done

# --- REGION: did the robot actually walk? The guest's own measurement.
banner "the walk itself, from the guest"
if [ "$walked" = 1 ] && [ -s "${WALK_TRACE:-}" ]; then
    f="$WALK_TRACE"
    travel="$(jget "$f" x_travel)"
    vx="$(jget "$f" vx_mean)"
    zmed="$(jget "$f" z_median)"
    tiltf="$(jget "$f" tilt_over_frac)"
    lo="$(awk -v v="$VMAX" -v t="$VX_TOL" 'BEGIN{printf "%.4f", v*(1-t)}')"
    hi="$(awk -v v="$VMAX" -v t="$VX_TOL" 'BEGIN{printf "%.4f", v*(1+t)}')"
    check "$(gt "$travel" 0 && echo 0 || echo 1)" "the robot went somewhere" "x_travel $travel m"
    check "$(num_ok "$vx" "$lo" "$hi" && echo 0 || echo 1)" \
          "at about the commanded ${VMAX} m/s" "vx_mean $vx, band $lo..$hi"
    check "$(num_ok "$zmed" 0.20 0.45 && echo 0 || echo 1)" \
          "on its feet the whole way" "z_median $zmed m"
    check "$(lt "$tiltf" 0.02 && echo 0 || echo 1)" "and upright" "tilt_over_frac $tiltf"
else
    check 1 "the checklist's hold step produced a measurement" "no trace"
fi
page nobanner
page health "03-health.json"
if [ -s "$OUT_DIR/03-health.json" ]; then
    reds="$(python3 -c "
import json
d = json.load(open('$OUT_DIR/03-health.json'))
print(','.join(n for n, l in (d.get('blocks') or []) if l == 'red'))" 2>/dev/null)"
    check "$([ -z "$reds" ] && echo 0 || echo 1)" \
          "no panel is in an error state at timer stop" "${reds:-none red} -- s001's TVP"
fi
"$CLOCK" mark walking >/dev/null

banner "the checklist was sufficient"
page errors
page shot "05-renders/05-walking.png"

# --- REGION: the trace assertion -- s001 step 8, made mechanical
#
# Every command string executed, against the ones the checklist contains. The
# console's generated block is included on the scenario's own terms ("came from
# the checklist OR the console's generated block"), fetched from the guest --
# even though the checklist never asks anyone to type one.
python3 - "$CMDLOG" "$tmp/steps.tsv" > "$tmp/trace.txt" <<'PY'
import sys
log, steps = sys.argv[1], sys.argv[2]
allowed_cmd, allowed_page = set(), {"boot"}   # boot is this verb's own reload
for line in open(steps, encoding="utf-8"):
    n, kind, head, fence, want = (line.rstrip("\n").split("\t") + ["", "", "", "", ""])[:5]
    for f in fence.split("\\n"):
        if not f.strip():
            continue
        (allowed_cmd if kind == "bash" else allowed_page).add(f.strip())
ran_cmd, ran_page = set(), set()
for line in open(log, encoding="utf-8"):
    if line.startswith("CMD: "):
        ran_cmd.add(line[5:].strip())
    elif line.startswith("PAGE: "):
        ran_page.add(line[6:].strip())
print("CMD_EXTRA=%s" % sorted(ran_cmd - allowed_cmd))
print("PAGE_EXTRA=%s" % sorted(ran_page - allowed_page))
print("CMD_RAN=%d PAGE_RAN=%d" % (len(ran_cmd), len(ran_page)))
PY
sed 's/^/[scenario]   /' "$tmp/trace.txt"
cmd_extra="$(sed -n 's/^CMD_EXTRA=//p' "$tmp/trace.txt")"
page_extra="$(sed -n 's/^PAGE_EXTRA=//p' "$tmp/trace.txt")"
check "$([ "$cmd_extra" = "[]" ] && echo 0 || echo 1)" \
      "every command executed came from the checklist" "$cmd_extra"
check "$([ "$page_extra" = "[]" ] && echo 0 || echo 1)" \
      "every page action came from the checklist" "$page_extra"

# --- REGION: the budget
banner "the time it took"
"$CLOCK" report > "$OUT_DIR/00-report.txt" 2>&1
sed 's/^/[clock] /' "$OUT_DIR/00-report.txt"
total="$(python3 - "$KENNEL_TIMINGS" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1], encoding="utf-8")
        if l.strip() and not l.startswith("#")]
marks = {r[3]: float(r[0]) for r in rows}
if "start" in marks and "walking" in marks:
    print("%.1f" % (marks["walking"] - marks["start"]))
else:
    print("")
PY
)"
check "$([ -n "$total" ] && lt "$total" "$BUDGET" && echo 0 || echo 1)" \
      "first boot to sustained commanded walking, inside the ${BUDGET}s ceiling" \
      "${total:-unknown} s on CLOCK_MONOTONIC_RAW"
if [ -n "$total" ]; then
    if lt "$total" "$TARGET_S"; then
        note "and inside the ${TARGET_S}s target" "$total s"
    else
        note "over the ${TARGET_S}s target, under the ceiling" "$total s"
    fi
fi

totals
