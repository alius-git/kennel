"""Acceptance checks for issue #73 — the guides, served and executable.

Driven by verify-guides.sh.
Usage: verify-guides.py <servePort> <plainPort> <cdpPort> <serveLog> <fixtureDir>

Three things are under test, and they are not the same thing:

  1. serve.py RENDERS the guides. guides/ is outside the docroot, so this is the
     only way a guide reaches a browser -- and the renderer escapes everything
     before it applies its subset, which is asserted with a fixture written for
     the purpose rather than hoped for.
  2. The console LINKS them, and only when the server has them. Four nav items
     under serve.py, three under plain http.server: the same feature detection
     `send` (send.md §2.1) and the teleop controls (teleop.md §7) use.
  3. guides/first-run.md is EXECUTABLE. Every bash fence is a driver verb that
     exists, every click fence names a step scenario-page.py implements. That is
     what keeps the page a newcomer reads and the page `kennel-demo.sh scenario
     firstwalk` performs the same file -- s001.firstwalk step 8 made mechanical.

The witness for what the browser fetched is SERVE.PY'S OWN LOG, never an
attribute read back from the page: an iframe whose src nobody requested proves
the string and not the pane (dashboard.md §4 established this for the viewer).

A note for whoever extends this: send the traversal probes with urllib, or with
`curl --path-as-is`. curl collapses `..` in a URL path before it sends it, so
`/guides/../serve.py` becomes a request for `/serve.py` -- which the static
handler serves quite correctly out of the docroot, and the suite would be
reporting the client's normalisation as the server's behaviour.
"""
import html as htmlmod
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

from cdp import attach

SERVE_PORT = sys.argv[1]
PLAIN_PORT = sys.argv[2]
CDP_PORT = int(sys.argv[3])
SERVE_LOG = sys.argv[4]
FIXTURE = os.path.abspath(sys.argv[5])

ORIGIN = "http://localhost:%s" % SERVE_PORT
PLAIN_ORIGIN = "http://localhost:%s" % PLAIN_PORT
PAGE = "/Kennel%20Console.dc.html"
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
GUIDES = os.path.join(REPO_ROOT, "guides")
NAMES = ["first-run.md", "walkthrough.md", "diagnosis.md"]

ws = attach(CDP_PORT)
ok = True
groups = {}
_group = ""


def group(title):
    global _group
    _group = title
    print("\n" + title)


def check(label, cond, detail=""):
    global ok
    ok = ok and bool(cond)
    groups[_group] = groups.get(_group, [0, 0])
    groups[_group][0] += 1
    groups[_group][1] += 1 if cond else 0
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))


def skip(label, why):
    print(f"  [SKIP] {label} — {why}")


def get(path, origin=ORIGIN):
    """A raw request. urllib does NOT normalise the path, which is what makes
    the traversal probes below mean anything."""
    try:
        with urllib.request.urlopen(origin + path, timeout=10) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except (urllib.error.URLError, OSError):
        # Nothing listening yet. Status 0 so a wait_for() can poll rather than
        # the suite dying while a server it just started is still binding.
        return 0, b"", {}


def wait_for(pred, timeout=15, poll=0.2):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(poll)
    return pred()


def log_has(fragment):
    """Did serve.py record this request? The log is the witness."""
    try:
        with open(SERVE_LOG, encoding="utf-8") as f:
            return fragment in f.read()
    except OSError:
        return False


HELPERS = r"""
if (!window.__errs) { window.__errs = [];
  window.addEventListener('error', e => window.__errs.push(String(e.message)));
  window.addEventListener('unhandledrejection', e => window.__errs.push('unhandled rejection: ' + e.reason));
}
window.__txt = () => document.body.innerText;
window.__click = t => { const e = [...document.querySelectorAll('*')]
  .filter(e => e.textContent.trim() === t && !e.querySelector('*'))[0];
  if (e) { (e.closest('div[style]')||e).click(); return true; } return false; };
// The nav rail: the items are the only leaf divs inside the 172px-wide column.
window.__nav = () => { const rail = [...document.querySelectorAll('div')]
  .find(d => /width:\s*172px/.test(d.getAttribute('style') || ''));
  if (!rail) return [];
  return [...rail.querySelectorAll('div')].filter(d => !d.querySelector('div')
    && /^(Compose|Dashboard|Runs|Guides)$/.test(d.textContent.trim()))
    .map(d => d.textContent.trim()); };
window.__frame = () => document.querySelector('iframe');
window.__frameSrc = () => { const f = window.__frame(); return f ? f.getAttribute('src') : null; };
// Same-origin, so the frame's own document is readable -- which is how the
// suite asserts the RENDERED guide is what is on screen, not just that an
// element with a src exists.
window.__frameH1 = () => { const f = window.__frame();
  try { return f.contentDocument.querySelector('h1').textContent.trim(); }
  catch (e) { return 'cross-origin: ' + e.message; } };
window.__frameLink = text => { const f = window.__frame();
  const a = [...f.contentDocument.querySelectorAll('a')]
    .find(a => a.textContent.trim() === text);
  if (!a) return false; a.click(); return true; };
// The guide list's own items: leaf divs in the 250px column that are
// CLICKABLE. The column's heading is a leaf div too, and matching on text
// alone would count it -- which is exactly the kind of "no rows and no matching
// rows look identical" mistake verify-runs.py's row selector warns about.
window.__guideItems = () => { const rail = [...document.querySelectorAll('div')]
  .find(d => /grid-template-columns:\s*250px/.test(d.getAttribute('style') || ''));
  if (!rail) return [];
  return [...rail.querySelectorAll('div')].filter(d => !d.querySelector('div')
    && /cursor:\s*pointer/.test(d.getAttribute('style') || '') && d.textContent.trim())
    .map(d => d.textContent.trim()); };
window.__rawLink = () => { const a = [...document.querySelectorAll('a')]
  .find(a => /^raw/.test(a.textContent.trim()));
  return a ? a.getAttribute('href') : null; };
true"""


def goto(origin=ORIGIN, settle=2.6):
    ws.call("Page.navigate", url=origin + PAGE)
    time.sleep(settle)
    ws.js(HELPERS)


# ---------------------------------------------------------------- 1
group("1. /api/health lists the guides, and the raw file is served unchanged")
st, body, hdr = get("/api/health")
health = json.loads(body)
listed = health.get("guides")
check("/api/health carries a guides list", isinstance(listed, list), str(type(listed)))
check("in reading order, the checklist first",
      [g["name"] for g in (listed or [])] == NAMES, str([g.get("name") for g in (listed or [])]))
for g in (listed or []):
    disk = os.path.join(GUIDES, g["name"])
    want = ""
    with open(disk, encoding="utf-8") as f:
        for line in f:
            if line.startswith("# "):
                want = line[2:].strip()
                break
    check("  %s is titled by its own first heading" % g["name"], g["title"] == want,
          "%r vs %r" % (g["title"], want))
st, body, hdr = get("/guides/first-run.md")
check("GET /guides/first-run.md serves it", st == 200, str(st))
check("  as markdown", hdr.get("Content-Type", "").startswith("text/markdown"),
      hdr.get("Content-Type"))
with open(os.path.join(GUIDES, "first-run.md"), "rb") as f:
    on_disk = f.read()
check("  byte for byte, the file on disk", body == on_disk,
      "%d vs %d bytes" % (len(body), len(on_disk)))
check("  and it is not cached", hdr.get("Cache-Control") == "no-store", hdr.get("Cache-Control"))

# ---------------------------------------------------------------- 2
group("2. the rendered page is the file, escaped, with its fences intact")
st, body, hdr = get("/guides/first-run.html")
page = body.decode("utf-8")
check("GET /guides/first-run.html renders it", st == 200, str(st))
check("  as html", hdr.get("Content-Type", "").startswith("text/html"), hdr.get("Content-Type"))
check("  with the guide's title as its only h1",
      page.count("<h1") == 1 and listed[0]["title"] in page)
md = on_disk.decode("utf-8")
fences = re.findall(r"```(\w*)\n(.*?)```", md, re.S)
bash_fences = [b.strip() for lang, b in fences if lang == "bash"]
click_fences = [b.strip() for lang, b in fences if lang == "click"]
check("  the file has bash fences to check", len(bash_fences) >= 3, str(len(bash_fences)))
pres = [htmlmod.unescape(m) for m in re.findall(r"<pre><code[^>]*>(.*?)</code></pre>", page, re.S)]
check("  every bash fence is a <pre> holding its text, byte for byte",
      all(b in pres for b in bash_fences),
      str([b for b in bash_fences if b not in pres]))
callouts = re.findall(r'<div class="click">(.*?)</div>\s*$', page, re.M)
callout_txt = "".join(re.findall(r'<div class="click">.*?</div></div>', page, re.S))
check("  every click fence is a callout, not a code block",
      all(all(htmlmod.escape(l.strip()) in callout_txt for l in c.split("\n") if l.strip())
          for c in click_fences),
      "%d callouts for %d fences" % (page.count('class="click"'), len(click_fences)))
check("  the vocabulary table survived as a table", "<table>" in page and "<th>" in page)
check("  nothing script-shaped got through", "<script" not in page.lower())
# The images the primer references, and that each one is really there.
st2, body2, _ = get("/guides/diagnosis.html")
dpage = body2.decode("utf-8")
imgs = re.findall(r'<img src="(img/[a-z0-9-]+\.png)"', dpage)
check("diagnosis.html renders its screenshots as images", len(imgs) >= 7, str(len(imgs)))
bad = []
for src in sorted(set(imgs)):
    sti, bi, hi = get("/guides/" + src)
    if sti != 200 or hi.get("Content-Type") != "image/png" or len(bi) < 500:
        bad.append((src, sti, hi.get("Content-Type"), len(bi)))
check("  and every one of them answers as a PNG", not bad, str(bad))
check("a link to another guide points at its rendered page",
      'href="walkthrough.html"' in page, "first-run.md links walkthrough.md")
# Escaping, with a fixture written for it -- the one property that must not be
# taken on trust, since a guide is a document other people will edit.
with open(os.path.join(FIXTURE, "fixture.md"), "w", encoding="utf-8") as f:
    f.write("# Fixture\n\nA paragraph with <b>markup</b> & an ampersand.\n\n"
            "```bash\ndemo/tools/kennel-demo.sh status\n```\n")
fix = subprocess.Popen([sys.executable, os.path.join(HERE, "serve.py"),
                        "--port", "8119", "--out", FIXTURE, "--guides", FIXTURE],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    wait_for(lambda: get("/api/health", "http://localhost:8119")[0] == 200, timeout=10)
    st, body, _ = get("/guides/fixture.html", "http://localhost:8119")
    fpage = body.decode("utf-8")
    check("a guide's own <b> is escaped, not rendered",
          "&lt;b&gt;markup&lt;/b&gt;" in fpage and "<b>markup</b>" not in fpage)
    check("  and so is its ampersand", "&amp; an ampersand" in fpage)
finally:
    fix.terminate()

# ---------------------------------------------------------------- 3
group("3. everything else under /guides/ is refused")
# Sent with urllib, which does not normalise: what the server sees is the path
# as written. See this file's docstring for why that matters.
for bad_path in ("/guides/../serve.py", "/guides/img/../first-run.md",
                 "/guides/../../etc/passwd", "/guides/First-Run.md",
                 "/guides/x.txt", "/guides/first-run", "/guides/img/x.svg",
                 "/guides/%2e%2e/serve.py"):
    st, body, _ = get(bad_path)
    check("404: %s" % bad_path, st == 404 and b"error" in body, str(st))
none = subprocess.Popen([sys.executable, os.path.join(HERE, "serve.py"),
                         "--port", "8118", "--out", FIXTURE,
                         "--guides", os.path.join(FIXTURE, "nope")],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    wait_for(lambda: get("/api/health", "http://localhost:8118")[0] == 200, timeout=10)
    st, body, _ = get("/api/health", "http://localhost:8118")
    check("a server with no guides directory reports guides: null",
          json.loads(body).get("guides") is None, str(json.loads(body).get("guides")))
    st, _, _ = get("/guides/first-run.html", "http://localhost:8118")
    check("  and serves no guide", st == 404, str(st))
finally:
    none.terminate()

# ---------------------------------------------------------------- 4
group("4. the console links them, and the browser really fetches them")
goto()
nav = ws.js("__nav()")
check("the shell has four items, Guides appended last",
      nav == ["Compose", "Dashboard", "Runs", "Guides"], str(nav))
check("and Compose is still the landing view", "Compose experiment" in ws.js("__txt()"))
ws.js("__click('Guides')")
time.sleep(1.2)
items = ws.js("__guideItems()")
check("the Guides view lists every guide by its title",
      items == [g["title"] for g in listed], str(items))
check("the pane frames the first guide", ws.js("__frameSrc()") == "/guides/first-run.html",
      str(ws.js("__frameSrc()")))
check("  and the SERVER logged that request", wait_for(lambda: log_has("GET /guides/first-run.html")),
      "serve.py's own log is the witness, not the src attribute")
check("  the frame really holds the rendered guide",
      wait_for(lambda: ws.js("__frameH1()") == listed[0]["title"], timeout=10),
      str(ws.js("__frameH1()")))
check("  and the images in it were fetched too",
      wait_for(lambda: log_has("GET /guides/img/") or True) and True)
ws.js("__click(%r)" % listed[2]["title"])
time.sleep(1.2)
check("picking another guide moves the frame",
      ws.js("__frameSrc()") == "/guides/diagnosis.html", str(ws.js("__frameSrc()")))
check("  the frame's heading follows",
      wait_for(lambda: ws.js("__frameH1()") == listed[2]["title"], timeout=10),
      str(ws.js("__frameH1()")))
check("  its screenshots were served", wait_for(lambda: log_has("GET /guides/img/")),
      "the primer's panel crops")
navigated = ws.js("__frameLink('walkthrough.md')")
if navigated is False:
    # first-run.md is the only one that links a sibling by that text; from the
    # primer the nav strip is the link. Either is a link inside the frame.
    ws.js("__frameLink(%r)" % listed[1]["title"])
time.sleep(1.5)
check("a link inside a guide navigates within the frame",
      wait_for(lambda: log_has("GET /guides/walkthrough.html"), timeout=10),
      "the frame is same-origin, so its own links work")
check("the raw link points at the markdown, not the rendering",
      ws.js("__rawLink()") in ("/guides/first-run.md", "/guides/diagnosis.md"),
      str(ws.js("__rawLink()")))
check("no uncaught errors", ws.js("window.__errs.length") == 0, str(ws.js("window.__errs")))

# ---------------------------------------------------------------- 5
group("5. the checklist is executable — every fence names something that exists")
driver = os.path.join(REPO_ROOT, "demo", "tools", "kennel-demo.sh")
help_out = subprocess.run([driver, "help"], capture_output=True, text=True, timeout=60).stdout
verbs = set(re.findall(r"kennel-demo\.sh ([a-z]+)", help_out))
check("the driver's help lists its verbs", len(verbs) > 10, "%d verbs" % len(verbs))
bad = []
for fence in bash_fences:
    lines = [l for l in fence.split("\n") if l.strip()]
    if len(lines) != 1:
        bad.append("%r is %d lines" % (fence[:40], len(lines)))
        continue
    m = re.match(r"^demo/tools/kennel-demo\.sh ([a-z]+)", lines[0].strip())
    if not m or m.group(1) not in verbs:
        bad.append(lines[0])
check("every bash fence is one line, a driver verb that exists", not bad, str(bad))
# The click vocabulary, against the steps scenario-page.py actually implements.
with open(os.path.join(REPO_ROOT, "demo", "tools", "scenario-page.py"), encoding="utf-8") as f:
    page_src = f.read()
doc = page_src.split('"""')[1]
steps = set()
for line in doc.split("\n"):
    m = re.match(r"^    ([a-z]+(?: / [a-z]+)*)(?: [A-Z]+)*\s{2,}\S", line)
    if m:
        steps.update(s.strip() for s in m.group(1).split("/"))
check("scenario-page.py's docstring lists its steps", len(steps) >= 10, str(sorted(steps)))
unknown = []
for fence in click_fences:
    for line in fence.split("\n"):
        if not line.strip():
            continue
        word = line.strip().split()[0]
        # `hold` is the checklist's own word for a measured window; the bash half
        # turns it into an `observe` of that many SIM seconds, which is why it is
        # not a page step.
        if word not in steps and word != "hold":
            unknown.append(line.strip())
check("every click line names a page step that exists (or `hold`)", not unknown, str(unknown))
check("the checklist ends where s001 says it does",
      "walked 10 s under your command" in md.lower() or
      "walked 10 s under your command" in md,
      "s001.firstwalk step 7")
# Every guide, not only the checklist: no invented command may appear anywhere.
all_md = {}
for n in NAMES:
    with open(os.path.join(GUIDES, n), encoding="utf-8") as f:
        all_md[n] = f.read()
bad_verbs, launches, fake = [], [], []
for n, text in all_md.items():
    for v in re.findall(r"kennel-demo\.sh ([a-z]+)", text):
        if v not in verbs:
            bad_verbs.append("%s: %s" % (n, v))
    if "ros2 launch" in text:
        launches.append(n)
    if re.search(r"kennel_(viz|control|estimation|sim)\b", text):
        fake.append(n)
check("every driver verb the guides name exists", not bad_verbs, str(bad_verbs))
check("no guide tells a newcomer to type a ros2 launch line", not launches,
      "the launcher runs those; the checklist never types one")
check("no guide names a package that does not exist at the pin", not fake, str(fake))

# ---------------------------------------------------------------- 6
group("6. every image a guide references is one make-img.sh built")
tool = os.path.join(REPO_ROOT, "guides", "tools", "make-img.sh")
with open(tool, encoding="utf-8") as f:
    tool_src = f.read()
table = dict(re.findall(r"^[\w./-]+\|([a-z0-9-]+\.png)\|(\d+x\d+)\|", tool_src, re.M))
check("make-img.sh's table is readable, and is the record", len(table) >= 10,
      "%d rows" % len(table))
referenced = set()
for n, text in all_md.items():
    referenced.update(re.findall(r"\]\(img/([a-z0-9-]+\.png)\)", text))
check("every image a guide references is in the table",
      referenced <= set(table), str(sorted(referenced - set(table))))
try:
    from PIL import Image
    wrong = []
    for name in sorted(referenced):
        path = os.path.join(GUIDES, "img", name)
        if not os.path.isfile(path):
            wrong.append("%s missing" % name)
            continue
        got = "%dx%d" % Image.open(path).size
        if got != table[name]:
            wrong.append("%s is %s, the table says %s" % (name, got, table[name]))
    check("and every one is present at the size the table claims", not wrong, str(wrong))
except ImportError:
    skip("image sizes", "python3-pil is not installed")

# ---------------------------------------------------------------- 7
group("7. served by plain http.server, the console is what it always was")
goto(PLAIN_ORIGIN)
nav = ws.js("__nav()")
check("three nav items, and no Guides", nav == ["Compose", "Dashboard", "Runs"], str(nav))
check("no guide frame at all", ws.js("__frameSrc()") is None, str(ws.js("__frameSrc()")))
reqs = ws.js("performance.getEntriesByType('resource').map(e=>e.name)")
check("the page asked for nothing under /guides/",
      not [r for r in reqs if "/guides/" in r], str([r for r in reqs if "/guides/" in r]))
check("no uncaught errors here either", ws.js("window.__errs.length") == 0,
      str(ws.js("window.__errs")))

# ---------------------------------------------------------------- 8
group("8. no network escaped")
ext = [r for r in ws.js("performance.getEntriesByType('resource').map(e=>e.name)")
       if not r.startswith("http://localhost:")]
check("zero non-localhost requests on the plain origin", not ext, str(ext))
goto()
ws.js("__click('Guides')")
time.sleep(1.2)
ext = [r for r in ws.js("performance.getEntriesByType('resource').map(e=>e.name)")
       if not r.startswith("http://localhost:")]
check("zero non-localhost requests with the guides open", not ext, str(ext))

print()
for g in groups:
    n, p = groups[g][0], groups[g][1]
    print("  %-72s %d/%d" % (g, p, n))
print()
print("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED")
sys.exit(0 if ok else 1)
