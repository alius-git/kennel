#!/usr/bin/env python3
"""Serve the Kennel Console and accept the run folder it exports. 2026-08-30.

WHERE IT RUNS: HOST (the machine with the browser), from the repository root or
anywhere -- it resolves its own directory.

    python3 kennel_console/serve.py [--port 8000] [--out ~/kennel-runs] [--dir DIR]
                                    [--bridge ws://GUEST:9090/]

    demo/tools/kennel-demo.sh console      # what actually starts it

Everything `python3 -m http.server --directory kennel_console` did, unchanged --
same URLs, same directory listing, same %20 in the page name (serve.md section 1)
-- plus three endpoints that let the console write its run folder where
`kennel-demo.sh run` already reads:

    GET  /api/health   {"kennel": true, "out": "<abs run dir>", "pin": "<sha>",
                        "bridge": "<ws url>"|null, "meshcat": "<http url>"|null}
    POST /api/runs     body = the export archive; writes run-<stamp>/ under --out
    GET  /api/runs     the run folders present, newest first

The console feature-detects /api/health and shows its `send to kennel-runs`
button only when this server answers, so plain http.server still serves the same
files to the same console (send.md section 2).

Stdlib only -- no dependencies beyond a Python 3 (serve.md section 1) -- and
bound to localhost: nothing here should be reachable off the host, and this one
writes to disk.

EXIT CODES
    0  clean shutdown (Ctrl-C)
    2  could not start: no such --dir, port in use, unwritable --out
"""
import argparse
import hashlib
import io
import json
import os
import re
import shutil
import sys
import zipfile
from datetime import datetime, timezone
from http.server import HTTPServer, SimpleHTTPRequestHandler

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
PIN_LOCK = os.path.join(REPO_ROOT, "stack", "pin.lock")

# The four files a console export carries (export.md section 1). The stack reads
# only the two YAMLs; a folder missing either of the other two is not an export.
ARTIFACT_NAMES = ("simulator_params_go2.yaml", "mit_controller_sim_go2.yaml",
                  "commands.txt", "run.json")

# What stampNow() emits: 'run-' + an ISO-8601 UTC instant with the punctuation
# stripped (export.md section 2.4). Matching the full shape rather than a `run-*`
# glob is what makes a path traversal structurally impossible on a POST that
# writes: no separator, no dot, no absolute path can satisfy it.
RUN_DIR_RE = re.compile(r"^run-[0-9]{8}T[0-9]{6}Z$")

# A run is ~10 kB. The cap exists so a mis-POSTed disk image is refused at the
# header rather than buffered.
MAX_UPLOAD = 8 * 1024 * 1024

# Where `kennel-demo.sh teleop` leaves the URLs it discovered, one line each,
# under --out. This server never runs virsh and never shells out: discovery
# belongs to the driver, which already knows the guest, and this process stays
# stdlib-only and localhost-bound (send.md section 7). Read per REQUEST, not at
# startup, so starting a bridge does not mean restarting a console the operator
# already has open.
BRIDGE_FILE = ".kennel-bridge"
MESHCAT_FILE = ".kennel-meshcat"

# A URL this server hands to the page, which will open a WebSocket to it. Only
# the two schemes that can mean anything here, and nothing with a control
# character or whitespace -- the file is written by the driver, but a stray edit
# should fail closed rather than become an attribute in the page.
URL_RE = re.compile(r"^(?:wss?|https?)://[A-Za-z0-9.:_@\[\]-]+(?:/[^\s\x00-\x1f]*)?$")


def side_channel(out_dir, name):
    """First line of <out>/<name>, when it is a plausible URL. None otherwise.

    Absent is the normal case: no teleop verb has run, so the console shows no
    bridge controls -- exactly as it behaves under plain http.server.
    """
    try:
        with open(os.path.join(out_dir, name), encoding="utf-8") as f:
            value = f.readline().strip()
    except OSError:
        return None
    return value if value and URL_RE.match(value) else None


def host_pin():
    """The stack pin, read from stack/pin.lock the way kennel-transfer.sh does.

    None when the file is absent or carries no `commit:` -- served as a null pin
    in /api/health and as a refusal on POST, never as a silent pass.
    """
    try:
        with open(PIN_LOCK, encoding="utf-8") as f:
            for line in f:
                if line.startswith("commit:"):
                    value = line.split(":", 1)[1].strip()
                    return value or None
    except OSError:
        return None
    return None


class Refused(Exception):
    """A validated refusal: an HTTP status and the lines the operator needs."""

    def __init__(self, status, *lines):
        super().__init__(lines[0] if lines else "refused")
        self.status = status
        self.lines = list(lines)


def validate_archive(raw, out_dir, pin):
    """Everything that can refuse a POST, before a single byte is written.

    Returns (run_name, [(name, bytes)]). Raises Refused otherwise. The order is
    deliberate: shape first, then meaning, then the destination -- so a wrong-pin
    archive is told about its pin rather than about a directory that exists.
    """
    if pin is None:
        raise Refused(500, "this server cannot read the stack pin from " + PIN_LOCK,
                      "Without it a run's provenance cannot be checked. Nothing was written.")
    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except (zipfile.BadZipFile, OSError) as exc:
        raise Refused(400, "the body is not a readable zip archive (%s)." % exc,
                      "The console posts the same archive `generate run` downloads.")

    infos = [i for i in zf.infolist() if not i.filename.endswith("/")]
    for info in infos:
        # STORED is not a shortcut, it is the fidelity contract (export.md
        # section 2.2): the YAML bytes sit in the archive uncompressed and
        # literal, so what lands on disk is what the emitter produced.
        if info.compress_type != zipfile.ZIP_STORED:
            raise Refused(400, "entry '%s' is compressed; a console export is STORED only." % info.filename,
                          "See kennel_console/export.md section 2.2.")

    prefixes = {i.filename.split("/")[0] for i in infos}
    if len(prefixes) != 1:
        raise Refused(400, "the archive holds %d top-level entries: %s"
                      % (len(prefixes), ", ".join(sorted(prefixes))),
                      "A console export is exactly one run-<stamp>/ folder.")
    run = prefixes.pop()
    if not RUN_DIR_RE.match(run):
        raise Refused(400, "top-level entry '%s' is not a run-<stamp>/ folder." % run,
                      "Expected the shape run-YYYYMMDDTHHMMSSZ, as stampNow() emits.")

    got = sorted(i.filename for i in infos)
    want = sorted("%s/%s" % (run, n) for n in ARTIFACT_NAMES)
    if got != want:
        missing = [n for n in want if n not in got]
        extra = [n for n in got if n not in want]
        detail = []
        if missing:
            detail.append("missing: " + ", ".join(missing))
        if extra:
            detail.append("unexpected: " + ", ".join(extra))
        raise Refused(400, "the archive is not a console export (%d entries, expected 4)." % len(got),
                      "; ".join(detail))

    files = []
    for name in ARTIFACT_NAMES:
        try:
            # ZipFile.read() checks the CRC-32 as it reads, so a corrupt entry
            # is refused here rather than written and discovered by the guest.
            files.append((name, zf.read("%s/%s" % (run, name))))
        except (zipfile.BadZipFile, OSError) as exc:
            raise Refused(400, "entry '%s/%s' does not read back (%s)." % (run, name, exc),
                          "Its CRC-32 does not match its bytes. Re-export.")

    body = dict(files)["run.json"]
    try:
        meta = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise Refused(400, "run.json does not parse as UTF-8 JSON (%s)." % exc)
    run_pin = meta.get("pin")
    if run_pin != pin:
        # Same refusal kennel-transfer.sh makes at exit 3, in the same words:
        # a run composed against another revision has no defined meaning here.
        raise Refused(409, "this run was generated against pin %s, the stack is pinned at %s."
                      % (run_pin, pin),
                      "Its keys have no defined meaning at this revision. Re-export from a",
                      "console served at the stack pin.")

    target = os.path.join(out_dir, run)
    if os.path.exists(target):
        raise Refused(409, "%s already exists." % target,
                      "Two exports one second apart share a stamp. Compose again, or move the",
                      "existing folder aside.")
    return run, files


def write_run(out_dir, run, files, raw):
    """Write the folder, then keep the archive beside it. Never partial.

    The archive is kept because it is the artifact the console actually produced:
    the folder is this server's rendering of it, and provenance that cannot be
    re-checked is not provenance.
    """
    target = os.path.join(out_dir, run)
    # exist_ok=False deliberately: the check in validate_archive is a courtesy
    # message, this is the guard. Two POSTs in the same second lose the race
    # here rather than interleaving files.
    os.makedirs(target, exist_ok=False)
    try:
        digests = {}
        for name, data in files:
            with open(os.path.join(target, name), "wb") as f:
                f.write(data)
            digests[name] = hashlib.sha256(data).hexdigest()
        with open(os.path.join(out_dir, run + ".zip"), "wb") as f:
            f.write(raw)
    except OSError:
        shutil.rmtree(target, ignore_errors=True)
        raise
    return target, digests


def list_runs(out_dir):
    """The run folders present, newest first -- what `status` and a Runs view ask."""
    runs = []
    try:
        names = os.listdir(out_dir)
    except OSError:
        return runs
    for name in names:
        path = os.path.join(out_dir, name)
        if not RUN_DIR_RE.match(name) or not os.path.isdir(path):
            continue
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            continue
        present = sorted(n for n in ARTIFACT_NAMES if os.path.isfile(os.path.join(path, n)))
        runs.append({
            "run": name,
            "path": path,
            "modified": datetime.fromtimestamp(mtime, timezone.utc)
                                .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "files": present,
            "complete": len(present) == len(ARTIFACT_NAMES),
            "_t": mtime,
        })
    runs.sort(key=lambda r: r["_t"], reverse=True)
    for r in runs:
        r.pop("_t")
    return runs


class Handler(SimpleHTTPRequestHandler):
    """http.server's handler, plus /api/. Static behaviour is untouched."""

    out_dir = None
    pin = None
    bridge = None          # --bridge / $KENNEL_BRIDGE_URL, overriding the file
    server_version = "KennelConsoleServe/1.0"

    def _json(self, status, payload):
        body = (json.dumps(payload, indent=2) + "\n").encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # The console holds run manifests in localStorage and this server writes
        # to disk: same-origin only, no matter what page asks.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _refusal(self, exc):
        self._json(exc.status, {"error": exc.lines[0], "detail": exc.lines[1:]})
        self.log_message("refused %d %s", exc.status, exc.lines[0])

    def do_GET(self):
        if self.path.split("?")[0] == "/api/health":
            self._json(200, {"kennel": True, "out": self.out_dir, "pin": self.pin,
                             # Resolved per request: `teleop` writes these while
                             # the console is already open, and an operator who
                             # has to restart the server to see a button has been
                             # given a worse version of no button at all.
                             "bridge": self.bridge or side_channel(self.out_dir, BRIDGE_FILE),
                             "meshcat": side_channel(self.out_dir, MESHCAT_FILE)})
            return
        if self.path.split("?")[0] == "/api/runs":
            self._json(200, {"out": self.out_dir, "runs": list_runs(self.out_dir)})
            return
        # Anything else is a file. This is the whole of the static contract.
        SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        if self.path.split("?")[0] != "/api/runs":
            self._json(404, {"error": "no such endpoint: %s" % self.path,
                             "detail": ["POST /api/runs is the only one."]})
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._refusal(Refused(411, "no Content-Length on the POST.",
                                  "The body must be the archive bytes."))
            return
        if length <= 0 or length > MAX_UPLOAD:
            self._refusal(Refused(413, "body is %d bytes; the limit is %d." % (length, MAX_UPLOAD),
                                  "A run folder is a few kilobytes."))
            return
        raw = self.rfile.read(length)
        if len(raw) != length:
            self._refusal(Refused(400, "the body ended early (%d of %d bytes)." % (len(raw), length)))
            return
        try:
            run, files = validate_archive(raw, self.out_dir, self.pin)
        except Refused as exc:
            self._refusal(exc)
            return
        try:
            path, digests = write_run(self.out_dir, run, files, raw)
        except OSError as exc:
            self._refusal(Refused(500, "could not write into %s (%s)." % (self.out_dir, exc)))
            return
        self.log_message("wrote %s", path)
        self._json(201, {"run": run, "path": path, "sha256": digests})

    def log_message(self, fmt, *args):
        """One line per request, on stdout -- the driver tees it to a log file."""
        sys.stdout.write("[serve.py] %s %s\n" % (
            datetime.now(timezone.utc).strftime("%H:%M:%SZ"), fmt % args))
        sys.stdout.flush()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--out", default=os.environ.get("KENNEL_DEMO_OUT")
                    or os.path.join(os.path.expanduser("~"), "kennel-runs"))
    ap.add_argument("--dir", default=HERE, help="docroot (default: kennel_console/)")
    ap.add_argument("--bridge", default=os.environ.get("KENNEL_BRIDGE_URL"),
                    help="rosbridge WebSocket URL to advertise in /api/health "
                         "(default: the first line of <out>/.kennel-bridge, "
                         "which kennel-demo.sh teleop writes)")
    args = ap.parse_args(argv)

    docroot = os.path.abspath(os.path.expanduser(args.dir))
    if not os.path.isdir(docroot):
        print("NONZERO SCRIPT EXIT: no such directory to serve: %s" % docroot, file=sys.stderr)
        return 2
    out_dir = os.path.abspath(os.path.expanduser(args.out))
    try:
        os.makedirs(out_dir, exist_ok=True)
    except OSError as exc:
        print("NONZERO SCRIPT EXIT: cannot use %s as the run directory: %s" % (out_dir, exc),
              file=sys.stderr)
        return 2

    pin = host_pin()
    Handler.out_dir = out_dir
    Handler.pin = pin
    if args.bridge and not URL_RE.match(args.bridge):
        print("NONZERO SCRIPT EXIT: --bridge is not a ws:// or http:// URL: %s" % args.bridge,
              file=sys.stderr)
        return 2
    Handler.bridge = args.bridge

    def handler(*a, **kw):
        return Handler(*a, directory=docroot, **kw)

    try:
        # localhost, not 0.0.0.0 (serve.md section 1) -- and this one writes files.
        httpd = HTTPServer(("127.0.0.1", args.port), handler)
    except OSError as exc:
        print("NONZERO SCRIPT EXIT: cannot bind port %d: %s" % (args.port, exc), file=sys.stderr)
        print("  Something else is already serving there. Set KENNEL_CONSOLE_PORT.", file=sys.stderr)
        return 2

    print("[serve.py] serving %s on http://localhost:%d/" % (docroot, args.port))
    print("[serve.py] run folders -> %s" % out_dir)
    print("[serve.py] stack pin     %s" % (pin or "UNKNOWN -- POST /api/runs will refuse"))
    print("[serve.py] bridge       %s" % (args.bridge or
          ("%s (when kennel-demo.sh teleop has written it)" % os.path.join(out_dir, BRIDGE_FILE))))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[serve.py] stopped")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
