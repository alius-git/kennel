#!/usr/bin/env bash
# Phase timer for the #22 demo dry run — durations from CLOCK_MONOTONIC_RAW.
#
#   p22-clock.sh mark <phase>     append a phase mark to the log
#   p22-clock.sh report           per-phase deltas and the total
#   p22-clock.sh ratio <seconds>  measure RAW vs adjusted clock over an interval
#
# WHY RAW, AND WHY THIS SCRIPT EXISTS AT ALL
#
# This host's kernel tick is pinned at 9000 us (vm/provisioning.md 6a), so
# CLOCK_REALTIME and CLOCK_MONOTONIC run ~10 % slow while CLOCK_MONOTONIC_RAW
# tracks true time. date(1), time(1), $SECONDS and $EPOCHREALTIME all read the
# adjusted clocks. Issue #22's deliverable IS a set of timings, so taking them
# with any of those would understate every number by about a tenth and the
# evidence would be quietly wrong.
#
# CLOCK_MONOTONIC_RAW has no epoch, so marks are only comparable within one
# boot. Each mark therefore also records CLOCK_REALTIME: it is the wrong clock
# for durations but the right one for saying when something happened, and a
# reboot mid-run shows up as a negative RAW delta against a positive wall one.
#
# Log path: $KENNEL_TIMINGS (default demo/evidence/00-timings.txt).

set -uo pipefail

LOG="${KENNEL_TIMINGS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/evidence/00-timings.txt}"

now() {
  python3 -c 'import time; print("%.6f %.6f %.6f" % (
      time.clock_gettime(time.CLOCK_MONOTONIC_RAW),
      time.clock_gettime(time.CLOCK_MONOTONIC),
      time.time()))'
}

usage() { sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 2; }

case "${1:-}" in

mark)
  phase="${2:-}"
  [[ -z "$phase" ]] && usage
  mkdir -p "$(dirname "$LOG")"
  if [[ ! -s "$LOG" ]]; then
    {
      echo "# Phase marks for issue #22 — demo dry run."
      echo "# Columns: raw_monotonic mono realtime phase"
      echo "# raw = CLOCK_MONOTONIC_RAW (true time); mono/realtime = NTP-adjusted"
      echo "# and ~10 % slow on this host (vm/provisioning.md 6a). Durations must"
      echo "# be computed from the raw column only."
      echo "# host $(uname -n)  kernel $(uname -r)"
    } > "$LOG"
  fi
  read -r raw mono real <<< "$(now)"
  printf '%s %s %s %s\n' "$raw" "$mono" "$real" "$phase" >> "$LOG"
  printf '[p22-clock] mark %-12s raw=%s  (%s)\n' "$phase" "$raw" \
    "$(python3 -c "import time;print(time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime($real)))")"
  ;;

report)
  [[ -s "$LOG" ]] || { echo "[p22-clock] no marks in $LOG" >&2; exit 1; }
  LOG="$LOG" python3 - <<'PY'
import os, sys, time
rows = []
for line in open(os.environ["LOG"]):
    if line.startswith("#") or not line.strip():
        continue
    raw, mono, real, phase = line.split(None, 3)
    rows.append((float(raw), float(mono), float(real), phase.strip()))
if len(rows) < 2:
    sys.exit("[p22-clock] need at least two marks to report a duration")

def hms(s):
    s = int(round(s)); return f"{s//3600:d}h{(s%3600)//60:02d}m{s%60:02d}s" if s >= 3600 \
        else (f"{s//60:d}m{s%60:02d}s" if s >= 60 else f"{s:d}s")

print(f"{'phase':<12} {'raw (true)':>12} {'adjusted':>12} {'ratio':>7}   started (UTC)")
print("-" * 72)
for (r0, m0, w0, p0), (r1, m1, _, _) in zip(rows, rows[1:]):
    dr, dm = r1 - r0, m1 - m0
    print(f"{p0:<12} {hms(dr):>12} {hms(dm):>12} {dm/dr if dr else 0:>7.3f}   "
          f"{time.strftime('%H:%M:%S', time.gmtime(w0))}")
print("-" * 72)
tr, tm = rows[-1][0] - rows[0][0], rows[-1][1] - rows[0][1]
print(f"{'TOTAL':<12} {hms(tr):>12} {hms(tm):>12} {tm/tr if tr else 0:>7.3f}")
print()
print(f"Total elapsed, true time (CLOCK_MONOTONIC_RAW): {tr:.1f} s = {hms(tr)}")
print(f"Same interval on the adjusted clock:            {tm:.1f} s = {hms(tm)}")
print(f"The adjusted clock lost {tr - tm:.1f} s over the run "
      f"({100 * (1 - tm / tr):.1f} % slow) — vm/provisioning.md 6a.")
print("Every duration above is the raw column. Quote no other.")
PY
  ;;

ratio)
  secs="${2:-30}"
  echo "[p22-clock] measuring RAW vs adjusted over ${secs}s of true time..."
  python3 -c '
import sys, time
n = float(sys.argv[1])
r0, m0, w0 = (time.clock_gettime(c) for c in
              (time.CLOCK_MONOTONIC_RAW, time.CLOCK_MONOTONIC, time.CLOCK_REALTIME))
# Busy-sleep against the RAW clock: time.sleep() is itself driven by the
# adjusted clock, so sleeping n seconds would sleep n of the WRONG seconds.
while time.clock_gettime(time.CLOCK_MONOTONIC_RAW) - r0 < n:
    time.sleep(0.05)
r1, m1, w1 = (time.clock_gettime(c) for c in
              (time.CLOCK_MONOTONIC_RAW, time.CLOCK_MONOTONIC, time.CLOCK_REALTIME))
print("  CLOCK_MONOTONIC_RAW  %.3f s   100.0 %%  (reference)" % (r1 - r0))
print("  CLOCK_MONOTONIC      %.3f s   %5.1f %%" % (m1 - m0, 100 * (m1 - m0) / (r1 - r0)))
print("  CLOCK_REALTIME       %.3f s   %5.1f %%" % (w1 - w0, 100 * (w1 - w0) / (r1 - r0)))
' "$secs"
  ;;

*) usage ;;
esac
