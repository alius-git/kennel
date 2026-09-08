#!/usr/bin/env bash
# Version: 2026.08.30
# Verify that the console drives the stack over rosbridge (#58).
#
#   ./kennel_console/verify-teleop.sh [servePort] [plainPort] [cdpPort] [bridgePort]
#
# Since #66 there are FOUR far ends, all fake-rosbridge.py: the plain one, one
# with a foreign publisher already on the topic, one that follows the gait
# parameter and publishes /gait_state for it, and one replaying the recorded
# FALL fixture so `reset sim` can be tested against a robot that is on the floor.
# Since #68 there is a FIFTH: the healthy recording replayed with the held trot
# dropped, so the page can drive a robot that is really publishing -- which is
# what the Dashboard needs before it will render an event feed at all. It answers
# /disturb_simulation LATE, because the real service blocks for the length of the
# push it was asked for and the page must keep publishing through it. The foreign
# fixture also REFUSES services now: somebody else driving and no disturber
# running is one state, and it is the state an operator who forgot the toggle
# reaches.
#
# Runs on the HOST. NO VM, NO ROS, NO STACK: the far end is fake-rosbridge.py,
# which records every op the page sends to a JSONL file, so every assertion is
# made against bytes the page actually put on the wire. The real protocol shapes
# are proven separately against the real bridge (stack/bridge.md §5).
#
# Like verify-send.sh it starts BOTH servers -- serve.py and a plain
# `python3 -m http.server` -- and drives one throwaway headless Chrome across
# both origins with external DNS blocked, because the property under test is
# feature detection: with serve.py the controls exist and work, with
# http.server they must not exist and must break nothing.
#
# The bridge URL reaches the page the way it does in real use: serve.py reads it
# from <out>/.kennel-bridge, which `kennel-demo.sh teleop` writes. The suite
# writes that file itself, so the hand-off is exercised rather than bypassed.
#
# Requires google-chrome.
#
# Exit codes:
#   0  every check passed
#   1  a check failed
#   2  could not run the checks (no google-chrome, a port in use)

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVE_PORT="${1:-8081}"
PLAIN_PORT="${2:-8082}"
CDP_PORT="${3:-9281}"
BRIDGE_PORT="${4:-9391}"
# A second fixture, identical but with a publisher already on the topic. The
# console must refuse to drive against it rather than join the fight.
FOREIGN_PORT="$((BRIDGE_PORT + 1))"
# A third that answers the gait parameter with a real /gait_state, so `sent` can
# become `active` -- or stay `sent` and time out into `refused` (#66).
GAIT_PORT="$((BRIDGE_PORT + 2))"
# A fourth replaying the recorded fall, minus the held trot the recording carries
# on /quad_control_target -- otherwise the page's probe refuses to drive and
# there is no reset to test.
FALL_PORT="$((BRIDGE_PORT + 3))"
# A fifth replaying the HEALTHY recording, same drop, and answering the
# disturbance service two seconds late (#68). The Dashboard renders its panels
# and its feed only once samples are arriving, so the feed assertions have to be
# made against a fixture that publishes -- a fake that answers services and says
# nothing else leaves the page correctly showing empty states.
HEALTHY_PORT="$((BRIDGE_PORT + 4))"
PAGE="Kennel%20Console.dc.html"

if ! command -v google-chrome >/dev/null 2>&1; then
  echo "google-chrome is required to drive the console -- install it, or run verify-serve.sh only."
  exit 2
fi

tmp="$(mktemp -d)"
profile="$tmp/profile"
out="$tmp/kennel-runs"
ops="$tmp/ops.jsonl"
foreign_ops="$tmp/ops-foreign.jsonl"
gait_ops="$tmp/ops-gait.jsonl"
fall_ops="$tmp/ops-fall.jsonl"
healthy_ops="$tmp/ops-healthy.jsonl"
mkdir -p "$profile" "$out"

# What `kennel-demo.sh teleop` writes after it has discovered the guest. serve.py
# reads it per request and reports it in /api/health; the console prefills its
# field from there. Writing it here is the point: the hand-off is under test.
echo "ws://localhost:$BRIDGE_PORT/" > "$out/.kennel-bridge"

# A run folder, so /api/runs has something to say. `inject` is gated on the
# NEWEST run's composed choices (#68) -- the disturbance service only exists if
# the run the guest launched composed block 4 -- and with no VM here, this
# fixture plays the part of that run. Deliberately minimal: the four provenance
# keys and the one choice the guard reads.
mkdir -p "$out/run-20260101T000000Z"
cat > "$out/run-20260101T000000Z/run.json" <<'RUNJSON'
{
  "run_id": "RUN-2026-0101-0000",
  "run": "run-20260101T000000Z",
  "generated_at": "2026-01-01T00:00:00Z",
  "pin": "dcf53c596339afd45b82f12c54b1e93e8273c2f4",
  "choices": {
    "world_urdf": "src/common/model/urdf/plane.urdf",
    "world_fix_link": "plane_base_link",
    "simulator_realtime_rate": 1.0,
    "publish_quad_state": true,
    "mpc_solver": "PARTIAL_CONDENSING_OSQP",
    "mpc_hpipm_mode": "SPEED",
    "mpc_condensed_size": 5,
    "disturbances": true
  }
}
RUNJSON

serve=""; plain=""; chrome=""; bridge=""; foreign=""; gaitb=""; fallb=""; healthyb=""
cleanup() {
  for p in "$chrome" "$serve" "$plain" "$bridge" "$foreign" "$gaitb" "$fallb" "$healthyb"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  [[ -n "$chrome" ]] && wait "$chrome" 2>/dev/null
  rm -rf "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

python3 "$DIR/fake-rosbridge.py" --port "$BRIDGE_PORT" --log "$ops" >"$tmp/bridge.log" 2>&1 &
bridge=$!
python3 "$DIR/fake-rosbridge.py" --port "$FOREIGN_PORT" --log "$foreign_ops" --foreign \
  --refuse-service >"$tmp/bridge-foreign.log" 2>&1 &
foreign=$!
python3 "$DIR/fake-rosbridge.py" --port "$GAIT_PORT" --log "$gait_ops" --gait-follow \
  >"$tmp/bridge-gait.log" 2>&1 &
gaitb=$!
python3 "$DIR/fake-rosbridge.py" --port "$FALL_PORT" --log "$fall_ops" \
  --replay "$DIR/fixtures/fall.jsonl.gz" --drop /quad_control_target \
  >"$tmp/bridge-fall.log" 2>&1 &
fallb=$!
# --loop so a group is never racing the end of a 30-second recording, and the
# rebase keeps /clock moving forward rather than looking like a sim reset.
python3 "$DIR/fake-rosbridge.py" --port "$HEALTHY_PORT" --log "$healthy_ops" \
  --replay "$DIR/fixtures/healthy.jsonl.gz" --drop /quad_control_target --loop \
  --service-delay /disturb_simulation:2 >"$tmp/bridge-healthy.log" 2>&1 &
healthyb=$!
python3 "$DIR/serve.py" --port "$SERVE_PORT" --out "$out" >"$tmp/serve.log" 2>&1 &
serve=$!
python3 -m http.server "$PLAIN_PORT" --directory "$DIR" >/dev/null 2>&1 &
plain=$!

# Wait for each to answer rather than sleeping at them (demo/dry-run.md F8).
for port in "$SERVE_PORT" "$PLAIN_PORT"; do
  up=0
  for _ in $(seq 40); do
    curl -sf -o /dev/null "http://localhost:$port/$PAGE" && { up=1; break; }
    sleep 0.25
  done
  [[ "$up" == 1 ]] || {
    echo "NONZERO SCRIPT EXIT: nothing answered on port $port within 10s." >&2
    [[ "$port" == "$SERVE_PORT" ]] && sed 's/^/  serve.py: /' "$tmp/serve.log" >&2
    exit 2
  }
done
for port in "$BRIDGE_PORT" "$FOREIGN_PORT" "$GAIT_PORT" "$FALL_PORT" "$HEALTHY_PORT"; do
  up=0
  for _ in $(seq 40); do
    # A TCP connect is enough: the fixture only speaks WebSocket, and the suite's
    # first real check is that the page can upgrade against it.
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { up=1; exec 3<&-; break; }
    sleep 0.25
  done
  [[ "$up" == 1 ]] || {
    echo "NONZERO SCRIPT EXIT: a fake bridge never came up on port $port." >&2
    sed 's/^/  fake-rosbridge: /' "$tmp/bridge.log" "$tmp/bridge-foreign.log" >&2
    exit 2
  }
done

# localhost is excluded from the DNS blackhole, and the fake bridge is on
# localhost -- so a page that dialled anything else would still be caught by the
# zero-non-localhost check in group 11.
google-chrome --headless --disable-gpu --no-sandbox \
  --user-data-dir="$profile" \
  --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost" \
  --remote-debugging-port="$CDP_PORT" --window-size=1400,900 \
  "http://localhost:$SERVE_PORT/$PAGE" >/dev/null 2>&1 &
chrome=$!

for _ in $(seq 40); do
  curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25
done
sleep 3   # let the console boot and the mock DataSource settle

python3 "$DIR/verify-teleop.py" "$SERVE_PORT" "$PLAIN_PORT" "$CDP_PORT" "$BRIDGE_PORT" "$ops" \
  "$FOREIGN_PORT" "$foreign_ops" "$GAIT_PORT" "$gait_ops" "$FALL_PORT" "$fall_ops" \
  "$HEALTHY_PORT" "$healthy_ops"
rc=$?

echo
echo "the fake bridges recorded $(wc -l < "$ops"), $(wc -l < "$foreign_ops"), \
$(wc -l < "$gait_ops"), $(wc -l < "$fall_ops") and $(wc -l < "$healthy_ops") ops."
exit $rc
