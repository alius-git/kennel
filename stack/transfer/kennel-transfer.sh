#!/bin/bash
# Version: 2026.09.10
# Kennel -- issue #20: push a console-exported run folder from the HOST into the
# guest and onto the config paths the launch files read inside the container.
#
# Runs on the HOST. It discovers the guest the way vm/test/verify-meshcat-host.sh
# does (libvirt DHCP lease by hostname), validates the run folder before it
# copies anything, scps the folder and the guest applier into a fixed staging
# directory, and then runs the applier over SSH. All the placing and all the
# verifying happen in guest-apply-config.sh, which is why this wrapper can stay
# thin and why issue #24 can skip it entirely (stack/transfer.md section 4).
#
# Usage:
#   stack/transfer/kennel-transfer.sh apply <run-folder> [--allow-pin-mismatch]
#   stack/transfer/kennel-transfer.sh restore-stock
#   stack/transfer/kennel-transfer.sh status
#
# <run-folder> is an UNPACKED run-<timestamp>/ directory as exported by the
# console (issue #19). The console cannot choose where the browser saves it, so
# the path is always an argument -- see kennel_console/export.md section 6.
#
# Since #74 `apply` also compares the run's `manifest_ref` (the sha256 of the
# version manifest the console knew when it composed the run) with the guest's
# ~/kennel-manifest.json, and WARNS when they differ or the guest has none. A
# warning and never a refusal: the pin is what decides whether a run means
# anything here, and the drift check (#75) is what names what changed.
#
# Exit codes are the applier's, with the host-side ones layered underneath:
#   0  success
#   1  verification failed (bytes on the config path are not the bytes asked for)
#   2  infrastructure error (bad arguments, unreadable run folder, no guest)
#   3  pin mismatch (override: --allow-pin-mismatch)
#   4  guest unreachable over SSH
#   5  guest IP could not be discovered
#
# See stack/transfer.md for the decisions, the staging contract and the evidence.

set -uo pipefail

# --- REGION: knobs
GUEST_HOSTNAME="${KENNEL_GUEST_HOSTNAME:-kennel-vm}"   # as it appears in the DHCP lease
LIBVIRT_NET="${KENNEL_LIBVIRT_NET:-default}"
GUEST_USER="${KENNEL_GUEST_USER:-yuuser24}"
SSH_KEY="${KENNEL_SSH_KEY:-$HOME/git/yuruna/test/status/ssh/yuruna_ed25519}"
GUEST_IP="${KENNEL_GUEST_IP:-}"
GUEST_DOMAIN="${KENNEL_VM_DOMAIN:-}"
STAGING="${KENNEL_STAGING:-kennel-staging}"            # relative to the guest's $HOME
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PIN_LOCK="$REPO_ROOT/stack/pin.lock"
APPLIER="$HERE/guest-apply-config.sh"

FILES=(simulator_params_go2.yaml mit_controller_sim_go2.yaml)

say()  { echo "$@"; }
warn() { echo "WARNING: $*" >&2; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }
usage() {
    sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- REGION: arguments
MODE="${1:-}"
RUN_FOLDER=""
ALLOW_PIN_MISMATCH=0
case "$MODE" in
    apply)
        RUN_FOLDER="${2:-}"
        [ -n "$RUN_FOLDER" ] || { fail "apply needs a run folder."; usage >&2; exit 2; }
        shift 2
        while [ $# -gt 0 ]; do
            case "$1" in
                --allow-pin-mismatch) ALLOW_PIN_MISMATCH=1; shift ;;
                *) fail "unknown option '$1'."; usage >&2; exit 2 ;;
            esac
        done
        ;;
    restore-stock|status) ;;
    -h|--help) usage; exit 0 ;;
    *) fail "expected a mode: apply | restore-stock | status"; usage >&2; exit 2 ;;
esac

[ -f "$APPLIER" ] || { fail "the guest applier is missing at $APPLIER."; exit 2; }

# --- REGION: the pin
# stack/pin.lock is the single source of truth (issue #12). Unlike the
# provisioning script -- which Yuruna fetches standalone into the guest with no
# checkout of this repo -- this script runs from the repo, so it READS the pin
# instead of carrying a derived copy of it.
PIN="$(grep '^commit:' "$PIN_LOCK" 2>/dev/null | awk '{print $2}')"
[ -n "$PIN" ] || { fail "could not read 'commit:' from $PIN_LOCK."; exit 2; }
say "pin              $PIN  ($PIN_LOCK)"

# --- REGION: validate the run folder BEFORE touching the guest
SIM_SHA=""; CTRL_SHA=""; RUN_NAME=""
if [ "$MODE" = apply ]; then
    [ -d "$RUN_FOLDER" ] || {
        fail "'$RUN_FOLDER' is not a directory." \
             "Pass an UNPACKED run-<timestamp>/ folder, not the .zip the console downloads:" \
             "  unzip ~/Downloads/run-<stamp>.zip -d ~/runs && $0 apply ~/runs/run-<stamp>"
        exit 2
    }
    # Normalize before anything uses it: a trailing slash makes `scp -r` copy the
    # folder's CONTENTS into runs/ instead of the folder itself, which would
    # scatter a run across the staging root.
    RUN_FOLDER="$(cd "$RUN_FOLDER" && pwd)"
    RUN_NAME="$(basename "$RUN_FOLDER")"
    for f in "${FILES[@]}"; do
        [ -f "$RUN_FOLDER/$f" ] || {
            fail "'$RUN_FOLDER' has no $f." \
                 "Every console export carries both YAMLs; this folder is not one," \
                 "or it was edited. Re-export rather than hand-assembling it."
            exit 2
        }
    done
    for f in commands.txt run.json; do
        [ -f "$RUN_FOLDER/$f" ] || warn "no $f in $RUN_FOLDER -- the stack does not read it, but a" \
                                        "complete export carries it (kennel_console/export.md section 1)."
    done

    if [ -f "$RUN_FOLDER/run.json" ]; then
        rj_pin="$(sed -n 's/.*"pin"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$RUN_FOLDER/run.json" | head -1)"
        if [ -n "$rj_pin" ] && [ "$rj_pin" != "$PIN" ]; then
            if [ "$ALLOW_PIN_MISMATCH" = 1 ]; then
                warn "run.json pin $rj_pin != stack pin $PIN -- proceeding, --allow-pin-mismatch given."
            else
                fail "this run was generated against pin $rj_pin, the stack is pinned at $PIN." \
                     "Its keys have no defined meaning at this revision. Re-export, or force with:" \
                     "  $0 apply $RUN_FOLDER --allow-pin-mismatch"
                exit 3
            fi
        fi
    fi

    # Taken HERE, on the host, before the copy. The applier is handed these and
    # asserts against them, so the reported chain is host -> guest -> container
    # rather than "whatever arrived -> container".
    SIM_SHA="$(sha256sum "$RUN_FOLDER/${FILES[0]}" | awk '{print $1}')"
    CTRL_SHA="$(sha256sum "$RUN_FOLDER/${FILES[1]}" | awk '{print $1}')"
    say "run folder       $RUN_NAME"
    say "  ${FILES[0]}  ${SIM_SHA:0:8}"
    say "  ${FILES[1]}  ${CTRL_SHA:0:8}"
fi

# --- REGION: find the guest
# Same discovery as vm/test/verify-meshcat-host.sh: the DHCP lease table carries
# the guest's HOSTNAME, so this works without knowing Yuruna's generated domain
# name (test-guest.ubuntu.server.24-01).
if [ -z "$GUEST_IP" ]; then
    GUEST_IP="$(virsh net-dhcp-leases "$LIBVIRT_NET" 2>/dev/null \
                | awk -v h="$GUEST_HOSTNAME" '$0 ~ h {print $5}' \
                | cut -d/ -f1 | tail -1)"
fi
if [ -z "$GUEST_IP" ] && [ -n "$GUEST_DOMAIN" ]; then
    GUEST_IP="$(virsh domifaddr "$GUEST_DOMAIN" --source lease 2>/dev/null \
                | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)"
fi
if [ -z "$GUEST_IP" ]; then
    fail "could not discover the guest IP on libvirt network '$LIBVIRT_NET'." \
         "Is the guest running?   virsh list --all" \
         "Leases:                 virsh net-dhcp-leases $LIBVIRT_NET" \
         "Override directly with: KENNEL_GUEST_IP=192.168.122.x $0 $MODE"
    exit 5
fi
say "guest            $GUEST_HOSTNAME at $GUEST_IP (libvirt '$LIBVIRT_NET')"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)
TARGET="$GUEST_USER@$GUEST_IP"

if ! ssh "${SSH_OPTS[@]}" "$TARGET" true 2>/dev/null; then
    fail "cannot reach the guest over SSH at $TARGET." \
         "Key: $SSH_KEY" \
         "Try: ssh -i $SSH_KEY $TARGET hostname" \
         "If the guest has just booted, sshWaitReady can take several minutes."
    exit 4
fi

# --- REGION: the version manifest (#74)
# A run composed in a console that knew the guest's manifest carries its
# manifest_ref. The guest is asked for its own here, where it is being sshed
# anyway. Different means the run was composed against another environment --
# a rebuilt baseline, an imported image, a repin -- which is worth a line in the
# operator's transcript and not worth refusing: the pin check above decides
# refusal, and `kennel-demo.sh drift` names what changed.
if [ "$MODE" = apply ]; then
    rj_ref=""
    [ -f "$RUN_FOLDER/run.json" ] \
        && rj_ref="$(sed -n 's/.*"manifest_ref"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$RUN_FOLDER/run.json" | head -1)"
    guest_ref="$(ssh "${SSH_OPTS[@]}" "$TARGET" 'sha256sum ~/kennel-manifest.json 2>/dev/null | cut -c1-64' 2>/dev/null)"
    if [ -z "$guest_ref" ]; then
        warn "the guest carries no version manifest (its baseline predates #74) -- this run's"
        warn "environment cannot be checked. Re-take the baseline: demo/tools/kennel-demo.sh snapshot"
    else
        say "manifest         ${guest_ref:0:12}  (the guest's)"
        if [ -z "$rj_ref" ]; then
            say "                 run.json names none (composed with no manifest known)"
        elif [ "$rj_ref" != "$guest_ref" ]; then
            warn "this run was composed against manifest ${rj_ref:0:12}, but the guest carries ${guest_ref:0:12}:"
            warn "the environment is not the one the run was composed for. Applying anyway --"
            warn "demo/tools/kennel-demo.sh drift names what differs from the guest's own baseline."
        else
            say "                 run.json names the same manifest"
        fi
    fi
fi

# --- REGION: stage
# The applier is copied on EVERY run, so the guest can never be running an older
# copy of it than the repo holds. It is small; correctness beats the round trip.
ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p '$STAGING/runs' '$STAGING/stock-backup'" || {
    fail "could not create the staging directory ~/$STAGING on the guest."
    exit 2
}
scp "${SSH_OPTS[@]}" -q "$APPLIER" "$TARGET:$STAGING/guest-apply-config.sh" || {
    fail "could not copy the applier to the guest."
    exit 2
}
ssh "${SSH_OPTS[@]}" "$TARGET" "chmod +x '$STAGING/guest-apply-config.sh'"

if [ "$MODE" = apply ]; then
    # The WHOLE folder goes across, not just the two YAMLs: commands.txt and
    # run.json are what #24 and #27 read, and a staged run that has lost its
    # provenance is not the artifact #19 exported.
    ssh "${SSH_OPTS[@]}" "$TARGET" "rm -rf '$STAGING/runs/$RUN_NAME'"
    scp "${SSH_OPTS[@]}" -q -r "$RUN_FOLDER" "$TARGET:$STAGING/runs/" || {
        fail "could not copy the run folder to the guest."
        exit 2
    }
    say "staged           ~/$STAGING/runs/$RUN_NAME"
fi

# --- REGION: apply, on the guest
say ""
ssh "${SSH_OPTS[@]}" "$TARGET" \
    "KENNEL_MODE='$MODE' KENNEL_RUN='$RUN_NAME' KENNEL_PIN='$PIN' \
     KENNEL_STAGING=\"\$HOME/$STAGING\" KENNEL_CONTAINER='$CONTAINER' \
     KENNEL_ALLOW_PIN_MISMATCH='$ALLOW_PIN_MISMATCH' \
     KENNEL_EXPECT_SIM_SHA='$SIM_SHA' KENNEL_EXPECT_CTRL_SHA='$CTRL_SHA' \
     '$STAGING/guest-apply-config.sh'"
rc=$?

case "$rc" in
    0) ;;
    1) fail "the transfer did not land: the config paths do not carry the expected bytes." \
            "The table above says which file and which hop disagreed." ;;
    3) fail "pin mismatch reported by the guest." ;;
    *) fail "the guest applier exited $rc -- see its diagnostics above." ;;
esac
exit $rc
