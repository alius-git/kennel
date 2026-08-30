#!/bin/bash
# Version: 2026.08.30
# Kennel -- demo driver: the demo-script phases behind single verbs, so an
# operator types a handful of commands instead of ~20 (follow-up to issue #22,
# feeding #27's quickstart; snapshot/reset/up from #51).
#
# Runs on the HOST. Every verb wraps the existing per-phase tool -- this script
# adds orchestration only (guest discovery, scp, ordering, timing), so the
# per-phase tools stay the source of truth for what each step does:
#
#   provision  Yuruna sequence workload.guest.ubuntu.server.24.kennel.reset.ssh
#              (cold path: start -> sizing -> stack -> baseline -> reset)
#   snapshot   vm/guest/.../ubuntu.server.24.kennel-baseline-prep.sh (on guest)
#              + Yuruna.Host's Save-VMDiskSnapshot   (on an already-green guest)
#   reset      Yuruna sequence workload.guest.ubuntu.server.24.kennel.reset.ssh
#              (warm path: revert the disk snapshot, ~1-3 min)
#   up         virsh start + lease/SSH wait + docker start
#   compose    demo/tools/p22-console-demo.sh      (console UI, scripted clicks)
#   transfer   stack/transfer/kennel-transfer.sh apply
#   launch     stack/composed-run/tools/p21-launch-from-commands.sh  (on guest)
#   verify     stack/verify/kennel-verify.sh                         (on guest)
#   walk       vm/test/verify-meshcat-host.sh + p21-trot-hold.sh
#   down       stack/known-good/tools/k13-stop.sh   (in the container)
#
# Usage:
#   kennel-demo.sh provision [--yes]   # clean guest -> baseline snapshot (~35 min; DESTROYS kennel-vm)
#   kennel-demo.sh all                 # compose -> transfer -> launch -> verify -> walk (~6 min)
#   kennel-demo.sh up                  # start the guest and make it reachable
#   kennel-demo.sh reset               # revert to the baseline snapshot (~1-3 min)
#   kennel-demo.sh snapshot [--yes]    # re-take the baseline from a green guest
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
#   YURUNA_IMAGE_DIR      ~/yuruna/image/ubuntu.env   where Get-Image.ps1 put the ISO
#   KENNEL_DEMO_OUT       ~/kennel-runs      where compose unpacks run folders
#   KENNEL_CONSOLE_PORT   8000               port compose serves the console on
#   KENNEL_SOLVER         PARTIAL_CONDENSING_OSQP   composed + expected solver
#   KENNEL_RATE           0.75               composed simulator_realtime_rate
#   KENNEL_SNAPSHOT_ID    kennel-vm-baseline snapshot id AND persisted domain name
#   KENNEL_VM_DOMAIN      (discovered)       libvirt domain, for up/snapshot
#   KENNEL_UP_TIMEOUT     600                bound on the boot wait in `up`
#   KENNEL_GUEST_HOSTNAME / KENNEL_GUEST_IP / KENNEL_SSH_KEY / KENNEL_GUEST_USER
#   KENNEL_LIBVIRT_NET / KENNEL_CONTAINER    as in kennel-transfer.sh
#
# Exit codes: 0 success; otherwise the wrapped tool's exit code, or 2 for this
# script's own argument/infrastructure errors. `up` adds 3 = the guest never
# became reachable within the bound.
#
# See demo/runbook.md for the operator-facing walkthrough and vm/snapshot.md for
# what the baseline snapshot is and what it costs.

set -uo pipefail

# --- REGION: knobs
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"
IMAGE_DIR="${YURUNA_IMAGE_DIR:-$HOME/yuruna/image/ubuntu.env}"
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

# The snapshot id is ALSO the persisted domain name -- Yuruna's saveDiskSnapshot
# renames the domain to it so the next cycle's `test-` sweep leaves it alone, and
# the requiresSnapshot probe looks for snapshot <id> on VM <id> (vm/snapshot.md).
SNAPSHOT_ID="${KENNEL_SNAPSHOT_ID:-kennel-vm-baseline}"
VM_DOMAIN="${KENNEL_VM_DOMAIN:-}"
UP_TIMEOUT="${KENNEL_UP_TIMEOUT:-600}"
# What Yuruna names the guest while it is still a disposable build VM, before
# the rename: `<testVmNamePrefix><guestKey>-01`.
YURUNA_BUILD_DOMAIN="${KENNEL_BUILD_DOMAIN:-test-guest.ubuntu.server.24-01}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

CONSOLE_URL="http://localhost:$PORT/Kennel%20Console.dc.html"
# `provision` and `reset` run the SAME sequence; the runner's requiresSnapshot
# probe is what makes it a 35-minute build or a 2-minute revert. Cold (no
# snapshot): the whole chain runs and ends by taking one. Warm: every prereq is
# skipped and only the revert + asserts run. See vm/snapshot.md section 2.
SEQUENCE="workload.guest.ubuntu.server.24.kennel.reset.ssh"

say()  { echo "[kennel-demo] $*"; }
warn() { echo "[kennel-demo] WARNING: $*" >&2; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }
usage() { sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
banner() { echo; echo "==== $* ===="; }

# --- REGION: guest plumbing (same discovery as kennel-transfer.sh)
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

lease_ip() {
    virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null \
        | awk -v h="$GUEST_HOSTNAME" '$0 ~ h {print $5}' \
        | cut -d/ -f1 | tail -1
}

need_guest() {
    [ -n "$GUEST_IP" ] || GUEST_IP="$(lease_ip)"
    [ -n "$GUEST_IP" ] || {
        fail "could not discover the guest IP on libvirt network '$LIBVIRT_NET'." \
             "Is the guest running?   virsh list --all" \
             "If it is merely shut off:  $0 up" \
             "Override directly with: KENNEL_GUEST_IP=192.168.122.x $0 ..."
        exit 2
    }
    TARGET="$GUEST_USER@$GUEST_IP"
    ssh "${SSH_OPTS[@]}" "$TARGET" true 2>/dev/null || {
        fail "cannot reach the guest over SSH at $TARGET." \
             "Key: $SSH_KEY" \
             "If the guest has just booted, sshWaitReady can take several minutes." \
             "Or let the driver wait for it:  $0 up"
        exit 2
    }
    say "guest            $GUEST_HOSTNAME at $GUEST_IP"
}

# --- REGION: libvirt domain plumbing (issue #51)
# Discovery of the GUEST is by DHCP lease hostname and never by domain name
# (vm/meshcat-exposure.md 3.1) -- which is exactly why saveDiskSnapshot may
# rename the domain out from under every other tool without breaking any of
# them. But `virsh start` needs a DOMAIN, so the two verbs that power the guest
# on and off (`up`, `snapshot`) have to resolve one, and after the rename there
# are two names it could be under.

# Domains whose interface MAC currently holds a lease for the kennel hostname.
domains_by_lease() {
    local macs d m
    macs="$(virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null \
            | awk -v h="$GUEST_HOSTNAME" '$0 ~ h {print tolower($3)}')"
    [ -n "$macs" ] || return 0
    for d in $(virsh list --all --name 2>/dev/null); do
        [ -n "$d" ] || continue
        for m in $macs; do
            if virsh domiflist "$d" 2>/dev/null | tr 'A-Z' 'a-z' | grep -q "$m"; then
                echo "$d"; break
            fi
        done
    done
}

# Echoes one domain name on stdout; diagnostics go to stderr so the caller can
# capture it. Order of preference: an explicit KENNEL_VM_DOMAIN, then whoever
# actually answers to the kennel hostname right now, then the persisted
# (post-snapshot) name, then Yuruna's build-VM name.
pick_domain() {
    local d n cands=()
    if [ -n "$VM_DOMAIN" ]; then
        virsh domstate "$VM_DOMAIN" >/dev/null 2>&1 || {
            fail "no libvirt domain named '$VM_DOMAIN' (KENNEL_VM_DOMAIN)." \
                 "What is defined:  virsh list --all"
            return 2
        }
        echo "$VM_DOMAIN"; return 0
    fi
    while read -r d; do [ -n "$d" ] && cands+=("$d"); done < <(domains_by_lease)
    for n in "$SNAPSHOT_ID" "$YURUNA_BUILD_DOMAIN"; do
        virsh domstate "$n" >/dev/null 2>&1 || continue
        case " ${cands[*]-} " in *" $n "*) ;; *) cands+=("$n") ;; esac
    done
    [ "${#cands[@]}" -gt 0 ] || {
        fail "no candidate libvirt domain for guest '$GUEST_HOSTNAME'." \
             "Looked for a domain holding its DHCP lease, then '$SNAPSHOT_ID', then '$YURUNA_BUILD_DOMAIN'." \
             "What is defined:  virsh list --all" \
             "Name one directly: KENNEL_VM_DOMAIN=<domain> $0 ..."
        return 2
    }
    # Two guests answering to one hostname is the failure mode the rename
    # introduces: both request a lease as 'kennel-vm' and lease_ip's `tail -1`
    # silently picks whichever renewed last. `provision` makes it impossible by
    # sweeping both names; everything else can only warn.
    if [ "${#cands[@]}" -gt 1 ]; then
        warn "more than one domain could be '$GUEST_HOSTNAME': ${cands[*]}"
        warn "using '${cands[0]}'. While both exist, lease discovery is a coin flip --"
        warn "destroy the stale one (virsh undefine), or set KENNEL_VM_DOMAIN."
    fi
    echo "${cands[0]}"
}

# Poll for the lease, then for an authenticated SSH shell. Bounded, and it
# OBSERVES the guest coming up rather than sleeping a fixed guess (dry-run.md F8):
# the loop exits the moment ssh answers, so a warm revert is not charged a cold
# boot's wait. Sets GUEST_IP / TARGET on success.
wait_for_guest() {   # $1 = bound in seconds
    local bound="${1:-$UP_TIMEOUT}" t0=$SECONDS ip=""
    while [ $((SECONDS - t0)) -lt "$bound" ]; do
        ip="$(lease_ip)"
        if [ -n "$ip" ] && ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" true 2>/dev/null; then
            GUEST_IP="$ip"; TARGET="$GUEST_USER@$ip"
            return 0
        fi
        sleep 2
    done
    return 1
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

# Install the kennel sequences + guest scripts into the framework clone
# (provisioning.md 4.2). Idempotent, so every verb that runs a sequence does it
# rather than trusting memory -- skipping it is dry-run finding F3, a failure
# twenty minutes into the cycle. It also causes the yellow 'fetch-and-execute
# fallback ... differs from HEAD' warning on a healthy run (F5) -- expected.
install_kennel_files() {
    cp "$REPO_ROOT"/vm/test/*.kennel*.yml "$YURUNA_DIR/test/sequences/" || return 2
    cp "$REPO_ROOT"/vm/guest/ubuntu.server.24/*.sh "$YURUNA_DIR/guest/ubuntu.server.24/" || return 2
    say "kennel files installed into the Yuruna clone (provisioning.md 4.2)"
}

need_yuruna() {
    [ -d "$YURUNA_DIR" ] || {
        fail "no Yuruna checkout at $YURUNA_DIR." \
             "The host baseline (vm/host-baseline.md) is a prerequisite; set YURUNA_DIR if it lives elsewhere."
        exit 2
    }
}

# --- REGION: verbs
do_provision() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1
    need_yuruna

    # -- preflight: fail in seconds on the prerequisites that otherwise fail
    #    20+ minutes into the run (dry-run.md F3).
    banner "preflight"

    # The three Yuruna patches (host-baseline.md §6.4) must be in the clone.
    # `git apply --reverse --check` succeeding means the patch is present.
    local p missing=0
    for p in "$REPO_ROOT"/vm/patches/*.patch; do
        if git -C "$YURUNA_DIR" apply --reverse --check "$p" >/dev/null 2>&1; then
            say "patch applied    $(basename "$p")"
        elif git -C "$YURUNA_DIR" apply --check "$p" >/dev/null 2>&1; then
            fail "Yuruna patch NOT applied: $(basename "$p")." \
                 "Apply it first:  git -C $YURUNA_DIR apply $p" \
                 "See vm/host-baseline.md §6.4."
            missing=1
        else
            fail "cannot tell whether $(basename "$p") is applied -- the Yuruna tree at" \
                 "$YURUNA_DIR matches neither state. Is it at tag 2026.08.04? (host-baseline.md §2)"
            missing=1
        fi
    done
    [ "$missing" = 0 ] || exit 2

    # The guest ISO is fetched once, up front -- Invoke-TestSequence does no
    # image download (host-baseline.md §5.1).
    if ! ls "$IMAGE_DIR"/*.iso >/dev/null 2>&1; then
        fail "no guest ISO under $IMAGE_DIR (~3.2 GB, fetched once)." \
             "cd $YURUNA_DIR/host/ubuntu.kvm/guest.ubuntu.server.24 && pwsh ./Get-Image.ps1" \
             "Different image dir? Set YURUNA_IMAGE_DIR."
        exit 2
    fi
    say "guest ISO        $(ls "$IMAGE_DIR"/*.iso | head -1)"

    install_kennel_files || exit 2
    say "this DESTROYS any existing '$GUEST_HOSTNAME' guest -- INCLUDING the baseline"
    say "snapshot '$SNAPSHOT_ID' -- and rebuilds it from clean (~35 min)."
    say "To return to the baseline instead, without rebuilding:  $0 reset"
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

    banner "provision: $SEQUENCE (cold path -- ends in snapshot '$SNAPSHOT_ID')"
    local t0=$SECONDS
    # BOTH names, and that is the whole point of the sweep. Once a baseline has
    # been taken the guest is no longer called `test-...`: saveDiskSnapshot
    # renamed it to the snapshot id precisely so the cycle sweep would leave it
    # alone. A clean rebuild has to opt back in by name, or the run finds the
    # persisted VM "already there", reuses it at its old size, and is never
    # clean at all (guest-sizing.md §2) -- and worse, the requiresSnapshot probe
    # then sees the surviving snapshot and takes the WARM path, so `provision`
    # silently becomes a `reset`. Prefixes are matched literally, never as
    # wildcards.
    #
    # -Command with a real array literal, and it has to be. Remove-TestVMFiles
    # declares -Prefix as [string[]], but `pwsh -File script.ps1 -Prefix a,b`
    # does NOT produce two elements: comma-as-array is a PowerShell *parser*
    # feature, and arguments arriving from a bash argv are bound as the literal
    # strings they are. Both `-Prefix "test-,$ID"` and `-Prefix test-,$ID` bind
    # ONE element named "test-,kennel-vm-baseline", which matches no VM at all
    # and reports "No VMs found" -- a sweep that silently does nothing. See
    # vm/snapshot.md §6, F3.
    pwsh -NoProfile -Command \
        "& ./test/Remove-TestVMFiles.ps1 -Prefix @('test-','$SNAPSHOT_ID') -Confirm:\$false" || exit $?
    # The reset sequence as TOP LEVEL. With the snapshot just swept away the
    # runner takes the cold path: start -> sizing -> stack -> baseline -> reset,
    # i.e. provisioning now ENDS in a snapshot and proves the revert on the way
    # out. Step count is not the invariant (it changes whenever a sequence gains
    # a step) -- 0 FAIL is.
    pwsh test/Invoke-TestSequence.ps1 -SequenceName "$SEQUENCE" || {
        fail "the sequence did not pass -- see the transcript above (expect 0 FAIL)."
        exit 1
    }
    say "provisioned in $(( (SECONDS-t0) / 60 ))m$(( (SECONDS-t0) % 60 ))s"
    banner "baseline"
    virsh snapshot-list "$SNAPSHOT_ID" 2>&1 | sed 's/^/[kennel-demo] /'
    say "the guest can now be returned to this state in seconds:  $0 reset"
}

do_up() {
    local d state t0=$SECONDS
    d="$(pick_domain)" || exit 2
    say "domain           $d"
    state="$(virsh domstate "$d" 2>/dev/null)"
    say "state            $state"
    case "$state" in
        running) ;;
        paused)
            virsh resume "$d" >/dev/null || { fail "virsh resume '$d' failed."; exit 2; } ;;
        "shut off"|shutoff|crashed)
            say "starting it"
            virsh start "$d" >/dev/null || { fail "virsh start '$d' failed."; exit 2; } ;;
        *)
            fail "domain '$d' is in state '$state', which this verb does not know how to fix." \
                 "Look at it:  virsh domstate $d ; virsh list --all"
            exit 2 ;;
    esac
    say "waiting for the DHCP lease and sshd (bounded at ${UP_TIMEOUT}s)"
    wait_for_guest "$UP_TIMEOUT" || {
        fail "'$d' never became reachable within ${UP_TIMEOUT}s." \
             "Watch it boot:  virsh console $d        (leave with Ctrl+])" \
             "Leases:         virsh net-dhcp-leases $LIBVIRT_NET" \
             "Raise the bound with KENNEL_UP_TIMEOUT if this host is slow."
        exit 3
    }
    say "guest            $GUEST_HOSTNAME at $GUEST_IP  (reachable after $((SECONDS-t0))s)"
    # No --restart policy, by design (provisioning.md §3.2): the container is
    # down after every boot, and nothing in `status` or `walk` starts it.
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "s=\$(sudo docker inspect --type container -f '{{.State.Status}}' '$CONTAINER' 2>/dev/null); \
         if [ \"\$s\" != running ]; then sudo docker start '$CONTAINER' >/dev/null && echo 'container started'; \
         else echo 'container already running'; fi" | sed 's/^/[kennel-demo] /'
    echo
    do_status
}

do_snapshot() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1
    need_yuruna
    need_guest

    banner "baseline prep (on the guest)"
    say "this re-takes the baseline snapshot '$SNAPSHOT_ID', overwriting any existing one."
    if [ "$yes" != 1 ]; then
        reply=""
        read -r -p "[kennel-demo] proceed? [y/N] " reply || true
        case "$reply" in y|Y|yes) ;; *) say "aborted (pass --yes to skip the prompt)."; exit 2 ;; esac
    fi
    guest_stage vm/guest/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/ubuntu.server.24.kennel-baseline-prep.sh" || {
        local rc=$?
        fail "the guest is not a clean baseline (prep exited $rc) -- refusing to snapshot it." \
             "A dirty baseline is worse than none: every future reset would return it." \
             "Fix what the prep script named above, then re-run:  $0 snapshot"
        exit "$rc"
    }

    banner "save disk snapshot"
    local d; d="$(pick_domain)" || exit 2
    say "domain           $d"
    say "snapshot id      $SNAPSHOT_ID"
    # Yuruna's own driver, not a re-implementation. The rename is the part that
    # must not be improvised: Save-VMDiskSnapshot renames the domain to the id
    # and relocates ~/yuruna/vms/<old> BEFORE snapshotting, because libvirt
    # freezes the domain XML into the snapshot metadata and a snapshot taken
    # under the old name can never be reverted (Yuruna.Host.psm1's own comment).
    # It also stops the VM first and leaves it stopped.
    #
    # The manifest sidecar is written the same way the saveDiskSnapshot step
    # handler writes it, with the same runtime dir and the host's own HostType.
    # Without it `reset` warns "no manifest ... proceeding (legacy snapshot)" on
    # every revert; a manifest with the WRONG fields is a hard refuse, which is
    # why the host type is asked for rather than assumed.
    local ps; ps="$(mktemp --suffix=.ps1)"
    cat > "$ps" <<'PSEOF'
param([Parameter(Mandatory)][string]$YurunaDir,
      [Parameter(Mandatory)][string]$VMName,
      [Parameter(Mandatory)][string]$Id)
$ErrorActionPreference = 'Stop'
$env:YURUNA_RUNTIME_DIR = (Join-Path $YurunaDir 'test/status/runtime')
Import-Module (Join-Path $YurunaDir 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $YurunaDir 'test/modules/Test.HostDetection.psm1')      -Force -DisableNameChecking
Import-Module (Join-Path $YurunaDir 'test/modules/Test.SnapshotManifest.psm1')   -Force -DisableNameChecking
if (-not (Save-VMDiskSnapshot -VMName $VMName -Id $Id -Confirm:$false)) {
    Write-Error "Save-VMDiskSnapshot '$VMName' -> '$Id' failed (see the warnings above)."
    exit 1
}
$manifest = Write-SnapshotManifest -VMName $Id -SnapshotId $Id -HostType (Get-HostType) -Confirm:$false
if ($manifest) { Write-Output "manifest: $manifest" }
else { Write-Warning "snapshot saved, but its manifest could not be written; reset will warn about a legacy snapshot." }
exit 0
PSEOF
    pwsh -NoProfile -File "$ps" -YurunaDir "$YURUNA_DIR" -VMName "$d" -Id "$SNAPSHOT_ID"
    local rc=$?
    rm -f "$ps"
    [ "$rc" -eq 0 ] || { fail "the snapshot was not taken (exit $rc)."; exit "$rc"; }

    banner "baseline"
    virsh snapshot-list "$SNAPSHOT_ID" 2>&1 | sed 's/^/[kennel-demo] /'
    say "the domain is now '$SNAPSHOT_ID' and it is STOPPED -- that is the documented"
    say "contract of saveDiskSnapshot. Bring it back with:  $0 up   (or $0 reset)"
}

do_reset() {
    need_yuruna
    install_kennel_files || exit 2
    cd "$YURUNA_DIR" || exit 2
    virsh list --all > /dev/null    # wake socket-activated libvirtd

    banner "reset: $SEQUENCE (warm path -- revert to '$SNAPSHOT_ID')"
    say "no Test-Config gate here: reset spends seconds, not the 35 minutes the gate"
    say "exists to protect. provision still gates."
    local t0=$SECONDS
    pwsh test/Invoke-TestSequence.ps1 -SequenceName "$SEQUENCE" || {
        fail "the reset sequence did not pass -- see the transcript above (expect 0 FAIL)." \
             "'requiresSnapshot: snapshot ... not on host' means there is no baseline yet:" \
             "take one with  $0 snapshot , or rebuild with  $0 provision ."
        exit 1
    }
    say "reset in $(( (SECONDS-t0) / 60 ))m$(( (SECONDS-t0) % 60 ))s"
    say "the guest is back at the baseline: stock configs at the pin, container running,"
    say "workspace built, no run applied. Compose and launch with:  $0 all"

    # Yuruna captures sshExec output only when a step FAILS, so a green sequence
    # leaves no record of WHICH baseline came back -- not in the HTML log, not in
    # cycle.events.ndjson. Print it here, host-side, so the operator's own
    # transcript carries it.
    banner "baseline record"
    GUEST_IP="${KENNEL_GUEST_IP:-}"      # the revert re-DHCPs; re-discover
    need_guest
    ssh "${SSH_OPTS[@]}" "$TARGET" "cat ~/.kennel-baseline" | sed 's/^/[kennel-demo] /'
    echo
    do_status
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
    up)        shift; do_up ;;
    reset)     shift; do_reset ;;
    snapshot)  shift; do_snapshot "$@" ;;
    compose)   shift; do_compose "$@" ;;
    transfer)  shift; do_transfer "$@" ;;
    launch)    shift; do_launch ;;
    verify)    shift; do_verify ;;
    walk)      shift; do_walk "$@" ;;
    down)      shift; do_down ;;
    status)    shift; do_status ;;
    all)       shift; do_all ;;
    -h|--help|help) usage ;;
    *) fail "expected a verb: provision | up | reset | snapshot | all | compose | transfer | launch | verify | walk | down | status"
       usage >&2; exit 2 ;;
esac
