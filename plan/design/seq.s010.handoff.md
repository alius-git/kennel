# seq.s010.handoff — The Safety-Gated Path Toward Hardware

> One sentence: hardware material is reachable only through a completed, evidence-backed simulation-first checklist, and the transfer package carries configs, manifests, and the gate record — never a claim the VM cannot make.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s010handoff-the-safety-gated-path-toward-hardware)

```mermaid
sequenceDiagram
    actor Noa
    participant Guides
    participant Gate as Safety Gate
    participant Store as Manifest Store
    participant Package as Transfer Package
    participant Harness as Yuruna Harness

    Note over Noa,Store: Seeded: run manifests from s002-s006, incl. one disturbance-recovery run and one verdict fell
    Noa->>Guides: open hardware notes (no completed gate)
    Guides-->>Noa: gate presented first — hardware material structurally unreachable
    Noa->>Gate: work checklist items
    Noa->>Gate: attach run with verdict fell
    Gate-->>Noa: rejected, reason stated (insufficient evidence)
    Noa->>Gate: attach manifest from drifted environment
    Gate-->>Noa: rejected, reason stated (version mismatch)
    Noa->>Gate: attach qualifying manifests (completed + manifest-matched)
    Noa->>Gate: complete remaining items
    Gate->>Gate: record completion: timestamp + evidence list
    Gate->>Package: produce transfer package (configs, run manifests, version manifest, gate record)
    Guides-->>Noa: hardware notes now presented (dedicated robot computer)
    Harness->>Guides: scan full guide path for scope honesty
    Guides-->>Harness: zero instructions run robot control from the VM; non-claims stated
    Harness->>Package: inspect package self-description
    Note over Harness,Package: TVP: hardware material unreachable before completion (structural, not a banner); rejection log holds both insufficient attempts with reasons; completion record lists manifests, all verdict completed + manifest-matched; package self-describing and environment-independent
```
