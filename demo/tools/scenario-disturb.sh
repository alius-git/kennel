#!/bin/bash
# Version: 2026.09.08
# Kennel -- issue #69: scenario s004.disturb, as a verb.
#
#   demo/tools/kennel-demo.sh scenario disturb
#
# Runs on the HOST, against a guest whose stack is up and whose applied run was
# composed WITH DISTURBANCES ON (#68) -- the disturbance service is block 4 of
# that run's commands.txt and does not otherwise exist.
#
# It walks plan/scenarios.md's s004 step by step and asserts each one from the
# witness that can actually see it:
#
#   1 velocity change    the joystick, and the guest's own measurement of what
#                        the robot did
#   2 moderate push      100 N for 0.2 s -> a stagger and a recovery
#   3 severe push        300 N sideways for 0.3 s -> a fall, the banner, and the
#                        disturbance inside the pinned post-mortem window
#   4 reset              /reset_sim from the console -> standing, the Dashboard
#                        cleared, and the fallen run's record still listed
#   5 manual stepping    OUT: manually_step_sim is fixed at stock
#                        (composer-scope.md §1.2). Printed as a BYPASS so the
#                        transcript is complete against the scenario's numbering
#   6 the process table  captured before, during and after EVERY step and
#                        diffed. This is the scenario's Target Verification
#                        Point and design.md's hard constraint made mechanical:
#                        the console called services and published topics, and
#                        never started or stopped a process.
#
# Every number about the robot comes out of k13-target-monitor.py running in the
# container (`kennel-bridge.sh observe`), never out of a variable read back from
# the page under test (kennel_console/dashboard.md §4). Every fact about the
# page is read from the DOM.
#
# IT LEAVES THE STACK STANDING AT STAND ON EVERY PATH: the trap disconnects the
# page, stops teleop (zero, STAND, bridge down -- in that order) and, if the
# robot is on the floor, runs `kennel-bridge.sh recover`.
#
# Knobs (environment variables):
#   KENNEL_SCENARIO_PORT   8094   the serve.py this scenario starts
#   KENNEL_SCENARIO_CDP    9294   the Chrome it drives
#   KENNEL_S004_PUSH_MODERATE  "100 0 0 0.2"   fx fy fz seconds. The measured
#                          stagger-and-recover push (plan/two-scenarios.md §0.1)
#   KENNEL_S004_PUSH_SEVERE    "0 300 0 0.3"   the measured felling push
#   KENNEL_S004_VX_TOL     0.2    the +/- band on the commanded velocity, as a
#                          fraction -- scenarios.md s004 step 1 says "converge"
#   KENNEL_S004_EVIDENCE   demo/evidence/s004-disturb
#   plus the guest knobs of verify-bridge-host.sh, passed through untouched.
#
# Exit codes:
#   0  every check passed
#   1  a check failed
#   2  could not run the checks (no chrome, no guest, no stack, a run composed
#      without disturbances, a port in use, not run from a checkout)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
DEMO="$HERE/kennel-demo.sh"
OUT_DIR="${KENNEL_S004_EVIDENCE:-$REPO_ROOT/demo/evidence/s004-disturb}"
# shellcheck source=scenario-lib.sh
. "$HERE/scenario-lib.sh"

MODERATE="${KENNEL_S004_PUSH_MODERATE:-100 0 0 0.2}"
SEVERE="${KENNEL_S004_PUSH_SEVERE:-0 300 0 0.3}"
VX_TOL="${KENNEL_S004_VX_TOL:-0.2}"
# TELEOP_VMAX in the console: a fully-pushed stick asks for this.
STICK_VX="${KENNEL_S004_STICK_VX:-0.5}"

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
    # If it is on the floor, put it back on its feet -- a failed scenario must
    # not cost the next one a relaunch it can avoid. Bounded, and best effort.
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

echo "=== scenario s004.disturb -- interventions, and the process set that never changes (#69) ==="
date -u +%FT%TZ
scenario_preflight disturb
trap cleanup EXIT

echo "guest        $GUEST_HOSTNAME at $GUEST_IP"
echo "evidence     $OUT_DIR"
echo "pushes       moderate [$MODERATE]   severe [$SEVERE]"
# The exclusion list is printed because an exclusion list is exactly where a
# check like the process-table one goes quietly wrong.
echo "ps excludes  $HARNESS_RE"

RUN="$(applied_run)"
echo "applied run  ${RUN:-<none>}"
[ -n "$RUN" ] || { fail "the guest has no applied run." \
    "Compose and run one:  KENNEL_DISTURBANCES=1 $DEMO compose && $DEMO run"; exit 2; }
[ "$(applied_choice disturbances)" = "true" ] || {
    fail "the applied run ($RUN) was composed with disturbances OFF." \
         "s004 needs the disturbance service, which is block 4 of commands.txt (#68):" \
         "  KENNEL_DISTURBANCES=1 $DEMO compose" \
         "  $DEMO run"; exit 2; }
# Block 4's own wait proved this at launch; a scenario that starts its own
# session asks again, because the launch may have been hours ago.
srv="$(ssh "${SSH_OPTS[@]}" "$TARGET" \
       "sudo docker exec $CONTAINER bash -c 'source /tmp/p21-env.sh >/dev/null 2>&1; timeout 15 ros2 service list 2>/dev/null'" \
       2>/dev/null | grep -c '^/disturb_simulation$')"
[ "$srv" = 1 ] || { fail "/disturb_simulation is not being served on the guest." \
    "The run says disturbances on, so block 4 should be running. Relaunch:  $DEMO launch"; exit 2; }
say "/disturb_simulation is served"

# ---------------------------------------------------------------- step 0
banner "0 · seed: a defined starting state, the bridge up, the reference process set"
"$DEMO" teleop >"$tmp/teleop.log" 2>&1
trc=$?
check "$trc" "kennel-demo.sh teleop brought the bridge up" \
      "$(grep -E '^\[kennel-demo\] bridge ' "$tmp/teleop.log" | head -1)"
[ "$trc" = 0 ] || { totals; exit 1; }

# A DEFINED STARTING STATE, and it is not a nicety. Measured 2026-09-08: a stack
# left at STAND after a walk can be sitting on the floor at z 0.13 m with the
# body over 0.5 rad -- and a 100 N push at a robot in that contact configuration
# ABORTS Drake's SAP solver and takes the simulator with it
# (sap_solver.cc:342, exit 134). Every number after that is measured against a
# corpse. So: recover first, then assert the state the scenario starts from.
# The same lesson stack/bridge.md §10.7 records for the live suite, one scenario
# further on.
say "establishing the starting state (kennel-bridge.sh recover)"
ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/kennel-bridge.sh recover" >"$tmp/recover.log" 2>&1
grep -E 'recovered|NONZERO' "$tmp/recover.log" | sed 's/^/[scenario]   /'
f="$(observe start 3)"
z0="$(jget "$f" z_median)"; t0="$(jget "$f" tilt_over_frac)"
num_ok "$z0" 0.25 0.35
check $? "the scenario starts from a robot that is standing" "z median ${z0:-unknown} m"
num_ok "$t0" 0 0.02
check $? "  and upright" "tilt over 0.5 rad in ${t0:-?} of samples"
if ! num_ok "$z0" 0.25 0.35 || ! num_ok "$t0" 0 0.02; then
    say "refusing to measure a scenario from a degenerate state -- relaunch:  $DEMO launch"
    totals; exit 1
fi
# BEFORE the page connects: this capture is the reference every later one is
# diffed against, and it already contains the disturber, the bridge's three and
# the watchdog -- all of them stack processes, none of them the console's.
capture_ps before
say "reference process set: $(wc -l < "$OUT_DIR/06-process-diffs/ps-before.txt") processes"
start_server
start_chrome
page boot
page connect
f="$(observe seed 3)"
# The WALL-clock rate, which is the one the page controls: its tick is a
# setInterval, and per SIM second the same stream reads 20/rate. The live suite
# made this correction first (stack/bridge.md §10) and it applies here for the
# same reason -- at any rtf but exactly 1.0 the sim-second reading is a true
# number about a different thing.
hzw="$(jget "$f" target.hz_wall)"; hzs="$(jget "$f" target.hz)"
num_ok "$hzw" 18 22
check $? "the page is publishing at 20 Hz" \
      "${hzw:-none} Hz wall (${hzs:-?} per sim-second at rtf $(jget "$f" rtf))"
dvx="$(jget "$f" target.distinct_vx)"
[ "$dvx" = "[0.0]" ]; check $? "and it is publishing zeros -- nobody has touched the stick" "$dvx"
[ -z "$(jget "$f" disturbance)" ] || [ "$(jget "$f" disturbance)" = "null" ]
check $? "nothing has been injected yet" "$(jget "$f" disturbance)"

# ---------------------------------------------------------------- step 1
banner "1 · velocity change: commanded and measured converge"
page gait WALKING_TROT
page stick -1
observe_bg vel 8 --rows
check $? "a measurement window is open"
sleep 1
wait "$OBS_PID"
cp "$OBS_FILE" "$OUT_DIR/04-traces/01-velocity.csv"
speed="$(jget "$OBS_FILE" speed_mean)"
lo="$(awk -v v="$STICK_VX" -v t="$VX_TOL" 'BEGIN{printf "%.3f", v*(1-t)}')"
hi="$(awk -v v="$STICK_VX" -v t="$VX_TOL" 'BEGIN{printf "%.3f", v*(1+t)}')"
num_ok "$speed" "$lo" "$hi"
check $? "measured speed is within ${VX_TOL/0./}0 % of the ${STICK_VX} m/s commanded" \
      "${speed:-none} m/s, band $lo-$hi (planar: /quad_state twist is world-frame, bridge.md §10.7)"
dist="$(jget "$OBS_FILE" dist_xy)"
gt "$dist" 0; check $? "and the robot actually travelled" "${dist:-none} m"
tilt="$(jget "$OBS_FILE" tilt_over_frac)"
num_ok "$tilt" 0 0.02; check $? "upright throughout" "tilt over 0.5 rad in ${tilt:-?} of samples"
gaitname="$(jget "$OBS_FILE" gait.name)"
[ "$gaitname" = "WALKING_TROT" ]; check $? "the gait the picker asked for is the one running" \
    "/gait_state's signature reads $gaitname (gait.cpp's own table; the message carries no name)"
capture_ps after-velocity
ps_same after-velocity

# ---------------------------------------------------------------- step 2
banner "2 · moderate push: a stagger, and a recovery"
observe_bg moderate 10 --rows
check $? "a measurement window is open"
sleep 1
# shellcheck disable=SC2086
page inject $MODERATE
wait "$OBS_PID"
cp "$OBS_FILE" "$OUT_DIR/04-traces/02-moderate.csv"
mag="$(awk -v a="${MODERATE%% *}" 'BEGIN{print a}')"
fmag="$(jget "$OBS_FILE" disturbance.force_max_norm)"
want_mag="$(python3 -c "
import sys
fx, fy, fz, _ = '$MODERATE'.split()
print('%.1f' % ((float(fx)**2 + float(fy)**2 + float(fz)**2) ** 0.5))")"
num_ok "$fmag" "$(awk -v m="$want_mag" 'BEGIN{print m-0.5}')" "$(awk -v m="$want_mag" 'BEGIN{print m+0.5}')"
check $? "the SIMULATOR was pushed with the magnitude the page asked for" \
      "${fmag:-none} N on /simulation_disturbance (the node rotates the vector into the robot's yaw frame; the magnitude is what survives)"
nd="$(jget "$OBS_FILE" disturbance.n)"
[ "$nd" = 2 ]; check $? "as one push and one zero, which is what a bounded disturbance is" "n=$nd"
simgap="$(jget "$OBS_FILE" disturbance.sim_gap)"
want_dur="$(echo "$MODERATE" | awk '{print $4}')"
num_ok "$simgap" "$(awk -v d="$want_dur" 'BEGIN{print d*0.8}')" "$(awk -v d="$want_dur" 'BEGIN{print d*1.25}')"
check $? "and it lasted the SIM seconds it was asked for" \
      "${simgap:-none} sim-s against ${want_dur} asked (wall $(jget "$OBS_FILE" disturbance.wall_gap) s)"
zmin="$(jget "$OBS_FILE" z_min)"
gt "$zmin" 0.15; check $? "the robot staggered but never went down" "z_min ${zmin:-none} m"
tilt="$(jget "$OBS_FILE" tilt_over_frac)"
num_ok "$tilt" 0 0.02; check $? "and stayed upright" "tilt over 0.5 rad in ${tilt:-?} of samples"
speed="$(jget "$OBS_FILE" speed_mean)"
num_ok "$speed" "$lo" "$hi"
check $? "it recovered the commanded speed inside the window" "${speed:-none} m/s over the whole 10 s"
page nobanner
page shot 05-renders/02-moderate.png
capture_ps after-moderate
ps_same after-moderate

# ---------------------------------------------------------------- step 3
banner "3 · severe push: a fall, and the disturbance inside the post-mortem"
observe_bg severe 12 --rows
check $? "a measurement window is open"
sleep 1
# shellcheck disable=SC2086
page inject $SEVERE
wait "$OBS_PID"
cp "$OBS_FILE" "$OUT_DIR/04-traces/03-severe.csv"
fmag="$(jget "$OBS_FILE" disturbance.force_max_norm)"
want_mag="$(python3 -c "
fx, fy, fz, _ = '$SEVERE'.split()
print('%.1f' % ((float(fx)**2 + float(fy)**2 + float(fz)**2) ** 0.5))")"
num_ok "$fmag" "$(awk -v m="$want_mag" 'BEGIN{print m-1}')" "$(awk -v m="$want_mag" 'BEGIN{print m+1}')"
check $? "the severe push reached the simulator" "${fmag:-none} N"
zmin="$(jget "$OBS_FILE" z_min)"; tilt="$(jget "$OBS_FILE" tilt_over_frac)"
# verify.md §4's own rule, applied to the guest's numbers: a fall is the body on
# the floor OR a sustained attitude violation. belly_contact never fires at this
# pin (§4.1), so it is not part of it.
if lt "$zmin" 0.15 || gt "$tilt" 0.15; then fell=0; else fell=1; fi
check "$fell" "the robot FELL, by the verification recipe's own rule" \
      "z_min ${zmin:-?} m, tilt over 0.5 rad in ${tilt:-?} of samples"
page banner 25
page feed 03-feed.json
page shot 05-renders/03-fall.png
# s004 step 3: "the disturbance event visible in the pinned window immediately
# before the fall". The feed dump is the pinned window itself, because the
# banner pins it -- so this reads the file the page just wrote.
python3 - "$OUT_DIR/03-feed.json" "$want_mag" > "$tmp/feedcheck.txt" 2>&1 <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
mag = float(sys.argv[2])
texts = [t for _, t in rows]
dist = [i for i, t in enumerate(texts) if t.startswith("Disturbance: %.0f N" % mag)]
fall = [i for i, t in enumerate(texts) if t.startswith("FALL:")]
times = [float(t.rstrip("s")) for t, _ in rows]
print("rows=%d disturbance_at=%s fall_at=%s" % (len(rows), dist, fall))
print("ORDER_OK" if dist and fall and dist[-1] < fall[0] else "ORDER_BAD")
# The pin holds [fallAt - 5, fallAt] and the feed's stamps are 0.1-s sim bins,
# so an event can legitimately SHARE the fall's bin and be rendered after it.
# What the post-mortem has to be true about is time: nothing later than the fall.
later = [texts[i] for i, t in enumerate(times) if fall and t > times[fall[0]] + 1e-9]
print("NOTHING_LATER" if fall and not later else "LATER: %s" % later[:2])
PY
grep -q ORDER_OK "$tmp/feedcheck.txt"
check $? "the disturbance is in the pinned window, before the fall" \
      "$(head -1 "$tmp/feedcheck.txt")"
grep -q NOTHING_LATER "$tmp/feedcheck.txt"
check $? "and nothing in the pinned window happened after the fall (s003 step 7's order)" \
      "$(sed -n 3p "$tmp/feedcheck.txt")"
capture_ps after-severe
ps_same after-severe

# ---------------------------------------------------------------- step 3v
banner "3v · the verdict: verify records what happened to this run"
# The recipe commands its own trot (checks 6-9), so the page must not be
# publishing while it runs -- two publishers on /quad_control_target do not
# merge (bridge.md §7).
page release
page disconnect
# WHICH verdict is the right one is decided by the robot, not by this script.
# Measured 2026-09-08: a disturbance fall is TRANSIENT -- pushed over at 300 N
# the robot reached z 0.105 m with the body past 0.5 rad in 74 % of samples, and
# was back at z 0.31 m and walking eleven sim-seconds later, inside the same
# observation window. kennel-verify.sh's verdict is about the state during ITS
# OWN window, which starts after that, so a stack that self-righted honestly
# reports `completed`. Asserting `fell` unconditionally would be asserting that
# the robot stays down, which this robot does not.
f="$(observe before-verify 3)"
zv="$(jget "$f" z_median)"
say "the robot is at z ${zv:-unknown} m going into verify"
"$DEMO" verify >"$tmp/verify-after-fall.log" 2>&1
vrc=$?
folder="$OUT/$RUN"
verdict="$(python3 -c "
import json
try: print(json.load(open('$folder/verify.json'))['verdict'])
except Exception: print('')" 2>/dev/null)"
# WHICH verdict is the right one is decided by the robot, not by this script,
# and it varies: measured z 0.312 m after one severe push and 0.206 m after the
# next, which gave `completed` and `unhealthy` from the same scenario step. A
# disturbance fall is REAL and TRANSIENT -- the robot rights itself in a few sim
# seconds -- and kennel-verify.sh judges the state during its OWN window, which
# opens after that. So the assertion is the one that holds either way: a report
# was filed, for THIS run, carrying a verdict the recipe defines (verify.md §8).
# The verdict itself is reported. demo/scenarios.md §s004 carries the finding:
# #69 expected `fell` here, and `fell` is what you get only if the robot is
# still down when the recipe looks.
case "$verdict" in
    fell|unhealthy|solver-failed|completed) ok_verdict=0 ;;
    *) ok_verdict=1 ;;
esac
check "$ok_verdict" "verify filed a report for this run, with a verdict the recipe defines" \
      "${verdict:-<no verify.json>} in $RUN/verify.json (exit $vrc, robot at z ${zv:-?} m)"
if [ "$verdict" = completed ]; then
    say "  the robot self-righted after the push: the fall was real and transient"
else
    say "  the robot was still down or unsteady when the recipe opened its window"
fi
cp "$folder/verify.json" "$OUT_DIR/03-verify-after-fall.json" 2>/dev/null
grep -E 'pass=|expect disturber' "$tmp/verify-after-fall.log" | sed 's/^/[scenario]   /'
capture_ps after-verify
ps_same after-verify

# ---------------------------------------------------------------- step 3r
banner "3r · the record: the Runs view shows it"
page connect
page runs 03-runs.json "$RUN" "$verdict"

# ---------------------------------------------------------------- step 4
banner "4 · reset: standing again, the Dashboard cleared, the record kept"
page reset
# Wait for the ROBOT, never for a clock: /reset_sim answers the moment the
# context is replaced, and the body still has to fall its spawn height and
# settle (about one sim-second, measured).
standing=1
for i in $(seq 1 12); do
    f="$(observe reset-$i 1)"
    z="$(jget "$f" z_median)"
    say "  z median ${z:-unknown} m"
    if [ -z "$z" ]; then
        require_sim "the reset" || break
    fi
    if num_ok "$z" 0.25 0.35; then standing=0; cp "$f" "$OUT_DIR/04-traces/04-reset.txt"; break; fi
done
check "$standing" "the robot is standing again after /reset_sim" "z median ${z:-unknown} m"
page nobanner
page simt 20
page feed 04-feed.json
python3 - "$OUT_DIR/04-feed.json" > "$tmp/resetfeed.txt" 2>&1 <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
texts = [t for _, t in rows]
call = [i for i, t in enumerate(texts) if t.startswith("/reset_sim called")]
clock = [i for i, t in enumerate(texts) if t.startswith("sim clock restarted at")]
print("call_at=%s clock_at=%s" % (call, clock))
print("BOTH_IN_ORDER" if call and clock and call[-1] < clock[-1] else "MISSING_OR_OUT_OF_ORDER")
PY
grep -q BOTH_IN_ORDER "$tmp/resetfeed.txt"
check $? "the feed carries the call and then its consequence" \
      "$(head -1 "$tmp/resetfeed.txt") -- '/reset_sim called ...' then 'sim clock restarted at ...'"
page runs 04-runs.json "$RUN" "$verdict"
page shot 05-renders/04-reset.png
capture_ps after-reset
ps_same after-reset

# ---------------------------------------------------------------- step 5
banner "5 · manual stepping"
bypass "5 manual-stepping" \
       "manually_step_sim is fixed at stock (composer-scope.md §1.2), so /step_sim is not served. Retirement: the composer offering the key, then the console's two step buttons calling it. demo/scenarios.md §s004"

# ---------------------------------------------------------------- step 6, 9
banner "6 · the process table, across every step"
say "six captures, each diffed against the reference taken before the page connected:"
ls "$OUT_DIR/06-process-diffs"/ps-*.txt | sed 's/^/[scenario]   /'
page errors

totals
