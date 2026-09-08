#!/bin/bash
# Version: 2026.09.08
# Kennel -- issue #70: measure the MPC solve margin across the composer's MVP
# knobs, and pick the stress preset from the table rather than from a guess.
#
#   stack/verify/tools/k14-sweep.sh [--points FILE] [--out DIR] [--sim-seconds N]
#
# Runs on the HOST. It OWNS THE GUEST for the length of the sweep: every point is
# a full compose -> transfer -> launch -> verify -> walk -> observe -> walk stop,
# which is the only honest way to measure a composition (the values only take
# effect at launch -- mapping.md §5 tier 2). Do not run it with a console
# connected or a trot held from another verb.
#
# WHAT IT MEASURES, and why it is not a guess. design.md §1 chose "disturbance
# service + stress preset (a composed configuration that predictably degrades
# MPC solve margin)" as the fault-injection mechanism, and #70 says
# "measurements, not guesses; one table". The margin is /solve_time against
# MPC_CONTROL_DT: the controller runs its MPC on a SIM-time timer every 10 ms
# and measures the solve with a WALL clock (mit_controller_node.cpp:885, :910).
# So simulator_realtime_rate 0 -- "as fast as possible" -- is the knob that looks
# like it should matter, and the sweep is what decides whether it does.
#
# Each point writes one CSV row and keeps its run folder, so any row can be
# reproduced with `kennel-demo.sh run <folder>`. A point whose verify fails is a
# DATA POINT, not a failure: obstacle terrain is expected to fall
# (transfer.md §6.3), and that is the red candidate.
#
# THE POINTS. The issue's grid pruned by composer-scope.md §2's 2x2: HPIPM mode
# is read only by the two HPIPM solvers, and condensed size only by the two
# partial-condensing ones, so the other cells differ in name and not in
# mechanism. What is left is 18 points -- 9 compositions at rate 1.0 and at
# rate 0 -- plus the red candidate three times.
#
# Knobs (environment variables):
#   KENNEL_SWEEP_SIM_SECONDS  20   the measurement window per point, in SIM s
#   KENNEL_SWEEP_OUT          stack/stress/evidence/sweep-<stamp>
#   KENNEL_SWEEP_RED          "PARTIAL_CONDENSING_OSQP 1.0 obstacle_terrain"
#                                  the red candidate: solver, rate, map
#   KENNEL_SWEEP_RED_RUNS     3    how many times to run it (#70 asks for three)
#   KENNEL_DEMO_OUT           ~/kennel-runs   where compose writes
#   plus the guest knobs of kennel-demo.sh, passed through untouched.
#
# Exit codes:
#   0  every point produced a row
#   1  a point could not be measured (its row says why, and the sweep went on)
#   2  could not start: no guest, no chrome, no console to compose in

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
DEMO="$REPO_ROOT/demo/tools/kennel-demo.sh"
SIM_SECONDS="${KENNEL_SWEEP_SIM_SECONDS:-20}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${KENNEL_SWEEP_OUT:-$REPO_ROOT/stack/stress/evidence/sweep-$STAMP}"
RED="${KENNEL_SWEEP_RED:-PARTIAL_CONDENSING_OSQP 1.0 obstacle_terrain}"
RED_RUNS="${KENNEL_SWEEP_RED_RUNS:-3}"
POINTS_FILE="${KENNEL_SWEEP_POINTS:-}"

say()  { echo "[k14-sweep] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

command -v google-chrome >/dev/null || { fail "google-chrome is required -- compose drives it."; exit 2; }
[ -x "$DEMO" ] || { fail "no driver at $DEMO."; exit 2; }

mkdir -p "$OUT/runs" "$OUT/points"
CSV="$OUT/sweep.csv"
LOG="$OUT/sweep.log"

# name solver hpipm condensed rate map
default_points() {
    cat <<'POINTS'
hpipm-speed-5-r1     PARTIAL_CONDENSING_HPIPM   SPEED   5   1.0  -
hpipm-robust-5-r1    PARTIAL_CONDENSING_HPIPM   ROBUST  5   1.0  -
hpipm-speed-1-r1     PARTIAL_CONDENSING_HPIPM   SPEED   1   1.0  -
hpipm-speed-10-r1    PARTIAL_CONDENSING_HPIPM   SPEED   10  1.0  -
fullhpipm-robust-r1  FULL_CONDENSING_HPIPM      ROBUST  -   1.0  -
osqp-5-r1            PARTIAL_CONDENSING_OSQP    -       5   1.0  -
osqp-1-r1            PARTIAL_CONDENSING_OSQP    -       1   1.0  -
osqp-10-r1           PARTIAL_CONDENSING_OSQP    -       10  1.0  -
qpoases-r1           FULL_CONDENSING_QPOASES    -       -   1.0  -
hpipm-speed-5-r0     PARTIAL_CONDENSING_HPIPM   SPEED   5   0    -
hpipm-robust-5-r0    PARTIAL_CONDENSING_HPIPM   ROBUST  5   0    -
hpipm-speed-1-r0     PARTIAL_CONDENSING_HPIPM   SPEED   1   0    -
hpipm-speed-10-r0    PARTIAL_CONDENSING_HPIPM   SPEED   10  0    -
fullhpipm-robust-r0  FULL_CONDENSING_HPIPM      ROBUST  -   0    -
osqp-5-r0            PARTIAL_CONDENSING_OSQP    -       5   0    -
osqp-1-r0            PARTIAL_CONDENSING_OSQP    -       1   0    -
osqp-10-r0           PARTIAL_CONDENSING_OSQP    -       10  0    -
qpoases-r0           FULL_CONDENSING_QPOASES    -       -   0    -
POINTS
}

if [ -n "$POINTS_FILE" ]; then
    [ -f "$POINTS_FILE" ] || { fail "no points file at $POINTS_FILE"; exit 2; }
    cp "$POINTS_FILE" "$OUT/points.txt"
else
    default_points > "$OUT/points.txt"
fi
# The red candidate, repeated: a composition that falls is only a preset if it
# falls REPEATEDLY, and transfer.md §6.3 measured obstacle terrain failing
# differently on repeat -- which is exactly why the number of runs is a knob and
# the outcome of each is a row.
set -- $RED
for i in $(seq 1 "$RED_RUNS"); do
    printf 'red-%d  %s  -  -  %s  %s\n' "$i" "$1" "$2" "$3" >> "$OUT/points.txt"
done

echo "point,solver,hpipm_mode,condensed,rate,map,rtf,mpc_mean_ms,mpc_p50_ms,mpc_p95_ms,mpc_max_ms,mpc_iters,mpc_over_deadline,wbc_p95_ms,wbc_over_deadline,overtime_d,mpc_fail_d,wbc_fail_d,early_d,verify_overtime,verify_exit,verdict,walked,fell,speed_mean,dist_xy,z_median,tilt_over_frac,run" > "$CSV"

{
echo "=== k14-sweep -- the MPC solve margin across the composer's MVP knobs (#70) ==="
date -u +%FT%TZ
echo "window       $SIM_SECONDS sim seconds per point"
echo "points       $(grep -c . "$OUT/points.txt") ($(grep -c '^red-' "$OUT/points.txt") of them the red candidate: $RED)"
echo "out          $OUT"
echo "deadline     MPC 10 ms (MPC_CONTROL_DT), WBC 2 ms (WBC_CYCLE_DT) -- wall clock, per sim-time cycle"
echo
} | tee "$LOG"

# The probe is a CONTAINER tool; kennel-bridge.sh copies it in and runs it,
# which is how every other live measurement here reads the stack. Staged once.
GUEST_STAGED=0
stage_probe() {
    [ "$GUEST_STAGED" = 1 ] && return 0
    "$DEMO" status >/dev/null 2>&1
    local ip key user
    ip="${KENNEL_GUEST_IP:-$(virsh net-dhcp-leases "${KENNEL_LIBVIRT_NET:-default}" 2>/dev/null \
         | awk -v h="${KENNEL_GUEST_HOSTNAME:-kennel-vm}" '$0 ~ h {print $5}' | cut -d/ -f1 | tail -1)}"
    [ -n "$ip" ] || { fail "could not discover the guest."; exit 2; }
    key="${KENNEL_SSH_KEY:-$HOME/git/yuruna/test/status/ssh/yuruna_ed25519}"
    user="${KENNEL_GUEST_USER:-yuuser24}"
    SSH_OPTS=(-i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
              -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)
    TARGET="$user@$ip"
    scp "${SSH_OPTS[@]}" -q "$HERE/k14-solve-probe.py" "$REPO_ROOT/stack/bridge/kennel-bridge.sh" \
        "$TARGET:/tmp/" || { fail "could not stage the probe to the guest."; exit 2; }
    ssh -n "${SSH_OPTS[@]}" "$TARGET" "chmod +x /tmp/kennel-bridge.sh" || exit 2
    GUEST_STAGED=1
    say "probe staged to $TARGET:/tmp/k14-solve-probe.py"
}

jget() {   # $1 = file, $2 = dotted path
    python3 - "$1" "$2" <<'PY'
import json, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8", errors="replace")
         if l.startswith("KENNEL_JSON ")]
if not lines:
    print(""); raise SystemExit(0)
d = json.loads(lines[-1][len("KENNEL_JSON "):])
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else (json.dumps(d) if isinstance(d, (list, dict)) else d))
PY
}

vjget() {   # $1 = verify.json, $2 = dotted path
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit(0)
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)
PY
}
# One check's status out of a verify report, by number.
vcheck() {   # $1 = verify.json, $2 = check number
    python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); raise SystemExit(0)
for c in d.get("checks", []):
    if c.get("n") == int(sys.argv[2]):
        print(c.get("status", "")); raise SystemExit(0)
print("")
PY
}

rc_all=0
n=0
run_prev=""
total="$(grep -c . "$OUT/points.txt")"
# The points are read ONCE into an array rather than streamed into the loop.
# `while read ... done < file` is the obvious shape and it is wrong here: every
# tool in the body runs ssh, ssh reads stdin, and the first point swallows the
# rest of the file -- the sweep then reports one row and exits looking healthy.
mapfile -t POINTS < "$OUT/points.txt"
for line in "${POINTS[@]}"; do
    [ -n "$line" ] || continue
    read -r name solver mode cond rate map <<< "$line"
    n=$((n + 1))
    t0=$SECONDS
    say "[$n/$total] $name -- $solver mode=$mode cond=$cond rate=$rate map=$map"
    plog="$OUT/points/$name.log"
    {
        echo "=== $name ==="; date -u +%FT%TZ
        echo "solver=$solver hpipm=$mode condensed=$cond rate=$rate map=$map"
        echo

        env_args=(KENNEL_SOLVER="$solver" KENNEL_RATE="$rate")
        [ "$mode" != "-" ] && env_args+=(KENNEL_HPIPM_MODE="$mode")
        [ "$cond" != "-" ] && env_args+=(KENNEL_CONDENSED="$cond")
        [ "$map" != "-" ] && env_args+=(KENNEL_MAP="$map")

        echo "--- compose"
        env "${env_args[@]}" "$DEMO" compose </dev/null 2>&1 | grep -E '\[ok |\[FAIL|run folder'
    } > "$plog" 2>&1
    before_run="$run_prev"
    run="$(ls -dt "${KENNEL_DEMO_OUT:-$HOME/kennel-runs}"/run-*/ 2>/dev/null | head -1 | sed 's:/$::')"
    # Compose is this point's precondition. Without a NEW run folder the rest of
    # the point would launch and measure the PREVIOUS point's composition and
    # file the numbers under this point's name -- the worst kind of wrong row.
    if [ -z "$run" ] || [ "$run" = "$before_run" ]; then
        say "  [$n/$total] compose produced no run folder -- see $plog"
        rc_all=1
        printf '%s,%s,%s,%s,%s,%s,,,,,,,,,,,,,,,,%s,,,,,,,\n' \
            "$name" "$solver" "$mode" "$cond" "$rate" "$map" "compose-failed" >> "$CSV"
        continue
    fi
    run_prev="$run"
    {
        echo "--- transfer + launch"
        "$DEMO" transfer </dev/null 2>&1 | grep -E '^\[kennel-demo\] run |NONZERO|matches' | head -6
        "$DEMO" launch </dev/null 2>&1 | grep -E '^\[p21-launch\]   |stack is up|NONZERO'
        echo "--- verify"
        "$DEMO" verify </dev/null 2>&1 | grep -E '^\[(PASS|FAIL|INFO)\]|pass=|verify report|NONZERO'
        echo "--- walk, then measure $SIM_SECONDS sim-s"
        "$DEMO" walk </dev/null 2>&1 | grep -E 'trotting|NONZERO'
    } >> "$plog" 2>&1
    stage_probe
    ssh -n "${SSH_OPTS[@]}" "$TARGET" \
        "KENNEL_MONITOR=/tmp/k14-solve-probe.py /tmp/kennel-bridge.sh observe $SIM_SECONDS --label $name" \
        >"$OUT/points/$name.json" 2>>"$plog"
    "$DEMO" walk stop </dev/null >>"$plog" 2>&1

    # Keep the run folder beside its row, so the row is reproducible.
    if [ -n "$run" ] && [ -d "$run" ]; then
        cp -r "$run" "$OUT/runs/" 2>/dev/null
        vj="$run/verify.json"
    else
        vj=/nonexistent
    fi

    rtf="$(jget "$OUT/points/$name.json" rtf)"
    if [ -z "$rtf" ]; then
        say "  [$n/$total] no measurement -- see $plog"
        rc_all=1
        printf '%s,%s,%s,%s,%s,%s,,,,,,,,,,,,,,,%s,,,,,,,%s\n' \
            "$name" "$solver" "$mode" "$cond" "$rate" "$map" "measure-failed" "$(basename "${run:-none}")" >> "$CSV"
        continue
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$name" "$solver" "$mode" "$cond" "$rate" "$map" \
        "$rtf" \
        "$(jget "$OUT/points/$name.json" mpc.mean_ms)" \
        "$(jget "$OUT/points/$name.json" mpc.p50_ms)" \
        "$(jget "$OUT/points/$name.json" mpc.p95_ms)" \
        "$(jget "$OUT/points/$name.json" mpc.max_ms)" \
        "$(jget "$OUT/points/$name.json" mpc.iters_mean)" \
        "$(jget "$OUT/points/$name.json" mpc.over_deadline)" \
        "$(jget "$OUT/points/$name.json" wbc.p95_ms)" \
        "$(jget "$OUT/points/$name.json" wbc.over_deadline)" \
        "$(jget "$OUT/points/$name.json" hb_deltas.num_mpc_solver_overtime)" \
        "$(jget "$OUT/points/$name.json" hb_deltas.num_mpc_solver_fail)" \
        "$(jget "$OUT/points/$name.json" hb_deltas.num_wbc_solver_fail)" \
        "$(jget "$OUT/points/$name.json" hb_deltas.num_early_contacts)" \
        "$(vjget "$vj" headline.mpc_overtime)" \
        "$(vjget "$vj" exit)" \
        "$(vjget "$vj" verdict)" \
        "$(vcheck "$vj" 8)" \
        "$(vcheck "$vj" 9)" \
        "$(jget "$OUT/points/$name.json" speed_mean)" \
        "$(jget "$OUT/points/$name.json" dist_xy)" \
        "$(jget "$OUT/points/$name.json" z_median)" \
        "$(jget "$OUT/points/$name.json" tilt_over_frac)" \
        "$(basename "${run:-none}")" >> "$CSV"
    say "  [$n/$total] rtf $(jget "$OUT/points/$name.json" rtf) · mpc p95 $(jget "$OUT/points/$name.json" mpc.p95_ms) ms · overtime Δ $(jget "$OUT/points/$name.json" hb_deltas.num_mpc_solver_overtime) · verdict $(vjget "$vj" verdict) · $((SECONDS - t0))s"
done 2>&1 | tee -a "$LOG"

{
echo
echo "=== the table ==="
column -s, -t < "$CSV"
echo
echo "wrote $CSV"
} | tee -a "$LOG"

exit "$rc_all"
