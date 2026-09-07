#!/bin/bash
# Version: 2026.09.07
# Kennel #65 / plan/teleop-joystick.md D.3 §8 -- WHICH readiness signal comes
# first when the rosbridge starts, measured WITHOUT the bias of asking one
# question at a time.
#
# Runs on the GUEST. kennel-bridge.sh polls its two signals in one loop, so the
# cheap probe (ss, milliseconds) only ever runs in the gaps left by the expensive
# one (ros2 node list inside the container, ~0.9 s) -- and the port therefore
# always LOOKS later than it is. Here the two watchers are separate processes
# against one clock, so neither starves the other.
#
# Usage: race-probe.sh [iterations]        (default 10)
set -uo pipefail
N="${1:-10}"
CONTAINER=dfki_quad
PRE='if [ -f /tmp/p21-env.sh ]; then source /tmp/p21-env.sh; else source /opt/ros/humble/setup.bash; source /root/ros2_ws/install/setup.bash; source /root/setup_ulab_workspace.bash; fi >/dev/null 2>&1'

echo "iteration,port_s,node_s,first,delta_s"
for i in $(seq 1 "$N"); do
  /tmp/kennel-bridge.sh stop >/dev/null 2>&1
  while ss -ltn 2>/dev/null | grep -q ':9090'; do sleep 0.2; done
  T0="$(date +%s.%N)"
  el() { awk -v a="$T0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.2f", b-a}'; }

  # Two watchers, one clock, neither waiting on the other.
  ( while :; do ss -ltn 2>/dev/null | grep -q ':9090' && { el > /tmp/race-port; break; }; sleep 0.02; done ) &
  wp=$!
  ( while :; do
      sudo docker exec "$CONTAINER" bash -c "$PRE; ros2 node list 2>/dev/null" 2>/dev/null \
        | grep -q '^/rosbridge_websocket$' && { el > /tmp/race-node; break; }
    done ) &
  wn=$!
  /tmp/kennel-bridge.sh start >/dev/null 2>&1
  wait $wp $wn 2>/dev/null
  p="$(cat /tmp/race-port 2>/dev/null)"; n="$(cat /tmp/race-node 2>/dev/null)"
  first="$(awk -v p="$p" -v n="$n" 'BEGIN{print (p<n)?"port":"node"}')"
  d="$(awk -v p="$p" -v n="$n" 'BEGIN{printf "%.2f", (p<n)?n-p:p-n}')"
  echo "$i,$p,$n,$first,$d"
  rm -f /tmp/race-port /tmp/race-node
done
/tmp/kennel-bridge.sh stop >/dev/null 2>&1
