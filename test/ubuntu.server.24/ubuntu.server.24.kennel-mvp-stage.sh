#!/bin/bash
# Version: 2026.09.10
# Kennel -- issue #24: stage everything the MVP sequence is about to run.
#
# Runs on the GUEST (kennel-vm), fetched and executed by one sshFetchAndExecute
# step. It is the guest-side half of what `kennel-demo.sh run` does from the
# host with scp: it puts the checked-in fixture and the four stack tools where
# the next steps expect them. Yuruna has no host-exec action and no scp action
# (stack/transfer.md 2.2), so a sequence cannot call a host-side wrapper -- but
# it does not need to, because the host is already serving this repository.
#
# WHERE THE BYTES COME FROM, and why it matters. Everything is fetched from the
# host's status service at /yuruna-repo/project/<path>, which is the PROJECT
# CLONE the runner just made -- i.e. the revision under test. The guest also has
# its own copy of the project at ~/yuruna/project, and this script deliberately
# ignores it: that copy is whatever the project was when the guest was
# provisioned, and it is frozen inside the baseline snapshot. Reading it would
# mean testing an old revision on every warm run.
#
# A PRIVATE project has no GitHub fallback -- fetch-and-execute.sh's fallback
# route is raw.githubusercontent.com, which can only 404 for a private
# repository -- so the host status service is the single source here and a
# fetch that fails is exit 2, before anything has touched the stack.
#
# Usage (the sequence's step; fetch-and-execute passes no arguments, so the
# fixture name is an environment variable set ahead of the call):
#   KENNEL_MVP_RUN=run-<stamp> \
#     /usr/local/lib/yuruna/fetch-and-execute.sh \
#       project/test/ubuntu.server.24/ubuntu.server.24.kennel-mvp-stage.sh
#
# Knobs (environment variables, all optional except the first):
#   KENNEL_MVP_RUN     (required)      the fixture directory name under test/fixtures/
#   KENNEL_STAGING     ~/kennel-staging   where the applier reads runs from
#                                         (stack/transfer.md 3 -- its contract)
#   KENNEL_MVP_DIR     ~/kennel-mvp    where this run's record is assembled
#   KENNEL_CONTAINER   dfki_quad       the container k13-stop.sh is copied into
#
# Exit codes:
#   0  staged: the fixture and the four tools are in place
#   2  could not fetch something from the host -- nothing was started, and the
#      stack has not been touched
#
# NB `set -u` is safe here: this script sources /etc/yuruna/host.env (a plain
# KEY=VALUE file) and never a ROS setup file, so it cannot trip the unbound
# AMENT_TRACE_SETUP_FILES dereference of stack/launch.md section 7.

set -uo pipefail

# --- REGION: knobs
RUN="${KENNEL_MVP_RUN:-}"
STAGING="${KENNEL_STAGING:-$HOME/kennel-staging}"
MVP_DIR="${KENNEL_MVP_DIR:-$HOME/kennel-mvp}"
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"

fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

[ -n "$RUN" ] || {
    fail "KENNEL_MVP_RUN is not set -- this script does not guess which fixture to stage." \
         "The sequence sets it; by hand it is the directory name under test/fixtures/."
    exit 2
}

# --- REGION: the host, which is the only source
# The status service's address is baked into the guest at New-VM time. Without
# it there is nothing to fetch from and no point going further.
# shellcheck disable=SC1091
[ -r /etc/yuruna/host.env ] && . /etc/yuruna/host.env
HOST_IP="${YURUNA_STATUS_SERVICE_IP:-}"
HOST_PORT="${YURUNA_STATUS_SERVICE_PORT:-}"
[ -n "$HOST_IP" ] && [ -n "$HOST_PORT" ] || {
    fail "no YURUNA_STATUS_SERVICE_IP/PORT in /etc/yuruna/host.env." \
         "That file is written by New-VM.ps1; a guest without it cannot reach the host's" \
         "serving of the project, which is where every file below comes from."
    exit 2
}
BASE="http://$HOST_IP:$HOST_PORT/yuruna-repo/project/"

# --no-proxy: the host lives on a private NAT address that an inherited
# http_proxy cannot route to (yuruna's own rule for host probes).
fetch() {   # $1 = path inside the project, $2 = destination file
    mkdir -p "$(dirname "$2")"
    wget --no-proxy --timeout=20 --tries=2 -qO "$2" "$BASE$1" && [ -s "$2" ] || {
        fail "could not fetch $BASE$1" \
             "The host status service is the ONLY source for a private project --" \
             "its GitHub fallback can only 404. Is the service up on the host?"
        exit 2
    }
    printf '  %s  %s\n' "$(sha256sum "$2" | cut -c1-64)" "$1"
}

echo "==== fixture $RUN ===="
# The four files of a console export (kennel_console/export.md 1). The applier
# reads the two YAMLs and checks run.json's pin; commands.txt is what the
# launcher runs. All four are staged so what lands on the guest is the run
# folder, not a subset of it.
for f in simulator_params_go2.yaml mit_controller_sim_go2.yaml commands.txt run.json; do
    fetch "test/fixtures/$RUN/$f" "$STAGING/runs/$RUN/$f"
done

echo "==== stack tools ===="
# The same four tools `kennel-demo.sh` scps for its transfer / launch / verify /
# down phases, from the same files -- so the sequence exercises the shipped
# tools rather than a second copy of what they do.
fetch stack/transfer/guest-apply-config.sh                 "$STAGING/guest-apply-config.sh"
fetch stack/known-good/tools/k13-stop.sh                   /tmp/k13-stop.sh
fetch stack/composed-run/tools/p21-launch-from-commands.sh /tmp/p21-launch-from-commands.sh
fetch stack/verify/kennel-verify.sh                        /tmp/kennel-verify.sh
chmod +x "$STAGING/guest-apply-config.sh" /tmp/k13-stop.sh \
         /tmp/p21-launch-from-commands.sh /tmp/kennel-verify.sh

# The stopper has to be INSIDE the container before the launcher runs. The
# launcher opens with "stopping anything already running", but that line is
# `[ -x /root/k13-stop.sh ] && /root/k13-stop.sh` -- a silent no-op until
# something has put it there. On a guest that has never run `down` (which is
# every guest fresh from a snapshot revert) a relaunch would otherwise stack a
# second simulator on the first. `kennel-demo.sh launch` does this same copy.
sudo docker start "$CONTAINER" >/dev/null 2>&1 || true
sudo docker cp /tmp/k13-stop.sh "$CONTAINER:/root/k13-stop.sh" || {
    fail "could not copy k13-stop.sh into container '$CONTAINER'." \
         "Without it the launcher cannot stop a previous session and would stack a second stack."
    exit 2
}

# The fixture name, for the steps that follow: they read it from here rather
# than restating it, so this script is the one place the sequence's literal
# reaches the guest.
mkdir -p "$MVP_DIR"
printf '%s\n' "$RUN" > "$MVP_DIR/fixture"

echo "==== staged ===="
echo "  fixture   $STAGING/runs/$RUN"
echo "  applier   $STAGING/guest-apply-config.sh"
echo "  launcher  /tmp/p21-launch-from-commands.sh"
echo "  recipe    /tmp/kennel-verify.sh"
echo "  stopper   $CONTAINER:/root/k13-stop.sh"
