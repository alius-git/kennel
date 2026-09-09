# Version: 2026.09.08
# Kennel -- the parts both scenario verbs share (#69, #71).
#
# SOURCED, never executed, by demo/tools/scenario-disturb.sh and
# scenario-diagnose.sh, which run on the HOST against a guest whose stack is up.
# `kennel-demo.sh scenario <name>` is how an operator reaches them.
#
# Everything here is copied from stack/bridge/verify-teleop-live.sh rather than
# imported from it: the guest discovery, the two halves of a check, the observe
# helpers, the Chrome flags. That is this repo's rule for suites (each is meant
# to be readable on its own, and a shared helper that drifts breaks them
# silently), and a scenario transcript should read like the live suite's because
# it is the same kind of document.
#
# What is NEW here, and why it is not in that suite:
#
#   capture_ps   the s004 Target Verification Point made mechanical -- the
#                container's process set before, during and after every step,
#                diffed. "The console called services and published topics and
#                never started or stopped a process" is the design's hard
#                constraint (design.md §2), and this is the only thing in the
#                repo that checks it.
#   page         one named step against the live page, through scenario-page.py.
#   require_sim  a scenario resets the simulator, and /reset_sim has a crash mode
#                (demo/scenarios.md §1.3): asked to resolve contacts from a
#                degenerate configuration, Drake's SAP solver aborts and takes
#                the simulator process with it. That is a RED result naming the
#                relaunch, never a retry.
#   note / bypass
#                a number worth having in the transcript, and a step this
#                scenario cannot check at all. Neither is a pass, and neither is
#                a silent skip.
#
# Knobs are the caller's; this file reads the ones every scenario shares:
#   KENNEL_SCENARIO_PORT   8094   the serve.py the scenario starts
#   KENNEL_SCENARIO_CDP    9294   the Chrome it drives
#   KENNEL_DEMO_OUT        ~/kennel-runs   the REAL out dir, so /api/health and
#                          /api/runs carry what they carry in use
#   plus the guest knobs of verify-bridge-host.sh, passed through untouched.

PORT="${KENNEL_SCENARIO_PORT:-8094}"
CDP_PORT="${KENNEL_SCENARIO_CDP:-9294}"
OUT="${KENNEL_DEMO_OUT:-$HOME/kennel-runs}"
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
PAGE="Kennel%20Console.dc.html"

GUEST_HOSTNAME="${KENNEL_GUEST_HOSTNAME:-kennel-vm}"
LIBVIRT_NET="${KENNEL_LIBVIRT_NET:-default}"
GUEST_USER="${KENNEL_GUEST_USER:-yuuser24}"
SSH_KEY="${KENNEL_SSH_KEY:-$HOME/git/yuruna/test/status/ssh/yuruna_ed25519}"
GUEST_IP="${KENNEL_GUEST_IP:-}"

say()  { echo "[scenario] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }
banner() { echo; echo "---- $* ----"; }

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

# --- REGION: preconditions, each naming its fix (#45)
# $2 = "nostack" for a scenario that must start with the stack DOWN. Every other
# verb drives a stack that is already up; s001 starts one from nothing and times
# how long that takes, so for that one a running stack is the precondition that
# must NOT hold (#73).
scenario_preflight() {   # $1 = scenario name, $2 = "" | nostack
    command -v google-chrome >/dev/null || {
        fail "google-chrome is required to drive the console."; exit 2; }
    [ -f "$REPO_ROOT/kennel_console/cdp.py" ] || {
        fail "run this from a repo checkout -- it imports kennel_console/cdp.py."; exit 2; }
    [ -x "$DEMO" ] || { fail "no driver at $DEMO."; exit 2; }
    curl -sf -o /dev/null "http://localhost:$PORT/$PAGE" && {
        fail "something is already answering on port $PORT." \
             "Set KENNEL_SCENARIO_PORT to a free port."; exit 2; }
    # A browser already on the debugging port is one this script did not start,
    # and attach() would drive THAT one -- the trap bridge.md §10.7 records.
    curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:$CDP_PORT/json" && {
        fail "a browser is already listening on the debugging port $CDP_PORT." \
             "Close it, or set KENNEL_SCENARIO_CDP to a free port."; exit 2; }

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
    if [ "${2:-}" = "nostack" ]; then
        "$REPO_ROOT/vm/test/verify-meshcat-host.sh" --quiet >/dev/null 2>&1 && {
            fail "a stack is already running, and this scenario starts one itself." \
                 "Its whole measurement is how long a first run takes from nothing." \
                 "Stop it:  demo/tools/kennel-demo.sh down"; exit 2; }
    else
        "$REPO_ROOT/vm/test/verify-meshcat-host.sh" --quiet >/dev/null 2>&1 || {
            fail "the simulator is not reachable -- there is no stack to drive." \
                 "Bring one up:  demo/tools/kennel-demo.sh run"; exit 2; }
    fi
}

# The run the guest actually applied, read from ITS OWN marker -- the same
# resolution `kennel-demo.sh verify` uses when it is invoked on its own
# (runs.md §2). A scenario asserts against the run the stack is running, never
# against the newest folder on this host.
applied_run() {
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "cat ~/kennel-staging/current-run 2>/dev/null" 2>/dev/null | tr -d '[:space:]'
}
applied_choice() {   # $1 = key -> the raw JSON value, or empty
    local run; run="$(applied_run)"
    [ -n "$run" ] || return 1
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "cat ~/kennel-staging/runs/$run/run.json 2>/dev/null" 2>/dev/null \
      | python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
v = (d.get('choices') or {}).get('$1')
print('' if v is None else json.dumps(v))"
}

# --- REGION: the two halves of a check (verify-teleop-live.sh's, copied)
check() {   # $1 = 0/1 condition (0 = pass), $2 = label, $3 = detail
    local st=FAIL; [ "$1" = 0 ] && st=PASS
    printf '%s|%s|%s\n' "$st" "$2" "${3:-}" >> "$results"
    printf '  [%s] %s%s\n' "$st" "$2" "${3:+ -- $3}"
}
# A step the scenario cannot assert here, printed with what it measured so the
# transcript is complete against scenarios.md's own numbering. It is NOT a
# failure and NOT a silent skip: demo/scenarios.md carries the retirement path.
bypass() {   # $1 = label, $2 = what was measured / why
    printf 'BYPASS|%s|%s\n' "$1" "${2:-}" >> "$results"
    printf '  [BYPASS] %s%s\n' "$1" "${2:+ -- $2}"
}
# Something measured and reported, not asserted. Distinct from `bypass`: a
# bypass is a step this scenario cannot check at all, a note is a number worth
# having in the transcript.
note() {   # $1 = label, $2 = value
    printf 'NOTE|%s|%s\n' "$1" "${2:-}" >> "$results"
    printf '  [NOTE] %s%s\n' "$1" "${2:+ -- $2}"
}
num_ok() {  # $1 = value, $2 = lo, $3 = hi -- empty value never passes
    [ -n "$1" ] || return 1
    awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'
}
gt() { [ -n "$1" ] && awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
lt() { [ -n "$1" ] && awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

# One number (or nested number) out of a monitor transcript.
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

# --- REGION: observing the guest
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
        grep -q '^NONZERO SCRIPT EXIT' "$OBS_FILE" && return 1
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

# --- REGION: the process table -- s004 step 6, the design's hard constraint
#
# `comm` AND `args`, sorted, with no pids: a pid changes on every launch and
# would make every capture differ for a reason that is not the console's. The
# cost is stated as a limit (demo/scenarios.md): a process restarted with the
# same command line is invisible to this. What it does catch is anything
# STARTED or STOPPED -- including the simulator dying, which is how the
# /reset_sim crash mode of plan/two-scenarios.md §0.1 shows up here.
#
# HARNESS_RE excludes only the harness's OWN instruments, and it is printed at
# the top of every transcript, because an exclusion list is exactly where a
# check like this goes quietly wrong. Captures are taken BETWEEN steps, when
# nothing of ours is inside the container, so the list is a safety net rather
# than the mechanism.
HARNESS_RE='k13-target-monitor[.]py|k14-solve-probe[.]py|kennel-verify[.]sh|check[.]py|^ps |ros2 (topic|service|param|node|run) '
capture_ps() {   # $1 = label
    mkdir -p "$OUT_DIR/06-process-diffs"
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "sudo docker exec $CONTAINER ps -e -o comm=,args= --no-headers" 2>/dev/null \
      | sed 's/  */ /g' | sed 's/^ *//' | grep -vE "$HARNESS_RE" | sort \
      > "$OUT_DIR/06-process-diffs/ps-$1.txt"
}
# Diff one capture against the reference, and check it is empty.
ps_same() {   # $1 = label
    local d="$OUT_DIR/06-process-diffs/diff-$1.txt"
    diff "$OUT_DIR/06-process-diffs/ps-before.txt" \
         "$OUT_DIR/06-process-diffs/ps-$1.txt" > "$d" 2>&1
    local rc=$?
    if [ "$rc" = 0 ]; then
        check 0 "the process set is unchanged after $1" \
              "$(wc -l < "$OUT_DIR/06-process-diffs/ps-$1.txt") processes, diff empty"
    else
        check 1 "the process set CHANGED after $1" "$(tr '\n' ' ' < "$d" | cut -c1-160)"
        # The one diff worth naming: the simulator gone is the /reset_sim crash
        # mode, and it costs a relaunch rather than a retry.
        grep -q '^< simulator ' "$d" && \
            say "the SIMULATOR is gone from the table -- /reset_sim aborted Drake's SAP solver." && \
            say "  Relaunch:  $DEMO launch      (plan/two-scenarios.md §0.1)"
    fi
}

# --- REGION: the sim is alive at all
# Two ways it dies under a scenario: the container stops, or the simulator
# process aborts (the SAP crash). Both look like "observe exits 2" from here.
require_sim() {   # $1 = what was being done, for the message
    local f; f="$(observe alive 1 2>/dev/null)"
    if ! grep -q '^KENNEL_JSON ' "$f" 2>/dev/null; then
        check 1 "the simulator is still running after $1" "$(head -2 "$f" | tr '\n' ' ')"
        say "no /clock: the simulator is not publishing. If it aborted, this costs a relaunch:"
        say "    $DEMO launch"
        return 1
    fi
    return 0
}

# --- REGION: the page
page() {   # one named step against the live page
    python3 "$HERE/scenario-page.py" --cdp "$CDP_PORT" --serve "$PORT" \
        --results "$results" --guest "$GUEST_IP" --out "$OUT_DIR" "$@"
}
# The same, but its checks go nowhere. A step called in a POLLING LOOP -- s003
# samples the tint about once a second for a minute -- would otherwise append a
# check per sample and bury the scenario's real ones under two hundred phantom
# passes.
page_quiet() {
    python3 "$HERE/scenario-page.py" --cdp "$CDP_PORT" --serve "$PORT" \
        --results /dev/null --guest "$GUEST_IP" --out "$OUT_DIR" "$@"
}

start_chrome() {
    [ -n "$chrome" ] && { kill "$chrome" 2>/dev/null; wait "$chrome" 2>/dev/null; }
    browsers=$((browsers + 1))
    local prof="$tmp/profile-$browsers"
    mkdir -p "$prof"
    # `MAP * ~NOTFOUND` maps IP literals too, so the guest has to be excluded by
    # name or the page's WebSocket never opens and the 3D pane never loads --
    # indistinguishable from a bridge that is down (bridge.md §10.7).
    google-chrome --headless --disable-gpu --no-sandbox \
        --user-data-dir="$prof" \
        --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE $GUEST_IP" \
        --remote-debugging-port="$CDP_PORT" --window-size=1500,950 \
        "http://localhost:$PORT/$PAGE" >"$tmp/chrome-$browsers.log" 2>&1 &
    chrome=$!
    chromes="$chromes $chrome"
    for _ in $(seq 60); do
        curl -sf -o /dev/null "http://127.0.0.1:$CDP_PORT/json" && break || sleep 0.25
    done
    sleep 3   # the console boots and the mock DataSource settles -- the same
              # settle every other suite takes, and the only one here
}

start_server() {
    python3 "$REPO_ROOT/kennel_console/serve.py" --port "$PORT" --out "$OUT" \
        >"$tmp/serve.log" 2>&1 &
    serve=$!
    local up=0
    for _ in $(seq 40); do
        curl -sf -o /dev/null "http://localhost:$PORT/$PAGE" && { up=1; break; }
        sleep 0.25
    done
    [ "$up" = 1 ] || { fail "the scenario's own serve.py never answered on $PORT." \
                            "$(tail -3 "$tmp/serve.log" 2>/dev/null)"; exit 2; }
}

# --- REGION: the totals, printed the way every other suite prints them
totals() {
    local np nf nb
    np=$(grep -c '^PASS|' "$results"); nf=$(grep -c '^FAIL|' "$results")
    nb=$(grep -c '^BYPASS|' "$results")
    echo
    [ "$nb" -gt 0 ] && {
        echo "bypassed (measured, not asserted -- see demo/scenarios.md):"
        grep '^BYPASS|' "$results" | cut -d'|' -f2- | sed 's/|/ -- /' | sed 's/^/  /'
    }
    echo "pass=$np fail=$nf bypass=$nb"
    [ "$nf" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
    return "$([ "$nf" = 0 ] && echo 0 || echo 1)"
}
