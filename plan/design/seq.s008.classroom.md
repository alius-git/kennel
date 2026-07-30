# seq.s008.classroom — Fleet Cold Start, Drift, and Reset

> One sentence: two seats from one image behave identically, the dirtied seat is detected and restored, and the between-cohort reset returns the fleet to uniform baseline.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s008classroom-fleet-cold-start-drift-and-reset)

```mermaid
sequenceDiagram
    actor Marcus
    actor Sofia
    participant Harness as Yuruna Harness
    participant SeatA as Seat A (kennel-vm)
    participant SeatB as Seat B (kennel-vm-b)
    participant Guides

    Note over Harness,SeatB: Seeded: released image; N = 2 seats provisioned from it
    Marcus->>SeatA: verify checksum + version manifest
    Marcus->>SeatB: verify checksum + version manifest
    SeatB-->>Marcus: manifests byte-identical across seats
    Sofia->>Guides: run first-walk checklist on Seat A
    SeatA-->>Sofia: sustained walking inside budget
    Sofia->>Guides: run first-walk checklist on Seat B
    SeatB-->>Sofia: same outcome, same budget
    Harness->>SeatB: dirty the seat (modify stack file + stray package)
    Harness->>SeatB: drift check
    SeatB-->>Harness: reports exactly the two deviations
    Harness->>SeatA: drift check
    SeatA-->>Harness: clean
    Sofia->>SeatB: place kept run manifest in designated workspace
    Marcus->>SeatB: reset to baseline
    SeatB-->>Marcus: drift check clean; workspace artifact survived
    Sofia->>Guides: re-run first-walk on reset Seat B
    SeatB-->>Sofia: same outcome, same budget
    Marcus->>SeatA: between-cohort routine: reset all, verify all
    Note over Harness,SeatB: TVP: one checksum, byte-identical manifests across seats; every seat (incl. reset one) walks inside budget; drift report names exactly the injected deviations, clean seats report none; workspace artifact survives reset
```
