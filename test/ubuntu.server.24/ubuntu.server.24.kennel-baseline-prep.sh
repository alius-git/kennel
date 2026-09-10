#!/bin/bash
# Version: 2026.09.10
# Kennel -- issue #51: make this guest a clean BASELINE, ready to be frozen into
# a Yuruna disk snapshot. Since #74 it also writes the guest's VERSION MANIFEST;
# since #75 it holds the package set still; since #76 it installs the
# appliance's first-boot key unit.
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
#   * the package set holds still: the periodic apt jobs are off. Ubuntu's
#     timers are Persistent, so the first boot after a revert of a days-old
#     baseline would otherwise upgrade it -- and the drift check (#75) would
#     report every such upgrade, correctly, as an environment that is no longer
#     the one the manifest describes (vm/drift.md);
#   * the first-boot key unit is installed, so an IMPORTED copy of this disk
#     trusts the importing host's SSH key instead of this host's (#76,
#     vm/image.md). On this disk it is a no-op: there is no KENNELKEY volume;
#   * `~/kennel-manifest.json` records what was frozen -- OS, kernel, Docker,
#     the image, the pin, ROS, Drake, every installed package (in a sidecar
#     list), and the kennel commit it was built from -- so a revert, a drift
#     check and an import can each prove what they got back (#74,
#     vm/manifest.md). `~/.kennel-baseline`, its three-line predecessor, is
#     still written for one release and read by nothing: DEPRECATED, remove it
#     with the next repin.
#
# fetch-and-execute passes NO arguments to the fetched script, so every knob is
# an environment variable -- same contract as ubuntu.server.24.dfki-quad.sh.
#
# Idempotent: running it twice in a row is the same as running it once, except
# that the second run writes a fresh `created` stamp -- and so a fresh
# manifest_ref, which is the sha256 of the manifest's bytes. That is why
# `kennel-demo.sh snapshot` re-takes a baseline rather than "refreshing" one.
#
# `==== name ====` banners are the per-phase timing checkpoints fetch-and-execute
# captures, exactly as in the provisioning script.
#
# Knobs beyond the ones in the REGION below, all environment variables:
#   KENNEL_MANIFEST         ~/kennel-manifest.json  the version manifest; its
#                                                   package list is written beside
#                                                   it as <name>.packages.txt
#   KENNEL_PROJECT_COMMIT / KENNEL_CONSOLE_VERSION / KENNEL_GUIDES_VERSION
#                           the build provenance. `kennel-demo.sh snapshot`
#                           passes all three from the checkout. Any left empty is
#                           read from the host's project archive -- the status
#                           service this script was fetched through -- and
#                           recorded as null when that is unreachable too
#   KENNEL_KEY_USER         the invoking user       whose authorized_keys the
#                                                   first-boot unit replaces
#   KENNEL_APT_WAIT         900                     seconds to wait for a periodic
#                                                   apt run already in flight
#
# Exit codes (stack/verify.md section 1's convention):
#   0  the guest is a clean baseline; the manifest written
#   1  an assertion failed -- the guest is NOT a baseline (message says which)
#   2  could not even look (no docker, no clone, no container, a missing tool)
#
# See vm/snapshot.md for what the snapshot is for and how it is taken, and
# vm/manifest.md for what the manifest records and who reads it.

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
# DEPRECATED (#74): kept for one release, read by nothing. The manifest below is
# the record now.
BASELINE_FILE="${KENNEL_BASELINE_FILE:-$HOME/.kennel-baseline}"
MANIFEST="${KENNEL_MANIFEST:-$HOME/kennel-manifest.json}"
KEY_USER="${KENNEL_KEY_USER:-$(id -un)}"
APT_WAIT="${KENNEL_APT_WAIT:-900}"
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
# The manifest is written by python3 and asserted with jq; the provenance is read
# with curl and git. All four are on every Yuruna ubuntu.server.24 guest -- a
# guest without one is not a guest this script was written for.
for tool in python3 jq curl git dpkg-query; do
    command -v "$tool" >/dev/null 2>&1 || {
        fail "'$tool' is not on this guest; the version manifest cannot be written without it."
        exit 2
    }
done
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

# --- REGION: phase 5 -- hold the package set still (#75)
# An appliance with a manifest must not change its own packages on a timer.
# Ubuntu server enables apt-daily and apt-daily-upgrade, both Persistent=true: a
# baseline reverted days after it was frozen would run unattended-upgrades within
# minutes of booting, and the drift check would -- correctly -- report every
# upgraded package. On the MVP guest it had already upgraded 135 packages during
# provisioning (vm/drift.md section 0). Off at the timer AND at apt's own periodic
# switch, so a timer re-enabled by a package upgrade still does nothing.
banner "hold the package set still"
apt_job_running() {
    local s st
    for s in apt-daily.service apt-daily-upgrade.service; do
        # is-active is 0 only for "active"; a oneshot in flight is "activating".
        st="$(systemctl show -p ActiveState --value "$s" 2>/dev/null || true)"
        case "$st" in activating|active|deactivating|reloading) return 0 ;; esac
    done
    return 1
}
for t in apt-daily.timer apt-daily-upgrade.timer; do
    if systemctl is-enabled --quiet "$t" 2>/dev/null; then
        sudo systemctl disable --now "$t" >/dev/null 2>&1 || true
        say "disabled         $t"
    else
        say "already off      $t"
    fi
done
printf '%s\n' \
    '// Written by ubuntu.server.24.kennel-baseline-prep.sh (Kennel #75). The appliance' \
    '// is pinned: apt never refreshes or upgrades it on a timer. See vm/drift.md.' \
    'APT::Periodic::Update-Package-Lists "0";' \
    'APT::Periodic::Unattended-Upgrade "0";' \
    | sudo tee /etc/apt/apt.conf.d/99kennel-no-periodic >/dev/null
# Disabling a timer does not stop a run already in flight, and a package list
# recorded while dpkg is still working is a lie. Wait for it -- observed, bounded.
t0=$SECONDS
while apt_job_running; do
    if [ $((SECONDS - t0)) -ge "$APT_WAIT" ]; then
        fail "a periodic apt run is still in flight after ${APT_WAIT}s." \
             "The package list would be recorded mid-upgrade. Inspect it:" \
             "  systemctl status apt-daily-upgrade.service apt-daily.service"
        exit 1
    fi
    sleep 5
done
for t in apt-daily.timer apt-daily-upgrade.timer; do
    if systemctl is-enabled --quiet "$t" 2>/dev/null; then
        fail "$t is still enabled after 'systemctl disable'."
        exit 1
    fi
done
say "periodic apt     off (/etc/apt/apt.conf.d/99kennel-no-periodic)"

# --- REGION: phase 6 -- the appliance's first-boot key unit (#76)
# The guest trusts ONE key: the building host's Yuruna harness key, put there by
# autoinstall. An exported copy of this disk must not keep trusting it on another
# host, and cloud-init cannot re-key it -- the installer disabled cloud-init on
# this guest (/etc/cloud/cloud-init.disabled, datasource None). So the baseline
# carries its own mechanism: a unit that, whenever a volume labelled KENNELKEY is
# attached, REPLACES the user's authorized_keys with the keys on it, and on the
# first such import regenerates the SSH host keys. `kennel-demo.sh import` builds
# that volume from the importing host's public key. On this disk there is no such
# volume, so every boot the unit starts, finds nothing, and exits 0.
banner "install the first-boot key unit"
getent passwd "$KEY_USER" >/dev/null || { fail "no user '$KEY_USER' on this guest (KENNEL_KEY_USER)."; exit 2; }
install_root_file() {   # $1 = mode, $2 = destination; the content on stdin
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if sudo cmp -s "$tmp" "$2"; then
        say "unchanged        $2"
    else
        sudo install -D -m "$1" -o root -g root "$tmp" "$2"
        say "installed        $2"
    fi
    rm -f "$tmp"
}
unit_tmp="$(mktemp)"
sed "s/@KENNEL_KEY_USER@/$KEY_USER/" > "$unit_tmp" <<'IMPORT_KEY_SH'
#!/bin/bash
# Version: 2026.09.10
# Kennel -- issue #76: install the SSH keys an importing host put on a volume
# labelled KENNELKEY. Installed into the baseline by
# test/ubuntu.server.24/ubuntu.server.24.kennel-baseline-prep.sh.
#
# Runs on the GUEST, as root, from kennel-import-key.service -- at every boot,
# and whenever udev sees a KENNELKEY volume appear (90-kennel-import-key.rules).
#
# With no such volume it does nothing. With one, it REPLACES the authorized_keys
# of @KENNEL_KEY_USER@ with the volume's authorized_keys (every line must be a
# public key ssh-keygen can fingerprint, or nothing is changed), and on the first
# import on this disk regenerates the SSH host keys, so two imports of one image
# do not share a host identity.
#
# Exit codes: always 0. A boot must never fail over a key volume; what happened
# is in the journal:  journalctl -t kennel-import-key
#
# See vm/image.md.
set -uo pipefail
USER_NAME="@KENNEL_KEY_USER@"
DEV=/dev/disk/by-label/KENNELKEY
MARK=/var/lib/kennel/imported
log() { logger -t kennel-import-key -- "$*" 2>/dev/null; echo "$*"; }
[ -e "$DEV" ] || exit 0
home="$(getent passwd "$USER_NAME" | cut -d: -f6)"
group="$(id -gn "$USER_NAME" 2>/dev/null)"
[ -n "$home" ] && [ -n "$group" ] || { log "no user $USER_NAME -- nothing changed"; exit 0; }
mnt="$(mktemp -d)"
work="$(mktemp -d)"
cleanup() { umount "$mnt" 2>/dev/null; rmdir "$mnt" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
mount -o ro "$DEV" "$mnt" 2>/dev/null || { log "could not mount $DEV -- nothing changed"; exit 0; }
[ -s "$mnt/authorized_keys" ] || { log "$DEV carries no authorized_keys -- nothing changed"; exit 0; }
mapfile -t lines < "$mnt/authorized_keys"
n=0
: > "$work/keys"
for line in "${lines[@]}"; do
    case "$line" in ""|\#*) continue ;; esac
    printf '%s\n' "$line" > "$work/one"
    if ssh-keygen -l -f "$work/one" >/dev/null 2>&1; then
        printf '%s\n' "$line" >> "$work/keys"
        n=$((n + 1))
    else
        log "a line on $DEV is not a public key -- nothing changed"
        exit 0
    fi
done
[ "$n" -gt 0 ] || { log "no public key on $DEV -- nothing changed"; exit 0; }
dest="$home/.ssh/authorized_keys"
install -d -m 0700 -o "$USER_NAME" -g "$group" "$home/.ssh"
if [ -f "$dest" ] && cmp -s "$work/keys" "$dest"; then
    log "authorized_keys of $USER_NAME already carries the $n key(s) on $DEV -- unchanged"
    exit 0
fi
install -m 0600 -o "$USER_NAME" -g "$group" "$work/keys" "$dest.kennel-new" \
    && mv -f "$dest.kennel-new" "$dest" \
    || { log "could not write $dest -- nothing changed"; exit 0; }
log "installed $n key(s) from $DEV as the authorized_keys of $USER_NAME: $(ssh-keygen -l -f "$dest" | awk '{print $2}' | paste -sd, -)"
if [ ! -f "$MARK" ]; then
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
    ssh-keygen -A >/dev/null 2>&1
    systemctl try-restart ssh.service >/dev/null 2>&1 || true
    mkdir -p "$(dirname "$MARK")"
    { date -u +%Y-%m-%dT%H:%M:%SZ; ssh-keygen -l -f "$dest"; } > "$MARK"
    log "regenerated the SSH host keys (the first import on this disk; marker $MARK)"
fi
exit 0
IMPORT_KEY_SH
install_root_file 0755 /usr/local/lib/kennel/import-key.sh < "$unit_tmp"
rm -f "$unit_tmp"
install_root_file 0644 /etc/systemd/system/kennel-import-key.service <<'IMPORT_KEY_UNIT'
# Kennel (#76) -- installed by ubuntu.server.24.kennel-baseline-prep.sh. See vm/image.md.
[Unit]
Description=Kennel: install the SSH keys on a KENNELKEY volume (appliance import)
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/kennel/import-key.sh

[Install]
WantedBy=multi-user.target
IMPORT_KEY_UNIT
install_root_file 0644 /etc/udev/rules.d/90-kennel-import-key.rules <<'IMPORT_KEY_RULES'
# Kennel (#76) -- installed by ubuntu.server.24.kennel-baseline-prep.sh. See vm/image.md.
# A KENNELKEY volume that appears after the unit's boot-time run starts it again.
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="KENNELKEY", TAG+="systemd", ENV{SYSTEMD_WANTS}+="kennel-import-key.service"
IMPORT_KEY_RULES
sudo systemctl daemon-reload
sudo udevadm control --reload >/dev/null 2>&1 || true
sudo systemctl enable kennel-import-key.service >/dev/null 2>&1 || true
systemctl is-enabled --quiet kennel-import-key.service || {
    fail "kennel-import-key.service did not enable."
    exit 1
}
# Run it once, now: on this disk it must be the silent no-op described above, and
# a unit that cannot even do nothing is not one to freeze into a baseline.
sudo /usr/local/lib/kennel/import-key.sh || { fail "the first-boot key unit's script failed on this guest."; exit 1; }
say "enabled          kennel-import-key.service (no KENNELKEY volume here: a no-op)"

# --- REGION: phase 7 -- record what is being frozen
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
say "$BASELINE_FILE (deprecated, #74):"
sed 's/^/    /' "$BASELINE_FILE"

# --- REGION: phase 8 -- attest the build inputs (#74)
# Which kennel commit built this guest, and which console and guides it was built
# beside. The guest has no checkout of the kennel repo -- but the host that
# served this script also serves the project clone as a `git archive HEAD`
# tarball, and a tar made by git archive carries its commit in the pax header.
# The guides version is the git TREE id of guides/, and `git write-tree` over the
# extracted directory reproduces `git rev-parse <commit>:guides` exactly
# (vm/manifest.md section 2). Knobs win; the archive fills in what they left
# empty; what neither supplies is recorded as null, with a warning -- a baseline
# is still a baseline without its provenance.
banner "attest the build inputs"
PROJECT_COMMIT="${KENNEL_PROJECT_COMMIT:-}"
CONSOLE_VERSION="${KENNEL_CONSOLE_VERSION:-}"
GUIDES_VERSION="${KENNEL_GUIDES_VERSION:-}"
PROVENANCE=knobs
if [ -z "$PROJECT_COMMIT" ] || [ -z "$CONSOLE_VERSION" ] || [ -z "$GUIDES_VERSION" ]; then
    PROVENANCE=unknown
    arc="$(mktemp -d)"
    if [ -r /etc/yuruna/host.env ]; then
        # shellcheck disable=SC1091
        . /etc/yuruna/host.env
    fi
    if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ] \
       && curl -fsS --noproxy '*' --max-time 120 -o "$arc/project.tgz" \
               "http://$YURUNA_STATUS_SERVICE_IP:$YURUNA_STATUS_SERVICE_PORT/yuruna-project-archive.tar.gz" 2>/dev/null; then
        PROVENANCE=status-service
        say "archive          http://$YURUNA_STATUS_SERVICE_IP:$YURUNA_STATUS_SERVICE_PORT/yuruna-project-archive.tar.gz ($(du -h "$arc/project.tgz" | cut -f1))"
        # Process substitution, not a pipe: get-tar-commit-id stops reading after
        # the first block, zcat takes SIGPIPE, and under pipefail + errexit a pipe
        # would end this script right here.
        [ -n "$PROJECT_COMMIT" ] \
            || PROJECT_COMMIT="$(git get-tar-commit-id < <(zcat "$arc/project.tgz" 2>/dev/null) 2>/dev/null || true)"
        if tar -xzf "$arc/project.tgz" -C "$arc" guides kennel_console/serve.py 2>/dev/null; then
            [ -n "$CONSOLE_VERSION" ] \
                || CONSOLE_VERSION="$(sed -n 's/^KENNEL_CONSOLE_VERSION *= *"\([^"]*\)".*/\1/p' "$arc/kennel_console/serve.py" | head -n 1)"
            [ -n "$GUIDES_VERSION" ] \
                || GUIDES_VERSION="$(cd "$arc/guides" \
                                     && git --git-dir="$arc/tree.git" init -q \
                                     && git --git-dir="$arc/tree.git" --work-tree=. add -A -f . \
                                     && git --git-dir="$arc/tree.git" --work-tree=. write-tree 2>/dev/null || true)"
        else
            say "WARNING: the project archive carries no guides/ or kennel_console/serve.py"
        fi
    fi
    rm -rf "$arc"
fi
# Shape checks, so a wrong value is recorded as null rather than as a lie.
[[ "$PROJECT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || PROJECT_COMMIT=""
[[ "$GUIDES_VERSION" =~ ^[0-9a-f]{40}$ ]] || GUIDES_VERSION=""
[[ "$CONSOLE_VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] || CONSOLE_VERSION=""
say "project_commit   ${PROJECT_COMMIT:-null}"
say "console_version  ${CONSOLE_VERSION:-null}"
say "guides_version   ${GUIDES_VERSION:-null}"
say "provenance       $PROVENANCE"
if [ -z "$PROJECT_COMMIT" ] || [ -z "$CONSOLE_VERSION" ] || [ -z "$GUIDES_VERSION" ]; then
    say "WARNING: incomplete build provenance -- neither the KENNEL_PROJECT_COMMIT /"
    say "         KENNEL_CONSOLE_VERSION / KENNEL_GUIDES_VERSION knobs nor the host's project"
    say "         archive supplied every value; the missing ones are recorded as null."
fi

# --- REGION: phase 9 -- write the version manifest (#74)
# Two files. The package list is a sidecar (~700 lines) so the manifest stays
# readable in a transcript and cheap to hand to the console; the manifest binds
# it by sha256. The manifest is written CANONICALLY -- sorted keys, two-space
# indent, one trailing newline -- because its identity, manifest_ref, is the
# sha256 of its bytes, and anything that re-serializes it must reproduce them.
# image_sha256 is null here and always will be: an image cannot contain its own
# checksum. `kennel-demo.sh export-image` fills it in the SHIPPED copy.
banner "write the version manifest"
PKG_FILE="$(dirname "$MANIFEST")/$(basename "$MANIFEST" .json).packages.txt"
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' \
    | awk -F'\t' '$3 == "installed" {print $1 "\t" $2}' | LC_ALL=C sort > "$PKG_FILE.tmp"
mv -f "$PKG_FILE.tmp" "$PKG_FILE"
pkg_count="$(wc -l < "$PKG_FILE")"
pkg_sha="$(sha256sum "$PKG_FILE" | cut -c1-64)"
[ "$pkg_count" -gt 0 ] || { fail "dpkg-query listed no installed packages."; exit 2; }

# Read out of the IMAGE, never out of the container: phase 1 stopped the
# container, and the facts are the image's to begin with. One throwaway
# container, no network, ~1 s.
# The probe is written to a file and fed to the throwaway container on stdin.
facts_sh="$(mktemp)"
cat > "$facts_sh" <<'IMAGE_FACTS'
. /etc/os-release 2>/dev/null
echo "container_os=${PRETTY_NAME:-}"
echo "ros_distro=${ROS_DISTRO:-}"
if [ -n "${ROS_DISTRO:-}" ]; then
    echo "ros_base=$(dpkg-query -W -f='${binary:Package} ${Version}' "ros-${ROS_DISTRO}-ros-base" 2>/dev/null)"
fi
echo "drake=$(head -n 1 /opt/drake/share/doc/drake/VERSION.TXT 2>/dev/null)"
IMAGE_FACTS
image_facts="$(sudo docker run --rm -i --network none --entrypoint bash "$IMAGE_NAME:latest" -s < "$facts_sh" 2>/dev/null || true)"
rm -f "$facts_sh"
fact() { printf '%s\n' "$image_facts" | sed -n "/^$1=/{s/^$1=//p;q}"; }
container_os="$(fact container_os)"
ros_distro="$(fact ros_distro)"
ros_base="$(fact ros_base)"
drake="$(fact drake)"
# Drake is neither `pydrake` (not importable without root's .bashrc) nor an apt
# package: it is the /opt/drake binary tarball, whose VERSION.TXT is a build
# stamp and an upstream sha. The pin's own docker/drake_setup.sh names the
# release it fetched; say both, as #74 asked ("record which").
drake_release="$(grep -o 'drake-[0-9][0-9.]*-[a-z]*' "$DFKI_QUAD_DIR/docker/drake_setup.sh" 2>/dev/null | head -n 1 || true)"
# NB: no apostrophe inside ${var:+word} within double quotes. Bash reads it as an
# opening quote and refuses the line at RUN time -- after `bash -n` has passed it
# (vm/manifest.md, finding F20).
drake_source="/opt/drake/share/doc/drake/VERSION.TXT in the image (a binary tarball"
[ -n "$drake_release" ] && drake_source="$drake_source; docker/drake_setup.sh at the pin fetches $drake_release"
drake_source="$drake_source)"
for v in container_os ros_distro ros_base drake; do
    [ -n "${!v}" ] || say "WARNING: could not read $v from the image $IMAGE_NAME:latest -- recorded as null"
done

docker_version="$(sudo docker version -f '{{.Server.Version}}' 2>/dev/null || true)"
[ -n "$docker_version" ] || { fail "could not read the Docker server version."; exit 2; }
# The kernel every revert will BOOT, which is the one GRUB defaults to -- not
# merely the one running now. The two differ when an upgrade installed a kernel
# this boot has not used yet, and then every reset would run a kernel the
# manifest does not name.
kernel="$(uname -r)"
boot_kernel="$(readlink -f /boot/vmlinuz 2>/dev/null | sed -n 's:^/boot/vmlinuz-::p')"
if [ -n "$boot_kernel" ] && [ "$boot_kernel" != "$kernel" ]; then
    fail "this guest runs kernel $kernel but boots $boot_kernel by default." \
         "Every revert would boot a kernel this manifest does not name. Reboot the guest," \
         "then take the baseline."
    exit 1
fi
os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
os_version_id="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
os_pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-}")"

python3 - "$MANIFEST" \
    pin "$DFKI_QUAD_COMMIT" \
    created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    os_id "$os_id" os_version_id "$os_version_id" os_pretty_name "$os_pretty" \
    kernel "$kernel" \
    docker "$docker_version" \
    image_id "$image_id" \
    container_os "$container_os" \
    ros_distro "$ros_distro" \
    ros_base "$ros_base" \
    drake "$drake" \
    drake_source "$drake_source" \
    packages_file "$(basename "$PKG_FILE")" packages_count "$pkg_count" packages_sha256 "$pkg_sha" \
    project_commit "$PROJECT_COMMIT" \
    console_version "$CONSOLE_VERSION" \
    guides_version "$GUIDES_VERSION" \
    provenance "$PROVENANCE" <<'MANIFEST_PY'
import json, os, sys

path = sys.argv[1]
kv = dict(zip(sys.argv[2::2], sys.argv[3::2]))
opt = lambda k: kv.get(k) or None
doc = {
    "schema": "kennel-manifest/1",
    "pin": kv["pin"],
    "created": kv["created"],
    "os": {"id": kv["os_id"], "version_id": kv["os_version_id"],
           "pretty_name": kv["os_pretty_name"]},
    "kernel": kv["kernel"],
    "docker": kv["docker"],
    "image_id": kv["image_id"],
    "container_os": opt("container_os"),
    "ros_distro": opt("ros_distro"),
    "ros_base": opt("ros_base"),
    "drake": opt("drake"),
    "drake_source": kv["drake_source"],
    "packages": {"file": kv["packages_file"], "count": int(kv["packages_count"]),
                 "sha256": kv["packages_sha256"]},
    "project_commit": opt("project_commit"),
    "console_version": opt("console_version"),
    "guides_version": opt("guides_version"),
    "provenance": kv["provenance"],
    "image_sha256": None,
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
MANIFEST_PY
[ "$(jq -r .pin "$MANIFEST")" = "$DFKI_QUAD_COMMIT" ] || { fail "the manifest did not record the pin."; exit 1; }
say "$MANIFEST:"
sed 's/^/    /' "$MANIFEST"
say "packages         $pkg_count in $PKG_FILE"
say "manifest_ref=$(sha256sum "$MANIFEST" | cut -c1-64)"

# --- REGION: phase 10 -- reclaim what does not belong in a frozen disk
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
