#!/bin/bash
# Version: 2026.09.06
# Kennel -- issue #21: prove the composed simulator_realtime_rate took effect.
#
# Runs on the GUEST, against an already-running stack -- launched by any means:
# it finds the container source chain itself (see the CHAIN region below, #45).
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

# --- REGION: the container source chain (#45)
# /tmp/p21-env.sh is written ONLY by p21-launch-from-commands.sh. This tool used
# to fall back to a THREE-LINE approximation of the chain -- no unitree overlay,
# no Drake exports, no ROS_PACKAGE_PATH -- which happened to suffice for reading
# /clock and would have drifted silently for anything else. It now falls back to
# the whole chain.
#
# The block between the CHAIN markers is IDENTICAL to
# stack/known-good/tools/prelude.sh, which is also what shell 1 of the console's
# commands.txt emits (launch.md 2). The markers are load-bearing: the check in
# stack/composed-run.md 9.2 diffs between them against prelude.sh, so the copies
# are proven identical rather than assumed to be. Sourcing the WRONG workspace
# setup silently partitions the ROS graph (launch.md 2.1), which is why this is a
# copy under test and not a paraphrase.
#
# It is never written back to /tmp/p21-env.sh: the launcher stays the only writer
# of that file, so its presence keeps meaning "the launcher ran".
# --- CHAIN BEGIN (identical to stack/known-good/tools/prelude.sh)
ENV_CHAIN='source /opt/ros/humble/setup.bash
[ -f /root/unitree_ros2/install/setup.bash ] && source /root/unitree_ros2/install/setup.bash
source /root/ros2_ws/install/setup.bash
export PATH="/opt/drake/bin:${PATH}"
export PYTHONPATH="/opt/drake/lib/python3.10/site-packages:${PYTHONPATH}"
export LD_LIBRARY_PATH="/opt/drake/lib:${LD_LIBRARY_PATH}"
export ROS_PACKAGE_PATH="/root/ros2_ws/src"
source /root/setup_ulab_workspace.bash
cd /root/ros2_ws'
# --- CHAIN END
# ${...} inside ENV_CHAIN stays literal: bash does not re-expand a variable's
# value, so these reach the container's shell unexpanded, exactly as they do in
# commands.txt.
ENV_PRELUDE="if [ -f /tmp/p21-env.sh ]; then source /tmp/p21-env.sh; else $ENV_CHAIN; fi >/dev/null 2>&1"

env_source() {
    if sudo docker exec "$CONTAINER" test -f /tmp/p21-env.sh 2>/dev/null
    then echo "/tmp/p21-env.sh (written by p21-launch-from-commands.sh)"
    else echo "built-in chain (no /tmp/p21-env.sh -- the stack was launched some other way)"
    fi
}

# Sim time in seconds, as a float. sec and nanosec are read separately: at 0.5x
# a 30 s window is only 15 sim-s, so whole-second resolution alone would carry a
# ~7 % quantisation error into a measurement with a 20 % acceptance window.
sim_now() {
    sudo docker exec "$CONTAINER" bash -c \
        "$ENV_PRELUDE
         timeout 15 ros2 topic echo /clock --once 2>/dev/null" 2>/dev/null \
    | awk '/^ *sec:/ {s=$2} /nanosec:/ {n=$2} END {if (s=="") exit 1; printf "%.3f", s + n/1e9}'
}

say "env              $(env_source)"

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
