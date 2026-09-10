#!/bin/bash
# Version: 2026.09.07
# Kennel -- demo driver: the demo-script phases behind single verbs, so an
# operator types a handful of commands instead of ~20 (follow-up to issue #22,
# feeding #27's quickstart; snapshot/reset/up from #51; setup/console/run and
# the zip-accepting transfer from #54; serve.py behind `console` from #56).
#
# Runs on the HOST. Every verb wraps the existing per-phase tool -- this script
# adds orchestration only (guest discovery, scp, ordering, timing), so the
# per-phase tools stay the source of truth for what each step does.
#
# Since #23 this repository is a Yuruna PROJECT: every verb that runs a sequence
# first CLONES this checkout's committed HEAD into $YURUNA_DIR/project (the
# framework's own project directory) and then runs the sequence with
# -NoProjectClone. Nothing is copied into the framework's own tree any more, and
# what runs is what is committed -- see test/README.md and KENNEL_PROJECT_URL.
#
#   setup      the once-per-host prerequisites of demo/runbook.md 2, checked
#              and where possible done (Yuruna clone, tag, patches, config,
#              Enable-TestAutomation.ps1, guest ISO, Test-Config gate)
#   provision  Yuruna sequence workload.guest.ubuntu.server.24.kennel.reset.ssh
#              (cold path: start -> sizing -> stack -> baseline -> reset)
#   snapshot   test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh
#              (on guest) + Yuruna.Host's Save-VMDiskSnapshot
#              (on an already-green guest)
#   reset      Yuruna sequence workload.guest.ubuntu.server.24.kennel.reset.ssh
#              (warm path: revert the disk snapshot, ~1-3 min)
#   up         virsh start + lease/SSH wait + docker start
#   halt       virsh shutdown + a bounded wait for the domain to stop
#   console    kennel_console/serve.py on kennel_console/, backgrounded, opened
#              (static files + the POST endpoint the console's `send to
#              kennel-runs` button writes run folders through)
#   compose    demo/tools/p22-console-demo.sh      (console UI, scripted clicks)
#   transfer   stack/transfer/kennel-transfer.sh apply   (run folder OR .zip)
#   launch     stack/composed-run/tools/p21-launch-from-commands.sh  (on guest)
#   verify     stack/verify/kennel-verify.sh                         (on guest),
#              then files its report in the applied run's folder as verify.json
#   scenario   demo/tools/scenario-<name>.sh -- one verification scenario of
#              plan/scenarios.md driven end to end and asserted (see
#              demo/scenarios.md). A test, not a demo phase. `firstwalk`
#              performs guides/first-run.md itself, so its subject is a
#              document rather than the stack.
#   walk       vm/test/verify-meshcat-host.sh + p21-trot-hold.sh
#   teleop     stack/bridge/kennel-bridge.sh (on guest) + verify-bridge-host.sh,
#              then the console: drive the robot from the browser joystick
#   down       stack/known-good/tools/k13-stop.sh   (in the container)
#   mvp        Yuruna sequence workload.guest.ubuntu.server.24.kennel.mvp.ssh
#              (#24): the demo as one sequence, asserted -- and its evidence
#              collected off the guest, which Yuruna itself cannot do
#
# Usage:
#   Once per host
#     kennel-demo.sh setup [--yes]     # check/do the prerequisites (runbook 2)
#     kennel-demo.sh provision [--yes] # clean guest -> baseline snapshot (~35 min; DESTROYS kennel-vm)
#
#   Each session
#     kennel-demo.sh up                # start the guest and make it reachable
#     kennel-demo.sh console [--no-open|stop]   # serve the console and open it
#     kennel-demo.sh run [run-folder|zip]       # transfer -> launch -> verify -> walk
#     kennel-demo.sh teleop            # drive it from the console's joystick
#     kennel-demo.sh teleop stop       # stop driving: zero, STAND, bridge down
#     kennel-demo.sh walk stop         # return the gait to STAND
#     kennel-demo.sh down              # stop the stack in the container
#     kennel-demo.sh reset             # revert to the baseline snapshot (~1-3 min)
#
#   Pieces
#     kennel-demo.sh all               # compose -> transfer -> launch -> verify -> walk (~6 min)
#     kennel-demo.sh compose [outdir]  # default outdir: ~/kennel-runs
#     kennel-demo.sh transfer [run-folder|zip]  # default: newest run, folder or zip
#     kennel-demo.sh launch
#     kennel-demo.sh verify
#     kennel-demo.sh walk              # trot + print the Meshcat URL
#     kennel-demo.sh status
#     kennel-demo.sh snapshot [--yes]  # re-take the baseline from a green guest
#     kennel-demo.sh halt              # power the guest down cleanly
#
#   Harness (the Yuruna sequences this repo ships as a project -- test/README.md)
#     kennel-demo.sh mvp               # the MVP sequence: revert -> stage the
#                                      # console's fixture -> apply -> launch ->
#                                      # assert walking on the composed solver
#                                      # (~4 min warm, ~40 min from no baseline)
#
#   Scenarios (tests against the running stack, not demo phases)
#     kennel-demo.sh scenario disturb  # s004: interventions, and the process
#                                      # set that never changes (#69)
#     kennel-demo.sh scenario diagnose # s003: degradation, fall, post-mortem (#71)
#     kennel-demo.sh scenario firstwalk # s001: guides/first-run.md performed and
#                                      # timed. Needs the stack DOWN and the
#                                      # console port free -- step 1 of the
#                                      # checklist is what starts it (#73)
#
# Knobs (all optional, environment variables):
#   YURUNA_DIR            ~/git/yuruna       framework checkout (setup, provision)
#   YURUNA_TAG            2026.08.04         framework release setup checks out
#   YURUNA_IMAGE_DIR      ~/yuruna/image/ubuntu.env   where Get-Image.ps1 put the ISO
#   KENNEL_HARNESS_EVIDENCE  test/evidence     where `mvp` leaves what it
#                                            collected off the guest and out of
#                                            the Yuruna cycle folder
#   KENNEL_PROJECT_URL    file://<this repo> what the verbs clone into
#                                            $YURUNA_DIR/project before running a
#                                            sequence (#23). The default is THIS
#                                            checkout, so a verb runs the branch
#                                            you are on -- but its COMMITTED
#                                            head: git clone, never the working
#                                            tree. Point it at the GitHub URL to
#                                            run what is pushed instead
#   KENNEL_DEMO_OUT       ~/kennel-runs      where compose unpacks run folders,
#                                            and where the console's send button
#                                            writes them through serve.py
#   KENNEL_DOWNLOADS      ~/Downloads        where the browser saves run-*.zip
#   KENNEL_CONSOLE_PORT   8000               port compose/console serve on
#   KENNEL_WATCHDOG       1                  start the guest-side target
#                                            watchdog with the bridge (#67);
#                                            0 leaves a killed tab's target in
#                                            force, which is what it is for
#   KENNEL_WATCHDOG_STALE 1.0                seconds without a target before the
#                                            watchdog zeroes it
#   KENNEL_SOLVER         PARTIAL_CONDENSING_OSQP   composed solver, and the
#                                            expected one when no run.json says
#   KENNEL_RATE           0.75               composed simulator_realtime_rate
#   KENNEL_PRESET         (none)             one of the presets the CONSOLE
#                                            ships (#72), picked in the UI by
#                                            its name or its slug:
#                                              stock-go2-walk
#                                              solver-benchmark-a-hpipm
#                                              solver-benchmark-b-osqp
#                                              stress
#                                            The composition is the page's data
#                                            (kennel_console/composer-scope.md
#                                            §7), never a table in this script;
#                                            a wrong name is refused by the page
#                                            with the four it offers. It fills
#                                            in only what you did not choose --
#                                            an explicit KENNEL_SOLVER or
#                                            KENNEL_RATE still wins. `stress` is
#                                            the measured red composition #71
#                                            needs (stack/stress.md §4)
#   KENNEL_DISTURBANCES   0                  1 composes the fourth block, the
#                                            disturbance service (#68)
#   KENNEL_MAP / KENNEL_HPIPM_MODE / KENNEL_CONDENSED   passed to compose; unset
#                                            leaves the control untouched
#   KENNEL_SNAPSHOT_ID    kennel-vm-baseline snapshot id AND persisted domain name
#   KENNEL_VM_DOMAIN      (discovered)       libvirt domain, for up/halt/snapshot
#   KENNEL_UP_TIMEOUT     600                bound on the boot wait in `up`
#   KENNEL_GUEST_HOSTNAME / KENNEL_GUEST_IP / KENNEL_SSH_KEY / KENNEL_GUEST_USER
#   KENNEL_LIBVIRT_NET / KENNEL_CONTAINER    as in kennel-transfer.sh
#
# Exit codes: 0 success; otherwise the wrapped tool's exit code, or 2 for this
# script's own argument/infrastructure errors. `up` adds 3 = the guest never
# became reachable within the bound. `setup` uses 2 for anything it found that
# it cannot do for you (group membership, a missing installer, a FAIL finding).
#
# See demo/runbook.md for the operator-facing walkthrough, vm/snapshot.md for
# what the baseline snapshot is and what it costs, and vm/host-baseline.md for
# what `setup` is automating.

set -uo pipefail

# --- REGION: knobs
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"
YURUNA_TAG="${YURUNA_TAG:-2026.08.04}"
IMAGE_DIR="${YURUNA_IMAGE_DIR:-$HOME/yuruna/image/ubuntu.env}"
OUT="${KENNEL_DEMO_OUT:-$HOME/kennel-runs}"
# Where `teleop` leaves the URLs it discovered, for serve.py to hand to the page
# through /api/health. Files rather than flags because the console is usually
# ALREADY RUNNING when teleop is used -- serve.py re-reads them per request, so
# nothing has to be restarted (send.md's feature detection, one level down).
BRIDGE_FILE="$OUT/.kennel-bridge"
MESHCAT_FILE="$OUT/.kennel-meshcat"
# Where the browser saves the console's archive. `transfer` and `run` look here
# as well as in OUT, so composing by hand needs no unzip and no path typed
# (issue #54); it is a knob because "Downloads" is a desktop convention, not a
# guarantee -- a locale or a changed Chrome setting moves it.
DOWNLOADS="${KENNEL_DOWNLOADS:-$HOME/Downloads}"
PORT="${KENNEL_CONSOLE_PORT:-8000}"
SOLVER="${KENNEL_SOLVER:-PARTIAL_CONDENSING_OSQP}"
RATE="${KENNEL_RATE:-0.75}"
# Whether the RATE above is a choice or a default, because a preset composes one
# and an explicit knob must still win.
RATE_IS_DEFAULT=0; [ -z "${KENNEL_RATE:-}" ] && RATE_IS_DEFAULT=1
SOLVER_IS_DEFAULT=0; [ -z "${KENNEL_SOLVER:-}" ] && SOLVER_IS_DEFAULT=1
# One of the presets the console ships (#72), by name or slug. This script does
# not know what any of them composes -- it hands the name to the page, which
# owns the data and refuses a name it does not offer.
PRESET="${KENNEL_PRESET:-}"

GUEST_HOSTNAME="${KENNEL_GUEST_HOSTNAME:-kennel-vm}"
LIBVIRT_NET="${KENNEL_LIBVIRT_NET:-default}"
GUEST_USER="${KENNEL_GUEST_USER:-yuuser24}"
SSH_KEY="${KENNEL_SSH_KEY:-$HOME/git/yuruna/test/status/ssh/yuruna_ed25519}"
GUEST_IP="${KENNEL_GUEST_IP:-}"
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
BRIDGE_PORT="${KENNEL_BRIDGE_PORT:-9090}"
# The guest-side dead man's switch (#67), started and stopped with the bridge.
# Knobs, not flags: they are passed through to the tool that defines them
# (stack/bridge/tools/k13-target-watchdog.py), as every other knob here is.
WATCHDOG="${KENNEL_WATCHDOG:-1}"
WATCHDOG_STALE="${KENNEL_WATCHDOG_STALE:-1.0}"
# The one topic two publishers can fight over (stack/launch.md §4.2).
TARGET_TOPIC=/quad_control_target

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

# What gets cloned into $YURUNA_DIR/project before a sequence runs (#23). A
# clone URL, exactly as Yuruna's own repositories.projectUrl is -- and the
# default is this checkout, so `provision`, `reset` and the harness verbs run
# the branch you are sitting on rather than whatever main holds. `git clone`
# takes the COMMITTED head, so an uncommitted edit under test/ does not run;
# install_kennel_project says so rather than letting you wonder.
PROJECT_URL="${KENNEL_PROJECT_URL:-file://$REPO_ROOT}"

# The origin is separate from the page URL because serve.py answers /api/
# there as well (kennel_console/send.md section 1).
CONSOLE_ORIGIN="http://localhost:$PORT"
CONSOLE_URL="$CONSOLE_ORIGIN/Kennel%20Console.dc.html"
# `provision` and `reset` run the SAME sequence; the runner's requiresSnapshot
# probe is what makes it a 35-minute build or a 2-minute revert. Cold (no
# snapshot): the whole chain runs and ends by taking one. Warm: every prereq is
# skipped and only the revert + asserts run. See vm/snapshot.md section 2.
SEQUENCE="workload.guest.ubuntu.server.24.kennel.reset.ssh"
# The one guest `test.config.yml` is scoped to. The stock template lists three;
# leaving the other two in makes every cycle build guests this repo has no use
# for (vm/host-baseline.md §3).
GUEST_KEY="guest.ubuntu.server.24"

say()  { echo "[kennel-demo] $*"; }
warn() { echo "[kennel-demo] WARNING: $*" >&2; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }
# The Usage block groups the verbs by when you reach for them and is therefore
# full of blank `#` separator lines -- so it is delimited by the Knobs heading
# that follows it, never by the first blank comment line.
usage() {
    sed -n '/^# Usage:/,/^# Knobs/p' "${BASH_SOURCE[0]}" \
        | sed '$d' | sed 's/^# \{0,1\}//'
}
banner() { echo; echo "==== $* ===="; }

# --- REGION: guest plumbing (same discovery as kennel-transfer.sh)
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

lease_ip() {
    virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null \
        | awk -v h="$GUEST_HOSTNAME" '$0 ~ h {print $5}' \
        | cut -d/ -f1 | tail -1
}

# Set once so a verb that calls need_guest twice cannot loop through `up`
# twice: the second failure is a real one and must be reported, not retried.
UP_ATTEMPTED=0

# True when the guest answers an authenticated SSH shell right now. Sets
# GUEST_IP/TARGET as a side effect when it does.
guest_reachable() {
    local ip="${GUEST_IP:-}"
    [ -n "$ip" ] || ip="$(lease_ip)"
    [ -n "$ip" ] || return 1
    ssh "${SSH_OPTS[@]}" "$GUEST_USER@$ip" true 2>/dev/null || return 1
    GUEST_IP="$ip"; TARGET="$GUEST_USER@$ip"
    return 0
}

need_guest() {
    guest_reachable && { say "guest            $GUEST_HOSTNAME at $GUEST_IP"; return 0; }

    # Not reachable. Before failing, look at WHY -- and note that "no lease" is
    # NOT the signal. libvirt keeps a lease in its file until it expires, so a
    # guest powered off a minute ago still resolves to an IP that nothing
    # answers on. Reachability is the only honest test; the domain state is what
    # says whether this is fixable here.
    #
    # A guest that is merely powered off is not an error the operator should
    # have to translate into another verb -- it is the state a host reboot
    # leaves behind, and `up` is the whole fix. Only that state is corrected
    # automatically. A domain that is already RUNNING but unreachable is a
    # different animal (mid-boot, or a broken network) and gets the diagnosis
    # instead of a silent ten-minute wait inside a verb as innocuous as `status`.
    if [ "$UP_ATTEMPTED" = 0 ]; then
        UP_ATTEMPTED=1
        local d state
        if d="$(pick_domain 2>/dev/null)" && [ -n "$d" ]; then
            state="$(virsh domstate "$d" 2>/dev/null)"
            case "$state" in
                "shut off"|shutoff|paused|crashed)
                    say "guest '$d' is $state -- starting it ($0 up)"
                    up_core || exit $?
                    guest_reachable && return 0 ;;
            esac
        fi
    fi

    if [ -n "${GUEST_IP:-}" ] || [ -n "$(lease_ip)" ]; then
        fail "cannot reach the guest over SSH at $GUEST_USER@${GUEST_IP:-$(lease_ip)}." \
             "Key: $SSH_KEY" \
             "The domain is running, so this is not a power state: it may still be booting" \
             "(sshWaitReady can take minutes), or the lease is stale." \
             "Let the driver wait for it:  $0 up" \
             "Watch it boot:  virsh console <domain>        (leave with Ctrl+])"
    else
        fail "could not discover the guest IP on libvirt network '$LIBVIRT_NET'." \
             "Is the guest defined?   virsh list --all" \
             "If it is running but still booting:  $0 up   (it waits, bounded)" \
             "Override directly with: KENNEL_GUEST_IP=192.168.122.x $0 ..."
    fi
    exit 2
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

# The four files a console export carries (kennel_console/export.md §1). The
# stack reads only the two YAMLs, but a folder missing either of the other two
# is not an export -- it is something hand-assembled, and transfer says so.
ARTIFACTS=(simulator_params_go2.yaml mit_controller_sim_go2.yaml commands.txt run.json)

# Newest run the operator could plausibly have meant, across BOTH places one can
# appear: the folders `compose` unpacks into OUT, and the archives the browser
# drops in DOWNLOADS when the composition was done by hand. Prints
# "<path>\t<why>" so the caller can explain its choice -- picking the wrong run
# silently is the one failure here the operator cannot see (they get a green
# demo of the wrong configuration).
pick_newest_run() {
    local best="" best_t=0 c t
    for c in "$OUT"/run-*/ ; do
        [ -d "$c" ] || continue
        c="${c%/}"
        t="$(stat -c %Y "$c" 2>/dev/null)" || continue
        [ "$t" -gt "$best_t" ] && { best="$c"; best_t="$t"; }
    done
    for c in "$DOWNLOADS"/run-*.zip ; do
        [ -f "$c" ] || continue
        t="$(stat -c %Y "$c" 2>/dev/null)" || continue
        # Strictly newer, so a zip and the folder unpacked FROM it resolve to the
        # folder -- re-running `run` after one must not unpack the same bytes again.
        [ "$t" -gt "$best_t" ] && { best="$c"; best_t="$t"; }
    done
    [ -n "$best" ] || return 1
    case "$best" in
        *.zip) printf '%s\tnewest archive in %s\n' "$best" "$DOWNLOADS" ;;
        *)     printf '%s\tnewest run folder in %s\n' "$best" "$OUT" ;;
    esac
}

# Validate an export archive, then unpack it into OUT. Echoes the run folder.
#
# The validation is before any write and is the same shape as the one
# kennel-transfer.sh does on a folder: what arrives here came out of a browser's
# download directory, which is also where every other .zip on the machine lives.
# Refusing early means a mis-picked archive costs a message, not a half-written
# run directory that the next `transfer` would happily push into the guest.
unpack_run_zip() {   # $1 = path to run-<stamp>.zip
    local zip="$1" entries prefix n missing=""
    entries="$(unzip -Z1 "$zip" 2>/dev/null)" || {
        fail "'$zip' is not readable as a zip archive." \
             "The console exports run-<stamp>.zip; this is something else."
        exit 2
    }
    prefix="$(printf '%s\n' "$entries" | cut -d/ -f1 | sort -u)"
    [ "$(printf '%s\n' "$prefix" | wc -l)" = 1 ] || {
        fail "'$zip' holds more than one top-level entry: $(echo $prefix)." \
             "A console export is exactly one run-<stamp>/ (export.md §2.2)."
        exit 2
    }
    case "$prefix" in
        run-*) ;;
        *) fail "'$zip' has top-level entry '$prefix', not a run-<stamp>/ folder." \
                "Re-export from the console rather than hand-assembling an archive."
           exit 2 ;;
    esac
    for n in "${ARTIFACTS[@]}"; do
        printf '%s\n' "$entries" | grep -qx "$prefix/$n" || missing="$missing $n"
    done
    [ -z "$missing" ] || {
        fail "'$zip' is missing:$missing" \
             "Every console export carries all four (export.md §1). Re-export."
        exit 2
    }
    # And nothing else. A stray fifth file is not a console export, and this is
    # an archive from a browser's download directory -- the one place on the
    # machine where a same-named zip from somewhere else is likely. Directory
    # entries are tolerated: the console emits none (four entries, export.md
    # §2.2) but `zip -r` writes one, and that difference is not a defect.
    local extra
    extra="$(printf '%s\n' "$entries" | grep -v '/$' \
             | grep -vxF "$(printf "$prefix/%s\n" "${ARTIFACTS[@]}")")"
    [ -z "$extra" ] || {
        fail "'$zip' carries entries a console export does not:" \
             "$(echo $extra)" \
             "Re-export rather than hand-assembling an archive."
        exit 2
    }

    mkdir -p "$OUT"
    # -o so unpacking the same archive twice is idempotent rather than an
    # interactive overwrite prompt in the middle of a demo. Same bytes either way.
    unzip -q -o "$zip" -d "$OUT" || { fail "could not unpack '$zip' into $OUT."; exit 2; }
    [ -d "$OUT/$prefix" ] || {
        fail "'$zip' unpacked without producing $OUT/$prefix."
        exit 2
    }
    echo "$OUT/$prefix"
}

# The solver the run was COMPOSED with, from its own run.json -- read the way
# kennel-transfer.sh reads the pin out of the same file, with sed rather than a
# JSON dependency. This is what `verify --expect-solver` must be given: taking
# it from $KENNEL_SOLVER instead means a by-hand HPIPM run is checked against the
# OSQP default and fails a verification it should pass.
solver_of_run() {   # $1 = run folder
    [ -f "$1/run.json" ] || return 1
    local v
    v="$(sed -n 's/.*"mpc_solver"[[:space:]]*:[[:space:]]*"\([A-Za-z_]*\)".*/\1/p' \
         "$1/run.json" | head -1)"
    [ -n "$v" ] || return 1
    echo "$v"
}

# Was this run composed with disturbances on (#68)? The key is written ONLY when
# on (kennel_console/export.md §3), so its absence is the answer for every run
# composed before the toggle existed as well as for every run composed with it
# off -- which is why this echoes 0/1 and never fails.
disturbances_of_run() {   # $1 = run folder -> 1 (on) or 0
    [ -f "$1/run.json" ] || { echo 0; return 0; }
    if grep -q '"disturbances"[[:space:]]*:[[:space:]]*true' "$1/run.json"; then
        echo 1
    else
        echo 0
    fi
}

# The stack pin, read the way kennel-transfer.sh and serve.py read it. Recorded
# in a verify report so a report says which revision it is a report OF (#64).
pin_sha() { sed -n 's/^commit:[[:space:]]*//p' "$REPO_ROOT/stack/pin.lock" | head -1; }

# The run folder a verify report belongs to (#64).
#
# In-process first: `run` and `all` set APPLIED_RUN, and that is the run the
# stack was just launched on. Standalone `verify` has no such memory, so it asks
# the GUEST what is applied -- ~/kennel-staging/current-run is the marker
# guest-apply-config.sh writes, and it is the same question `status` answers.
# Silent failure is deliberate: a verify with nothing applied is a legitimate
# thing to do, and do_verify says so rather than inventing a folder.
applied_run_dir() {
    if [ -n "$APPLIED_RUN" ] && [ -d "$APPLIED_RUN" ]; then echo "$APPLIED_RUN"; return 0; fi
    local name
    name="$(ssh "${SSH_OPTS[@]}" "$TARGET" 'cat ~/kennel-staging/current-run 2>/dev/null' 2>/dev/null | tr -d '\r')"
    [ -n "$name" ] && [ -d "$OUT/$name" ] && { echo "$OUT/$name"; return 0; }
    return 1
}

# Put this repository where Yuruna discovers a project: a fresh clone at
# $YURUNA_DIR/project (#23). Every verb that runs a sequence does it rather than
# trusting memory -- skipping it is dry-run finding F3, a failure twenty minutes
# into the cycle -- and every such verb then passes -NoProjectClone, so what
# runs is THIS clone and not a re-clone from test.config.yml's projectUrl.
#
# It replaces the copy-into-the-framework-tree step of provisioning.md 4.2,
# which is what retires that bypass AND its yellow 'fetch-and-execute fallback
# ... differs from HEAD' warning (F5): the served file is now a committed file
# of a real clone, so its digest matches its own HEAD.
#
# Wipe-and-clone, like Yuruna's own Update-ProjectClone, so nothing from a
# previous run can leak forward -- with the same guard it has: refuse to delete
# anything that is not literally <YURUNA_DIR>/project.
install_kennel_project() {
    local dst="$YURUNA_DIR/project" sha subj dirty
    case "$dst" in
        */project) ;;
        *) fail "refusing to remove '$dst' -- it is not a .../project path."; return 2 ;;
    esac
    rm -rf "$dst" || { fail "could not remove the old project clone at $dst."; return 2; }
    git clone -q "$PROJECT_URL" "$dst" 2>/dev/null || {
        fail "could not clone the project into $dst." \
             "  url: $PROJECT_URL" \
             "A private repo needs a non-interactive credential on this host:  gh auth login" \
             "Point KENNEL_PROJECT_URL somewhere else to run a different tree (test/README.md 2)."
        return 2
    }
    sha="$(git -C "$dst" rev-parse --short HEAD)"
    subj="$(git -C "$dst" log -1 --pretty=%s)"
    say "project clone    $sha  $subj"
    # The one thing a clone cannot carry: what you have not committed. Only
    # worth saying when the clone came from this checkout -- from any other URL
    # the local tree was never the subject.
    if [ "$PROJECT_URL" = "file://$REPO_ROOT" ]; then
        dirty="$(git -C "$REPO_ROOT" status --porcelain -- test/ demo/ stack/ kennel_console/ guides/ 2>/dev/null)"
        [ -n "$dirty" ] && {
            warn "uncommitted changes are NOT in that clone -- the sequences will run HEAD:"
            printf '%s\n' "$dirty" | sed 's/^/[kennel-demo]        /' >&2
        }
    fi
    return 0
}

# applied | missing | unknown, for one patch file. `git apply --reverse
# --check` succeeding means the tree already carries the change; plain --check
# succeeding means it does not and the patch would still apply cleanly. Neither
# succeeding means the tree is at some third state -- a different tag, or an
# edit on top -- and guessing at that is how you corrupt someone's clone.
patch_state() {   # $1 = path to a .patch
    if   git -C "$YURUNA_DIR" apply --reverse --check "$1" >/dev/null 2>&1; then echo applied
    elif git -C "$YURUNA_DIR" apply         --check "$1" >/dev/null 2>&1; then echo missing
    else echo unknown
    fi
}

need_yuruna() {
    [ -d "$YURUNA_DIR" ] || {
        fail "no Yuruna checkout at $YURUNA_DIR." \
             "The host baseline (vm/host-baseline.md) is a prerequisite; set YURUNA_DIR if it lives elsewhere."
        exit 2
    }
}

# --- REGION: verbs
# --- REGION: setup (issue #54)
# The once-per-host prerequisites of demo/runbook.md §2, checked in one place and
# done where a script is allowed to do them. It is a CHECKER first and a fixer
# second: every item prints its state, and the ones this script must not decide
# for you (group membership, the host installer, a FAIL finding) are reported as
# `needs you` with the command to run, never silently worked around.
#
# Idempotent by construction -- every item asks the host what state it is in
# rather than remembering what a previous run did, so a second `setup` on a ready
# host is all `ok` and changes nothing.
SETUP_BLOCKED=0
setup_item() {   # $1 = ok|did|needs|info, $2 = item, $3.. = detail
    local st="$1" item="$2"; shift 2
    printf '[kennel-demo] %-6s %-16s %s\n' "$st" "$item" "$*"
    [ "$st" = needs ] && SETUP_BLOCKED=$((SETUP_BLOCKED + 1))
    return 0
}
setup_fix() { local l; for l in "$@"; do printf '[kennel-demo]        %s\n' "$l"; done; }

# Changes in the Yuruna clone that this repo did NOT put there. Everything the
# kennel workflow writes into the clone is accounted for: the three patches touch
# exactly the files they name, the project clone lives at project/ (gitignored
# upstream) and test.config.yml is the operator's (also gitignored). Whatever is
# left is somebody's own work, and `setup` will not check out over it.
# Where an older kennel copied its files inside the framework clone, for the
# ones this repo still ships. Paths are relative to $YURUNA_DIR, one per line,
# and only the ones that actually exist there are printed -- so on a host that
# never ran an older kennel this is empty and `setup` reports `ok`.
retired_kennel_copies() {
    local f p
    for f in "$REPO_ROOT"/test/*.kennel*.yml; do
        p="test/sequences/$(basename "$f")"
        [ -e "$YURUNA_DIR/$p" ] && echo "$p"
    done
    for f in "$REPO_ROOT"/test/ubuntu.server.24/*.sh; do
        p="guest/ubuntu.server.24/$(basename "$f")"
        [ -e "$YURUNA_DIR/$p" ] && echo "$p"
    done
    return 0
}

yuruna_unexpected_changes() {
    local expected=() f pth line known
    for f in "$REPO_ROOT"/vm/patches/*.patch; do
        while read -r pth; do [ -n "$pth" ] && expected+=("$pth"); done \
            < <(sed -n 's|^+++ b/||p' "$f")
    done
    # The RETIRED copies. Before #23 this driver copied the sequences and the
    # guest scripts into the framework's own tree; a host that ran an older
    # kennel still has them. They are this repo's litter rather than somebody
    # else's work, so they must never block a checkout -- `setup` item 8 deletes
    # them instead. Derived from what this repo ships now, under the names it
    # used to ship them as.
    while read -r pth; do [ -n "$pth" ] && expected+=("$pth"); done \
        < <(retired_kennel_copies)
    # IFS= is load-bearing. Porcelain writes two status columns then a space:
    # a MODIFIED file is " M path" and a plain `read` would eat that leading
    # space, shifting every tracked path by one character -- which silently turns
    # the three patched files into "changes this driver did not make".
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        pth="${line:3}"
        # The operator's own config and the backup §3 tells them to take.
        case "$pth" in test/test.config.yml*) continue ;; esac
        known=0
        for f in "${expected[@]}"; do [ "$f" = "$pth" ] && { known=1; break; }; done
        [ "$known" = 1 ] || echo "$pth"
    done < <(git -C "$YURUNA_DIR" status --porcelain 2>/dev/null)
}

# The guestSequence list as it currently stands, one key per line.
config_guest_sequence() {   # $1 = path to test.config.yml
    awk '/^guestSequence:/ {inb=1; next} inb && /^- / {sub(/^- /, ""); print; next} inb {exit}' "$1"
}

# repositories.projectUrl as it currently stands, or empty. Read the same way
# guestSequence is -- by line, not by a YAML parser -- because this file carries
# the operator's comments and nothing here may reformat it.
config_project_url() {   # $1 = path to test.config.yml
    sed -n 's/^[[:space:]]*projectUrl:[[:space:]]*//p' "$1" 2>/dev/null \
        | head -1 | tr -d '"'"'" | sed 's/[[:space:]]*$//'
}

# This repository's clone URL, as an operator would write it into
# test.config.yml: the origin, without the .git suffix Yuruna's own examples
# omit. Falls back to the local path, which is what a checkout with no origin
# actually is.
kennel_origin_url() {
    local u
    u="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)" || u=""
    [ -n "$u" ] || { echo "file://$REPO_ROOT"; return 0; }
    echo "${u%.git}"
}

do_setup() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1

    banner "setup: the once-per-host prerequisites (demo/runbook.md §2)"
    mkdir -p "$OUT"

    # 1. The clone. Nothing below this can even be looked at without it, so it is
    #    the one item that stops the whole verb rather than counting a block.
    if [ -d "$YURUNA_DIR/.git" ]; then
        setup_item ok "yuruna clone" "$YURUNA_DIR"
    else
        setup_item needs "yuruna clone" "not at $YURUNA_DIR"
        setup_fix "The host installer clones it, installs KVM/libvirt/pwsh and adds you to the groups:" \
                  "  bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)" \
                  "Then LOG OUT AND BACK IN, and run this verb again." \
                  "Clone somewhere else? Set YURUNA_DIR."
        return 2
    fi

    # 2. Group membership. A script cannot give itself groups it did not start
    #    with -- the session's credentials were fixed at login -- so this is the
    #    canonical `needs you`, and worth distinguishing from "never added".
    # `id -nG` with no argument reports THIS PROCESS's groups -- what the session
    # actually has. `id -nG <user>` queries the group database -- what the user
    # has been granted. The two differing is precisely the "added, but you have
    # not logged back in" case, and it is worth telling apart from "never added"
    # because the fix is completely different.
    local g me session_groups db_groups missing_groups="" stale_groups=""
    me="$(id -un)"
    session_groups=" $(id -nG 2>/dev/null) "
    db_groups=" $(id -nG "$me" 2>/dev/null) "
    for g in libvirt kvm; do
        case "$session_groups" in *" $g "*) continue ;; esac
        case "$db_groups" in
            *" $g "*) stale_groups="$stale_groups $g" ;;
            *)        missing_groups="$missing_groups $g" ;;
        esac
    done
    if [ -z "$missing_groups$stale_groups" ]; then
        setup_item ok "groups" "libvirt kvm"
    elif [ -n "$stale_groups" ] && [ -z "$missing_groups" ]; then
        setup_item needs "groups" "you are in$stale_groups, but this session predates that"
        setup_fix "Log out and back in (or: newgrp libvirt), then run this verb again."
    else
        setup_item needs "groups" "not a member of:$missing_groups$stale_groups"
        setup_fix "sudo usermod -aG libvirt,kvm $me    # then log out and back in" \
                  "The host installer does this for you (vm/host-baseline.md §2)."
    fi

    # 3. The release. Kennel is validated against exactly one Yuruna tag; a clone
    #    at some other revision is the cause of the 'matches neither state'
    #    patch verdict below, so it is settled first.
    local head want unexpected
    want="$(git -C "$YURUNA_DIR" rev-parse "$YURUNA_TAG^{commit}" 2>/dev/null)"
    if [ -z "$want" ]; then
        git -C "$YURUNA_DIR" fetch --tags --quiet 2>/dev/null
        want="$(git -C "$YURUNA_DIR" rev-parse "$YURUNA_TAG^{commit}" 2>/dev/null)"
    fi
    head="$(git -C "$YURUNA_DIR" rev-parse HEAD 2>/dev/null)"
    if [ -z "$want" ]; then
        setup_item needs "yuruna tag" "tag $YURUNA_TAG not in the clone, even after fetch --tags"
        setup_fix "git -C $YURUNA_DIR fetch --tags     # needs network" \
                  "Set YURUNA_TAG to validate against a different release."
    elif [ "$head" = "$want" ]; then
        setup_item ok "yuruna tag" "$YURUNA_TAG"
    else
        unexpected="$(yuruna_unexpected_changes)"
        if [ -n "$unexpected" ]; then
            setup_item needs "yuruna tag" "at ${head:0:12}, not $YURUNA_TAG -- and the tree has changes to keep"
            setup_fix "Checking out would discard or conflict with work this driver did not make:"
            printf '%s\n' "$unexpected" | while read -r pth; do setup_fix "  $pth"; done
            setup_fix "Deal with those, then re-run. Nothing was changed."
        elif git -C "$YURUNA_DIR" checkout --quiet "$YURUNA_TAG" 2>/dev/null; then
            setup_item did "yuruna tag" "checked out $YURUNA_TAG"
        else
            setup_item needs "yuruna tag" "could not check out $YURUNA_TAG"
            setup_fix "git -C $YURUNA_DIR checkout $YURUNA_TAG"
        fi
    fi

    # 4. The three patches. `provision` refuses without them; here they are
    #    applied, because applying a patch the repo ships is this driver's own
    #    business and takes milliseconds.
    local ptc
    for ptc in "$REPO_ROOT"/vm/patches/*.patch; do
        case "$(patch_state "$ptc")" in
            applied) setup_item ok "patch" "$(basename "$ptc")" ;;
            missing)
                if git -C "$YURUNA_DIR" apply "$ptc" 2>/dev/null; then
                    setup_item did "patch" "applied $(basename "$ptc")"
                else
                    setup_item needs "patch" "$(basename "$ptc") would not apply"
                    setup_fix "git -C $YURUNA_DIR apply $ptc      # to see why"
                fi ;;
            *)
                setup_item needs "patch" "$(basename "$ptc") -- tree matches neither state"
                setup_fix "The clone is not at $YURUNA_TAG, or something edited the same lines." \
                          "See vm/host-baseline.md §6.4." ;;
        esac
    done

    # 5. test.config.yml. Created from the template and scoped when absent; only
    #    inspected when present, because it is the operator's file (gitignored
    #    upstream) and may carry settings this driver knows nothing about.
    local cfg="$YURUNA_DIR/test/test.config.yml" tmpl="$YURUNA_DIR/test/test.config.yml.template" seq
    if [ ! -f "$cfg" ]; then
        if [ ! -f "$tmpl" ]; then
            setup_item needs "test.config" "neither test.config.yml nor its template exists"
            setup_fix "Is $YURUNA_DIR really a Yuruna clone at $YURUNA_TAG?"
        else
            cp "$tmpl" "$cfg" && \
            awk -v g="$GUEST_KEY" '
                /^guestSequence:/ { print; print "- " g; inb=1; next }
                inb && /^- / { next }
                inb { inb=0 }
                { print }' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg" && \
            awk -v u="$(kennel_origin_url)" '
                /^ *projectUrl:/ { sub(/projectUrl:.*/, "projectUrl: " u) }
                { print }' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
            setup_item did "test.config" "created from the template, guestSequence scoped to $GUEST_KEY, projectUrl set to this repo"
        fi
    else
        seq="$(config_guest_sequence "$cfg" | tr '\n' ' ' | sed 's/ *$//')"
        if [ "$seq" = "$GUEST_KEY" ]; then
            setup_item ok "test.config" "guestSequence: $GUEST_KEY"
        else
            # Not fixed automatically: a wider list is a legitimate choice for a
            # host that validates more than kennel, and rewriting it would break
            # that operator's other work to save this one an edit.
            setup_item info "test.config" "guestSequence is '$seq'"
            setup_fix "Kennel validates only $GUEST_KEY; the others cost a full guest build each." \
                      "Scope it in $cfg (vm/host-baseline.md §3)."
        fi

        # 5a. projectUrl -- which repository a CYCLE clones and runs (#23). The
        #     driver's own verbs do not read it (they clone KENNEL_PROJECT_URL
        #     themselves and pass -NoProjectClone), so this is only inspected,
        #     never rewritten in a file that already exists: an operator who
        #     points it somewhere else has done so on purpose.
        local url want_url
        url="$(config_project_url "$cfg")"
        want_url="$(kennel_origin_url)"
        if [ "$url" = "$want_url" ]; then
            setup_item ok "projectUrl" "$url"
        elif [ "$url" = "file://$REPO_ROOT" ]; then
            setup_item info "projectUrl" "$url  (this checkout -- a cycle runs the branch you are on)"
        else
            setup_item needs "projectUrl" "is '${url:-unset}', not this repository"
            setup_fix "A Yuruna cycle clones that URL and runs ITS test/ -- so today a cycle" \
                      "would not run Kennel at all. Set in $cfg:" \
                      "  repositories:" \
                      "    projectUrl: $want_url            # what is pushed" \
                      "    #projectUrl: file://$REPO_ROOT   # or the branch you are on" \
                      "See test/README.md §2."
        fi
    fi

    # 6. Unattended-run prep. Guarded on the capture file rather than run every
    #    time: Enable-TestAutomation records the host's PRIOR settings so its
    #    sibling can restore them, and a second run against an already-modified
    #    host would capture the automation's own values as "the operator's".
    #    (Save-HostAutomationState refuses to overwrite for the same reason -- the
    #    guard here is so the rest of the script does not run at all.)
    local capture="$YURUNA_DIR/test/status/runtime/host.pre-automation.json"
    if [ -f "$capture" ]; then
        setup_item ok "automation" "host settings already captured"
    else
        # stdin from /dev/null on purpose. Enable-TestAutomation offers to
        # apt-get any missing host packages, but only when it believes a human is
        # there; redirected input makes it print the install line instead of
        # blocking. `setup` must never hang waiting for an answer nobody is
        # giving -- the missing packages, if any, are the installer's job (§2).
        if (cd "$YURUNA_DIR" && pwsh -NoProfile host/ubuntu.kvm/Enable-TestAutomation.ps1) \
             < /dev/null > "$OUT/.setup-automation.log" 2>&1 || [ -f "$capture" ]; then
            setup_item did "automation" "Enable-TestAutomation.ps1 (display sleep off; reverse with Disable-TestAutomation.ps1)"
        else
            setup_item needs "automation" "Enable-TestAutomation.ps1 failed"
            setup_fix "cd $YURUNA_DIR && pwsh host/ubuntu.kvm/Enable-TestAutomation.ps1" \
                      "Log: $OUT/.setup-automation.log"
        fi
    fi

    # 7. The guest ISO -- ~3.2 GB and ~9 min, and not counted in provision's 35.
    if ls "$IMAGE_DIR"/*.iso >/dev/null 2>&1; then
        setup_item ok "guest ISO" "$(ls "$IMAGE_DIR"/*.iso | head -1)"
    else
        setup_item info "guest ISO" "absent from $IMAGE_DIR (~3.2 GB, ~9 min to fetch)"
        local reply=y
        if [ "$yes" != 1 ]; then
            reply=""
            read -r -p "[kennel-demo] fetch it now? [y/N] " reply || true
        fi
        case "$reply" in
            y|Y|yes)
                if (cd "$YURUNA_DIR/host/ubuntu.kvm/guest.ubuntu.server.24" && pwsh ./Get-Image.ps1); then
                    setup_item did "guest ISO" "fetched into $IMAGE_DIR"
                else
                    setup_item needs "guest ISO" "Get-Image.ps1 failed"
                    setup_fix "cd $YURUNA_DIR/host/ubuntu.kvm/guest.ubuntu.server.24 && pwsh ./Get-Image.ps1"
                fi ;;
            *)
                setup_item needs "guest ISO" "skipped -- provision cannot run without it"
                setup_fix "cd $YURUNA_DIR/host/ubuntu.kvm/guest.ubuntu.server.24 && pwsh ./Get-Image.ps1" ;;
        esac
    fi

    # 8. The project clone (#23). `provision`, `reset` and the harness verbs do
    #    this too, on every run -- omitting it is dry-run finding F3, a failure
    #    twenty minutes in -- so this is a convenience, not the contract.
    #
    #    It also SWEEPS the retired copies an older kennel left inside the
    #    framework's own tree. That is not tidiness: Test-Config parses every
    #    sequence under test/sequences/ and scans it for logical usernames, so a
    #    stale copy there is a second, older definition of a sequence that has
    #    moved into the project -- and the project's copy is the one that runs.
    local retired n=0 pth
    retired="$(retired_kennel_copies)"
    if [ -n "$retired" ]; then
        while IFS= read -r pth; do
            [ -n "$pth" ] || continue
            rm -f "$YURUNA_DIR/$pth" && n=$((n + 1))
        done <<< "$retired"
        setup_item did "retired copies" "removed $n pre-#23 file(s) from the framework tree"
        setup_fix "They were copies of this repo's sequences and guest scripts; the project" \
                  "clone below is where Yuruna reads them from now (test/README.md §1)."
    fi
    # Reported as `ok` when the clone is already this checkout's HEAD, so a
    # second `setup` on a ready host is genuinely all-`ok` rather than reporting
    # work it did not do. The clone itself is still unconditional -- see
    # install_kennel_project.
    local had_clone=0 old_head=""
    if [ -d "$YURUNA_DIR/project/.git" ]; then
        had_clone=1
        old_head="$(git -C "$YURUNA_DIR/project" rev-parse HEAD 2>/dev/null)"
    fi
    if ! install_kennel_project >/dev/null 2>&1; then
        setup_item needs "project clone" "could not clone $PROJECT_URL into $YURUNA_DIR/project"
        setup_fix "A private repo needs a non-interactive credential here:  gh auth login" \
                  "See test/README.md §4 for the credential, §2 for the URL."
    elif [ "$had_clone" = 1 ] && [ "$old_head" = "$(git -C "$YURUNA_DIR/project" rev-parse HEAD 2>/dev/null)" ]; then
        setup_item ok "project clone" "$YURUNA_DIR/project already at $(git -C "$YURUNA_DIR/project" rev-parse --short HEAD)"
    else
        setup_item did "project clone" "cloned $PROJECT_URL at $(git -C "$YURUNA_DIR/project" rev-parse --short HEAD)"
    fi

    # 9. The gate. Last, because the items above are what it would otherwise
    #    report as findings, and reading it first teaches the operator nothing.
    banner "gate: Test-Config (read the findings, not the PASS/WARN totals -- provisioning.md §4.3)"
    virsh list --all > /dev/null 2>&1    # wake socket-activated libvirtd (§6.2)
    if (cd "$YURUNA_DIR" && pwsh test/Test-Config.ps1 -SkipSend); then
        setup_item ok "config gate" "0 FAIL"
    else
        setup_item needs "config gate" "Test-Config.ps1 reported FAIL findings (above)"
        setup_fix "Fix the FAIL findings; WARNs are advisory." \
                  "A host clock WARN is one of them -- advisory here, but fix it before an" \
                  "unattended cycle:  sudo chronyc makestep   (vm/provisioning.md §6a.1)"
    fi

    # 10. Informational only: chrome is the scripted compose's hands. `run` and
    #     the by-hand console path do not need it.
    if command -v google-chrome >/dev/null 2>&1; then
        setup_item ok "google-chrome" "present (needed only by 'compose')"
    else
        setup_item info "google-chrome" "absent -- 'compose' needs it; 'console' + 'run' do not"
    fi

    banner "setup"
    if [ "$SETUP_BLOCKED" -gt 0 ]; then
        say "$SETUP_BLOCKED item(s) need you. Fix them and run '$0 setup' again."
        return 2
    fi
    say "this host is ready. Next:  $0 provision   (~35 min, once per host)"
}

do_provision() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1
    need_yuruna

    # -- preflight: fail in seconds on the prerequisites that otherwise fail
    #    20+ minutes into the run (dry-run.md F3).
    banner "preflight"

    # The three Yuruna patches (host-baseline.md §6.4) must be in the clone.
    local p missing=0
    for p in "$REPO_ROOT"/vm/patches/*.patch; do
        case "$(patch_state "$p")" in
            applied) say "patch applied    $(basename "$p")" ;;
            missing)
                fail "Yuruna patch NOT applied: $(basename "$p")." \
                     "Apply it first:  git -C $YURUNA_DIR apply $p" \
                     "Or let the driver do it:  $0 setup" \
                     "See vm/host-baseline.md §6.4."
                missing=1 ;;
            *)
                fail "cannot tell whether $(basename "$p") is applied -- the Yuruna tree at" \
                     "$YURUNA_DIR matches neither state. Is it at tag $YURUNA_TAG? (host-baseline.md §2)"
                missing=1 ;;
        esac
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

    install_kennel_project || exit 2
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
    pwsh test/Invoke-TestSequence.ps1 -SequenceName "$SEQUENCE" -NoProjectClone || {
        fail "the sequence did not pass -- see the transcript above (expect 0 FAIL)."
        exit 1
    }
    say "provisioned in $(( (SECONDS-t0) / 60 ))m$(( (SECONDS-t0) % 60 ))s"
    banner "baseline"
    virsh snapshot-list "$SNAPSHOT_ID" 2>&1 | sed 's/^/[kennel-demo] /'
    say "the guest can now be returned to this state in seconds:  $0 reset"
}

# The work of `up`, without the closing `status`. Split out because need_guest
# calls it from inside another verb, where a full status dump in the middle of
# `run`'s transfer phase would be noise rather than information.
up_core() {
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
}

do_up() {
    up_core || exit $?
    echo
    do_status
}

do_halt() {
    local d state t0=$SECONDS
    d="$(pick_domain)" || exit 2
    say "domain           $d"
    state="$(virsh domstate "$d" 2>/dev/null)"
    say "state            $state"
    case "$state" in
        "shut off"|shutoff) say "already shut off"; return 0 ;;
    esac
    # An ACPI shutdown, not `virsh destroy`: the guest holds a built workspace
    # and a container, and pulling its power is how a qcow2 acquires the kind of
    # damage a baseline snapshot exists to undo. If the guest ignores it, say so
    # rather than escalating on the operator's behalf.
    say "asking it to shut down (ACPI)"
    virsh shutdown "$d" >/dev/null || { fail "virsh shutdown '$d' failed."; exit 2; }
    while [ $((SECONDS - t0)) -lt "$UP_TIMEOUT" ]; do
        state="$(virsh domstate "$d" 2>/dev/null)"
        [ "$state" = "shut off" ] && { say "shut off after $((SECONDS-t0))s"; return 0; }
        sleep 2
    done
    fail "'$d' was still '$state' after ${UP_TIMEOUT}s." \
         "Watch it:  virsh console $d        (leave with Ctrl+])" \
         "Force it (last resort, it is a power cut):  virsh destroy $d"
    exit 3
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
    guest_stage test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh
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
    install_kennel_project || exit 2
    cd "$YURUNA_DIR" || exit 2
    virsh list --all > /dev/null    # wake socket-activated libvirtd

    banner "reset: $SEQUENCE (warm path -- revert to '$SNAPSHOT_ID')"
    say "no Test-Config gate here: reset spends seconds, not the 35 minutes the gate"
    say "exists to protect. provision still gates."
    local t0=$SECONDS
    pwsh test/Invoke-TestSequence.ps1 -SequenceName "$SEQUENCE" -NoProjectClone || {
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

# --- REGION: the harness verbs (issues #24, #25)
# `mvp` runs the MVP sequence; `cycle` runs a whole Yuruna cycle. Both wrap a
# Yuruna entry point rather than reimplementing one, and both COLLECT: Yuruna
# keeps a step's output only when the step fails, and has no action that copies
# a file back to the host, so a green run's evidence has to be fetched.
MVP_SEQUENCE="workload.guest.ubuntu.server.24.kennel.mvp.ssh"
HARNESS_EVIDENCE="${KENNEL_HARNESS_EVIDENCE:-$REPO_ROOT/test/evidence}"

# Everything a run leaves behind, into $HARNESS_EVIDENCE/<label>-<stamp>/:
# the guest's ~/kennel-mvp (the verify report and the three process logs the
# MVP sequence assembled there), the newest Yuruna cycle folder (HTML
# transcript, cycle.events.ndjson, manifest.json), status.json and the newest
# per-step perf rows. Best-effort by design -- a failed collection must not
# turn a green run red, and on a RED run it is the more useful half.
#
# No .yml is ever copied: this lands under test/, and every directory named
# `test` in a project is a sequence directory -- a stray sequence file there
# would be discovered as one.
harness_collect() {   # $1 = label
    local label="$1" dest cyc
    dest="$HARNESS_EVIDENCE/$label-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$dest" || return 0
    if guest_reachable; then
        scp "${SSH_OPTS[@]}" -qr "$TARGET:kennel-mvp" "$dest/" 2>/dev/null \
            && say "collected        the guest's run record -> $dest/kennel-mvp/"
    else
        warn "the guest is not reachable -- its run record was left on it."
    fi
    cyc="$(ls -dt "$YURUNA_DIR"/test/status/log/[0-9]*/ 2>/dev/null | head -1)"
    if [ -n "$cyc" ]; then
        mkdir -p "$dest/cycle"
        cp "$cyc"/*.html "$cyc"/*.ndjson "$cyc"/manifest.json "$dest/cycle/" 2>/dev/null
        say "collected        $(basename "$cyc") -> $dest/cycle/"
    fi
    cp "$YURUNA_DIR/test/status/runtime/status.json" "$dest/status.json" 2>/dev/null
    cp "$(ls -t "$YURUNA_DIR"/test/status/perf/cycles/*.jsonl 2>/dev/null | head -1)" \
       "$dest/perf.jsonl" 2>/dev/null
    say "evidence         $dest"
    return 0
}

# The MVP sequence as a verb (#24). Warm on a host that holds the baseline --
# revert, stage, apply, launch, assert, record, stop, about four minutes -- and
# the whole cold chain on a host that does not, which is `provision` plus this.
do_mvp() {
    need_yuruna
    install_kennel_project || exit 2
    cd "$YURUNA_DIR" || exit 2
    virsh list --all > /dev/null    # wake socket-activated libvirtd

    # Which path this will take, asked of the host rather than assumed -- the
    # difference is four minutes against forty, and an operator should know
    # which one they just started.
    if virsh snapshot-list "$SNAPSHOT_ID" 2>/dev/null | grep -q "$SNAPSHOT_ID"; then
        banner "mvp: $MVP_SEQUENCE (warm path -- the baseline is on this host)"
        say "revert -> stage the fixture -> apply -> launch -> assert walking (~4 min)"
    else
        banner "mvp: $MVP_SEQUENCE (COLD path -- no '$SNAPSHOT_ID' snapshot on this host)"
        say "the whole chain runs first: start -> sizing -> stack -> baseline -> reset (~40 min)."
        say "To build the appliance deliberately instead:  $0 provision"
    fi
    local t0=$SECONDS rc=0
    pwsh test/Invoke-TestSequence.ps1 -SequenceName "$MVP_SEQUENCE" -NoProjectClone || rc=1
    say "mvp in $(( (SECONDS-t0) / 60 ))m$(( (SECONDS-t0) % 60 ))s"

    # Collected on BOTH paths, because a red run is the one whose logs matter.
    GUEST_IP="${KENNEL_GUEST_IP:-}"      # the revert re-DHCPs; re-discover
    harness_collect mvp
    [ "$rc" = 0 ] || {
        fail "the MVP sequence did not pass -- see the transcript above (expect 0 FAIL)." \
             "The failing step's description says which class it is: ASSERT_FAILED is a red" \
             "stack, INFRASTRUCTURE is the recipe not being able to look (stack/verify.md §1)." \
             "'requiresSnapshot: snapshot ... not on host' means there is no baseline yet."
        exit 1
    }
    say "the stack ran the fixture and walked on it. The run stays applied;"
    say "return the guest to stock with:  $0 reset"
}

# --- REGION: the console as a verb (issue #54)
# `compose` serves the console for the length of one scripted run and takes it
# down again. Composing BY HAND needs the opposite: a server that outlives the
# command that started it, so the operator can sit in the browser and then run
# other verbs in the same terminal. Hence a pidfile rather than a job.
CONSOLE_PIDFILE="$OUT/.console.pid"
CONSOLE_LOG="$OUT/.console.log"

console_alive() { curl -sf -o /dev/null "$CONSOLE_URL"; }

do_console() {
    local open=1
    case "${1:-}" in
        stop)      console_stop; return $? ;;
        --no-open) open=0 ;;
        "")        ;;
        *) fail "console takes no argument, or --no-open, or stop."; exit 2 ;;
    esac
    mkdir -p "$OUT"
    if console_alive; then
        say "already served on port $PORT"
    else
        # serve.py is `python3 -m http.server --directory kennel_console` plus a
        # POST endpoint, so the console it serves can write the run folder into
        # OUT itself -- no Downloads hop, no unzip (kennel_console/send.md). It
        # is passed OUT explicitly rather than through the environment so the
        # log line says where the runs land even when the operator set
        # KENNEL_DEMO_OUT in another shell.
        nohup python3 "$REPO_ROOT/kennel_console/serve.py" --port "$PORT" --out "$OUT" \
            >"$CONSOLE_LOG" 2>&1 &
        echo $! > "$CONSOLE_PIDFILE"
        local t0=$SECONDS
        until console_alive; do
            [ $((SECONDS - t0)) -lt 15 ] || {
                fail "the console did not answer on port $PORT within 15s." \
                     "Server log: $CONSOLE_LOG" \
                     "Is something else on that port? Set KENNEL_CONSOLE_PORT."
                console_stop >/dev/null 2>&1
                exit 2
            }
            sleep 0.25
        done
        say "serving          kennel_console/ on port $PORT (pid $(cat "$CONSOLE_PIDFILE"))"
    fi
    say "console          $CONSOLE_URL"
    if [ "$open" = 1 ] && command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$CONSOLE_URL" >/dev/null 2>&1 &
    fi
    echo
    say "compose the run in the browser, then either:"
    say "  * click 'send to $(basename "$OUT")' -- it writes the run folder straight into $OUT"
    say "  * or click 'generate run' and let the archive land in $DOWNLOADS"
    say "then, in this terminal:"
    say "    $0 run"
    say "it finds whichever of the two is newer by itself -- no unzip, no path."
    say "stop the server with:  $0 console stop"
}

console_stop() {
    if [ -f "$CONSOLE_PIDFILE" ]; then
        local pid; pid="$(cat "$CONSOLE_PIDFILE")"
        if kill "$pid" 2>/dev/null; then
            say "stopped the console server (pid $pid)"
        else
            say "no server running at pid $pid (already gone)"
        fi
        rm -f "$CONSOLE_PIDFILE"
    elif console_alive; then
        # Someone else's http.server, or one from a previous shell. Killing a
        # process this script did not start is not its call to make.
        warn "port $PORT answers, but $CONSOLE_PIDFILE does not exist -- this driver did not"
        warn "start that server, so it will not stop it. Find it with:  lsof -i :$PORT"
        return 2
    else
        say "no console server running"
    fi
}

SERVER_PID=""
# A named preset (#72) is the PAGE's data, not this script's. `KENNEL_PRESET`
# travels through p22-console-demo.sh to the console, which picks the option
# whose name -- or slug -- matches and loads a whole composition it ships; the
# panes are then read back and printed as PRESET_<KEY>= lines. Refusing a wrong
# name is the page's job too, because the page is the only thing that knows what
# presets there are: a table here could disagree with it silently, and did not
# have to, so there is none. The four are Stock Go2 walk, Solver benchmark A
# (HPIPM), Solver benchmark B (OSQP) and Stress -- each a measured row of
# stack/stress.md §2, recorded in kennel_console/composer-scope.md §7.

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
    # A preset fills in only what the operator did not choose: an EXPLICIT
    # KENNEL_SOLVER or KENNEL_RATE still wins, a defaulted one yields to the
    # preset by being passed through EMPTY -- which p22 reads as "touch no
    # control", the meaning every other knob there already has.
    local solver="$SOLVER" rate="$RATE"
    if [ -n "$PRESET" ]; then
        [ "$SOLVER_IS_DEFAULT" = 1 ] && solver=""
        [ "$RATE_IS_DEFAULT" = 1 ] && rate=""
        say "preset           $PRESET -- picked in the console by text; the composition is the page's (composer-scope.md §7)"
    fi
    KENNEL_CONSOLE_URL="$CONSOLE_URL" KENNEL_SOLVER="$solver" KENNEL_RATE="$rate" \
        KENNEL_PRESET="$PRESET" \
        KENNEL_MAP="${KENNEL_MAP:-}" \
        KENNEL_HPIPM_MODE="${KENNEL_HPIPM_MODE:-}" KENNEL_CONDENSED="${KENNEL_CONDENSED:-}" \
        KENNEL_DISTURBANCES="${KENNEL_DISTURBANCES:-0}" \
        "$HERE/p22-console-demo.sh" "$OUT"
    local rc=$?
    [ -n "$SERVER_PID" ] && { kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
    [ $rc -eq 0 ] || {
        fail "compose failed (p22-console-demo.sh exited $rc)." \
             "It needs google-chrome; to compose by hand instead, see demo/runbook.md §3.2." \
             "A refused preset name is exit 1 and the page lists the four it ships."
        return $rc
    }
    say "run folder       $(latest_run)"
}

# Set by do_transfer to the folder it actually applied, so do_verify can ask
# THAT run what solver it was composed with rather than assuming the default.
APPLIED_RUN=""

do_transfer() {
    local target="${1:-}" why="given on the command line" picked folder
    if [ -z "$target" ]; then
        picked="$(pick_newest_run)" || {
            fail "no run given, and none found in $OUT or $DOWNLOADS." \
                 "Compose one in the console:  $0 console      (then click Generate run)" \
                 "Or have the driver compose it:  $0 compose" \
                 "Different download directory? Set KENNEL_DOWNLOADS."
            exit 2
        }
        target="${picked%%$'\t'*}"
        why="${picked#*$'\t'}"
    fi
    [ -e "$target" ] || {
        fail "no such run: '$target'."
        exit 2
    }
    say "run              $target"
    say "                 ($why)"
    if [ -f "$target" ]; then
        case "$target" in
            *.zip) folder="$(unpack_run_zip "$target")" || exit $?
                   say "unpacked to      $folder" ;;
            *) fail "'$target' is a file but not a .zip." \
                    "Pass the run-<stamp>/ folder, or the run-<stamp>.zip the console exported."
               exit 2 ;;
        esac
    else
        folder="$target"
    fi
    "$REPO_ROOT/stack/transfer/kennel-transfer.sh" apply "$folder" || return $?
    APPLIED_RUN="$folder"
}

do_launch() {
    need_guest
    # Stage the stopper INTO the container before launching. The launcher opens
    # with "stopping anything already running", but that line is
    # `[ -x /root/k13-stop.sh ] && /root/k13-stop.sh` -- and until something has
    # put the script there, it is a silent no-op. On a guest that has never run
    # `down` (a fresh provision, or anything after a `reset`) a relaunch
    # therefore stacks a second simulator on top of the first: the sim clock
    # carries on from the old session, the robot is still lying where the
    # previous controller dropped it, and the new controller never reaches
    # "Starting controller" for a stream of early-contact faults.
    #
    # `down` already does exactly this copy, which is why relaunching after a
    # `down` always looked fine. Doing it here makes the launcher's own stated
    # behaviour true on every launch instead of only after one particular verb.
    guest_stage stack/known-good/tools/k13-stop.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "sudo docker cp /tmp/k13-stop.sh $CONTAINER:/root/k13-stop.sh" >/dev/null || {
        fail "could not stage k13-stop.sh into container '$CONTAINER'."; return 2; }
    guest_stage stack/composed-run/tools/p21-launch-from-commands.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/p21-launch-from-commands.sh"
}

do_verify() {
    need_guest
    # The expected solver comes from the run that was just applied, and only
    # falls back to the knob when this verb was invoked on its own (nothing was
    # applied in this process, so the only thing left to believe is the default).
    local expect="$SOLVER" src="\$KENNEL_SOLVER"
    if [ -n "$APPLIED_RUN" ]; then
        local from_run
        if from_run="$(solver_of_run "$APPLIED_RUN")"; then
            expect="$from_run"; src="$(basename "$APPLIED_RUN")/run.json"
        else
            warn "no mpc_solver in $APPLIED_RUN/run.json -- expecting '$SOLVER' from the knob."
        fi
    fi
    say "expect solver    $expect  (from $src)"
    # Check 1 asserts EXACTLY the six healthy-session nodes. A teleop session adds
    # four more -- three rosbridge, and since #67 the target watchdog -- so with
    # one up the check is told to tolerate them; otherwise a correct stack
    # reports `extra:` (verify.md check 1).
    local expect_bridge=0
    if bridge_up; then
        expect_bridge=1
        say "bridge is up     check 1 will tolerate the four nodes a teleop session adds"
        warn "checks 6-9 command their own trot: DISCONNECT the console first, or the"
        warn "two publishers fight and the walking checks measure the argument."
    fi
    local folder run_name=""
    folder="$(applied_run_dir)" && run_name="$(basename "$folder")"
    # Same two-step resolution as the solver, for the same reason (runs.md §2):
    # the run applied in THIS process if there was one, else the guest's own
    # marker. A run composed with disturbances on launches a seventh node, and
    # check 1 has to be told so or a healthy stack reports `extra:` and fails.
    local expect_disturber=0 dsrc=""
    if [ -n "$APPLIED_RUN" ]; then
        expect_disturber="$(disturbances_of_run "$APPLIED_RUN")"
        dsrc="$(basename "$APPLIED_RUN")/run.json"
    elif [ -n "$folder" ]; then
        expect_disturber="$(disturbances_of_run "$folder")"
        dsrc="$run_name/run.json"
    fi
    if [ "$expect_disturber" = 1 ]; then
        say "expect disturber 1  (from ${dsrc:-the applied run}) -- check 1 will tolerate /disturbance_node"
    fi
    guest_stage stack/verify/kennel-verify.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "KENNEL_EXPECT_BRIDGE=$expect_bridge KENNEL_EXPECT_DISTURBER=$expect_disturber \
         KENNEL_RUN='$run_name' KENNEL_PIN='$(pin_sha)' \
         /tmp/kennel-verify.sh --expect-solver '$expect' --controller-log /tmp/p21-ctrl.log"
    local rc=$?
    # The report belongs WITH the run it is of (#64). kennel-verify.sh has always
    # written a full report to /tmp/kennel-verify on the guest and this driver has
    # always read only the exit code, so the Runs view had nothing real to show
    # and listed five invented runs instead.
    #
    # Exit 2 is "could not even look": there is no verdict to file, and an old
    # verify.json left in place would be a lie about a run that never ran. Say so
    # instead.
    if [ "$rc" = 2 ]; then
        warn "verify could not look (exit 2) -- no report filed."
    elif [ -z "$folder" ]; then
        warn "no applied run to file the report against -- it stays on the guest at"
        warn "  /tmp/kennel-verify/report.json  (transfer a run first, or check ~/kennel-staging/current-run)"
    else
        local verdict=""
        if scp "${SSH_OPTS[@]}" -q "$TARGET:/tmp/kennel-verify/report.json" "$folder/verify.json" 2>/dev/null; then
            scp "${SSH_OPTS[@]}" -q "$TARGET:/tmp/kennel-verify/report.txt" "$folder/verify.txt" 2>/dev/null
            verdict="$(sed -n 's/.*"verdict"[[:space:]]*:[[:space:]]*"\([a-z-]*\)".*/\1/p' "$folder/verify.json" | head -1)"
            say "verify report    $folder/verify.json (verdict ${verdict:-unknown})"
        else
            warn "the guest wrote no report.json -- is stack/verify/kennel-verify.sh current there?"
        fi
    fi
    return $rc
}

do_walk() {
    need_guest
    guest_stage stack/composed-run/tools/p21-trot-hold.sh
    if [ "${1:-start}" = "stop" ]; then
        ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/p21-trot-hold.sh stop"
        return $?
    fi
    # Only on the way IN. Two publishers on /quad_control_target do not merge:
    # the controller reads the latest every cycle, so a held trot and a connected
    # browser alternate and the robot jitters between two speeds. Proceeding is
    # the operator's call -- they may have closed the page -- but it must not be
    # a surprise. (`walk stop` above needs no such warning: it is the fix.)
    if bridge_up; then
        warn "the rosbridge is running: if a console is connected and driving, it is"
        warn "publishing $TARGET_TOPIC too and the two will fight."
        warn "Disconnect it in the browser, or:  $0 teleop stop"
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
    say "or drive it yourself:      $0 teleop"
}

do_teleop() {
    if [ "${1:-start}" = "stop" ]; then
        need_guest
        # ORDER MATTERS. Zero the target and return to STAND first, while the
        # bridge is still up and the browser can still be publishing; only then
        # take the bridge away. The other order leaves the controller holding
        # the last target it got with nothing left to change it -- the robot
        # walks away and only `walk stop` or a relaunch stops it.
        guest_stage stack/composed-run/tools/p21-trot-hold.sh
        ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/p21-trot-hold.sh stop"
        guest_stage stack/bridge/kennel-bridge.sh
        ssh "${SSH_OPTS[@]}" "$TARGET" "KENNEL_BRIDGE_PORT=$BRIDGE_PORT /tmp/kennel-bridge.sh stop"
        local rc=$?
        rm -f "$BRIDGE_FILE" "$MESHCAT_FILE"
        say "teleop stopped. The console will report the bridge as unreachable."
        return $rc
    fi
    [ "${1:-start}" = "start" ] || { fail "teleop takes no argument, or stop."; exit 2; }

    need_guest
    # A held trot is the one publisher this driver knows it started, and it
    # fights the browser for /quad_control_target: the controller takes whichever
    # message arrived last, so the robot alternates between two speeds. `run`
    # ends with one held, which is exactly the state an operator reaches this
    # verb from. Stopping it also puts the gait back to STAND, so the first gait
    # the operator picks in the console is a deliberate one.
    guest_stage stack/composed-run/tools/p21-trot-hold.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" "/tmp/p21-trot-hold.sh stop" >/dev/null 2>&1 \
        && say "stopped the held trot (the console is the publisher now)"

    guest_stage stack/bridge/kennel-bridge.sh
    # The bridge script starts the watchdog and observes the stack, and both of
    # those live in tools it copies into the container -- so they have to be on
    # the guest first. Staged here rather than assumed present.
    guest_stage stack/bridge/tools/k13-target-watchdog.py
    guest_stage stack/bridge/tools/k13-target-monitor.py
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "KENNEL_BRIDGE_PORT=$BRIDGE_PORT KENNEL_WATCHDOG=$WATCHDOG \
         KENNEL_WATCHDOG_STALE=$WATCHDOG_STALE /tmp/kennel-bridge.sh start" || {
        local rc=$?
        fail "the bridge did not start on the guest (exit $rc)."
        [ "$rc" = 2 ] && say "The stack has to be running first:  $0 launch"
        return $rc
    }

    local ws
    ws="$("$REPO_ROOT/vm/test/verify-bridge-host.sh" --quiet)" || {
        local rc=$?
        "$REPO_ROOT/vm/test/verify-bridge-host.sh"    # re-run loud for the diagnosis
        fail "the bridge is up in the guest but not reachable from this host (exit $rc)."
        return $rc
    }
    mkdir -p "$OUT"
    printf '%s\n' "$ws" > "$BRIDGE_FILE"

    # Best effort: the 3D pane is the other half of driving, and the console can
    # only offer it if something tells it the URL. Never fatal -- teleop works
    # with the Meshcat tab the operator already has open.
    local mc
    if mc="$("$REPO_ROOT/vm/test/verify-meshcat-host.sh" --quiet 2>/dev/null)"; then
        printf '%s\n' "$mc" > "$MESHCAT_FILE"
    else
        rm -f "$MESHCAT_FILE"
        mc=""
    fi

    console_alive || do_console --no-open >/dev/null

    echo
    say "bridge           $ws"
    [ -n "$mc" ] && say "meshcat          $mc"
    say "console          $CONSOLE_URL"
    echo
    say "In the console: Dashboard -> Interventions -> connect, pick a gait, push the stick."
    say "The velocity target is published while the page is connected; releasing the"
    say "stick ramps it back to zero. STAND and E-STOP are beside the gait picker."
    if [ "$WATCHDOG" != 0 ]; then
        say "A guest-side watchdog is running: if this page dies without warning, the"
        say "robot's target is zeroed ${WATCHDOG_STALE}s later. It is the only thing that"
        say "catches a killed tab -- JavaScript cannot (kennel_console/teleop.md §5)."
    else
        say "KENNEL_WATCHDOG=0: nothing will stop the robot if this page dies. Use"
        say "$0 teleop stop."
    fi
    say "When you are done:  $0 teleop stop"
}

# --- REGION: scenarios (#69, #71)
# A scenario is a TEST: it drives the console against the running stack and
# asserts plan/scenarios.md's numbered steps from the guest and from the DOM.
# This verb adds nothing but dispatch -- every knob reaches the scenario through
# the environment, as every other verb's do.
do_scenario() {
    local name="${1:-}"
    local -a available=()
    local f
    for f in "$HERE"/scenario-*.sh; do
        [ -f "$f" ] || continue
        case "$f" in *scenario-lib.sh) continue ;; esac
        available+=("$(basename "$f" .sh | sed 's/^scenario-//')")
    done
    if [ -z "$name" ]; then
        say "scenarios: ${available[*]-none}"
        say "  $0 scenario <name>        (what each asserts: demo/scenarios.md)"
        return 0
    fi
    local script="$HERE/scenario-$name.sh"
    [ -x "$script" ] || {
        fail "no scenario '$name'." "Available: ${available[*]-none}"              "What each one asserts: demo/scenarios.md"
        exit 2
    }
    shift
    exec "$script" "$@"
}

do_down() {
    need_guest
    ssh "${SSH_OPTS[@]}" "$TARGET" "[ -x /tmp/p21-trot-hold.sh ] && /tmp/p21-trot-hold.sh stop" \
        >/dev/null 2>&1
    guest_stage stack/known-good/tools/k13-stop.sh
    ssh "${SSH_OPTS[@]}" "$TARGET" \
        "sudo docker cp /tmp/k13-stop.sh $CONTAINER:/root/k13-stop.sh && \
         sudo docker exec $CONTAINER bash /root/k13-stop.sh"
    # k13-stop.sh reaps the bridge too (its pidfile is /tmp/k13-bridge.pid and
    # its two children are in the sweep), so all that is left here is the URL
    # the console would otherwise still be offered.
    rm -f "$BRIDGE_FILE" "$MESHCAT_FILE"
    say "stack stopped in container '$CONTAINER'. The container itself is left running."
}

# Cheap and host-side: the pidfile lives in the container, but the socket is the
# guest's (--network host), so a listener check answers the question without an
# SSH round trip per caller.
bridge_up() { "$REPO_ROOT/vm/test/verify-bridge-host.sh" --quiet >/dev/null 2>&1; }

do_status() {
    "$REPO_ROOT/stack/transfer/kennel-transfer.sh" status
    echo
    # Only when a serve.py is answering: the run folders it knows about are the
    # ones `run` would pick between, and reading them from the server rather
    # than from the filesystem is what proves the two agree about OUT. Gated on
    # /api/health and not merely on the port answering -- a plain http.server
    # would 404 here, and reporting that as "no runs" would be a lie about the
    # directory rather than a fact about the server.
    if curl -sf "$CONSOLE_ORIGIN/api/health" 2>/dev/null | grep -q '"kennel"'; then
        local runs
        runs="$(curl -sf "$CONSOLE_ORIGIN/api/runs" 2>/dev/null \
                | sed -n 's/^[[:space:]]*"run"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        if [ -n "$runs" ]; then
            say "console runs in $OUT (newest first):"
            printf '%s\n' "$runs" | head -5 | sed 's/^/[kennel-demo]   /'
        else
            say "console served, no run folders in $OUT yet"
        fi
        echo
    fi
    local url
    if url="$("$REPO_ROOT/vm/test/verify-meshcat-host.sh" --quiet 2>/dev/null)"; then
        say "Meshcat reachable:  $url"
    else
        say "Meshcat not reachable (simulator not running, or guest down)."
    fi
    local ws
    if ws="$("$REPO_ROOT/vm/test/verify-bridge-host.sh" --quiet 2>/dev/null)"; then
        say "bridge reachable:   $ws"
        # Only when there is a bridge to ask about: the watchdog lives beside it.
        guest_stage stack/bridge/kennel-bridge.sh >/dev/null 2>&1 \
            && ssh "${SSH_OPTS[@]}" "$TARGET" \
                 "KENNEL_WATCHDOG=$WATCHDOG /tmp/kennel-bridge.sh status" 2>/dev/null \
               | grep watchdog | sed 's/^\[kennel-bridge\] /[kennel-demo] /'
    else
        say "bridge not up (start it with:  $0 teleop)"
    fi
}

# Shared by `all` and `run`: banner, time, and stop at the first failure naming
# the verb to resume from. Timing every phase is not decoration -- the phase
# table in demo/runbook.md §3 is built from these numbers.
PHASE_MARKS=""
phase() {   # $1 = name, $2.. = command
    local name="$1" t0=$SECONDS; shift
    banner "$name"
    "$@" || { fail "phase '$name' failed -- fix it and re-run from that verb."; exit 1; }
    PHASE_MARKS="$PHASE_MARKS$name $(( SECONDS-t0 ))s\n"
}

phase_summary() {
    banner "done"
    printf "$PHASE_MARKS" | awk '{printf "[kennel-demo]   %-9s %s\n", $1, $2}'
}

do_all() {
    phase compose  do_compose
    phase transfer do_transfer
    phase launch   do_launch
    phase verify   do_verify
    phase walk     do_walk
    phase_summary
}

# `run` is `all`'s by-hand sibling: the composition came from an operator in the
# browser rather than from p22-console-demo.sh, so there is no compose phase and
# the run to apply has to be FOUND -- newest folder in OUT or newest archive in
# DOWNLOADS, whichever is newer. Everything downstream is the same five tools in
# the same order, including the guest phase, which is what makes `run` work on a
# host whose guest is merely powered off (need_guest brings it up).
do_run() {
    phase guest    need_guest
    phase transfer do_transfer "$@"
    phase launch   do_launch
    phase verify   do_verify
    phase walk     do_walk
    phase_summary
}

# --- REGION: dispatch
case "${1:-}" in
    setup)     shift; do_setup "$@" ;;
    provision) shift; do_provision "$@" ;;
    up)        shift; do_up ;;
    halt)      shift; do_halt ;;
    reset)     shift; do_reset ;;
    mvp)       shift; do_mvp ;;
    snapshot)  shift; do_snapshot "$@" ;;
    console)   shift; do_console "$@" ;;
    run)       shift; do_run "$@" ;;
    compose)   shift; do_compose "$@" ;;
    transfer)  shift; do_transfer "$@" ;;
    launch)    shift; do_launch ;;
    verify)    shift; do_verify ;;
    walk)      shift; do_walk "$@" ;;
    teleop)    shift; do_teleop "$@" ;;
    down)      shift; do_down ;;
    status)    shift; do_status ;;
    scenario)  shift; do_scenario "$@" ;;
    all)       shift; do_all ;;
    -h|--help|help) usage ;;
    *) fail "expected a verb: setup | provision | up | halt | reset | snapshot | console | run | all | compose | transfer | launch | verify | walk | teleop | down | status | scenario | mvp"
       usage >&2; exit 2 ;;
esac
