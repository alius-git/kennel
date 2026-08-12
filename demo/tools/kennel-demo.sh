#!/bin/bash
# Version: 2026.08.12
# Kennel -- demo driver: the demo-script phases behind single verbs, so an
# operator types a handful of commands instead of ~20 (follow-up to issue #22,
# feeding #27's quickstart).
#
# Runs on the HOST. Every verb wraps the existing per-phase tool -- this script
# adds orchestration only (guest discovery, scp, ordering, timing), so the
# per-phase tools stay the source of truth for what each step does:
#
#   provision  Yuruna sequence workload.guest.ubuntu.server.24.kennel.stack.ssh
#   compose    demo/tools/p22-console-demo.sh      (console UI, scripted clicks)
#   transfer   stack/transfer/kennel-transfer.sh apply
#   launch     stack/composed-run/tools/p21-launch-from-commands.sh  (on guest)
#   verify     stack/verify/kennel-verify.sh                         (on guest)
#   walk       vm/test/verify-meshcat-host.sh + p21-trot-hold.sh
#   down       stack/known-good/tools/k13-stop.sh   (in the container)
#
# Usage:
#   kennel-demo.sh provision [--yes]   # clean guest -> stack ready (~33 min; DESTROYS kennel-vm)
#   kennel-demo.sh all                 # compose -> transfer -> launch -> verify -> walk (~6 min)
#   kennel-demo.sh compose [outdir]    # default outdir: ~/kennel-runs
#   kennel-demo.sh transfer [run-folder]   # default: newest run-* in outdir
#   kennel-demo.sh launch
#   kennel-demo.sh verify
#   kennel-demo.sh walk [stop]         # start (default): trot + print the Meshcat URL
#   kennel-demo.sh down                # stop the stack in the container
#   kennel-demo.sh status
#
# Knobs (all optional, environment variables):
#   YURUNA_DIR            ~/git/yuruna       framework checkout (provision)
#   KENNEL_DEMO_OUT       ~/kennel-runs      where compose unpacks run folders
#   KENNEL_CONSOLE_PORT   8000               port compose serves the console on
#   KENNEL_SOLVER         PARTIAL_CONDENSING_OSQP   composed + expected solver
#   KENNEL_RATE           0.75               composed simulator_realtime_rate
#   KENNEL_GUEST_HOSTNAME / KENNEL_GUEST_IP / KENNEL_SSH_KEY / KENNEL_GUEST_USER
#   KENNEL_LIBVIRT_NET / KENNEL_CONTAINER    as in kennel-transfer.sh
#
# Exit codes: 0 success; otherwise the wrapped tool's exit code, or 2 for this
# script's own argument/infrastructure errors.
#
# See demo/runbook.md for the operator-facing walkthrough.

set -uo pipefail

# --- REGION: knobs
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"
OUT="${KENNEL_DEMO_OUT:-$HOME/kennel-runs}"
PORT="${KENNEL_CONSOLE_PORT:-8000}"
SOLVER="${KENNEL_SOLVER:-PARTIAL_CONDENSING_OSQP}"
RATE="${KENNEL_RATE:-0.75}"

GUEST_HOSTNAME="${KENNEL_GUEST_HOSTNAME:-kennel-vm}"
LIBVIRT_NET="${KENNEL_LIBVIRT_NET:-default}"
GUEST_USER="${KENNEL_GUEST_USER:-yuuser24}"
SSH_KEY="${KENNEL_SSH_KEY:-$HOME/git/yuruna/test/status/ssh/yuruna_ed25519}"
GUEST_IP="${KENNEL_GUEST_IP:-}"
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

CONSOLE_URL="http://localhost:$PORT/Kennel%20Console.dc.html"
SEQUENCE="workload.guest.ubuntu.server.24.kennel.stack.ssh"

say()  { echo "[kennel-demo] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }
usage() { sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
banner() { echo; echo "==== $* ===="; }

# --- REGION: guest plumbing (same discovery as kennel-transfer.sh)
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

need_guest() {
    if [ -z "$GUEST_IP" ]; then
        GUEST_IP="$(virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null \
                    | awk -v h="$GUEST_HOSTNAME" '$0 ~ h {print $5}' \
                    | cut -d/ -f1 | tail -1)"
    fi
    [ -n "$GUEST_IP" ] || {
        fail "could not discover the guest IP on libvirt network '$LIBVIRT_NET'." \
             "Is the guest running?   virsh list --all" \
             "Override directly with: KENNEL_GUEST_IP=192.168.122.x $0 ..."
        exit 2
    }
    TARGET="$GUEST_USER@$GUEST_IP"
    ssh "${SSH_OPTS[@]}" "$TARGET" true 2>/dev/null || {
        fail "cannot reach the guest over SSH at $TARGET." \
             "Key: $SSH_KEY" \
             "If the guest has just booted, sshWaitReady can take several minutes."
        exit 2
    }
    say "guest            $GUEST_HOSTNAME at $GUEST_IP"
}

# Copy a repo tool to the guest's /tmp (the pattern launch.md §8 and
# verify.md §1 document) and leave it executable.
guest_stage() {   # $1 = repo-relative script path
    local name; name="$(basename "$1")"
    scp "${SSH_OPTS[@]}" -q "$REPO_ROOT/$1" "$TARGET:/tmp/$name" || {
        fail "could not copy $1 to the guest."; exit 2; }
    ssh "${SSH_OPTS[@]}" "$TARGET" "chmod +x /tmp/$name"
}

latest_run() { ls -dt "$OUT"/run-*/ 2>/dev/null | head -1 | sed 's:/$::'; }

# --- REGION: verbs
do_provision() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1
    [ -d "$YURUNA_DIR" ] || {
        fail "no Yuruna checkout at $YURUNA_DIR." \
             "The host baseline (vm/host-baseline.md) is a prerequisite; set YURUNA_DIR if it lives elsewhere."
        exit 2
    }
    say "this DESTROYS any existing '$GUEST_HOSTNAME' guest and rebuilds it from clean (~33 min)."
    if [ "$yes" != 1 ]; then
        reply=""
        read -r -p "[kennel-demo] proceed? [y/N] " reply || true
        case "$reply" in y|Y|yes) ;; *) say "aborted (pass --yes to skip the prompt)."; exit 2 ;; esac
    fi

    cd "$YURUNA_DIR" || exit 2
    banner "gate: Test-Config (read the findings, not the PASS/WARN totals -- provisioning.md §4.3)"
    virsh list --all > /dev/null    # wake socket-activated libvirtd
    pwsh test/Test-Config.ps1 -SkipSend || {
        fail "Test-Config reported FAIL findings -- fix those before spending the boot time."
        exit 2
    }

    banner "provision: $SEQUENCE"
    local t0=$SECONDS
    pwsh test/Remove-TestVMFiles.ps1 -Prefix test- -Confirm:\$false || exit $?
    pwsh test/Invoke-TestSequence.ps1 -SequenceName "$SEQUENCE" || {
        fail "the sequence did not pass -- see the transcript above (expect 28/28 PASS)."
        exit 1
    }
    say "provisioned in $(( (SECONDS-t0) / 60 ))m$(( (SECONDS-t0) % 60 ))s"
}

SERVER_PID=""
do_compose() {
    OUT="${1:-$OUT}"
    mkdir -p "$OUT"
    if ! curl -sf -o /dev/null "$CONSOLE_URL"; then
        say "serving the console on port $PORT (kennel_console/serve.md §1)"
        python3 -m http.server "$PORT" --directory "$REPO_ROOT/kennel_console" \
            >/dev/null 2>&1 &
        SERVER_PID=$!
        trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null' EXIT
        for _ in $(seq 1 20); do
            curl -sf -o /dev/null "$CONSOLE_URL" && break
            sleep 0.25
        done
    fi
    KENNEL_CONSOLE_URL="$CONSOLE_URL" KENNEL_SOLVER="$SOLVER" KENNEL_RATE="$RATE" \
        "$HERE/p22-console-demo.sh" "$OUT"
    local rc=$?
    [ -n "$SERVER_PID" ] && { kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
    [ $rc -eq 0 ] || {
        fail "compose failed (p22-console-demo.sh exited $rc)." \
             "It needs google-chrome; to compose by hand instead, see demo/runbook.md §3.2."
        return $rc
    }
    say "run folder       $(latest_run)"
}

do_transfer() {
    local folder="${1:-}"
    [ -n "$folder" ] || folder="$(latest_run)"
    [ -n "$folder" ] || {
        fail "no run folder given and none found under $OUT." \
             "Compose one first: $0 compose"
        exit 2
    }
    "$REPO_ROOT/stack/transfer/kennel-transfer.sh" apply "$folder"
}

do_launch() {
    need_guest
    guest_stage stack/composed-run/tools/p21-launch-from-commands.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/p21-launch-from-commands.sh"
}

do_verify() {
    need_guest
    guest_stage stack/verify/kennel-verify.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "/tmp/kennel-verify.sh --expect-solver '$SOLVER' --controller-log /tmp/p21-ctrl.log"
}

do_walk() {
    need_guest
    guest_stage stack/composed-run/tools/p21-trot-hold.sh
    if [ "${1:-start}" = "stop" ]; then
        ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/p21-trot-hold.sh stop"
        return $?
    fi
    local url
    url="$("$REPO_ROOT/vm/test/verify-meshcat-host.sh" --quiet)" || {
        local rc=$?
        "$REPO_ROOT/vm/test/verify-meshcat-host.sh"   # re-run loud for the diagnosis
        fail "Meshcat is not reachable from the host (exit $rc) -- is the stack launched?"
        return $rc
    }
    ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/p21-trot-hold.sh start" || return $?
    echo
    say "the robot is trotting. Watch it here:"
    say "    $url"
    say "return it to STAND with:  $0 walk stop"
}

do_down() {
    need_guest
    ssh "${SSH_OPTS[@]}" "$TARGET" "[ -x /tmp/p21-trot-hold.sh ] && /tmp/p21-trot-hold.sh stop" \
        >/dev/null 2>&1
    guest_stage stack/known-good/tools/k13-stop.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "sudo docker cp /tmp/k13-stop.sh $CONTAINER:/root/k13-stop.sh && \
         sudo docker exec $CONTAINER bash /root/k13-stop.sh"
    say "stack stopped in container '$CONTAINER'. The container itself is left running."
}

do_status() {
    "$REPO_ROOT/stack/transfer/kennel-transfer.sh" status
    echo
    local url
    if url="$("$REPO_ROOT/vm/test/verify-meshcat-host.sh" --quiet 2>/dev/null)"; then
        say "Meshcat reachable:  $url"
    else
        say "Meshcat not reachable (simulator not running, or guest down)."
    fi
}

do_all() {
    local t0 marks=""
    phase() {   # $1 = name, $2.. = command
        local name="$1"; shift
        banner "$name"
        t0=$SECONDS
        "$@" || { fail "phase '$name' failed -- fix it and re-run from that verb."; exit 1; }
        marks="$marks$name $(( SECONDS-t0 ))s\n"
    }
    phase compose  do_compose
    phase transfer do_transfer
    phase launch   do_launch
    phase verify   do_verify
    phase walk     do_walk
    banner "done"
    printf "$marks" | awk '{printf "[kennel-demo]   %-9s %s\n", $1, $2}'
}

# --- REGION: dispatch
case "${1:-}" in
    provision) shift; do_provision "$@" ;;
    compose)   shift; do_compose "$@" ;;
    transfer)  shift; do_transfer "$@" ;;
    launch)    shift; do_launch ;;
    verify)    shift; do_verify ;;
    walk)      shift; do_walk "$@" ;;
    down)      shift; do_down ;;
    status)    shift; do_status ;;
    all)       shift; do_all ;;
    -h|--help|help) usage ;;
    *) fail "expected a verb: provision | all | compose | transfer | launch | verify | walk | down | status"
       usage >&2; exit 2 ;;
esac
