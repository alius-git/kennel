#!/usr/bin/env bash
# Version: 2026.09.07
# Kennel -- issue #65: the teleop path, asserted against the REAL stack.
#
# Runs on the HOST, against a guest whose stack is up. Teleop has been verified
# two ways since #58 -- 51 checks against a fake bridge with no VM
# (kennel_console/verify-teleop.sh) and 13 transcripts against the real stack
# (stack/bridge.md §8) -- and the transcripts are evidence, not a test: nothing
# re-runs them. This is the test.
#
#   stack/bridge/verify-teleop-live.sh
#
# It starts its own serve.py and its own headless Chrome, runs `kennel-demo.sh
# teleop`, drives the page over CDP against the real ws:// URL, and asserts on
# the GUEST -- every number comes out of k13-target-monitor.py running in the
# container, never out of a variable read back from the page under test
# (kennel_console/dashboard.md §4). The page's own state is read from the DOM.
#
# IT LEAVES THE STACK IN STAND ON EVERY PATH, as kennel-verify.sh does: the trap
# runs `kennel-demo.sh teleop stop` (zero, STAND, bridge down -- in that order),
# and the E-STOP group is followed by `kennel-bridge.sh recover`, so a failed run
# costs no relaunch.
#
# Knobs (environment variables):
#   KENNEL_LIVE_PORT        8093   the serve.py this suite starts
#   KENNEL_LIVE_CDP         9293   the Chrome it drives
#   KENNEL_LIVE_DRIVE_SIM_S 20     the driving window, in SIM seconds
#   KENNEL_LIVE_QUICK       0      1 skips the `verify` group (it costs ~2 min)
#   KENNEL_DEMO_OUT         ~/kennel-runs   the REAL out dir: .kennel-bridge has
#                                  to reach the page the way it does in use
#   plus the guest knobs of verify-bridge-host.sh (KENNEL_GUEST_HOSTNAME,
#   KENNEL_SSH_KEY, KENNEL_GUEST_IP, ...), passed through untouched.
#
# Exit codes:
#   0  every check passed
#   1  a check failed
#   2  could not run the checks (no chrome, no guest, no stack, a port in use,
#      not run from a repo checkout)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PORT="${KENNEL_LIVE_PORT:-8093}"
CDP_PORT="${KENNEL_LIVE_CDP:-9293}"
DRIVE_SIM_S="${KENNEL_LIVE_DRIVE_SIM_S:-20}"
QUICK="${KENNEL_LIVE_QUICK:-0}"
OUT="${KENNEL_DEMO_OUT:-$HOME/kennel-runs}"
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
PAGE="Kennel%20Console.dc.html"
DEMO="$REPO_ROOT/demo/tools/kennel-demo.sh"

GUEST_HOSTNAME="${KENNEL_GUEST_HOSTNAME:-kennel-vm}"
LIBVIRT_NET="${KENNEL_LIBVIRT_NET:-default}"
GUEST_USER="${KENNEL_GUEST_USER:-yuuser24}"
SSH_KEY="${KENNEL_SSH_KEY:-$HOME/git/yuruna/test/status/ssh/yuruna_ed25519}"
GUEST_IP="${KENNEL_GUEST_IP:-}"

say()  { echo "[live] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

# --- REGION: preconditions, each with its fix (#45)
command -v google-chrome >/dev/null || { fail "google-chrome is required to drive the console."; exit 2; }
[ -f "$REPO_ROOT/kennel_console/cdp.py" ] || {
    fail "run this from a repo checkout -- it imports kennel_console/cdp.py."; exit 2; }
[ -x "$DEMO" ] || { fail "no driver at $DEMO."; exit 2; }
curl -sf -o /dev/null "http://localhost:$PORT/$PAGE" && {
    fail "something is already answering on port $PORT." \
         "Set KENNEL_LIVE_PORT to a free port."; exit 2; }
# A browser already on the debugging port is one this suite did not start, and
# attach() would drive THAT one. An orphan left by an earlier run made a whole
# run meaningless before this check existed: every CDP call went to a browser
# whose renderer had been killed, and the guest correctly reported that nothing
# was publishing. Refuse, and name the fix.
curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:$CDP_PORT/json" && {
    fail "a browser is already listening on the debugging port $CDP_PORT." \
         "Close it:  pkill -f 'remote-debugging-port=929[3]'   (the bracket keeps" \
         "the pattern from matching the shell that carries it -- launch.md §7 trap 6)" \
         "or set KENNEL_LIVE_CDP to a free port."; exit 2; }

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

# Lease-by-hostname, the region of verify-bridge-host.sh, copied rather than
# re-derived: `kennel-vm` is the guest's HOSTNAME and never the libvirt domain
# name (vm/meshcat-exposure.md §3.1).
if [ -z "$GUEST_IP" ]; then
    GUEST_IP="$(virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null \
                | awk -v h="$GUEST_HOSTNAME" '$0 ~ h {print $5}' | cut -d/ -f1 | tail -1)"
fi
[ -n "$GUEST_IP" ] || {
    fail "could not discover the guest on libvirt network '$LIBVIRT_NET'." \
         "Is it running?   demo/tools/kennel-demo.sh up"; exit 2; }
TARGET="$GUEST_USER@$GUEST_IP"
ssh "${SSH_OPTS[@]}" "$TARGET" true 2>/dev/null || {
    fail "cannot reach the guest over SSH at $TARGET." "Key: $SSH_KEY"; exit 2; }
"$REPO_ROOT/vm/test/verify-meshcat-host.sh" --quiet >/dev/null 2>&1 || {
    fail "the simulator is not reachable -- there is no stack to drive." \
         "Bring one up:  demo/tools/kennel-demo.sh run"; exit 2; }

tmp="$(mktemp -d)"
results="$tmp/checks.psv"
: > "$results"

serve=""; chrome=""; chromes=""; browsers=0
cleanup() {
    echo
    say "leaving the stack as it was found: zero, STAND, bridge down"
    "$DEMO" teleop stop >"$tmp/teardown.log" 2>&1
    sed 's/^/[live]   /' "$tmp/teardown.log" 2>/dev/null | tail -4
    # EVERY browser this suite started, not merely the last one: group 7 starts
    # a second, and the first one outliving the run is what poisoned run 2.
    for p in $chromes "$serve"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    for p in $chromes; do wait "$p" 2>/dev/null; done
    rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

# --- REGION: the two halves of a check
# Both halves of this suite append to one file, the way kennel-verify.sh's stages
# do: the bash half asserts what the GUEST saw, the python half what the PAGE
# shows, and the totals at the end are of both.
check() {   # $1 = 0/1 condition (0 = pass), $2 = label, $3 = detail
    local st=FAIL; [ "$1" = 0 ] && st=PASS
    printf '%s|%s|%s\n' "$st" "$2" "${3:-}" >> "$results"
    printf '  [%s] %s%s\n' "$st" "$2" "${3:+ -- $3}"
}
num_ok() {  # $1 = value, $2 = lo, $3 = hi -- empty value never passes
    [ -n "$1" ] || return 1
    awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'
}

# One number (or nested number) out of a monitor transcript. The host has
# python3 -- every suite here needs it -- so the JSON is parsed, not pattern-matched.
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

# Start a window and RETURN once it is really open, so the caller can act inside
# it. Sets OBS_FILE and OBS_PID; `wait $OBS_PID` collects it.
OBS_FILE=""; OBS_PID=""
observe_bg() {   # $1 = label, $2 = sim seconds, $3.. = extra args
    local label="$1" secs="$2"; shift 2
    OBS_FILE="$tmp/observe-$label.txt"
    : > "$OBS_FILE"
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "/tmp/kennel-bridge.sh observe $secs --label $label $*" >"$OBS_FILE" 2>/dev/null &
    OBS_PID=$!
    for _ in $(seq 160); do
        grep -q '^KENNEL_MEASURING ' "$OBS_FILE" && return 0
        sleep 0.25
    done
    return 1
}

observe() {   # $1 = label, $2 = sim seconds, $3.. = extra args -> file path on stdout
    local label="$1" secs="$2"; shift 2
    local f="$tmp/observe-$label.txt"
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "/tmp/kennel-bridge.sh observe $secs --label $label $*" >"$f" 2>/dev/null
    echo "$f"
}

page() {   # the python half: a named step against the live page
    python3 "$HERE/verify-teleop-live.py" --cdp "$CDP_PORT" --serve "$PORT" \
        --results "$results" --bridge "$WS" --guest "$GUEST_IP" "$@"
}

start_chrome() {
    # A killed renderer does not end the BROWSER, and a second browser cannot
    # have the same debugging port or the same profile -- so the old one is shut
    # down first and each browser gets its own profile directory. (Found the
    # honest way: group 7 attached to the dead browser and every CDP call timed
    # out.)
    [ -n "$chrome" ] && { kill "$chrome" 2>/dev/null; wait "$chrome" 2>/dev/null; }
    browsers=$((browsers + 1))
    local prof="$tmp/profile-$browsers"
    mkdir -p "$prof"
    # MAP * ~NOTFOUND MAPS IP LITERALS TOO -- measured: with only `EXCLUDE
    # localhost` the page's WebSocket to ws://<guest>:9090/ never opens and the
    # 3D pane's iframe never loads, which looks exactly like a bridge that is
    # down. The guest is named here, and that is what makes the "nothing but
    # localhost and the guest" assertion of group 9 mean something.
    google-chrome --headless --disable-gpu --no-sandbox --no-zygote \
        --user-data-dir="$prof" \
        --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE $GUEST_IP" \
        --remote-debugging-port="$CDP_PORT" --window-size=1400,900 \
        "http://localhost:$PORT/$PAGE" >"$tmp/chrome-$browsers.log" 2>&1 &
    chrome=$!
    chromes="$chromes $chrome"
    for _ in $(seq 60); do
        curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25
    done
    sleep 3   # the console boots and the mock DataSource settles -- the same
              # settle every other suite takes, and the only one here
}

echo "=== verify-teleop-live -- the teleop path against the real stack (#65) ==="
echo "guest      $GUEST_HOSTNAME at $GUEST_IP"
echo "repo       $REPO_ROOT"
echo "windows    drive $DRIVE_SIM_S sim-s"
echo

# The instrument goes to the guest first: kennel-bridge.sh observe copies it into
# the container. Staged here rather than assumed, so this suite works on a guest
# that has never run the driver.
scp "${SSH_OPTS[@]}" -q "$HERE/tools/k13-target-monitor.py" "$HERE/kennel-bridge.sh" "$TARGET:/tmp/" || {
    fail "could not stage the guest tools."; exit 2; }
ssh "${SSH_OPTS[@]}" "$TARGET" "chmod +x /tmp/kennel-bridge.sh /tmp/k13-target-monitor.py"

python3 "$REPO_ROOT/kennel_console/serve.py" --port "$PORT" --out "$OUT" >"$tmp/serve.log" 2>&1 &
serve=$!
up=0
for _ in $(seq 40); do
    curl -sf -o /dev/null "http://localhost:$PORT/$PAGE" && { up=1; break; }
    sleep 0.25
done
[ "$up" = 1 ] || { fail "the suite's own serve.py never answered on $PORT."; \
                   sed 's/^/  serve.py: /' "$tmp/serve.log" >&2; exit 2; }

echo "0. a known starting state, then the teleop verb"
# A live regression suite has to START somewhere defined. Without this the robot
# is wherever the last run left it, and commanding a trot at a collapsed robot
# produces a thrash that reads as 0.33 m/s of travel with the body over 0.5 rad
# of tilt in 97% of samples -- measured, on this guest, before this line existed.
# `recover` is the cheap way there: no relaunch (see kennel-bridge.sh).
ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/kennel-bridge.sh recover" >"$tmp/recover0.txt" 2>/dev/null
check $? "the robot starts standing, at the origin, at STAND" \
      "$(grep -o 'standing at [0-9.]* m' "$tmp/recover0.txt" | tail -1)"

echo "   the teleop verb brings the bridge up and hands the page its URL"
"$DEMO" teleop >"$tmp/teleop.log" 2>&1
check $? "kennel-demo.sh teleop exits 0" "$(grep -c . "$tmp/teleop.log") lines"
WS="$("$REPO_ROOT/vm/test/verify-bridge-host.sh" --quiet 2>/dev/null)"
check $? "the bridge answers a WebSocket handshake from this host" "$WS"
health="$(curl -sf "http://localhost:$PORT/api/health")"
hb="$(printf '%s' "$health" | sed -n 's/.*"bridge": "\([^"]*\)".*/\1/p')"
[ -n "$WS" ] && [ "$hb" = "$WS" ]; check $? "/api/health carries that exact URL" "$hb"
printf '%s' "$health" | grep -q '"meshcat": "http'; check $? "and the viewer's URL"

start_chrome
echo "1. connect: one socket, and the page drives at 20 Hz"
page boot; page connect
f="$(observe connect 5)"
hzw="$(jget "$f" target.hz_wall)"; hzs="$(jget "$f" target.hz)"
num_ok "$hzw" 18 22
check $? "the guest sees 20 Hz on /quad_control_target" \
      "$hzw Hz wall (the page's timer is a wall-clock timer); $hzs per SIM second"
dv="$(jget "$f" target.distinct_vx)"
[ "$dv" = "[0.0]" ]; check $? "and every message is a zero before the stick moves" "$dv"

echo "2. the stick drives the real robot"
page gait WALKING_TROT; page stick-down
f="$(observe drive "$DRIVE_SIM_S")"
hzw="$(jget "$f" target.hz_wall)"; vx="$(jget "$f" vx_mean)"; dx="$(jget "$f" x_travel)"
zm="$(jget "$f" z_median)"; tf="$(jget "$f" tilt_over_frac)"; gn="$(jget "$f" gait.name)"
gs="$(jget "$f" target.gap_std_ms)"; gx="$(jget "$f" target.gap_max_ms)"; rtf="$(jget "$f" rtf)"
tx="$(jget "$f" tilt_max)"
num_ok "$hzw" 18 22;     check $? "still 20 Hz while driving" "$hzw Hz wall, rtf $rtf"
num_ok "$vx" 0.15 10;    check $? "the robot is walking" "vx_mean $vx m/s, required >= 0.15"
num_ok "$dx" 0.01 1000;  check $? "and travelling" "x_travel $dx m in $DRIVE_SIM_S sim-s"
num_ok "$zm" 0.20 0.45;  check $? "at a standing height" "z median $zm m"
num_ok "$tf" 0 0.02;     check $? "and upright" "max tilt $tx rad, over 0.5 rad in $tf of samples"
[ "$gn" = WALKING_TROT ]; check $? "the gait the picker asked for is the one running" "/gait_state says $gn"
say "    D.3 §6 lag: gap_std ${gs} ms, gap_max ${gx} ms at rtf $rtf"
page status

echo "3. releasing the stick stops the robot"
observe_bg release 8
check $? "the monitor is watching before the stick is released"
page stick-up
wait "$OBS_PID"
f="$OBS_FILE"
fz="$(jget "$f" target.first_zero_after_nonzero_sim)"
rest="$(jget "$f" vx_below_0_05_since_sim)"
[ -n "$fz" ]; check $? "a zero goes on the wire after the release" "at sim $fz"
if [ -n "$fz" ] && [ -n "$rest" ]; then
    awk -v a="$rest" -v b="$fz" 'BEGIN{exit !(a-b<=3.0 && a-b>=-0.5)}'; check $? \
        "and the robot is at rest within 3 sim-s of it" "$(awk -v a="$rest" -v b="$fz" 'BEGIN{printf "%.2f", a-b}') sim-s"
else
    check 1 "and the robot is at rest within 3 sim-s of it" "zero=$fz rest=$rest"
fi

echo "4. STAND"
page stand
f="$(observe stand 3)"
gn="$(jget "$f" gait.name)"; lv="$(jget "$f" target.last_msg.body_x_dot)"
[ "$gn" = STAND ];  check $? "the sequencer is standing" "/gait_state says $gn"
[ "$lv" = "0.0" ];  check $? "and the last target on the wire is a zero" "body_x_dot $lv"

echo "5. a second publisher is refused, not joined"
page disconnect
"$DEMO" walk >"$tmp/walk.log" 2>&1
check $? "a held trot is running (kennel-demo.sh walk)" "the driver warns about the bridge -- expected"
page connect-expect-refused
"$DEMO" walk stop >"$tmp/walkstop.log" 2>&1
page disconnect
page connect          # its own checks say whether it drove again

echo "6. the killed renderer -- what a dead man's switch has to catch"
page gait WALKING_TROT; page stick-down
f="$(observe prekill 4)"
vx="$(jget "$f" vx_mean)"; tv="$(jget "$f" target.last_msg.body_x_dot)"
num_ok "$tv" 0.4 0.6
check $? "a non-zero target is in force when the tab dies" "commanding $tv m/s; the robot is at $vx m/s"
renderers="$(pgrep -P "$chrome" -f -- '--type=renderer' | tr '\n' ' ')"
n_rend="$(printf '%s' "$renderers" | wc -w)"
[ "$n_rend" -ge 1 ]; check $? "the renderer processes are children of this browser" "$n_rend of them (--no-zygote)"
observe_bg kill 30
check $? "the monitor is watching before the tab dies"
for p in $renderers; do kill -9 "$p" 2>/dev/null; done
dead=1
for _ in $(seq 12); do
    alive=0; for p in $renderers; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && { dead=0; break; }
    sleep 0.25
done
check $dead "kill -9 took: no renderer process is left" "$renderers"
page expect-dead
wait "$OBS_PID"
f="$OBS_FILE"
vx="$(jget "$f" vx_mean)"; dx="$(jget "$f" x_travel)"; sw="$(jget "$f" sim_window)"
rest="$(jget "$f" vx_below_0_05_since_sim)"
fz="$(jget "$f" target.first_zero_after_nonzero_sim)"
tv="$(jget "$f" target.last_msg.body_x_dot)"
lw="$(jget "$f" target.last_wall)"; lnw="$(jget "$f" target.last_nonzero_wall)"
# WHAT IS ASSERTED HERE IS THAT NOTHING INTERVENES -- not what the abandoned
# robot then does. Measured over two consecutive runs of this suite: once it
# walked 13.6 m and was still going at the end of the window; once it destabilised
# after 3.8 m and came to a stop of its own accord. Both are an uncommanded robot
# carrying a stale order, which is the whole finding; asserting the first
# outcome would have made this group a coin toss (it did, before this comment).
[ -z "$fz" ];         check $? "no zero is ever published for the abandoned robot" "zero=${fz:-none}"
num_ok "$tv" 0.4 0.6; check $? "the stack is still holding the target the dead page sent" "$tv m/s"
awk -v v="$dx" 'BEGIN{exit !(v>0.5 || v<-0.5)}'
check $? "and it carried the robot somewhere with nobody watching" "$dx m in $sw sim-s"
say "    D.3 §5 MEASURED: $dx m travelled in $sw sim-s after the tab died"
say "    (mean $vx m/s; came to rest on its own: ${rest:-never})."
say "    The last target the stack received was at wall $lw (last non-zero $lnw)."
say "    Nothing but 'kennel-demo.sh teleop stop' ends this -- which is #67."
"$DEMO" teleop stop >"$tmp/teleopstop.log" 2>&1
f="$(observe afterstop 5)"
rest="$(jget "$f" vx_below_0_05_since_sim)"
[ -n "$rest" ]; check $? "teleop stop is what stops it" "at rest from sim $rest"

echo "7. E-STOP, and a stack that can be handed back"
"$DEMO" teleop >"$tmp/teleop2.log" 2>&1
check $? "the bridge comes back up"
WS="$("$REPO_ROOT/vm/test/verify-bridge-host.sh" --quiet 2>/dev/null)"
start_chrome
page boot; page connect; page gait WALKING_TROT; page stick-down
f="$(observe predrive 3)" ; vx="$(jget "$f" vx_mean)"
num_ok "$vx" 0.05 10; check $? "driving again in a fresh browser" "vx_mean $vx m/s"
page estop
f="$(observe estop 4)"
zm="$(jget "$f" z_median)"; lv="$(jget "$f" target.last_msg.body_x_dot)"
awk -v v="$zm" 'BEGIN{exit !(v<0.15)}'; check $? "the robot is on the floor" "z median $zm m"
[ "$lv" = "0.0" ]; check $? "and the target was zeroed on the way" "body_x_dot $lv"
ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/kennel-bridge.sh recover" >"$tmp/recover.txt" 2>/dev/null
check $? "kennel-bridge.sh recover puts it back on its feet -- no relaunch" \
      "$(grep -o 'standing at [0-9.]* m' "$tmp/recover.txt" | tail -1)"
grep -q 'leaving EMERGENCY_DAMPING' "$tmp/recover.txt"
check $? "by leaving EMERGENCY_DAMPING, which nothing had ever done before #65"

echo "8. teardown leaves nothing"
"$DEMO" teleop stop >"$tmp/teleopstop2.log" 2>&1
check $? "teleop stop exits 0"
if ssh "${SSH_OPTS[@]}" "$TARGET" "ss -ltn | grep -q ':9090'"; then
    check 1 "the port is closed" "something is still listening on 9090"
else
    check 0 "the port is closed"
fi
# Poll for it rather than looking once: `stop` INTs, waits, KILLs, and the two
# children leave the process table a moment after the port closes. The [] in the
# patterns keep them from matching the very command line that carries them
# (launch.md §7 trap 6).
left=1
for _ in $(seq 20); do
    n="$(ssh "${SSH_OPTS[@]}" "$TARGET" \
        "sudo docker exec $CONTAINER ps ax -o args --no-headers 2>/dev/null | grep -c 'rosbridge_server/rosbridge_websocke[t]\|rosapi/rosapi_nod[e]'" \
        2>/dev/null | tr -d '[:space:]')"
    [ "$n" = 0 ] && { left=0; break; }
    sleep 0.5
done
check $left "and no bridge process survives in the container" "${n:-?} left"
curl -sf "http://localhost:$PORT/api/health" | grep -q '"bridge": null'
check $? "/api/health reports no bridge"

echo "9. the page itself"
page errors

echo
awk -F'|' '{n[$1]++} END {printf "pass=%d fail=%d\n", n["PASS"], n["FAIL"]}' "$results"
if grep -q '^FAIL|' "$results"; then
    echo "SOME CHECKS FAILED"; grep '^FAIL|' "$results" | sed 's/^FAIL|/  /'
    exit 1
fi
echo "ALL CHECKS PASSED"
