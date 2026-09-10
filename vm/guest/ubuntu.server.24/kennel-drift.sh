#!/bin/bash
# Version: 2026.09.10
# Kennel -- issue #75: the appliance's drift check. Compares the live guest with
# the version manifest its baseline froze (#74, ~/kennel-manifest.json) and
# prints one line per deviation.
#
# Runs on the GUEST (kennel-vm), as the guest user, three ways:
#   * fetched and executed by the reset sequence's last step --
#       /usr/local/lib/yuruna/fetch-and-execute.sh project/vm/guest/ubuntu.server.24/kennel-drift.sh
#   * staged to /tmp and run over ssh by `kennel-demo.sh drift` (and by `reset`,
#     `export-image` and `import`, which all refuse a drifted guest);
#   * by hand. It takes NO arguments -- fetch-and-execute passes none -- so every
#     knob is an environment variable.
#
# What is a finding, in the order they are printed:
#
#   pin           the dfki-quad clone is not at the manifest's pin
#   tracked-file  a TRACKED file in the clone differs from the pin. Tracked only,
#                 which is vm/snapshot.md F1: the build stamp and ws/log are
#                 untracked on every healthy guest. An APPLIED COMPOSED RUN IS
#                 DRIFT -- its two YAMLs are tracked files overwritten in place --
#                 and a note below says so rather than hiding it
#   package       a dpkg package added, removed, or at another version than the
#                 manifest's package list (the sidecar beside the manifest)
#   image         the dfki_quad image is not the manifest's, or the container is
#                 absent, or it runs another image
#   build-stamp   ws/.kennel-built-<pin> or ws/install/setup.bash is missing
#   kernel        the running kernel is not the one the manifest names
#
# What is deliberately NOT judged: untracked files; ~/kennel-staging (the
# staging area, which the next `transfer` rewrites and `reset` removes); process
# state (whether the stack or the container is running is a session's business,
# not the environment's); the host.
#
# Output: the DRIFT lines, `note:` lines, then
#   findings=<n> manifest_ref=<sha256 of the manifest's bytes> checked=<UTC>
# and the same as JSON at $KENNEL_DRIFT_OUT, which `kennel-demo.sh drift` copies
# to the host for the console (kennel_console/serve.py, /api/health "drift").
#
# Knobs (environment variables):
#   KENNEL_MANIFEST     ~/kennel-manifest.json   the manifest to compare against
#   KENNEL_DRIFT_OUT    ~/kennel-drift.json      where the JSON report goes
#   DFKI_QUAD_DIR       ~/dfki-quad              the stack clone
#   KENNEL_CONTAINER    dfki_quad
#   KENNEL_IMAGE        dfki_quad                (image and container share the
#                                                 name; see --type container below)
#   KENNEL_STAGING      ~/kennel-staging
#
# Exit codes (stack/verify.md section 1's convention):
#   0  no findings -- this guest is the manifest's environment
#   1  drift -- one DRIFT line per finding above
#   2  could not look: no manifest, a package list that is not the manifest's,
#      no docker, no clone, a missing tool
#
# See vm/drift.md.

set -uo pipefail

MANIFEST="${KENNEL_MANIFEST:-$HOME/kennel-manifest.json}"
OUT_JSON="${KENNEL_DRIFT_OUT:-$HOME/kennel-drift.json}"
DFKI_QUAD_DIR="${DFKI_QUAD_DIR:-$HOME/dfki-quad}"
CONTAINER_NAME="${KENNEL_CONTAINER:-dfki_quad}"
IMAGE_NAME="${KENNEL_IMAGE:-dfki_quad}"
STAGING="${KENNEL_STAGING:-$HOME/kennel-staging}"

fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

FINDINGS=()   # "<class>\t<detail>"
NOTES=()
finding() { FINDINGS+=("$1"$'\t'"$2"); printf 'DRIFT %-13s %s\n' "$1" "$2"; }
note()    { NOTES+=("$1"); echo "note: $1"; }

# --- REGION: preconditions (exit 2: the question cannot be answered)
for tool in jq python3 git sha256sum dpkg-query; do
    command -v "$tool" >/dev/null 2>&1 || {
        fail "'$tool' is not on this guest -- the drift check cannot run without it."
        exit 2
    }
done
[ -r "$MANIFEST" ] || {
    fail "no version manifest at $MANIFEST." \
         "Its baseline predates #74. Re-take the baseline from the HOST:" \
         "  demo/tools/kennel-demo.sh snapshot"
    exit 2
}
jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1 || {
    fail "$MANIFEST is not a JSON object -- it was edited, or truncated."
    exit 2
}
m() { jq -r "$1 // empty" "$MANIFEST"; }
PIN="$(m .pin)"
IMAGE_ID="$(m .image_id)"
KERNEL="$(m .kernel)"
PKG_REL="$(m .packages.file)"
PKG_SHA="$(m .packages.sha256)"
for k in PIN IMAGE_ID KERNEL PKG_REL PKG_SHA; do
    [ -n "${!k}" ] || { fail "the manifest carries no value for '$k' -- it is not a kennel-manifest/1."; exit 2; }
done
PKG_FILE="$(dirname "$MANIFEST")/$PKG_REL"
[ -r "$PKG_FILE" ] || { fail "the manifest's package list $PKG_FILE is missing."; exit 2; }
[ "$(sha256sum "$PKG_FILE" | cut -c1-64)" = "$PKG_SHA" ] || {
    fail "$PKG_FILE is not the package list this manifest recorded (sha256 differs)." \
         "Comparing against it would report the edit, not the guest."
    exit 2
}
sudo docker info >/dev/null 2>&1 || { fail "docker does not answer on this guest."; exit 2; }
[ -d "$DFKI_QUAD_DIR/.git" ] || { fail "no dfki-quad clone at $DFKI_QUAD_DIR."; exit 2; }

REF="$(sha256sum "$MANIFEST" | cut -c1-64)"
echo "manifest         $MANIFEST"
echo "manifest_ref     $REF"
echo "pin              $PIN"

# --- REGION: pin
head="$(git -C "$DFKI_QUAD_DIR" rev-parse HEAD 2>/dev/null || true)"
[ "$head" = "$PIN" ] || finding pin "clone at ${head:-unknown}, manifest pin $PIN"

# --- REGION: tracked files (F1: tracked only)
mapfile -t dirty < <(git -C "$DFKI_QUAD_DIR" status --porcelain --untracked-files=no 2>/dev/null)
for l in "${dirty[@]}"; do
    [ -n "$l" ] && finding tracked-file "$l"
done

# --- REGION: packages
# The same query, filter and sort the prep script recorded the list with, so a
# difference is a difference in the guest and never in the formatting.
now="$(mktemp)"
diffpy="$(mktemp)"
trap 'rm -f "$now" "$diffpy"' EXIT
dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' 2>/dev/null \
    | awk -F'\t' '$3 == "installed" {print $1 "\t" $2}' | LC_ALL=C sort > "$now"
# The comparison is a small Python program written to a temp file and run from there.
cat > "$diffpy" <<'PKG_PY'
import sys

def load(path):
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line:
                name, _, version = line.partition("\t")
                out[name] = version
    return out

was, now = load(sys.argv[1]), load(sys.argv[2])
for name in sorted(set(was) | set(now)):
    if name not in was:
        print("%s %s (added)" % (name, now[name]))
    elif name not in now:
        print("%s %s (removed)" % (name, was[name]))
    elif was[name] != now[name]:
        print("%s (was %s, now %s)" % (name, was[name], now[name]))
PKG_PY
mapfile -t pkgdiff < <(python3 "$diffpy" "$PKG_FILE" "$now")
for l in "${pkgdiff[@]}"; do
    [ -n "$l" ] && finding package "$l"
done

# --- REGION: image and container
# --type container is not optional: the image is ALSO called dfki_quad, so a
# bare `docker inspect` resolves the image and exits 0 (vm/provisioning.md 5a).
img="$(sudo docker image inspect -f '{{.Id}}' "$IMAGE_NAME:latest" 2>/dev/null || true)"
if [ -z "$img" ]; then
    finding image "image $IMAGE_NAME:latest absent (manifest ${IMAGE_ID#sha256:})"
elif [ "$img" != "$IMAGE_ID" ]; then
    finding image "image $IMAGE_NAME:latest is ${img#sha256:} (manifest ${IMAGE_ID#sha256:})"
fi
cimg="$(sudo docker inspect --type container -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
if [ -z "$cimg" ]; then
    finding image "container $CONTAINER_NAME absent"
elif [ "$cimg" != "$IMAGE_ID" ]; then
    finding image "container $CONTAINER_NAME runs ${cimg#sha256:} (manifest ${IMAGE_ID#sha256:})"
fi

# --- REGION: build stamp
for f in "$DFKI_QUAD_DIR/ws/.kennel-built-$PIN" "$DFKI_QUAD_DIR/ws/install/setup.bash"; do
    [ -f "$f" ] || finding build-stamp "missing $f"
done

# --- REGION: kernel
running="$(uname -r)"
[ "$running" = "$KERNEL" ] || finding kernel "running $running, manifest $KERNEL"

# --- REGION: notes
current="$(cat "$STAGING/current-run" 2>/dev/null || true)"
if [ -n "$current" ]; then
    note "a composed run is applied ($current). Its two YAMLs are tracked files overwritten in place, so an applied run IS drift and is reported above; kennel-demo.sh reset returns them to stock."
fi

# --- REGION: report
CHECKED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$OUT_JSON" "$CHECKED" "$REF" "${#FINDINGS[@]}" "${FINDINGS[@]}" "${NOTES[@]}" <<'REPORT_PY'
import json, os, sys

path, checked, ref, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
rest = sys.argv[5:]
findings = [dict(zip(("class", "detail"), f.split("\t", 1))) for f in rest[:n]]
doc = {"schema": "kennel-drift/1", "checked": checked, "manifest_ref": ref,
       "findings": findings, "notes": rest[n:]}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
REPORT_PY
echo "findings=${#FINDINGS[@]} manifest_ref=$REF checked=$CHECKED"
[ "${#FINDINGS[@]}" -eq 0 ] && exit 0
exit 1
