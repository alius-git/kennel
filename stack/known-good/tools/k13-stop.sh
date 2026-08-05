#!/bin/bash
# Bounded teardown. Signal by recorded PID, then reap by EXACT process name.
# Never `pkill -f` -- it matches this very shell's command line (#10, §5a).
for f in /tmp/k13-*.pid; do
  [ -f "$f" ] || continue
  p=$(cat "$f" 2>/dev/null)
  [ -n "$p" ] && kill -INT "$p" 2>/dev/null || true
done
for _ in $(seq 1 10); do
  alive=0
  for f in /tmp/k13-*.pid; do
    [ -f "$f" ] || continue
    p=$(cat "$f" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=1
  done
  [ "$alive" = 0 ] && break
  sleep 1
done
for f in /tmp/k13-*.pid; do
  [ -f "$f" ] || continue
  p=$(cat "$f" 2>/dev/null)
  [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
  rm -f "$f"
done
# NB "mitcontrollerno" is not a typo: Linux caps comm at 15 chars
# (TASK_COMM_LEN 16), so the 17-char "mitcontrollernode" is truncated and
# `pkill -x mitcontrollernode` silently never matches.
for n in simulator leg_driver mitcontrollerno log_cpu_power joy_linux_node ros2; do
  pkill -KILL -x "$n" 2>/dev/null || true
done
# joy_to_target.py runs under `python3`, so its comm is "python3" and -x never
# matches it -- stale copies otherwise pile up and show as duplicate
# /joy_to_target nodes in `ros2 node list`. Match the script PATH instead: it
# cannot match this script's own cmdline, which is the trap -f normally carries.
pkill -KILL -f 'controllers/joy_to_target[.]py' 2>/dev/null || true
true
