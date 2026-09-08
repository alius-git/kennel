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
# WHAT IT ASSERTS, and what it only measures. s003 asks for a healthy walk that
# degrades visibly -- the MPC block going green -> amber, the feed carrying
# deadline violations with measured values -- and then falls. On this guest, at
# this pin, the MPC solve margin CANNOT be degraded by any composed
# configuration: measured across eighteen compositions, the solver takes 1.1-1.3
# ms against a 10 ms budget, and "as fast as possible" is only 2.2x
# (stack/stress.md §3). So:
#
#   asserted    the walk starts healthy; the run degrades through CONTACT stress
#               (early contacts on obstacle terrain, which is what the red
#               preset induces); the fall; the banner; the pinned window; the
#               order of the post-mortem; the verdict filed against the run; the
#               Runs row; the reset restoring a standing robot
#   BYPASS      the MPC block reaching amber, and a deadline-violation entry in
#               the feed. Both are PRINTED with what was measured, and both
#               become ordinary checks the moment KENNEL_S003_EXPECT_MPC_AMBER
#               or KENNEL_S003_EXPECT_DEADLINE is set -- their defaults are a
#               measured fact about this host, not a waiver.
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
#   KENNEL_S003_EXPECT_MPC_AMBER  0  see above
#   KENNEL_S003_EXPECT_DEADLINE   0  see above
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
EXPECT_AMBER="${KENNEL_S003_EXPECT_MPC_AMBER:-0}"
EXPECT_DEADLINE="${KENNEL_S003_EXPECT_DEADLINE:-0}"
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
if [ "$EXPECT_AMBER" = 1 ] || [ "$EXPECT_DEADLINE" = 1 ]; then
    echo "expecting    MPC amber=$EXPECT_AMBER, a deadline entry=$EXPECT_DEADLINE (asserted, not bypassed)"
else
    echo "expecting    contact stress, not solver stress -- the MPC margin is not"
    echo "             composable at this pin on this host (stack/stress.md §3)"
fi

start_server

fell_count=0
attempt=0
while [ "$attempt" -lt "$ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    banner "attempt $attempt of $ATTEMPTS"

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
    check "$lrc" "the stack launched on it" \
          "$(grep -E 'node graph complete' "$tmp/launch-$attempt.log" | sed 's/.*): //')"
    [ "$lrc" = 0 ] || { totals; exit 1; }
    RUN="$(applied_run)"
    say "applied run  $RUN"

    "$DEMO" teleop >"$tmp/teleop-$attempt.log" 2>&1
    capture_ps "before-$attempt"
    [ "$attempt" = 1 ] && cp "$OUT_DIR/06-process-diffs/ps-before-1.txt" \
                             "$OUT_DIR/06-process-diffs/ps-before.txt"
    start_chrome
    page boot
    page connect

    # ---- step 1: healthy
    banner "attempt $attempt · 1 · a live healthy run"
    page health "01-health-attempt$attempt.json"
    green="$(python3 -c "
import json
d = json.load(open('$OUT_DIR/01-health-attempt$attempt.json'))
bad = [b for b in d['blocks'] if b[1] not in ('green', 'off')]
print(len(bad), bad[:2])")"
    case "$green" in 0\ *) rc=0 ;; *) rc=1 ;; esac
    check "$rc" "every pipeline block starts green (or off, where the composition disabled it)" \
          "$green"
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
    fell=1
    amber_seen=""
    for i in $(seq 1 200); do
        kill -0 "$OBS_PID" 2>/dev/null || break
        page health "$tmp/h.json" >/dev/null 2>&1
        cat "$tmp/h.json" >> "$OUT_DIR/02-tint-history-attempt$attempt.jsonl"
        echo >> "$OUT_DIR/02-tint-history-attempt$attempt.jsonl"
        if [ -z "$amber_seen" ] && grep -q '"amber"' "$tmp/h.json"; then
            amber_seen="$(python3 -c "
import json
d = json.load(open('$tmp/h.json'))
print(','.join(b[0] for b in d['blocks'] if b[1] == 'amber'), 'at sim', d.get('sim'))")"
            say "  first amber: $amber_seen"
            page shot "05-renders/02-amber-attempt$attempt.png" >/dev/null 2>&1
        fi
        if python3 -c "
import json, sys
d = json.load(open('$tmp/h.json'))
sys.exit(0 if any(b[1] == 'red' for b in d['blocks']) else 1)" 2>/dev/null; then
            fell=0
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
for chunk in open(sys.argv[1]).read().split("}\n{"):
    c = chunk if chunk.startswith("{") else "{" + chunk
    c = c if c.endswith("}") else c + "}"
    try:
        rows.append(json.loads(c))
    except Exception:
        pass
if not rows:
    print("0 0 none"); raise SystemExit(0)
first = rows[0]["blocks"]
green0 = all(b[1] in ("green", "off") for b in first)
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
    case "$tint" in 1\ *) rc=0 ;; *) rc=1 ;; esac
    check "$rc" "the tint history starts green and ends red" "$tint"
    case "$tint" in *"amber: none"*) rc=1 ;; *) rc=0 ;; esac
    check "$rc" "and something went AMBER before the fall -- the degradation was visible" \
          "$tint"
    # The MPC block specifically: a BYPASS by default, because the margin is not
    # composable here (stack/stress.md §3), and an ordinary check when the knob
    # says the sweep found a composition that changes that.
    case "$tint" in 1\ 1\ *) mpc_amber=0 ;; *) mpc_amber=1 ;; esac
    if [ "$EXPECT_AMBER" = 1 ]; then
        check "$mpc_amber" "the MPC block reached amber before the fall" "$tint"
    elif [ "$mpc_amber" = 0 ]; then
        check 0 "the MPC block reached amber before the fall (it did, unexpectedly)" \
              "stack/stress.md §3 says it should not be reachable here -- worth re-running the sweep"
    else
        bypass "3 mpc-amber" \
               "measured: the MPC block never left green. The solve margin is not degradable by composition at this pin on this host (stack/stress.md §3); the red preset induces CONTACT stress. Retirement: an upstream MPC horizon/dt parameter, or a slower reference host. Set KENNEL_S003_EXPECT_MPC_AMBER=1 to assert it"
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
    [ "$(j nothing_later)" = True
    ]; check $? "nothing in the pinned window happened after the fall (step 7's order)" "$order"
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
               "measured: $(j deadline) deadline violations and $(j solver_failed) solver failures in the pinned window. The MPC solves in 1.1-1.3 ms against a 10 ms budget whatever is composed (stack/stress.md §3), so there is nothing to violate. Set KENNEL_S003_EXPECT_DEADLINE=1 to assert it"
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
    banner "attempt $attempt · 8 · reset: standing again, the record kept"
    page reset
    standing=1
    for i in $(seq 1 12); do
        f="$(observe "reset-$attempt-$i" 1)"
        z="$(jget "$f" z_median)"
        say "  z median ${z:-unknown} m"
        [ -z "$z" ] && { require_sim "the reset" || break; }
        if num_ok "$z" 0.25 0.35; then standing=0; break; fi
    done
    check "$standing" "the robot is standing again after /reset_sim" "z median ${z:-unknown} m"
    page nobanner
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

totals
