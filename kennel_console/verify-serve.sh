#!/usr/bin/env bash
# Verify the console prototype serves and boots with no network.
#
# Issue #16. Run from anywhere:  ./kennel_console/verify-serve.sh [port]
#
# Checks, in order:
#   1. the vendored runtime matches the SRI hashes pinned in support.js
#   2. nothing the browser loads points off-host
#   3. every asset is served over HTTP
#   4. (if google-chrome is present) the page renders with all DNS blocked
#
# Exit 0 = the documented serve command gives a working, offline-capable console.
#
# KENNEL_SERVE_CMD picks the server (issue #56). Default is the historical
# `python3 -m http.server`, which is what the offline claim in serve.md was
# proven on and stays the thing this suite defends. Point it at serve.py to
# assert the same properties of the server the driver now starts:
#
#   KENNEL_SERVE_CMD='python3 kennel_console/serve.py --port PORT' \
#     ./kennel_console/verify-serve.sh
#
# PORT in the string is replaced with the port. The command must serve
# kennel_console/ at the docroot and must not need arguments after it.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-8000}"
PAGE="Kennel%20Console.dc.html"
fail=0
ok()   { printf '  [ OK ] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; fail=1; }

echo "1. vendored runtime vs the SRI hashes pinned in support.js"
# The hashes are read from support.js itself, so this cannot drift from the pin.
while read -r url sri; do
  file="$DIR/vendor/$(basename "$url")"
  if [[ ! -f "$file" ]]; then bad "missing $(basename "$file")"; continue; fi
  got="sha384-$(openssl dgst -sha384 -binary "$file" | openssl base64 -A)"
  if [[ "$got" == "$sri" ]]; then ok "$(basename "$file")"
  else bad "$(basename "$file") — expected $sri, got $got"; fi
done < <(grep -oE 'var [A-Z_]+_URL = "[^"]+";|var [A-Z_]+_SRI = "[^"]+";' "$DIR/support.js" \
         | grep -oE '"[^"]+"' | tr -d '"' | paste - -)

echo "2. no off-host references in what the browser loads"
if grep -qE 'src="https?://|href="https?://' "$DIR/Kennel Console.dc.html"; then
  bad "Kennel Console.dc.html still loads something over the network:"
  grep -oE '(src|href)="https?://[^"]*"' "$DIR/Kennel Console.dc.html" | sed 's/^/         /'
else
  ok "Kennel Console.dc.html loads only local assets"
fi
if grep -qE 'url\(https?://' "$DIR/vendor/fonts/plex.css"; then
  bad "vendor/fonts/plex.css still points at Google Fonts"
else
  ok "vendor/fonts/plex.css points at local woff2 only"
fi

echo "3. every asset is served over HTTP on :$PORT"
SERVE_CMD="${KENNEL_SERVE_CMD:-python3 -m http.server PORT --directory $DIR}"
echo "  [ -- ] server: ${SERVE_CMD//PORT/$PORT}"
# Word-split on purpose: the knob is a command line, not a path.
# shellcheck disable=SC2086
${SERVE_CMD//PORT/$PORT} >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 20); do
  curl -sf -o /dev/null "http://localhost:$PORT/$PAGE" && break || sleep 0.25
done
assets=("$PAGE" support.js vendor/react.production.min.js
        vendor/react-dom.production.min.js vendor/babel.min.js vendor/fonts/plex.css)
while IFS= read -r f; do assets+=("vendor/fonts/$f"); done \
  < <(cd "$DIR/vendor/fonts" && ls ./*.woff2 | sed 's|^\./||')
for a in "${assets[@]}"; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/$a")"
  [[ "$code" == 200 ]] && ok "200  $a" || bad "$code  $a"
done

echo "4. headless render with all external DNS blocked"
if command -v google-chrome >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  timeout 120 google-chrome --headless --disable-gpu --no-sandbox \
    --user-data-dir="$tmp/profile" \
    --host-resolver-rules="MAP * ~NOTFOUND, EXCLUDE localhost" \
    --virtual-time-budget=20000 --dump-dom \
    "http://localhost:$PORT/$PAGE" > "$tmp/dom.html" 2>/dev/null
  # Un-booted, the page is the raw <x-dc> template: mustaches and sc-* elements
  # survive into the DOM. Booted, React has replaced all of them.
  if grep -q 'Compose experiment' "$tmp/dom.html" && ! grep -q '{{' "$tmp/dom.html"; then
    ok "console booted offline, Compose view rendered, 0 unresolved placeholders"
  else
    bad "console did not boot offline ($(grep -c '{{' "$tmp/dom.html") unresolved placeholders)"
  fi
  rm -rf "$tmp"
else
  echo "  [SKIP] google-chrome not installed — steps 1-3 still prove the assets"
fi

echo
[[ $fail -eq 0 ]] && echo "PASS — one command serves an offline-capable console." \
                  || echo "FAIL — see above."
exit $fail
