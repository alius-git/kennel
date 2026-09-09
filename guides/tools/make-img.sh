#!/usr/bin/env bash
# Version: 2026.09.09
# Build guides/img/ from renders that already exist in this repository (#73).
#
# WHERE IT RUNS: HOST, from anywhere -- it resolves the repository root itself.
#
#   guides/tools/make-img.sh [--check]
#
# Every picture in the guides is a REAL render of the console or of Meshcat,
# produced by a suite or a scenario verb on the live stack and committed under
# kennel_console/ or demo/evidence/. Nothing here is drawn, mocked up or
# re-staged: a guide that illustrated itself with an invented screenshot would
# be teaching a console that does not exist.
#
# Two kinds of row, and the difference matters:
#
#   COPY  a whole page, copied byte for byte -- so git stores no new blob for it
#         (the deck under slides/ does the same with its images)
#   CROP  one panel, cut out of a whole-page render with PIL at the box below.
#         The boxes were measured once on the 1500x807 and 1600x857 renders the
#         scenario verbs and dashboard-shot.sh produce; --check re-asserts every
#         source's size before cropping, so a re-render at another window size
#         fails here rather than silently producing a picture of the wrong panel.
#
# The table IS the record: kennel_console/guides.md quotes it, and
# verify-guides.py group 6 parses it out of this file to assert that every image
# a guide references exists and has the size claimed here.
#
#   --check   verify only: sources present and the right size, targets present
#             and the right size. Writes nothing. This is what a suite runs.
#
# Needs python3 with PIL (Pillow) for the crops -- `apt install python3-pil`.
#
# Exit codes:
#   0  every image was written (or, with --check, is present and correct)
#   1  a check failed
#   2  could not even look: no PIL, a missing source render

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
IMG="$REPO_ROOT/guides/img"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
[ $# -gt 1 ] && { echo "usage: make-img.sh [--check]" >&2; exit 2; }

say()  { echo "[make-img] $*"; }
fail() { echo "NONZERO SCRIPT EXIT: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; }

python3 -c "import PIL" 2>/dev/null || {
    fail "python3 with PIL (Pillow) is required for the crops." \
         "Debian/Ubuntu:  sudo apt install python3-pil"; exit 2; }

# --- REGION: the table. source | target | WxH of the target | box (crop only)
#
# COPY rows carry no box: the target is the source, byte for byte, and its size
# is the source's.
TABLE="
kennel_console/composer-scope-render.png|compose.png|1400x900|
kennel_console/send-render.png|send.png|1400x757|
demo/evidence/07-meshcat-walking.png|meshcat-walking.png|1280x657|
kennel_console/dashboard-render.png|dashboard.png|1600x857|
kennel_console/teleop-render.png|teleop.png|1500x797|
kennel_console/runs-render.png|runs.png|1600x857|
demo/evidence/s004-disturb/05-renders/04-reset.png|reset.png|1500x807|
demo/evidence/s003-diagnose/05-renders/02-amber-attempt2.png|panel-health-amber.png|512x212|980,188,1492,400
demo/evidence/s003-diagnose/05-renders/03-red-attempt2.png|panel-health-red.png|512x212|980,188,1492,400
demo/evidence/s003-diagnose/05-renders/03-red-attempt2.png|panel-counters.png|512x182|980,403,1492,585
demo/evidence/s003-diagnose/05-renders/03-red-attempt2.png|panel-feed-pinned.png|512x202|980,590,1492,792
demo/evidence/s003-diagnose/05-renders/03-red-attempt2.png|banner.png|1315x33|178,5,1493,38
kennel_console/dashboard/evidence/05-timeline.png|panel-timeline.png|850x205|182,400,1032,605
kennel_console/dashboard/evidence/04-live.png|panel-plots.png|850x205|182,613,1032,818
kennel_console/dashboard-render.png|statusbar.png|1420x29|180,828,1600,857
"

mkdir -p "$IMG"
rc=0
n=0
while IFS='|' read -r src target size box; do
    [ -z "${src:-}" ] && continue
    n=$((n + 1))
    abs="$REPO_ROOT/$src"
    [ -f "$abs" ] || { fail "no such render: $src" "It is the source of guides/img/$target."; rc=2; continue; }
    out="$IMG/$target"
    if [ "$CHECK" = 1 ]; then
        [ -f "$out" ] || { echo "  [FAIL] $target missing -- run guides/tools/make-img.sh"; rc=1; continue; }
        got="$(python3 -c "from PIL import Image;i=Image.open('$out');print('%dx%d'%i.size)")"
        if [ "$got" = "$size" ]; then echo "  [ ok ] $target  $got  <- $src"
        else echo "  [FAIL] $target is $got, the table says $size"; rc=1; fi
        continue
    fi
    if [ -z "${box:-}" ]; then
        cp "$abs" "$out" || { rc=1; continue; }
    else
        python3 - "$abs" "$out" "$box" <<'PY' || rc=1
import sys
from PIL import Image
src, out, box = sys.argv[1], sys.argv[2], tuple(int(v) for v in sys.argv[3].split(","))
im = Image.open(src)
if box[2] > im.size[0] or box[3] > im.size[1]:
    print("NONZERO SCRIPT EXIT: %s is %dx%d, the box %s does not fit"
          % (src, im.size[0], im.size[1], box), file=sys.stderr)
    raise SystemExit(1)
im.crop(box).save(out)
PY
    fi
    got="$(python3 -c "from PIL import Image;i=Image.open('$out');print('%dx%d'%i.size)" 2>/dev/null)"
    if [ "$got" = "$size" ]; then say "$target  $got  <- $src${box:+  crop $box}"
    else fail "$target came out $got, the table says $size" \
              "The source render's size changed -- re-measure the box, do not edit the size."; rc=1; fi
done <<< "$TABLE"

echo
[ "$rc" = 0 ] && echo "[make-img] $n images, all as the table says" \
              || echo "[make-img] $n images, some wrong -- see above"
exit $rc
