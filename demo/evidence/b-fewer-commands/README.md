# Evidence — fewer commands (issue #54)

Captured 2026-08-30 on the host of [`vm/host-baseline.md` §1](../../../vm/host-baseline.md),
against the `kennel-vm-baseline` guest. The claims these support are tabulated in
[`demo/runbook.md` §7.5](../../runbook.md).

| File | What it shows |
|---|---|
| `01-setup-first.txt` | `setup` on a host missing two items — `did` for both, full `Test-Config` gate, exit 0 |
| `02-setup-idempotent.txt` | `setup` twice more: all `ok`, and the two runs' item lines are byte-identical |
| `03-setup-patch-reversed.txt` | One patch reversed → exactly one line differs, and it is that patch |
| `04-setup-refuses-foreign-changes.txt` | `setup` refuses to check out over changes it cannot account for |
| `05-help-grouped.txt` | `help`, grouped by when you reach for each verb |
| `06-run-from-cold.txt` | `halt`, then `run` alone from a shut-off guest → walking in 1 m 49 s |
| `07-run-twice.txt` | `run` twice in a row, the second over a running trotting stack (and the #52 race, re-verified green) |
| `08-compose-by-hand-hpipm.txt` | Composed HPIPM + rate 0.5 by hand; `run` picked the `.zip` from `~/Downloads` and verified against `run.json` |
| `08-compose-by-hand-render.png` | The console at the moment that composition was made |
| `09-session-verbs.txt` | `walk stop`, `down`, `status`, `console stop` |
| `10-all-unchanged.txt` | `all` still green, unchanged by this branch |
| `11-provision-preflight.txt` | `provision`'s refactored preflight, declined at the prompt — nothing destroyed |
| `12-transfer-refusals.txt` | Four non-export archives refused, nothing written |
