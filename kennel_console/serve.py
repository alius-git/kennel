#!/usr/bin/env python3
"""Serve the Kennel Console, accept the run folder it exports, and serve the guides. 2026-09-09.

WHERE IT RUNS: HOST (the machine with the browser), from the repository root or
anywhere -- it resolves its own directory.

    python3 kennel_console/serve.py [--port 8000] [--out ~/kennel-runs] [--dir DIR]
                                    [--bridge ws://GUEST:9090/] [--guides DIR]

    demo/tools/kennel-demo.sh console      # what actually starts it

Everything `python3 -m http.server --directory kennel_console` did, unchanged --
same URLs, same directory listing, same %20 in the page name (serve.md section 1)
-- plus three endpoints that let the console write its run folder where
`kennel-demo.sh run` already reads:

    GET  /api/health   {"kennel": true, "out": "<abs run dir>", "pin": "<sha>",
                        "bridge": "<ws url>"|null, "meshcat": "<http url>"|null,
                        "guides": [{"name": "first-run.md", "title": "..."}]|null}
    POST /api/runs     body = the export archive; writes run-<stamp>/ under --out
    GET  /api/runs     the run folders present, newest first -- with each run's
                       composed `choices` and, once `kennel-demo.sh verify` has
                       filed one, a summary of its verify report (#64)
    GET  /api/runs/<stamp>/<file>
                       one file out of one run folder: the four export artifacts
                       plus verify.json / verify.txt. Read-only, allow-listed
    GET  /guides/<name>.md      the guide's own bytes (#73)
    GET  /guides/<name>.html    the same file rendered -- the console frames this
    GET  /guides/img/<file>.png one image out of guides/img/

guides/ is OUTSIDE the docroot, so plain http.server cannot serve a guide
however it is asked: the Guides item exists exactly when this server does.

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
import html
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

# What `kennel-demo.sh verify` files beside them (#64): kennel-verify.sh's own
# report, machine-readable and human-readable. Served, never written here -- the
# console composes runs, the driver runs them, and only the driver has a verdict.
REPORT_NAMES = ("verify.json", "verify.txt")

# The only files GET /api/runs/<stamp>/<file> will serve. An allow-list rather
# than a sanitiser: a run folder is a known set of names, so there is nothing to
# sanitise and no path to traverse.
SERVABLE = {n: ("application/json" if n.endswith(".json")
                else "text/plain; charset=utf-8")
            for n in ARTIFACT_NAMES + REPORT_NAMES}
SERVABLE["simulator_params_go2.yaml"] = "text/plain; charset=utf-8"
SERVABLE["mit_controller_sim_go2.yaml"] = "text/plain; charset=utf-8"

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

# ---- The guides (#73) -------------------------------------------------------
#
# guides/ sits OUTSIDE this server's docroot, so `python3 -m http.server
# --directory kennel_console` cannot reach it however it is asked. That is the
# feature-detection rule holding by construction rather than by a flag: served
# any other way the console has no /api/health, no guides list, and no Guides
# item -- exactly what send.md §2.1 and teleop.md §7 do.
#
# The reading order a newcomer needs, then anything else alphabetically -- so
# #77's safety gate and hardware notes land at the end without a code change.
GUIDE_ORDER = ("first-run.md", "walkthrough.md", "diagnosis.md")
# A guide is named in kebab-case and nothing else, and an image is a PNG. Both
# are matched in full and the path is then BUILT from what matched, never joined
# with what the request said -- the reasoning _run_file already applies to a run
# folder: with no separator, no dot and no absolute path able to satisfy either
# pattern, traversal is structurally impossible rather than filtered.
GUIDE_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
GUIDE_IMG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*\.png$")


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


def guide_title(path):
    """A guide's first `# ` line, which is its title. The file name otherwise."""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("# "):
                    return line[2:].strip()
    except OSError:
        pass
    return os.path.basename(path)


def guide_list(guides_dir):
    """What /api/health advertises: the guides present, in reading order.

    None when there is no guides directory -- the same shape `bridge` and
    `meshcat` use for absent, and what the page feature-detects on. Read per
    REQUEST, like the side channels: a guide edited while the console is open
    should show without a restart.
    """
    if not guides_dir or not os.path.isdir(guides_dir):
        return None
    try:
        names = [n for n in os.listdir(guides_dir)
                 if n.endswith(".md") and GUIDE_RE.match(n[:-3])]
    except OSError:
        return None
    ordered = [n for n in GUIDE_ORDER if n in names]
    ordered += sorted(n for n in names if n not in GUIDE_ORDER)
    return [{"name": n, "title": guide_title(os.path.join(guides_dir, n))} for n in ordered]


# ---- Markdown, rendered here and never in the page --------------------------
#
# The console's runtime offers its template no raw-HTML binding, and the page
# paints only canvases through refs; putting a renderer in there would mean
# introducing the one thing the page has never had. It renders here instead,
# where html.escape lives, and the page frames the result exactly as it frames
# Meshcat (dashboard.md §1.1).
#
# A FIXED SUBSET, stdlib only. Every run of text is escaped BEFORE any inline
# rule runs, so nothing a guide contains can become markup; anything the subset
# does not know becomes a paragraph rather than being passed through.
_CODE_RE = re.compile(r"`([^`]+)`")
_IMG_RE = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)\)")
_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
_BOLD_RE = re.compile(r"\*\*([^*]+)\*\*")
_EM_RE = re.compile(r"(?<![*\w])\*([^*\n]+)\*(?!\*)")
_MD_LINK_RE = re.compile(r"^([a-z0-9][a-z0-9-]*)\.md(#[A-Za-z0-9_-]+)?$")
_HTTP_RE = re.compile(r"^https?://")


def _anchor(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def _inline(text):
    """One line of prose: escaped, then the inline subset, code spans first.

    Code spans are lifted out before anything else runs, so `**not bold**`
    inside backticks stays literal -- and so a guide can show the markup it is
    teaching without the renderer eating it.
    """
    spans = []

    def keep(m):
        spans.append(html.escape(m.group(1)))
        return "\x00%d\x00" % (len(spans) - 1)

    text = _CODE_RE.sub(keep, text)
    text = html.escape(text)

    def image(m):
        alt, src = m.group(1), m.group(2)
        # Only the guides' own image directory. Anything else is not an image
        # this server can serve, so it is shown as the path it is.
        if not src.startswith("img/") or not GUIDE_IMG_RE.match(src[4:]):
            return "<code>%s</code>" % html.escape(src)
        return '<img src="%s" alt="%s">' % (html.escape(src), html.escape(alt))

    def link(m):
        label, href = m.group(1), m.group(2)
        md = _MD_LINK_RE.match(href)
        if md:
            # Guides link to each other, and the frame navigates within them.
            return '<a href="%s.html%s">%s</a>' % (md.group(1), md.group(2) or "", label)
        if _HTTP_RE.match(href):
            return '<a href="%s" target="_blank" rel="noopener">%s</a>' % (html.escape(href), label)
        if href.startswith("#"):
            return '<a href="%s">%s</a>' % (html.escape(href), label)
        # A repo path. The console serves the console and the guides, and
        # nothing else -- a link here would 404 in the frame and look like a
        # broken guide, so it is rendered as what it is: a path to type.
        return label if label == href else "%s (<code>%s</code>)" % (label, html.escape(href))

    text = _IMG_RE.sub(image, text)
    text = _LINK_RE.sub(link, text)
    text = _BOLD_RE.sub(lambda m: "<strong>%s</strong>" % m.group(1), text)
    text = _EM_RE.sub(lambda m: "<em>%s</em>" % m.group(1), text)
    return re.sub(r"\x00(\d+)\x00", lambda m: "<code>%s</code>" % spans[int(m.group(1))], text)


GUIDE_CSS = """
:root{color-scheme:dark}
body{margin:0;padding:26px 30px 60px;background:#0a0d12;color:#dbe2ea;
  font:400 14px/1.65 'IBM Plex Sans',system-ui,sans-serif;max-width:900px}
h1{font:600 22px 'IBM Plex Sans';margin:0 0 6px}
h2{font:600 16px 'IBM Plex Sans';margin:30px 0 8px;padding-top:14px;border-top:1px solid #1b222c}
h3{font:600 13px 'IBM Plex Sans';margin:20px 0 6px;color:#c3ccd6}
p{margin:9px 0}
a{color:#8fc9ea;text-decoration:none}
a:hover{text-decoration:underline}
code{font:400 12px 'IBM Plex Mono',ui-monospace,monospace;background:#12181f;
  border:1px solid #1f2731;border-radius:3px;padding:1px 5px;color:#c3ccd6}
pre{background:#0f141b;border:1px solid #1f2731;border-radius:6px;padding:12px 14px;
  overflow-x:auto;margin:10px 0}
pre code{background:none;border:0;padding:0;color:#8fc9ea;font-size:12px}
.click{background:#101a24;border:1px solid #2f5d78;border-left-width:3px;border-radius:5px;
  padding:10px 14px;margin:10px 0}
.click .lead{font:500 10px 'IBM Plex Mono';letter-spacing:.06em;text-transform:uppercase;
  color:#6f7a88;margin-bottom:5px}
.click div.step{font:500 13px 'IBM Plex Mono';color:#dbe2ea}
table{border-collapse:collapse;margin:12px 0;font-size:13px;display:block;overflow-x:auto}
th{text-align:left;font:600 10px 'IBM Plex Mono';letter-spacing:.06em;text-transform:uppercase;
  color:#9aa5b1;border-bottom:1px solid #2b3543;padding:6px 12px 6px 0}
td{border-bottom:1px solid #161d26;padding:6px 12px 6px 0;vertical-align:top}
blockquote{margin:12px 0;padding:2px 0 2px 14px;border-left:2px solid #2b3543;color:#a8b3c0}
ul,ol{margin:9px 0;padding-left:22px}
li{margin:4px 0}
img{max-width:100%;border:1px solid #1f2731;border-radius:6px;margin:10px 0;display:block}
hr{border:0;border-top:1px solid #1b222c;margin:26px 0}
.nav{font:400 11px 'IBM Plex Mono';color:#6f7a88;margin-bottom:20px}
.nav a{margin-right:14px}
"""


def render_md(text, name, guides):
    """One guide as a page. The subset is fixed and everything else is a
    paragraph -- a renderer that guessed would eventually guess wrong about a
    document this repo asks people to follow literally."""
    out, i = [], 0
    lines = text.split("\n")
    title = name

    def flush_para(buf):
        if buf:
            out.append("<p>%s</p>" % _inline(" ".join(buf)))
            buf.clear()

    para = []
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if stripped.startswith("```"):
            lang = stripped[3:].strip().lower()
            i += 1
            body = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1
            flush_para(para)
            if lang == "click":
                # What a person does in the console rather than in a terminal.
                # The same fence the s001 verb executes, so the reader and the
                # audit are looking at one file (demo/scenarios.md §6).
                steps = "".join('<div class="step">%s</div>' % html.escape(b.strip())
                                for b in body if b.strip())
                out.append('<div class="click"><div class="lead">in the console</div>%s</div>' % steps)
            else:
                out.append('<pre><code class="lang-%s">%s</code></pre>'
                           % (html.escape(lang or "text"), html.escape("\n".join(body))))
            continue

        if stripped.startswith("|") and i + 1 < len(lines) \
                and set(lines[i + 1].strip()) <= set("|-: "):
            flush_para(para)
            cells = [c.strip() for c in stripped.strip("|").split("|")]
            out.append("<table><thead><tr>%s</tr></thead><tbody>"
                       % "".join("<th>%s</th>" % _inline(c) for c in cells))
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                row = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                out.append("<tr>%s</tr>" % "".join("<td>%s</td>" % _inline(c) for c in row))
                i += 1
            out.append("</tbody></table>")
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            flush_para(para)
            level = len(m.group(1))
            body = m.group(2).strip()
            if level == 1 and title == name:
                title = body
            out.append("<h%d id=\"%s\">%s</h%d>" % (level, _anchor(body), _inline(body), level))
            i += 1
            continue

        if re.match(r"^(-|\d+\.)\s+", stripped):
            flush_para(para)
            tag = "ul" if stripped.startswith("-") else "ol"
            out.append("<%s>" % tag)
            while i < len(lines) and re.match(r"^(-|\d+\.)\s+", lines[i].strip()):
                out.append("<li>%s</li>" % _inline(re.sub(r"^(-|\d+\.)\s+", "", lines[i].strip())))
                i += 1
            out.append("</%s>" % tag)
            continue

        if stripped.startswith(">"):
            flush_para(para)
            quote = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                quote.append(lines[i].strip().lstrip(">").strip())
                i += 1
            out.append("<blockquote>%s</blockquote>" % _inline(" ".join(quote)))
            continue

        if set(stripped) == {"-"} and len(stripped) >= 3:
            flush_para(para)
            out.append("<hr>")
            i += 1
            continue

        if not stripped:
            flush_para(para)
        else:
            para.append(stripped)
        i += 1
    flush_para(para)

    nav = " ".join('<a href="%s.html">%s</a>' % (g["name"][:-3], html.escape(g["title"]))
                   for g in (guides or []))
    return ("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<title>%s — Kennel guides</title>"
            "<link href=\"../vendor/fonts/plex.css\" rel=\"stylesheet\">"
            "<style>%s</style></head><body>\n<div class=\"nav\">%s</div>\n%s\n</body></html>\n"
            % (html.escape(title), GUIDE_CSS, nav, "\n".join(out)))


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


def read_json(path):
    """A JSON file, or None. A run folder an operator has edited by hand is not a
    reason for this server to stop answering."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def verify_summary(report):
    """What the Runs table needs out of a verify report (#64).

    A SUMMARY and not the report: the full thing carries every check's measured
    string and the whole metrics block, which is a table's worth of data per row.
    `GET /api/runs/<stamp>/verify.json` serves the rest.

    Note what is deliberately NOT in here: a key called "run".
    `kennel-demo.sh status` lists runs by sed-ing `"run": "..."` lines out of
    this document, so a nested one would appear in the driver's output as a run
    that does not exist.
    """
    if not isinstance(report, dict):
        return None
    return {
        "verdict": report.get("verdict"),
        "exit": report.get("exit"),
        "pass": report.get("pass"),
        "fail": report.get("fail"),
        "finished_at": report.get("finished_at"),
        "active_solver": report.get("active_solver"),
        "headline": report.get("headline"),
        "sim_window": (report.get("metrics") or {}).get("sim_window"),
        "checks": [{"n": c.get("n"), "name": c.get("name"), "status": c.get("status")}
                   for c in (report.get("checks") or []) if isinstance(c, dict)],
    }


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
        extra = sorted(n for n in REPORT_NAMES if os.path.isfile(os.path.join(path, n)))
        meta = read_json(os.path.join(path, "run.json")) or {}
        report = read_json(os.path.join(path, "verify.json"))
        runs.append({
            "run": name,
            "path": path,
            "modified": datetime.fromtimestamp(mtime, timezone.utc)
                                .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "files": present + extra,
            # `complete` still means the four artifacts a console export carries.
            # A run without a verify is a run that has not been run, not a broken
            # export -- the Runs view shows it as `staged`.
            "complete": len(present) == len(ARTIFACT_NAMES),
            "run_id": meta.get("run_id"),
            "choices": meta.get("choices"),
            "verify": verify_summary(report),
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
    guides_dir = None      # --guides / $KENNEL_GUIDES; None = no Guides item (#73)
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
                             "meshcat": side_channel(self.out_dir, MESHCAT_FILE),
                             # null with no guides directory, which is also what
                             # plain http.server gives the page: no /api/health
                             # at all. One rule, two ways of being absent (#73).
                             "guides": guide_list(self.guides_dir)})
            return
        if self.path.split("?")[0] == "/api/runs":
            self._json(200, {"out": self.out_dir, "runs": list_runs(self.out_dir)})
            return
        if self.path.split("?")[0].startswith("/api/runs/"):
            self._run_file(self.path.split("?")[0][len("/api/runs/"):])
            return
        if self.path.split("?")[0].startswith("/guides/"):
            self._guide(self.path.split("?")[0][len("/guides/"):])
            return
        # Anything else is a file. This is the whole of the static contract.
        SimpleHTTPRequestHandler.do_GET(self)

    def _guide(self, rest):
        """GET /guides/<name>.md | <name>.html | img/<file>.png (#73).

        Three shapes and nothing else. Each segment is matched against a pattern
        in full and the path is then BUILT from what matched -- so no separator,
        no dot and no absolute path in the request can reach a file this was not
        asked for, the same way _run_file is safe.
        """
        guides = guide_list(self.guides_dir)
        if guides is None:
            self._json(404, {"error": "this server has no guides directory",
                             "detail": ["Start it with --guides <dir>, or from a checkout "
                                        "where guides/ exists."]})
            return
        name, _, ext = rest.rpartition(".")
        served = None
        if rest.startswith("img/"):
            leaf = rest[len("img/"):]
            if GUIDE_IMG_RE.match(leaf):
                served = (os.path.join(self.guides_dir, "img", leaf), "image/png", "rb")
        elif ext == "md" and GUIDE_RE.match(name):
            served = (os.path.join(self.guides_dir, name + ".md"),
                      "text/markdown; charset=utf-8", "rb")
        elif ext == "html" and GUIDE_RE.match(name):
            served = (os.path.join(self.guides_dir, name + ".md"),
                      "text/html; charset=utf-8", "md")
        if served is None:
            self._json(404, {"error": "no such guide: %s" % rest,
                             "detail": ["GET /guides/<name>.md, /guides/<name>.html or "
                                        "/guides/img/<file>.png, where <name> is one of: "
                                        + ", ".join(g["name"][:-3] for g in guides)]})
            return
        path, ctype, mode = served
        try:
            with open(path, "rb") as f:
                raw = f.read()
        except OSError:
            self._json(404, {"error": "no such guide file: %s" % rest})
            return
        if mode == "md":
            body = render_md(raw.decode("utf-8", "replace"),
                             os.path.basename(path), guides).encode("utf-8")
        else:
            body = raw
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _run_file(self, rest):
        """GET /api/runs/<stamp>/<file> -- one file out of one run folder (#64).

        The Runs view reads verify.json for verdicts and counters, and the two
        YAMLs for the config diff. Both path segments are checked against a
        pattern and an allow-list and the path is then BUILT from them, so
        nothing the request says can reach outside the run directory: no
        separator, no dot and no absolute path satisfies either check.
        """
        parts = rest.split("/")
        if len(parts) != 2 or not RUN_DIR_RE.match(parts[0]) or parts[1] not in SERVABLE:
            self._json(404, {"error": "no such run file: %s" % rest,
                             "detail": ["GET /api/runs/run-<stamp>/<file>, where <file> is one of: "
                                        + ", ".join(sorted(SERVABLE))]})
            return
        path = os.path.join(self.out_dir, parts[0], parts[1])
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self._json(404, {"error": "%s has no %s" % (parts[0], parts[1]),
                             "detail": ["A run has a verify report only after "
                                        "`kennel-demo.sh run` (or `verify`) has run it."]})
            return
        self.send_response(200)
        self.send_header("Content-Type", SERVABLE[parts[1]])
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

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
    ap.add_argument("--guides", default=os.environ.get("KENNEL_GUIDES")
                    or os.path.join(REPO_ROOT, "guides"),
                    help="the guides directory to serve and render (#73). "
                         "Absent means no Guides item in the console at all.")
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
    guides_dir = os.path.abspath(os.path.expanduser(args.guides)) if args.guides else None
    Handler.guides_dir = guides_dir if guides_dir and os.path.isdir(guides_dir) else None

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
    print("[serve.py] guides       %s" % (
        "%s (%d)" % (Handler.guides_dir, len(guide_list(Handler.guides_dir) or []))
        if Handler.guides_dir else "none -- the console will show no Guides item"))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n[serve.py] stopped")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
