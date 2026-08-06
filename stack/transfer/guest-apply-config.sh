#!/bin/bash
# Version: 2026.08.06
# Kennel -- issue #20: apply a console-exported run folder to the dfki-quad
# container's config paths, prove the bytes landed, and put the stock files back.
#
# Runs on the GUEST (kennel-vm), not on the host and not in the container. It is
# the guest half of the transfer; kennel-transfer.sh is the host half that scps
# this script and a run folder in and then calls it. It is deliberately
# self-contained and env-driven so that issue #24's Yuruna sequence -- whose only
# verbs are sshExec / sshFetchAndExecute -- can stage a fixture and run it with
# no host-side wrapper at all. See stack/transfer.md section 4 for that contract.
#
# Modes (KENNEL_MODE):
#   apply           place KENNEL_RUN's two YAMLs, then verify (the default)
#   restore-stock   put the pin's stock YAMLs back, then verify
#   status          report what is live right now; changes nothing
#
# Exit codes are distinct on purpose -- each failure mode has a different fix:
#   0  success; every checksum matched
#   1  VERIFICATION failed -- the bytes on the config path are not the bytes
#      asked for. This is the acceptance criterion failing, not a broken guest.
#   2  infrastructure error -- could not even look (no clone, no container, no
#      run folder, unusable arguments)
#   3  pin mismatch -- the run folder or the clone is not the revision this
#      transfer is defined against (override: KENNEL_ALLOW_PIN_MISMATCH=1)
#
# NB: `set -u` is safe HERE, unlike in stack/verify/kennel-verify.sh: this
# script never sources a ROS setup file, so it never trips the unbound
# AMENT_TRACE_SETUP_FILES dereference described in stack/launch.md section 7.

set -uo pipefail

# --- REGION: knobs
MODE="${KENNEL_MODE:-apply}"
RUN="${KENNEL_RUN:-}"
PIN="${KENNEL_PIN:-}"
STAGING="${KENNEL_STAGING:-$HOME/kennel-staging}"
CLONE="${KENNEL_CLONE:-$HOME/dfki-quad}"
CONTAINER="${KENNEL_CONTAINER:-dfki_quad}"
ALLOW_PIN_MISMATCH="${KENNEL_ALLOW_PIN_MISMATCH:-0}"
# Optional: shas computed on the HOST before the copy. When set, they close the
# host->guest hop, so the reported chain is host -> guest -> container rather
# than staging -> container. kennel-transfer.sh always sets them; #24 need not.
EXPECT_SIM_SHA="${KENNEL_EXPECT_SIM_SHA:-}"
EXPECT_CTRL_SHA="${KENNEL_EXPECT_CTRL_SHA:-}"

RUNS_DIR="$STAGING/runs"
BACKUP_ROOT="$STAGING/stock-backup"
CURRENT_MARK="$STAGING/current-run"

# --- REGION: the two files, and every path each one has
# Everything below is derived from (package, filename): the path in the clone,
# the path in the container's source space, and the path the launch file
# actually resolves through get_package_share_directory().
PKGS=(simulator controllers)
FILES=(simulator_params_go2.yaml mit_controller_sim_go2.yaml)

rel_path()       { echo "ws/src/$1/config/$2"; }                       # in the clone
guest_path()     { echo "$CLONE/ws/src/$1/config/$2"; }                # on the guest fs
container_src()  { echo "/root/ros2_ws/src/$1/config/$2"; }            # bind-mounted twin
container_read() { echo "/root/ros2_ws/install/$1/share/$1/config/$2"; }  # what launch reads

say()  { echo "[$MODE] $*"; }
warn() { echo "[$MODE] WARNING: $*" >&2; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

# --- REGION: preconditions
[ -d "$CLONE/.git" ] || {
    fail "no dfki-quad clone at $CLONE -- this guest is not provisioned." \
         "Provision it first (issue #10):" \
         "  /usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.dfki-quad.sh" \
         "Override the location with KENNEL_CLONE=/path/to/dfki-quad"
    exit 2
}

case "$MODE" in
    apply|restore-stock|status) ;;
    *) fail "unknown KENNEL_MODE '$MODE'." "Expected: apply | restore-stock | status"; exit 2 ;;
esac

if [ "$MODE" != "status" ] && [ -z "$PIN" ]; then
    fail "KENNEL_PIN is unset -- the stock backup is keyed on the stack pin." \
         "Pass the SHA from stack/pin.lock:" \
         "  KENNEL_PIN=\$(grep '^commit:' stack/pin.lock | awk '{print \$2}')"
    exit 2
fi

# The container is where the acceptance criterion is checked, so it has to be
# there in every mode. `--type container` is not optional: the IMAGE is also
# called dfki_quad, so a bare `docker inspect` resolves to it and exits 0 with an
# empty .State.Status (vm/provisioning.md section 5a, defect 2).
cstate="$(sudo docker inspect --type container -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"
if [ -z "$cstate" ]; then
    fail "no container named '$CONTAINER' on this guest." \
         "The transfer verifies its work from inside the container, so it cannot proceed." \
         "Create it with the provisioning script (issue #10), or set KENNEL_CONTAINER."
    exit 2
fi
if [ "$cstate" != "running" ]; then
    say "container is '$cstate' -- starting it (no --restart policy, by design)"
    sudo docker start "$CONTAINER" >/dev/null || {
        fail "'sudo docker start $CONTAINER' failed." "Inspect it: sudo docker logs $CONTAINER"
        exit 2
    }
fi

# HEAD drift is a WARNING, never fatal: the stock backup is materialized from the
# pin OBJECT (git show <pin>:<path>), so it is correct whatever HEAD points at.
# The warning exists because a drifted HEAD means restore-stock restores the
# PIN's stock, which is then not the same thing as `git checkout`ing the file.
if [ -n "$PIN" ]; then
    head_sha="$(git -C "$CLONE" rev-parse HEAD 2>/dev/null)"
    [ "$head_sha" = "$PIN" ] || warn "clone HEAD is ${head_sha:-unknown}, stack pin is $PIN --" \
                                     "restore-stock will restore the PIN's stock files, not HEAD's."
fi

# --- REGION: helpers
sha_guest() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
sha_ctr()   { sudo docker exec "$CONTAINER" sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
resolve_ctr() { sudo docker exec "$CONTAINER" readlink -f "$1" 2>/dev/null; }
short() { [ -n "${1:-}" ] && echo "${1:0:8}" || echo "--------"; }

# Materialize stock-backup/<pin>/ from the pin object and prove the
# materialization is exact by comparing git's own blob hash against the file
# written. Idempotent: a complete, verified backup is left alone.
ensure_backup() {
    local dir="$BACKUP_ROOT/$PIN" i pkg file rel want got
    mkdir -p "$dir"
    for i in 0 1; do
        pkg="${PKGS[$i]}"; file="${FILES[$i]}"; rel="$(rel_path "$pkg" "$file")"
        want="$(git -C "$CLONE" rev-parse "$PIN:$rel" 2>/dev/null)"
        if [ -z "$want" ]; then
            fail "the clone cannot produce $rel at pin $PIN." \
                 "The pin object is missing from $CLONE -- fetch it, or re-provision." \
                 "  git -C $CLONE fetch --all && git -C $CLONE cat-file -e $PIN"
            exit 2
        fi
        if [ -f "$dir/$file" ]; then
            got="$(git -C "$CLONE" hash-object "$dir/$file" 2>/dev/null)"
            [ "$got" = "$want" ] && continue
            warn "stock backup for $file did not match the pin's blob -- re-materializing"
        fi
        git -C "$CLONE" show "$PIN:$rel" > "$dir/$file" || {
            fail "could not write the stock backup to $dir/$file." "Disk full? Permissions?"
            exit 2
        }
        got="$(git -C "$CLONE" hash-object "$dir/$file" 2>/dev/null)"
        if [ "$got" != "$want" ]; then
            fail "the stock backup of $file does not hash to the pin's blob." \
                 "expected $want, got ${got:-nothing} -- refusing to trust it."
            exit 1
        fi
        say "stock backup materialized: $file (blob $(short "$want"))"
    done
}

# Replace one config file. Written to a sibling temp and renamed, so a reader
# never sees a half-written YAML. The rename swaps the inode, which is safe:
# colcon's --symlink-install links install/<pkg>/share/<pkg>/config/<file> to the
# SOURCE PATH, not to an inode, so the link still resolves to the new bytes.
place() {
    local src="$1" dst="$2" tmp="$2.kennel-tmp.$$"
    cp -f "$src" "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$dst"
}

# The acceptance criterion, per file: the same sha256 on the host (when given),
# in the staging copy, on the guest filesystem, at the container's source path,
# and at the path the launch file actually reads -- plus the proof that the last
# of those is the symlink-install link into the source tree, which is why no
# rebuild is needed.
verify_all() {
    local ref_dir="$1" label="$2" rc=0 i pkg file want gsha csrc cread link expect
    printf '\n  %-30s %-9s %-9s %-9s %-9s %s\n' file staging guest ctr-src ctr-read result
    printf '  %-30s %-9s %-9s %-9s %-9s %s\n' \
        "------------------------------" --------- --------- --------- --------- ------
    for i in 0 1; do
        pkg="${PKGS[$i]}"; file="${FILES[$i]}"
        want="$(sha_guest "$ref_dir/$file")"
        gsha="$(sha_guest "$(guest_path "$pkg" "$file")")"
        csrc="$(sha_ctr  "$(container_src "$pkg" "$file")")"
        cread="$(sha_ctr "$(container_read "$pkg" "$file")")"
        link="$(resolve_ctr "$(container_read "$pkg" "$file")")"

        local result=OK
        [ -n "$want" ] || { result="NO-REF"; rc=1; }
        [ "$gsha"  = "$want" ] || { result=MISMATCH; rc=1; }
        [ "$csrc"  = "$want" ] || { result=MISMATCH; rc=1; }
        [ "$cread" = "$want" ] || { result=MISMATCH; rc=1; }
        [ "$link"  = "$(container_src "$pkg" "$file")" ] || { result=NOT-SYMLINKED; rc=1; }

        # The host's own sha, when the wrapper computed one before copying.
        if [ "$i" = 0 ]; then expect="$EXPECT_SIM_SHA"; else expect="$EXPECT_CTRL_SHA"; fi
        if [ -n "$expect" ] && [ "$expect" != "$want" ]; then
            result=HOST-DIFFERS; rc=1
        fi

        printf '  %-30s %-9s %-9s %-9s %-9s %s\n' \
            "$file" "$(short "$want")" "$(short "$gsha")" "$(short "$csrc")" "$(short "$cread")" "$result"
        # Detail goes to stdout, not stderr, so the table and its explanation
        # stay in order when this is relayed over SSH into a run log.
        if [ "$result" != OK ]; then
            echo "      reference ($label) ${want:-MISSING}"
            echo "      guest     $(guest_path "$pkg" "$file")  ${gsha:-MISSING}"
            echo "      ctr src   $(container_src "$pkg" "$file")  ${csrc:-MISSING}"
            echo "      ctr read  $(container_read "$pkg" "$file")  ${cread:-MISSING}"
            echo "      resolves  ${link:-NOTHING}"
            [ -n "$expect" ] && echo "      host      $expect"
        fi
    done
    echo
    return $rc
}

# --- REGION: modes
case "$MODE" in

apply)
    [ -n "$RUN" ] || {
        fail "KENNEL_MODE=apply needs KENNEL_RUN (the run folder name under $RUNS_DIR)." \
             "Available: $(ls "$RUNS_DIR" 2>/dev/null | tr '\n' ' ')"
        exit 2
    }
    run_dir="$RUNS_DIR/$RUN"
    [ -d "$run_dir" ] || {
        fail "no run folder at $run_dir." \
             "Copy one in first (kennel-transfer.sh does this), or fix KENNEL_RUN." \
             "Available: $(ls "$RUNS_DIR" 2>/dev/null | tr '\n' ' ')"
        exit 2
    }
    for f in "${FILES[@]}"; do
        [ -f "$run_dir/$f" ] || {
            fail "the run folder is missing $f." \
                 "A console export (issue #19) always carries both YAMLs; this folder is" \
                 "not one, or was edited. Re-export rather than hand-assembling it."
            exit 2
        }
    done

    # run.json is provenance, not config -- but the pin it records is a contract.
    # A folder generated against another revision produces YAML whose keys have
    # no defined meaning at this stack.
    if [ -f "$run_dir/run.json" ]; then
        rj_pin="$(sed -n 's/.*"pin"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$run_dir/run.json" | head -1)"
        if [ -n "$rj_pin" ] && [ "$rj_pin" != "$PIN" ]; then
            if [ "$ALLOW_PIN_MISMATCH" = 1 ]; then
                warn "run.json pin $rj_pin != stack pin $PIN -- proceeding, override is set."
            else
                fail "run.json was generated against pin $rj_pin, this stack is $PIN." \
                     "Re-export from a console serving the current pin, or override with:" \
                     "  KENNEL_ALLOW_PIN_MISMATCH=1"
                exit 3
            fi
        fi
    else
        warn "no run.json in $run_dir -- provenance unchecked (the two YAMLs are present)."
    fi

    ensure_backup

    say "applying run '$RUN'"
    for i in 0 1; do
        pkg="${PKGS[$i]}"; file="${FILES[$i]}"
        place "$run_dir/$file" "$(guest_path "$pkg" "$file")" || {
            fail "could not write $(guest_path "$pkg" "$file")." "Permissions? Disk full?"
            exit 2
        }
        say "  -> $(container_src "$pkg" "$file")"
    done

    if verify_all "$run_dir" "run folder $RUN"; then
        echo "$RUN" > "$CURRENT_MARK"
        say "OK -- the container's config paths carry run '$RUN'."
        say "The stack reads these at LAUNCH; relaunch for them to take effect (stack/launch.md section 1)."
        exit 0
    fi
    fail "the configs on the container's paths are NOT the run folder's bytes." \
         "Nothing was rolled back -- inspect the table above, then either re-run" \
         "the apply or return to a known state with KENNEL_MODE=restore-stock."
    exit 1
    ;;

restore-stock)
    # Materialize from git if the backup is absent: the source of truth for
    # "stock" is the pin object, not a file some earlier apply happened to save.
    # That makes restore-stock work on a guest where apply never ran.
    ensure_backup
    dir="$BACKUP_ROOT/$PIN"

    say "restoring the stock configs at pin $PIN"
    for i in 0 1; do
        pkg="${PKGS[$i]}"; file="${FILES[$i]}"
        place "$dir/$file" "$(guest_path "$pkg" "$file")" || {
            fail "could not write $(guest_path "$pkg" "$file")." "Permissions? Disk full?"
            exit 2
        }
        say "  -> $(container_src "$pkg" "$file")"
    done

    if verify_all "$dir" "stock at $PIN"; then
        rm -f "$CURRENT_MARK"
        say "OK -- the baseline is back on the container's config paths."
        exit 0
    fi
    fail "the configs on the container's paths are NOT the pin's stock bytes." \
         "Inspect the table above. The clone can always regenerate them:" \
         "  git -C $CLONE show $PIN:ws/src/simulator/config/simulator_params_go2.yaml"
    exit 1
    ;;

status)
    live="$(cat "$CURRENT_MARK" 2>/dev/null)"
    say "staging     $STAGING"
    say "clone       $CLONE (HEAD $(git -C "$CLONE" rev-parse --short HEAD 2>/dev/null))"
    say "container   $CONTAINER ($cstate)"
    say "applied run ${live:-<none -- stock, or never applied>}"
    say "runs staged $(ls "$RUNS_DIR" 2>/dev/null | tr '\n' ' ')"

    printf '\n  %-30s %-9s %-9s %-9s %s\n' file guest ctr-src ctr-read matches
    printf '  %-30s %-9s %-9s %-9s %s\n' \
        "------------------------------" --------- --------- --------- -------
    for i in 0 1; do
        pkg="${PKGS[$i]}"; file="${FILES[$i]}"
        gsha="$(sha_guest "$(guest_path "$pkg" "$file")")"
        csrc="$(sha_ctr  "$(container_src "$pkg" "$file")")"
        cread="$(sha_ctr "$(container_read "$pkg" "$file")")"
        match="unknown"
        # Compare against every reference this guest can name, cheapest first.
        for cand_dir in "$BACKUP_ROOT"/*/ "$RUNS_DIR"/*/; do
            [ -f "$cand_dir/$file" ] || continue
            if [ "$(sha_guest "$cand_dir/$file")" = "$gsha" ]; then
                case "$cand_dir" in
                    "$BACKUP_ROOT"/*) match="stock@$(basename "$cand_dir" | cut -c1-8)" ;;
                    *)                match="$(basename "$cand_dir")" ;;
                esac
                break
            fi
        done
        printf '  %-30s %-9s %-9s %-9s %s\n' \
            "$file" "$(short "$gsha")" "$(short "$csrc")" "$(short "$cread")" "$match"
    done
    echo
    exit 0
    ;;
esac
