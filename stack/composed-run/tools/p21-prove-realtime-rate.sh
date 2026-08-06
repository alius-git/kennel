#!/bin/bash
# Version: 2026.08.06
# Kennel -- issue #21: prove the composed simulator_realtime_rate took effect.
#
# Runs on the GUEST, against an already-running stack.
#
# stack/verify.md's recipe reports the realtime rate as [INFO] -- informative,
# never asserted, because #14 could not know what any given run composed. #21
# composes a specific value and its acceptance is "prove each composed value",
# so this turns the same observable into a pass/fail.
#
# Method: sim time from /clock against the guest's MONOTONIC clock. Monotonic,
# not wall: vm/provisioning.md 6a documents a host whose NTP-adjusted clocks run
# ~10 % slow. That defect is the host's and this measurement is the guest's, but
# the ratio is the whole result here, so it is taken from the one clock that
# cannot be re-railed by chrony underneath it.
#
# Usage:
#   p21-prove-realtime-rate.sh [expected] [tolerance] [window-seconds]
#   p21-prove-realtime-rate.sh 0.5            # defaults: tol 0.1, window 30 s
#
# Exit codes:
#   0  the measured ratio is within tolerance of the expected value
#   1  it is not -- the composed rate did not take effect
#   2  infrastructure error (no container, /clock not being published)

set -uo pipefail

EXPECTED="${1:-0.5}"
TOLERANCE="${2:-0.1}"
WINDOW="${3:-30}"
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"

say()  { echo "[p21-rate] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

[ -n "$(sudo docker inspect --type container -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" ] || {
    fail "no container named '$CONTAINER'."; exit 2; }

# Sim time in seconds, as a float. sec and nanosec are read separately: at 0.5x
# a 30 s window is only 15 sim-s, so whole-second resolution alone would carry a
# ~7 % quantisation error into a measurement with a 20 % acceptance window.
sim_now() {
    sudo docker exec "$CONTAINER" bash -c \
        'source /tmp/p21-env.sh >/dev/null 2>&1 || {
             source /opt/ros/humble/setup.bash
             source /root/ros2_ws/install/setup.bash
             source /root/setup_ulab_workspace.bash
         } >/dev/null 2>&1
         timeout 15 ros2 topic echo /clock --once 2>/dev/null' 2>/dev/null \
    | awk '/^ *sec:/ {s=$2} /nanosec:/ {n=$2} END {if (s=="") exit 1; printf "%.3f", s + n/1e9}'
}

mono() { awk '{printf "%.3f", $1}' /proc/uptime; }   # CLOCK_MONOTONIC, in seconds

s0="$(sim_now)"; w0="$(mono)"
[ -n "$s0" ] || { fail "/clock is not being published -- is the simulator running?" \
                       "Launch it: ~/p21-launch-from-commands.sh"; exit 2; }
say "t0  sim ${s0}s  monotonic ${w0}s"
say "observing ${WINDOW} s ..."
sleep "$WINDOW"
s1="$(sim_now)"; w1="$(mono)"
[ -n "$s1" ] || { fail "/clock stopped being published during the window -- the simulator died."; exit 2; }
say "t1  sim ${s1}s  monotonic ${w1}s"

read -r ratio ds dw < <(awk -v s0="$s0" -v s1="$s1" -v w0="$w0" -v w1="$w1" \
    'BEGIN {ds=s1-s0; dw=w1-w0; printf "%.3f %.3f %.3f", (dw>0 ? ds/dw : 0), ds, dw}')

lo="$(awk -v e="$EXPECTED" -v t="$TOLERANCE" 'BEGIN{printf "%.3f", e-t}')"
hi="$(awk -v e="$EXPECTED" -v t="$TOLERANCE" 'BEGIN{printf "%.3f", e+t}')"
ok="$(awk -v r="$ratio" -v lo="$lo" -v hi="$hi" 'BEGIN{print (r>=lo && r<=hi) ? 1 : 0}')"

echo
if [ "$ok" = 1 ]; then
    echo "[PASS] realtime-rate -- /clock vs guest monotonic: measured ${ratio}" \
         "(${ds} sim-s in ${dw} s), required ${EXPECTED} +/- ${TOLERANCE} i.e. [${lo}, ${hi}]"
    exit 0
fi
echo "[FAIL] realtime-rate -- /clock vs guest monotonic: measured ${ratio}" \
     "(${ds} sim-s in ${dw} s), required ${EXPECTED} +/- ${TOLERANCE} i.e. [${lo}, ${hi}]"
fail "the composed simulator_realtime_rate did not take effect." \
     "Check the value actually on the config path:" \
     "  sudo docker exec $CONTAINER grep simulator_realtime_rate \\" \
     "    /root/ros2_ws/install/simulator/share/simulator/config/simulator_params_go2.yaml" \
     "and remember the stack reads it at LAUNCH -- relaunch after a transfer."
exit 1
