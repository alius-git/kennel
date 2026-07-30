# seq.s005.compare — Solver Benchmark and Run Comparison

> One sentence: two runs differing in one composed choice, plus a seeded failure, yield honest verdict badges and a diff that isolates exactly the difference.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s005compare-solver-benchmark-and-run-comparison)

```mermaid
sequenceDiagram
    actor Alex
    participant Console
    participant Terminal as VM Terminal
    participant Stack
    participant Store as Manifest Store
    participant Harness as Yuruna Harness

    Note over Alex,Console: Seeded: "Solver benchmark" preset; obstacle terrain; fixed run duration
    Alex->>Console: compose with solver A; Generate run
    Alex->>Terminal: launch; complete fixed-duration run
    Console->>Store: manifest A (verdict completed, counters)
    Alex->>Console: duplicate preset; change ONLY MPC solver to B
    Alex->>Terminal: launch; complete identical run
    Console->>Store: manifest B (verdict, counters)
    Harness->>Terminal: seed failing run (config that cannot hold deadline)
    Stack-->>Console: solver failures accumulate
    Console->>Store: manifest F (verdict solver-failed, counters)
    Alex->>Console: open Runs view
    Console-->>Alex: three rows: map, stages, duration, verdict badges, counters
    Alex->>Console: select A + B
    Console-->>Alex: side-by-side diff: solver field (+ dependent fields) only
    Alex->>Console: select A + F
    Console-->>Alex: diff isolates the failing configuration delta
    Harness->>Store: cross-check manifests vs event feeds and table
    Note over Harness,Store: TVP: verdicts completed/completed/solver-failed with counters consistent with events; A-B diff contains solver (+dependents) and nothing else; same version-manifest ref on compared runs; table counters equal manifest values
```
