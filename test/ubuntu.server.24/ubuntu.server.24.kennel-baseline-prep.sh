#!/bin/bash
# Version: 2026.08.30
# Kennel -- issue #51: make this guest a clean BASELINE, ready to be frozen into
# a Yuruna disk snapshot.
#
# Runs on the GUEST (kennel-vm), over Yuruna's sshFetchAndExecute:
#   /usr/local/lib/yuruna/fetch-and-execute.sh project/test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh
# and equally over plain SSH, which is how `kennel-demo.sh snapshot` runs it.
#
# "Clean baseline" is a specific claim, and every clause of it is ASSERTED here
# rather than assumed, because a snapshot is the one artifact whose defects are
# invisible: a baseline taken over a composed run silently returns that composed
# run for the rest of the guest's life.
#
#   * nothing of the stack is running, and the container is stopped;
#   * no composed run is staged or applied -- the config paths carry the pin's
#     stock YAMLs, so `~/kennel-staging` is gone and the clone is clean;
#   * the clone sits at the pin and has no local modifications;
#   * the workspace is BUILT (a baseline without a build is worth nothing --
#     rebuilding it is most of the 33 minutes the snapshot exists to avoid);
#   * `~/.kennel-baseline` records what was frozen, so a later revert can prove
#     it got back what it expected.
#
# fetch-and-execute passes NO arguments to the fetched script, so every knob is
# an environment variable -- same contract as ubuntu.server.24.dfki-quad.sh.
#
# Idempotent: running it twice in a row is the same as running it once. The
# second run finds nothing to stop, no staging directory, and rewrites
# ~/.kennel-baseline with a fresh `created` stamp.
#
# `==== name ====` banners are the per-phase timing checkpoints fetch-and-execute
# captures, exactly as in the provisioning script.
#
# Exit codes (stack/verify.md section 1's convention):
#   0  the guest is a clean baseline; ~/.kennel-baseline written
#   1  an assertion failed -- the guest is NOT a baseline (message says which)
#   2  could not even look (no docker, no clone, no container)
#
# See vm/snapshot.md for what the snapshot is for and how it is taken.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# --- REGION: knobs
# The stack pin. As in ubuntu.server.24.dfki-quad.sh, this literal is a DERIVED
# COPY of stack/pin.lock's `commit:` -- fetch-and-execute drops this script into
# the guest alone, with no checkout of the kennel repo to read it from. The drift
# check is the "assert the baseline records the pin" step in
# test/workload.guest.ubuntu.server.24.kennel.baseline.ssh.yml, which
# re-states the SHA independently (vm/provisioning.md section 8).
DFKI_QUAD_COMMIT="${DFKI_QUAD_COMMIT:-dcf53c596339afd45b82f12c54b1e93e8273c2f4}"
DFKI_QUAD_DIR="${DFKI_QUAD_DIR:-$HOME/dfki-quad}"
CONTAINER_NAME="${KENNEL_CONTAINER:-dfki_quad}"
# Separate from CONTAINER_NAME even though they are the same string today: the
# image and the container really do share the name `dfki_quad`, which is the
# whole reason `docker inspect` needs --type container everywhere in this repo
# (vm/provisioning.md section 5a, defect 2). One variable for two things would
# make an override of either silently wrong.
IMAGE_NAME="${KENNEL_IMAGE:-dfki_quad}"
STAGING="${KENNEL_STAGING:-$HOME/kennel-staging}"
BASELINE_FILE="${KENNEL_BASELINE_FILE:-$HOME/.kennel-baseline}"
# Seconds `docker stop` gets before SIGKILL. Bounded on purpose: this script is
# the last thing that runs before the VM is powered off for the snapshot, so a
# container that will not stop must not hang the cycle.
STOP_TIMEOUT="${KENNEL_STOP_TIMEOUT:-30}"

BUILD_STAMP="$DFKI_QUAD_DIR/ws/.kennel-built-$DFKI_QUAD_COMMIT"

banner() { echo ""; echo -e "\e[1;36m==== $* ====\e[0m"; }
say()    { echo "$*"; }
fail()   { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

# --- REGION: preconditions
# Exit 2 territory: things that make the question unanswerable rather than
# answered "no".
command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1 || {
    fail "docker is not available on this guest." \
         "This script prepares a PROVISIONED guest; run the provisioning script first" \
         "(vm/provisioning.md), or set KENNEL_CONTAINER if the container is named differently."
    exit 2
}
[ -d "$DFKI_QUAD_DIR/.git" ] || {
    fail "no dfki-quad clone at $DFKI_QUAD_DIR." \
         "This guest was never provisioned; see vm/provisioning.md."
    exit 2
}
# --type container is not optional: the IMAGE is also called dfki_quad, so a bare
# `docker inspect` resolves to it, exits 0, and reports an empty status
# (vm/provisioning.md section 5a, defect 2).
cstate="$(sudo docker inspect --type container -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
[ -n "$cstate" ] || {
    fail "no container named '$CONTAINER_NAME' on this guest." \
         "A baseline without the container is not the appliance; provision it first."
    exit 2
}

# --- REGION: phase 1 -- stop everything the stack left running
banner "stop the stack"
if [ "$cstate" = running ]; then
    # The teardown pattern of stack/known-good/tools/k13-stop.sh, inlined: this
    # script arrives on the guest alone (fetch-and-execute copies no siblings),
    # so it cannot call that file, and /root/k13-stop.sh is only present in the
    # container once `kennel-demo.sh down` has put it there.
    #
    # Signal by recorded PID, then reap by EXACT process name. NEVER `pkill -f`
    # -- it matches the very shell running it (vm/provisioning.md section 5a).
    say "container is running -- stopping the stack inside it first"
    sudo docker exec "$CONTAINER_NAME" bash -c '
        # The trot publisher of p21-trot-hold.sh, if a walk was left running.
        if [ -f /tmp/p21-trot-pub.pid ]; then
            kill "$(cat /tmp/p21-trot-pub.pid)" 2>/dev/null || true
            rm -f /tmp/p21-trot-pub.pid
        fi
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
        # "mitcontrollerno" is not a typo: Linux caps comm at 15 chars, so the
        # 17-char "mitcontrollernode" is truncated and -x never matches the
        # full name (k13-stop.sh carries the same note).
        for n in simulator leg_driver mitcontrollerno log_cpu_power joy_linux_node ros2; do
            pkill -KILL -x "$n" 2>/dev/null || true
        done
        # joy_to_target.py runs under python3, so its comm is "python3" and -x
        # never matches it. Match the script PATH instead -- that cannot match
        # this shell own cmdline, which is the trap -f normally carries.
        pkill -KILL -f "controllers/joy_to_target[.]py" 2>/dev/null || true
        true' >/dev/null 2>&1 || true
    say "stopping container '$CONTAINER_NAME' (bounded at ${STOP_TIMEOUT}s)"
    sudo docker stop -t "$STOP_TIMEOUT" "$CONTAINER_NAME" >/dev/null || {
        fail "'sudo docker stop $CONTAINER_NAME' did not return cleanly." \
             "Inspect it: sudo docker logs $CONTAINER_NAME"
        exit 2
    }
else
    say "container '$CONTAINER_NAME' is already '$cstate' -- nothing to stop"
fi
say "container state: $(sudo docker inspect --type container -f '{{.State.Status}}' "$CONTAINER_NAME")"

# --- REGION: phase 2 -- the clone must be stock
# ASSERTED BEFORE the staging directory is cleared, deliberately. A composed run
# shows up here as a dirty working tree, and when it does, ~/kennel-staging is
# the evidence: `current-run` names the run that dirtied it. Deleting that first
# would throw away the only thing that says which run to blame.
banner "assert the clone is stock"
head="$(git -C "$DFKI_QUAD_DIR" rev-parse HEAD)"
say "HEAD=$head"
say "pin =$DFKI_QUAD_COMMIT"
if [ "$head" != "$DFKI_QUAD_COMMIT" ]; then
    fail "the dfki-quad clone is not at the stack pin." \
         "HEAD=$head" \
         "pin =$DFKI_QUAD_COMMIT" \
         "A baseline at another revision would freeze the wrong stack. Re-provision," \
         "or set DFKI_QUAD_COMMIT if this guest is deliberately at another pin."
    exit 1
fi
# TRACKED files only, and that is deliberate. A correctly provisioned guest
# ALWAYS has untracked files in this clone: the build stamp
# `ws/.kennel-built-<pin>` sits inside the worktree and upstream's .gitignore
# does not cover it (it covers ws/build, ws/install, ws/log, ws/data). A bare
# `git status --porcelain` therefore can never be empty here, and asserting on
# it would reject every real baseline. What "stock" actually means is that no
# TRACKED file differs from the pin -- the two composed YAMLs are tracked and
# are overwritten in place, so `transfer` shows up as ` M` and is caught.
# Untracked entries are build artifacts; they are reported, not judged.
dirty="$(git -C "$DFKI_QUAD_DIR" status --porcelain --untracked-files=no)"
if [ -n "$dirty" ]; then
    fail "the dfki-quad clone has modified tracked files -- this guest is NOT stock." \
         "A snapshot taken now would return this composed state on every reset."
    echo "$dirty" | sed 's/^/    /' >&2
    echo "  Put the stock configs back first, from the HOST:" >&2
    echo "    stack/transfer/kennel-transfer.sh restore-stock" >&2
    echo "  (it materializes them from the pin object, so it works whatever HEAD says)" >&2
    exit 1
fi
say "tracked files: no modifications (configs are stock at the pin)"
untracked="$(git -C "$DFKI_QUAD_DIR" ls-files --others --exclude-standard)"
if [ -n "$untracked" ]; then
    say "untracked (build artifacts, expected):"
    echo "$untracked" | sed 's/^/    /'
fi

# --- REGION: phase 3 -- the workspace must be built
banner "assert the workspace is built"
missing=0
if [ -f "$BUILD_STAMP" ]; then
    say "build stamp      $BUILD_STAMP"
else
    say "build stamp      MISSING: $BUILD_STAMP"; missing=1
fi
if [ -f "$DFKI_QUAD_DIR/ws/install/setup.bash" ]; then
    say "colcon install   $DFKI_QUAD_DIR/ws/install/setup.bash"
else
    say "colcon install   MISSING: $DFKI_QUAD_DIR/ws/install/setup.bash"; missing=1
fi
if [ "$missing" != 0 ]; then
    fail "this guest has no built workspace at the pin, so a baseline of it is worthless." \
         "The whole point of the snapshot is to skip the build; freezing an unbuilt" \
         "guest freezes the 33 minutes back in. Provision it first (vm/provisioning.md)."
    exit 1
fi

# --- REGION: phase 4 -- no run is staged or current
banner "clear the staging directory"
if [ -d "$STAGING" ]; then
    current="$(cat "$STAGING/current-run" 2>/dev/null || true)"
    [ -n "$current" ] && say "was applied: $current (the clone is stock, so it was already restored)"
    say "removing $STAGING ($(du -sh "$STAGING" 2>/dev/null | cut -f1))"
    rm -rf "$STAGING"
else
    say "no staging directory -- nothing to clear"
fi
say "staging: absent (no run is current in a baseline)"

# --- REGION: phase 5 -- record what is being frozen
banner "record the baseline"
image_id="$(sudo docker image inspect -f '{{.Id}}' "$IMAGE_NAME:latest" 2>/dev/null || true)"
[ -n "$image_id" ] || {
    fail "could not read the image id of '$IMAGE_NAME:latest'." \
         "The container exists but its image does not -- this guest is in a state" \
         "the provisioning script does not produce."
    exit 2
}
# One line per fact, `key=value`, so a sequence step can assert one of them with
# `grep -qx` and no parser.
{
    echo "pin=$DFKI_QUAD_COMMIT"
    echo "image_id=$image_id"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BASELINE_FILE"
say "$BASELINE_FILE:"
sed 's/^/    /' "$BASELINE_FILE"

# --- REGION: phase 6 -- reclaim what does not belong in a frozen disk
# Not an optimization for its own sake: everything below is re-fetched or
# re-generated on demand, and every byte of it is a byte the snapshot carries
# forever, plus a byte of divergence inside the qcow2 on each revert.
banner "reclaim"
before="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
sudo apt-get clean
sudo journalctl --vacuum-time=1d >/dev/null 2>&1 || true
sync
after="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
say "free on /: ${before} GiB -> ${after} GiB"

echo ""
echo -e "\e[1;32m==== this guest is a clean baseline. ====\e[0m"
