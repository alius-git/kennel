# seq.s003.diagnose — Live Degradation, Fall, and Post-Mortem Diagnosis

> One sentence: induced controller stress degrades a healthy walk into a fall while the dashboard narrates every step and pins the evidence.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s003diagnose-live-degradation-fall-and-post-mortem-diagnosis)

```mermaid
sequenceDiagram
    actor Alex
    participant Harness as Yuruna Harness
    participant Console
    participant Bridge
    participant Stack
    participant Sim
    participant Store as Manifest Store

    Note over Alex,Sim: Seeded: live healthy run — blocks green, contacts aligned, counters flat
    Harness->>Stack: induce stress (stress preset / demanding terrain segment)
    Stack-->>Bridge: MPC solve times climb toward 10 ms deadline
    Bridge-->>Console: MPCDiagnostics stream
    Console-->>Alex: MPC block green to amber; event feed logs deadline violation (value, iters)
    Console-->>Alex: overtime sparkline rises; block flashes per increment
    Stack-->>Bridge: early touchdown FL
    Console-->>Alex: gait timeline highlights mismatch; event feed logs leg + offset
    Sim-->>Bridge: belly contact / attitude threshold crossed
    Console-->>Alex: FALL event; red banner raised
    Console->>Console: pin last 5 s of events for post-mortem
    Console->>Store: record run verdict fell + headline counters
    Alex->>Console: read pinned post-mortem
    Console-->>Alex: ordered: deadline violations, contact mismatches, fall trigger values
    Alex->>Console: sim reset (interventions toolbar)
    Console->>Bridge: /reset_sim service call
    Sim-->>Console: standing restored; dashboard clears to healthy
    Alex->>Console: open Runs view
    Console-->>Alex: fallen run listed, verdict fell, counters preserved
    Note over Harness,Store: TVP: every induced signal has its diagnosis entry with measured values; pinned window covers 5 s before fall timestamp; tint history green-amber-red in step with counters; Runs table shows verdict fell
```
