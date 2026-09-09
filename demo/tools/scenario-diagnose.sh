#!/bin/bash
# Version: 2026.09.08
# Kennel -- issue #71: scenario s003.diagnose, as a verb.
#
#   demo/tools/kennel-demo.sh scenario diagnose
#
# Runs on the HOST, against a guest that is up. UNLIKE `scenario disturb`, this
# one owns its own composition: it composes the stress preset (#70) itself and
# launches it, up to three times, because what it is testing is a run that
# DEGRADES and falls, and the composition is half of that.
#
# It never loops until green. Three attempts, a count, and an exit code from the
# count -- #71's own words: "it never loops until green, and a 0-of-3 is a red
# result with the traces attached".
#
# WHAT IT ASSERTS. s003 asks for a healthy walk that degrades visibly -- the MPC
# block going green -> amber, the feed carrying deadline violations with measured
# values -- and then falls. The stress preset is what makes that happen, and it
# was picked from a measured table rather than guessed at
# (stack/stress.md): PARTIAL_CONDENSING_OSQP at mpc_condensed_size 1, on the flat
# plane, which takes 3.44-3.57 ms per solve against 1.16 for the same solver at
# stock condensing, peaks at 7.2-10.3 ms -- over the console's 7 ms amber line
# every time -- and falls, three runs of three.
#
# The two knobs below exist because those are measurements, not laws. On a host
# where the margin behaves differently the defaults are wrong, and the verb then
# PRINTS what it measured as a bypass instead of failing a check about somebody
# else's hardware. stack/stress.md carries the numbers that justify each default.
#
# The walk is commanded from the PAGE with the joystick centred (#71's own
# wording): the gait picker, then the vx field, published at 20 Hz by the
# console. Nothing else publishes.
#
# Knobs (environment variables):
#   KENNEL_S003_ATTEMPTS       3     compose+launch+drive attempts
#   KENNEL_S003_WINDOW         60    sim seconds to walk before giving up on a fall
#   KENNEL_S003_VX             0.3   commanded forward velocity, m/s -- the
#                              velocity check 8's band is tuned for
#   KENNEL_S003_EXPECT_MPC_AMBER  1  assert that the MPC block reaches amber
#                              before the fall. 0 measures and prints it instead
#   KENNEL_S003_EXPECT_DEADLINE   1  assert a deadline-violation entry in the
#                              pinned window. 0 measures and prints it instead
#   KENNEL_S003_EVIDENCE       demo/evidence/s003-diagnose
#   KENNEL_PRESET              stress   the composition to induce it with
#   plus the guest knobs of verify-bridge-host.sh and the compose knobs of
#   p22-console-demo.sh, passed through untouched.
#
# Exit codes:
#   0  the preset fell on at least two of the attempts, and every asserted
#      observable held on the attempts that fell
#   1  it fell fewer than twice, or an assertion failed -- the traces are the
#      result, not a reason to run it again
#   2  could not run at all (no chrome, no guest, a port in use, no checkout)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DEMO="$HERE/kennel-demo.sh"
OUT_DIR="${KENNEL_S003_EVIDENCE:-$REPO_ROOT/demo/evidence/s003-diagnose}"
# shellcheck source=scenario-lib.sh
. "$HERE/scenario-lib.sh"

ATTEMPTS="${KENNEL_S003_ATTEMPTS:-3}"
WINDOW="${KENNEL_S003_WINDOW:-60}"
VX="${KENNEL_S003_VX:-0.3}"
# Both default to 1 because both were measured true with the stress preset on
# the reference guest (stack/stress.md §4): every one of three runs crossed the
# console's amber line, and the feed carries WBC deadline entries throughout.
EXPECT_AMBER="${KENNEL_S003_EXPECT_MPC_AMBER:-1}"
EXPECT_DEADLINE="${KENNEL_S003_EXPECT_DEADLINE:-1}"
export KENNEL_PRESET="${KENNEL_PRESET:-stress}"
# Two of three is #70's own bar for a red preset, and #71 inherits it.
NEED_FELL="${KENNEL_S003_NEED_FELL:-2}"

mkdir -p "$OUT_DIR/04-traces" "$OUT_DIR/05-renders" "$OUT_DIR/06-process-diffs"
tmp="$(mktemp -d)"
results="$tmp/checks.psv"
: > "$results"
serve=""; chrome=""; chromes=""; browsers=0

cleanup() {
    echo
    say "leaving the stack as a scenario found it: standing, STAND, bridge down"
    page disconnect >/dev/null 2>&1
    "$DEMO" teleop stop >"$tmp/teardown.log" 2>&1
    sed 's/^/[scenario]   /' "$tmp/teardown.log" 2>/dev/null | tail -3
    local f z
    f="$(observe leaving 2 2>/dev/null)"
    z="$(jget "$f" z_median)"
    if [ -n "$z" ] && lt "$z" 0.15; then
        say "the robot is down (z $z m) -- recovering"
        ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/kennel-bridge.sh recover" 2>&1 \
            | grep -E 'recovered|NONZERO' | sed 's/^/[scenario]   /'
    fi
    for p in $chromes "$serve"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    for p in $chromes; do wait "$p" 2>/dev/null; done
    rm -rf "$tmp" 2>/dev/null || true
}

echo "=== scenario s003.diagnose -- degradation, a fall, and the post-mortem (#71) ==="
date -u +%FT%TZ
scenario_preflight diagnose
trap cleanup EXIT

echo "guest        $GUEST_HOSTNAME at $GUEST_IP"
echo "evidence     $OUT_DIR"
echo "preset       $KENNEL_PRESET   attempts $ATTEMPTS, need $NEED_FELL to fall"
echo "walk         vx $VX m/s from the page, joystick centred, ${WINDOW} sim-s per attempt"
echo "ps excludes  $HARNESS_RE"
echo "asserting    MPC amber=$EXPECT_AMBER, a deadline entry=$EXPECT_DEADLINE"
[ "$EXPECT_AMBER" = 1 ] && [ "$EXPECT_DEADLINE" = 1 ] \
    || echo "             (the rest is measured and printed, not asserted -- stack/stress.md)"

start_server

fell_count=0
mpc_amber_count=0
attempt=0
while [ "$attempt" -lt "$ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    banner "attempt $attempt of $ATTEMPTS"

    # END THE PREVIOUS ATTEMPT'S SESSION FIRST. Every attempt relaunches the
    # stack, and `p21-launch-from-commands.sh` opens by reaping /tmp/k13-*.pid --
    # which is the bridge and the watchdog. Relaunching under a live teleop
    # session therefore tears the bridge out from under a still-connected page,
    # and the launcher's own six-node wait then has to converge through the DDS
    # participants that leaves behind. Measured: /drake_simulator missing from
    # `ros2 node list` for the whole 120 s bound on a stack that was healthy the
    # moment the bound expired -- #52's shape, one layer along.
    if [ "$attempt" -gt 1 ]; then
        page disconnect >/dev/null 2>&1
        "$DEMO" teleop stop >"$tmp/teleop-stop-$attempt.log" 2>&1
        say "the previous attempt's session is closed (bridge down) before relaunching"
    fi

    # --- compose and launch the red preset. Never `run`: the recipe's own trot
    # would fall on terrain and stop the chain at verify, and the fall has to
    # happen under the console's eyes.
    say "composing the $KENNEL_PRESET preset"
    "$DEMO" compose >"$tmp/compose-$attempt.log" 2>&1
    crc=$?
    check "$crc" "the $KENNEL_PRESET preset composed" \
          "$(grep -E 'run folder' "$tmp/compose-$attempt.log" | tail -1 | sed 's/.*run folder *//')"
    [ "$crc" = 0 ] || { totals; exit 1; }
    "$DEMO" transfer >"$tmp/transfer-$attempt.log" 2>&1
    "$DEMO" launch >"$tmp/launch-$attempt.log" 2>&1
    lrc=$?
    if [ "$lrc" != 0 ]; then
        # An attempt that could not be launched is an attempt that did not
        # happen. It is recorded with its log and the verb moves on, because
        # three attempts is what #71 asks for and one bad launch is not a
        # verdict about the preset.
        cp "$tmp/launch-$attempt.log" "$OUT_DIR/00-launch-failed-attempt$attempt.log"
        # A NOTE, not a failure: a stack that would not come up is a `launch`
        # problem, not an s003 result, and the verdict this verb owns is the
        # fall count. If launches keep failing that count will not reach its bar
        # and the verb goes red for the right reason.
        note "attempt $attempt could not be launched -- recorded, and the verb goes on" \
             "exit $lrc: $(grep -E 'NONZERO|never' "$tmp/launch-$attempt.log" | head -1 | cut -c1-110)"
        ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/kennel-bridge.sh recover" >/dev/null 2>&1
        continue
    fi
    check 0 "the stack launched on it" \
          "$(grep -E 'node graph complete' "$tmp/launch-$attempt.log" | sed 's/.*): //')"
    RUN="$(applied_run)"
    say "applied run  $RUN"

    "$DEMO" teleop >"$tmp/teleop-$attempt.log" 2>&1
    capture_ps "before-$attempt"
    cp "$OUT_DIR/06-process-diffs/ps-before-$attempt.txt" \
       "$OUT_DIR/06-process-diffs/ps-before.txt"
    start_chrome
    page boot
    page connect

    # ---- step 1: healthy
    banner "attempt $attempt · 1 · a live healthy run"
    page health "01-health-attempt$attempt.json"
    # WHAT A COMPOSED PRESET LOOKS LIKE AT t=0, and why s003's step 1 reads
    # differently here than it does in the scenario document.
    #
    # s003 opens on "a run is live and healthy: all pipeline blocks green" and
    # then has the harness INDUCE stress. The mechanism design.md §1 chose is a
    # composed configuration -- and a composition is in effect from the
    # controller's first solve. Measured: under the stress preset the MPC block
    # is already amber while the robot is standing, before any velocity is
    # commanded, because the solver is taking 3.5 ms with peaks over the
    # console's 7 ms line from the very first cycle.
    #
    # So what is asserted here is that the panel SHOWS the degradation the
    # composition induces -- which is s003 step 3's observable, arriving earlier
    # than its narrative expects -- and the green-to-amber TRANSITION is a
    # bypass, recorded with its reason (demo/scenarios.md §2.3).
    health0="$(python3 -c "
import json
d = json.load(open('$OUT_DIR/01-health-attempt$attempt.json'))
mpc = [b for b in d['blocks'] if b[0].upper().startswith('MPC')]
print('%d' % (0 if (mpc and mpc[0][1] in ('amber', 'red')) else 1),
      'mpc=%s' % (mpc[0][1] if mpc else 'absent'),
      'blocks=%s' % ','.join('%s:%s' % (b[0], b[1]) for b in d['blocks']))")"
    # A NOTE, not a check: the console's MPC tint is the worst solve in the most
    # recent 100 ms bin, and under this preset -- 3.5 ms mean with peaks over the
    # 7 ms line -- whether any single bin crosses is chance. Measured across two
    # attempts: amber at connect once, green once. What is ASSERTED is that the
    # block reaches amber over the run, which the tint history below does.
    note "the MPC block at connect, before the walk is commanded" "$health0"
    bypass "1-3 green-to-amber transition" \
           "the composed preset degrades the margin from the controller's FIRST solve, so there is no green run to watch turn amber. A transition needs an EVENT during the run, and the only event mechanism at this pin is the disturbance service -- which is s004's (demo/scenarios.md §2.3)"
    page nobanner
    page shot "05-renders/01-green-attempt$attempt.png"

    # ---- step 2: the walk, and the degradation
    banner "attempt $attempt · 2 · walk, and watch it degrade"
    page gait WALKING_TROT
    page vx "$VX"
    observe_bg "walk$attempt" "$WINDOW" --rows
    check $? "a ${WINDOW} sim-s measurement window is open"
    # Poll the page while the guest measures: the tint history and the banner are
    # what s003 is about, and they only exist while it is happening.
    : > "$OUT_DIR/02-tint-history-attempt$attempt.jsonl"
    amber_seen=""
    for i in $(seq 1 200); do
        kill -0 "$OBS_PID" 2>/dev/null || break
        page_quiet health "$tmp/h.json" >/dev/null 2>&1
        cat "$tmp/h.json" >> "$OUT_DIR/02-tint-history-attempt$attempt.jsonl"
        echo >> "$OUT_DIR/02-tint-history-attempt$attempt.jsonl"
        if [ -z "$amber_seen" ] && grep -q '"amber"' "$tmp/h.json"; then
            amber_seen="$(python3 -c "
import json
d = json.load(open('$tmp/h.json'))
print(','.join(b[0] for b in d['blocks'] if b[1] == 'amber'), 'at sim', d.get('sim'))")"
            say "  first amber: $amber_seen"
            page_quiet shot "05-renders/02-amber-attempt$attempt.png" >/dev/null 2>&1
        fi
        sleep 1
    done
    wait "$OBS_PID"
    cp "$OBS_FILE" "$OUT_DIR/04-traces/walk-attempt$attempt.csv"
    zmin="$(jget "$OBS_FILE" z_min)"; tilt="$(jget "$OBS_FILE" tilt_over_frac)"
    dist="$(jget "$OBS_FILE" dist_xy)"; early="$(jget "$OBS_FILE" gait.name)"
    say "  guest: dist_xy ${dist:-?} m, z_min ${zmin:-?} m, tilt over 0.5 rad in ${tilt:-?}"
    # The GUEST's verdict on whether it fell, by verify.md §4's rule -- the page's
    # banner is asserted separately, and the two must agree.
    if lt "$zmin" 0.15 || gt "$tilt" 0.15; then guest_fell=0; else guest_fell=1; fi

    if [ "$guest_fell" != 0 ]; then
        say "attempt $attempt did NOT fall in $WINDOW sim-s -- recording it and moving on"
        check 0 "attempt $attempt: the run survived the window (recorded, not a failure)" \
              "dist_xy ${dist:-?} m, z_min ${zmin:-?} m, tilt ${tilt:-?} -- transfer.md §6.3 measured this map failing differently on repeat"
        page release
        page disconnect
        ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/kennel-bridge.sh recover" >/dev/null 2>&1
        continue
    fi

    fell_count=$((fell_count + 1))
    check 0 "attempt $attempt: the robot FELL, by the verification recipe's own rule" \
          "z_min ${zmin:-?} m, tilt over 0.5 rad in ${tilt:-?} of samples, after ${dist:-?} m"

    # ---- steps 3-7: the narration, in order
    banner "attempt $attempt · 3-7 · what the console said while it happened"
    page banner 30
    page feed "03-feed-attempt$attempt.json"
    page shot "05-renders/03-red-attempt$attempt.png"

    # The tint history: green before, and what reached amber before the fall.
    tint="$(python3 - "$OUT_DIR/02-tint-history-attempt$attempt.jsonl" <<'PYEOF'
import json, sys
rows = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except ValueError:
        pass
if not rows:
    print("0 0 none"); raise SystemExit(0)
first = rows[0]["blocks"]
# "Starts green" is about the MPC block, for the same reason step 1 is: the
# contact, gait and swing blocks tint amber the moment an early contact arrives,
# which on this preset is before the walk is commanded, and that is a true
# reading of a real counter rather than an unhealthy start.
green0 = all(b[1] == "green" for b in first if b[0].upper().startswith("MPC"))
amber = sorted({b[0] for r in rows for b in r["blocks"] if b[1] == "amber"})
red = sorted({b[0] for r in rows for b in r["blocks"] if b[1] == "red"})
mpc_amber = any(b[0].upper().startswith("MPC") and b[1] == "amber"
                for r in rows for b in r["blocks"])
print("%d %d %s | amber: %s | red: %s"
      % (1 if green0 else 0, 1 if mpc_amber else 0, len(rows),
         ",".join(amber) or "none", ",".join(red) or "none"))
PYEOF
)"
    say "  tint history: $tint"
    # Every block red at the fall is the fall's own consequence, and it is what
    # is asserted per attempt.
    case "$tint" in *"red: none"*) rc=1 ;; *) rc=0 ;; esac
    check "$rc" "every pipeline block ends RED at the fall" "$tint"
    case "$tint" in *"amber: none"*) rc=1 ;; *) rc=0 ;; esac
    check "$rc" "and something went AMBER before it -- the degradation was visible" "$tint"
    # The MPC block specifically -- the SECOND field of the tint summary, read on
    # its own. Reading it as "green at the start AND amber later" was a check
    # about two different things wearing one name, and it failed for the first
    # one while the second was true.
    # The MPC block specifically -- the SECOND field of the tint summary, read on
    # its own. It is counted here and ASSERTED at the end, over the attempts,
    # because it is a property of the preset and not of any one run: the console
    # tints on the worst solve in a 100 ms bin, and at this preset's 3.4-3.6 ms
    # mean whether a given bin crosses 7 ms is chance. Measured 2 of 3.
    case "$tint" in *\ 1\ *) mpc_amber=0 ;; *) mpc_amber=1 ;; esac
    if [ "$mpc_amber" = 0 ]; then
        mpc_amber_count=$((mpc_amber_count + 1))
        note "attempt $attempt: the MPC block reached amber before the fall" "$tint"
    else
        note "attempt $attempt: the MPC block did not reach amber" \
             "the composition degrades the margin (stack/stress.md §4) but the console tints on the worst solve in a 100 ms bin, and not every bin crosses 7 ms"
    fi

    # The feed: the entries s003 step 7 asks to read in order.
    order="$(python3 - "$OUT_DIR/03-feed-attempt$attempt.json" <<'PYEOF'
import json, re, sys
rows = json.load(open(sys.argv[1]))
times = [float(t.rstrip("s")) for t, _ in rows]
texts = [t for _, t in rows]
dl = [i for i, t in enumerate(texts) if re.match(r"^(MPC|WBC) missed its \d+ ms deadline", t)]
sf = [i for i, t in enumerate(texts) if re.match(r"^(MPC|WBC) solver failed", t)]
ct = [i for i, t in enumerate(texts)
      if re.match(r"^(Early|Late) contact (FL|FR|RL|RR) [-+−]\d+ ms vs planned touchdown$", t)]
fa = [i for i, t in enumerate(texts) if t.startswith("FALL:")]
later = [texts[i] for i, t in enumerate(times) if fa and t > times[fa[0]] + 1e-9]
span = (times[fa[0]] - times[0]) if fa and times else 0.0
print(json.dumps({
    "rows": len(rows), "deadline": len(dl), "solver_failed": len(sf),
    "contact": len(ct), "fall": len(fa),
    "contact_before_fall": bool(ct and fa and ct[0] < fa[0]),
    "deadline_before_fall": bool(dl and fa and dl[0] < fa[0]),
    "nothing_later": bool(fa and not later),
    "window_span_s": round(span, 2),
    "fall_text": texts[fa[0]] if fa else "",
}))
PYEOF
)"
    say "  post-mortem: $order"
    echo "$order" > "$OUT_DIR/03-postmortem-attempt$attempt.json"
    j() { python3 -c "import json,sys; print(json.loads('''$order''')['$1'])"; }
    [ "$(j fall)" -ge 1 ]
    check $? "the pinned post-mortem ends in the FALL entry, with its trigger values" \
          "$(j fall_text)"
    [ "$(j nothing_later)" = True ]
    check $? "nothing in the pinned window happened after the fall (step 7's order)" "$order"
    [ "$(j contact)" -ge 1 ] && [ "$(j contact_before_fall)" = True ]
    check $? "at least one contact-mismatch entry, with leg and offset, before the fall (step 4)" \
          "$(j contact) contact entries"
    gt "$(j window_span_s)" 2
    check $? "the pinned window covers more than the fall itself (step 6: the last five seconds)" \
          "$(j window_span_s) s of events pinned"
    if [ "$EXPECT_DEADLINE" = 1 ]; then
        [ "$(j deadline)" -ge 1 ] && [ "$(j deadline_before_fall)" = True ]
        check $? "a deadline-violation entry with a measured value, before the fall (step 3)" \
              "$(j deadline) entries"
    elif [ "$(j deadline)" -ge 1 ]; then
        check 0 "a deadline-violation entry appeared (unexpectedly, and welcome)" \
              "$(j deadline) entries -- stack/stress.md §3 says the margin should not be reachable here"
    else
        bypass "3f deadline-entry" \
               "measured: $(j deadline) deadline violations and $(j solver_failed) solver failures in the pinned window. Set KENNEL_S003_EXPECT_DEADLINE=1 to assert it"
    fi

    # ---- step 6: the verdict, and the record
    banner "attempt $attempt · 6 · the verdict and the record"
    page release
    page disconnect
    f="$(observe "before-verify-$attempt" 3)"
    zv="$(jget "$f" z_median)"
    "$DEMO" verify >"$tmp/verify-$attempt.log" 2>&1
    vrc=$?
    verdict="$(python3 -c "
import json
try: print(json.load(open('$OUT/$RUN/verify.json'))['verdict'])
except Exception: print('')" 2>/dev/null)"
    case "$verdict" in
        fell|unhealthy|solver-failed|completed) rc=0 ;;
        *) rc=1 ;;
    esac
    check "$rc" "verify filed a report for this run, with a verdict the recipe defines" \
          "${verdict:-<none>} in $RUN/verify.json (exit $vrc, robot at z ${zv:-?} m)"
    cp "$OUT/$RUN/verify.json" "$OUT_DIR/04-verify-attempt$attempt.json" 2>/dev/null
    grep -E 'pass=' "$tmp/verify-$attempt.log" | sed 's/^/[scenario]   /'
    page connect
    page runs "05-runs-attempt$attempt.json" "$RUN" "$verdict"
    capture_ps "after-attempt$attempt"
    ps_same "after-attempt$attempt"

    # ---- step 8: the reset
    banner "attempt $attempt · 8 · reset: the sim restarts, the record is kept"
    page reset
    # WHAT A RESET CAN UNDO. /reset_sim replaces the simulator's context: the
    # clock goes back to zero and the robot is respawned at 0.4 m. It does NOT
    # undo the COMPOSITION, and the stress preset is a composition that cannot
    # hold the body up -- measured, it settles at z 0.15-0.20 m and the fall rule
    # fires again within seconds. So what is asserted here is the reset, and what
    # is reported is where the robot ended up. s003 step 8's "the dashboard
    # clears to healthy" is true of a healthy composition and not of this one,
    # which is the honest reading of resetting a sim that is still misconfigured
    # (demo/scenarios.md §2.3).
    reset_ok=1
    for i in $(seq 1 12); do
        f="$(observe "reset-$attempt-$i" 1)"
        z="$(jget "$f" z_median)"
        say "  z median ${z:-unknown} m"
        [ -z "$z" ] && { require_sim "the reset" || break; }
        if gt "$z" 0.15; then reset_ok=0; break; fi
    done
    check "$reset_ok" "the robot left the floor after /reset_sim" \
          "z median ${z:-unknown} m -- the stress composition settles well under the 0.30 m it is commanded to"
    page simt 20
    page runs "06-runs-after-reset-attempt$attempt.json" "$RUN" "$verdict"
    page shot "05-renders/04-reset-attempt$attempt.png"
    page errors

    # #71: the preset falls on >= 2 of 3, and the verb reports which. Stop as
    # soon as that is settled -- a third attempt after two falls measures nothing
    # new and costs five minutes.
    [ "$fell_count" -ge "$NEED_FELL" ] && break
done

banner "the result"
say "fell $fell_count of $attempt attempts (needed $NEED_FELL)"
[ "$fell_count" -ge "$NEED_FELL" ]
check $? "the $KENNEL_PRESET preset falls on at least $NEED_FELL of $attempt attempts" \
      "fell $fell_count of $attempt -- stack/stress.md carries the measured rate"
# The degradation, asserted over the attempts for the same reason the fall is:
# both are properties of the composition, and both vary run to run.
if [ "$EXPECT_AMBER" = 1 ]; then
    [ "$mpc_amber_count" -ge 1 ]
    check $? "and the MPC block reached amber on at least one of them -- the degradation is visible" \
          "amber on $mpc_amber_count of $fell_count falling attempts (measured 2 of 3, stack/stress.md §4)"
else
    bypass "3 mpc-amber" \
           "measured: amber on $mpc_amber_count of $fell_count falling attempts. Set KENNEL_S003_EXPECT_MPC_AMBER=1 to assert it"
fi

totals
