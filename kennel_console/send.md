# The console writes the run folder where the driver reads

Implementation record for
[issue #56](https://github.com/alius-git/kennel/issues/56) — one **send to
kennel-runs** click puts a composed run in `~/kennel-runs`, so
[`kennel-demo.sh run`](../demo/tools/kennel-demo.sh) finds it with no Downloads
folder, no `unzip`, and no path typed. Closes
[#44](https://github.com/alius-git/kennel/issues/44) (§5).

Consumes [`export.md`](export.md) ([#19](https://github.com/alius-git/kennel/issues/19))
unchanged: the bytes sent are the bytes `generate run ↓` downloads, and §4
group 2 asserts exactly that by doing both in one session. Pin:
`dcf53c596339afd45b82f12c54b1e93e8273c2f4` ([`stack/pin.lock`](../stack/pin.lock)).

Verified 2026-08-30 — 43 checks, [`verify-send.sh`](verify-send.sh), plus a green
end-to-end `console → send → run` on the live guest
([`send/evidence/04-console-send-run.txt`](send/evidence/04-console-send-run.txt)).

> **This is not a bypass — it is a bypass being retired.**
> [`design.md` §4](../plan/design.md#4-foundations-realization) puts run
> manifests and the two generated YAMLs in "the designated workspace directory",
> and [`stack/transfer.md`](../stack/transfer.md)'s bypass note names precisely
> this as the retirement path for the scp hand-off: *"the console writes where
> the stack already reads."* Half of that arrives here — the console now writes
> to a host directory the driver reads. The **host → guest hop remains**, so
> `kennel-transfer.sh` still has work to do; what is gone is the browser's
> download folder standing in for a workspace.
>
> The constraint that is **not** touched:
> [`design.md` §2](../plan/design.md#2-poc-topology) and
> [`03-console.md`](../plan/design/03-console.md) lock *configure + monitor,
> never orchestrate* — "the console generates commands; the user runs them …
> never through hidden orchestration", "no process control anywhere". Writing a
> file is not process control. **No button in this issue launches anything**, and
> §6 records the one that was deliberately not built.

## 1. What is delivered

| Artifact | Purpose |
|---|---|
| [`serve.py`](serve.py) | `http.server` plus three `/api/` endpoints; what `kennel-demo.sh console` now starts |
| `Kennel Console.dc.html` | Feature-detects the server; renders one extra button when it is there |
| [`verify-send.sh`](verify-send.sh) · [`verify-send.py`](verify-send.py) | 43 checks across **both** servers |
| [`send/evidence/`](send/evidence/) | The six transcripts this record reads |

```bash
python3 kennel_console/serve.py --port 8000 --out ~/kennel-runs
demo/tools/kennel-demo.sh console        # the same thing, backgrounded
```

Three endpoints, all `localhost`-only:

| Endpoint | Answer |
|---|---|
| `GET /api/health` | `{"kennel": true, "out": "<abs run dir>", "pin": "<sha>"}` |
| `POST /api/runs` | body = the export archive → writes `run-<stamp>/` under `--out`, `201` with a sha256 per file |
| `GET /api/runs` | the run folders present, newest first — what `kennel-demo.sh status` now lists |

Everything else `serve.py` does is what `python3 -m http.server --directory
kennel_console` did: same URLs, same directory listing, same `%20`
([`serve.md` §1](serve.md)).

## 2. The five decisions

### 2.1 Feature detection, not a build flag

The console asks `/api/health` once on mount. `serve.py` answers; plain
`http.server` returns 404; offline returns nothing. Only the first case renders
the button, so **one file** serves both worlds and the offline claim
[`serve.md` §2](serve.md) makes is untouched.

The alternative — a flag baked in at serve time, or two copies of the page — would
have meant the artifact `plan/` refers to was no longer the artifact being
served. The probe is deliberately inert: it cannot throw (a `try` around a
promise chain that already has a `.catch`), it cannot delay the first render
(nothing awaits it), and it cannot disturb the 10 Hz mock loop. §4 group 5
asserts all of that from the far side, with an error collector installed before
the page loads — an unhandled rejection is invisible to a DOM check and is
exactly the failure a feature probe invites.

It is a same-origin request, so the suites' zero-non-localhost assertion still
holds and still means what it meant.

### 2.2 The same three lines as `onGenerate`

`send()` calls `stampNow()`, `artifacts()`, `buildZip()` — the identical
sequence, on the identical `cfg`. The one thing that differs is where the Blob
goes: `fetch` instead of an anchor click.

This is [`export.md` §2.1](export.md) applied one level up. A second serializer
here, however small, would be a second thing to keep in step with the emitters,
and its drift would show up as a run that launches differently depending on
which button the operator pressed. §4 group 2 exports **both ways in one
session** and byte-compares — not because the code paths look the same, but so
that they stay so.

### 2.3 The STORED-zip validation is the fidelity check

The POST body is an archive, not four files in a multipart form, and `serve.py`
re-derives everything from it: exactly four entries under exactly one
`run-<stamp>/`, every entry **STORED**, every CRC-32 verified by reading it back,
`run.json` parsing and carrying the host's pin.

Sending the four files individually would have been simpler and would have
thrown away the property [`export.md` §2.2](export.md) built: the archive is
uncompressed and literal on purpose, so validating it *is* validating the bytes.
A deflated entry is refused rather than inflated, because an archive the console
did not write is not a console export whatever it contains.

**Validation completes before any write.** A refusal costs a message, never a
half-written run directory that the next `transfer` would happily push into the
guest — the same reasoning `unpack_run_zip` in the driver already applies to an
archive from a downloads folder.

Two refusals are worth naming:

- **Wrong pin → `409`**, in the words `kennel-transfer.sh` uses at its exit 3:
  a run composed against another revision has no defined meaning at this one.
  The message names both pins.
- **The folder name must match `run-YYYYMMDDTHHMMSSZ`.** This is the shape
  `stampNow()` emits, and matching it in full rather than globbing `run-*` is
  what makes path traversal structurally impossible on an endpoint that writes:
  no separator, no dot, no absolute path can satisfy the pattern. §4 group 4
  posts `../../etc` and gets a `400`.

The same refusals by hand, with the run directory listed after each one to show
that nothing was written:
[`05-refusals-by-curl.txt`](send/evidence/05-refusals-by-curl.txt).

### 2.4 The archive is kept beside the folder

A `201` writes both `run-<stamp>/` and `run-<stamp>.zip`. The folder is what the
driver consumes; the archive is what the console actually produced, and
provenance that cannot be re-checked is not provenance. It costs eleven
kilobytes. `pick_newest_run` prefers a folder over a zip of the same age, so the
kept archive never competes with the folder it came from.

### 2.5 `localhost` only

`serve.md` §1 called binding to `localhost` a preference — nothing needed to be
reachable off-host. With a POST that writes to disk it becomes a constraint, so
`serve.py` binds `127.0.0.1` explicitly rather than inheriting `http.server`'s
`0.0.0.0` default. There is no authentication and there should not need to be:
the endpoint is not reachable from another machine.

## 3. What the operator sees

![The export strip after a send: the four download buttons, the send button, and the path the server wrote](send-render.png)

The button is appended **after** the existing export rows, and the strip's
contents are not moved or reordered — [`export.md` §5](export.md) explains why
that matters: [`verify-generate.py`](verify-generate.py) clicks tabs by exact
text in document order, and rearranging the strip silently redirects those
clicks into a download. The four `#19` rows are exactly where they were.

The strip reports the absolute path the server wrote, so the next thing the
operator types is `kennel-demo.sh run` and nothing else. If the console's pin
literal ever differs from the server's, the strip says so **before** a send
rather than after a `409`.

`kennel-demo.sh console` prints both routes now — the button and `generate
run ↓` — because the download path is still fully supported and is the only one
available when the console is served by something else.

`kennel-demo.sh status` gained the run listing, read from `GET /api/runs` rather
than from the filesystem, so a disagreement about `--out` would show up there.
It is gated on `/api/health`: against a plain `http.server` the driver says
nothing about runs rather than reporting an absent API as an empty directory
([`06-status-both-servers.txt`](send/evidence/06-status-both-servers.txt)).

## 4. Verification

```bash
./kennel_console/verify-send.sh        # 43 checks — this issue
./kennel_console/verify-export.sh      # #19 — still green (55)
./kennel_console/verify-generate.sh    # #18 — still green (46)
./kennel_console/verify-scope.sh       # #17 — still green
./kennel_console/verify-serve.sh       # #16 — still green, now on both servers
```

`verify-send.sh` starts **both** servers and drives one throwaway headless
Chrome across the two origins with all external DNS blocked. `--out` is a temp
directory, so it never touches the operator's `~/kennel-runs`. Transcript:
[`01-verify-send.txt`](send/evidence/01-verify-send.txt).

| Group | Asserts |
|---|---|
| 0 · Surface | `/api/health` reports the run dir and the pin; the button renders and names its destination; `generate run ↓` and all four `#19` export rows are untouched |
| 1 · The write | One click → a folder in `--out` with the four files; the two YAMLs **byte-identical to the rendered panes**; `run.json` carries the composed (non-stock) solver, the pin, and its own folder name; the strip reports the path |
| 2 · Sent == downloaded | Both exports in one session: the three deterministic files byte-identical; `run.json` differs only in `run`, `generated_at`, `run_id`; identical composed choices |
| 3 · The kept archive | STORED, every CRC-32 valid, four entries under the run folder, byte-identical to the folder on disk |
| 4 · Refusals | Wrong pin → 409, three entries → 400, a deflated entry → 400, an existing folder → 409, not-a-zip → 400, a traversing name → 400 — and **nothing written** in any refused case |
| 5 · The other server | Under plain `http.server`: no button, the export strip intact, zero unresolved placeholders, **zero errors or unhandled rejections** |
| 6 · Network | Zero non-localhost requests |

The suites were also run the other way round — `verify-serve.sh` against
`serve.py`, via the new `KENNEL_SERVE_CMD` knob — so the server the driver
starts is held to the same offline contract as the one `serve.md` was proven on
([`02-verify-serve-both-servers.txt`](send/evidence/02-verify-serve-both-servers.txt)).

**End to end on the live guest**, 2026-08-30
([`04-console-send-run.txt`](send/evidence/04-console-send-run.txt)): `console`
→ compose `PARTIAL_CONDENSING_HPIPM` → *send* → `run` with no argument.

```
[kennel-demo] run              /home/thales/kennel-runs/run-20260830T200816Z
[kennel-demo]                  (newest run folder in /home/thales/kennel-runs)
[kennel-demo] expect solver    PARTIAL_CONDENSING_HPIPM  (from run-20260830T200816Z/run.json)
...
[PASS] 10 composed-config  -- measured PARTIAL_CONDENSING_HPIPM
pass=10 fail=0
VERDICT: PASS -- healthy and walking
```

| Phase | Time |
|---|---|
| guest | 0 s (already up) |
| transfer | 2 s |
| launch | 43 s |
| verify | 35 s |
| walk | 5 s |

The composed solver reached the running controller, and `verify` expected it
because it read the **sent run's** `run.json` — the by-hand path the driver's
§3.3 was built for, now with no archive in between.

## 5. Issue #44, folded in

`COMMAND_BLOCKS`' third label said `wait ~10 s for the robot to settle first`.
[#22](https://github.com/alius-git/kennel/issues/22) followed it literally and
started the controller while the simulator was still enumerating joints. The
number was wrong twice: it accounted for the settle but not for simulator
startup, and it drifted by 1/rate at any composed `simulator_realtime_rate`
below 1.0 (0.75 → 13.3 s, 0.5 → 20 s for the settle alone).

It now reads:

```
# 3 · MIT controller — wait until /clock advances and /quad_state exists, then ~10 sim seconds to settle
```

True at every rate, because it names an observable state and measures the settle
in **sim** seconds — the one clock the composer cannot move
([`stack/launch.md` §1](../stack/launch.md)). One literal feeds both the UI block
and `commands.txt`, so they changed together.

No suite asserted the old string: `verify-export.py` group 4 compares
`commands.txt` against the UI command bodies (which start `source /opt/ros`),
not the labels, and `verify-generate.py` asserts only that the word *settle*
reaches the operator — which it still does. **No assertion was changed**, and all
three suites stayed green ([`03-other-suites-green.txt`](send/evidence/03-other-suites-green.txt)).

## 6. The button that was not built

A **launch** button in the console was specified as an option for this issue and
is deliberately absent.

Every other MVP shortcut in this repo is a *bypass*: a stand-in with a retirement
path, logged in [#26](https://github.com/alius-git/kennel/issues/26). Launching
from the console would not be one. `design.md` §2 says the user's terminal
running the commands **is** the product experience, and `03-console.md` says "no
process control anywhere" — so the design's end state is not a console that
launches. A button for it would be a permanent deviation with nothing to retire
into, which is a different and heavier thing to put in the product's shape.

The gap it would close is already closed by two commands the operator types
themselves: *send*, then `kennel-demo.sh run`. If it is ever built it should be
off by default (`serve.py --allow-launch`), recorded here as a deviation rather
than a bypass, and added to #26's log so nobody mistakes it for the design.

## 7. Limits

- **The host → guest hop remains.** `serve.py` writes on the host; the guest
  gets the run through `kennel-transfer.sh` as before. The transfer bypass is
  half retired, not retired.
- **One operator, one host.** No authentication, `localhost` only, and a single
  `--out`. A shared or multi-seat host is a different problem and not this one.
- **The stamp is still the browser's clock** ([`export.md` §6](export.md)). Two
  exports inside the same second collide, and the server answers `409` rather
  than merging them — which is how §4 group 2 discovered that a send and a
  download one second apart share a folder name.
- **`run.json` is still deliberately minimal** and still not the Run Manifests &
  Config Schema foundation. Writing it to a designated directory does not
  promote it.
- **The Dashboard is untouched.** It still runs on `MockDataSource`; nothing
  here goes near the `DataSource` seam.

## 8. What this feeds

| Issue | What it takes from here |
|---|---|
| [#4](https://github.com/alius-git/kennel/issues/4) | Half of the run-manifest store's retirement path, exercised end to end |
| [#24](https://github.com/alius-git/kennel/issues/24) | `POST /api/runs` is a scriptable way to stage a run without a browser download directory |
| [#26](https://github.com/alius-git/kennel/issues/26) | One bypass narrowed (`transfer.md`), and §6's non-deviation recorded as a decision |
