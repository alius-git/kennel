# seq.s006.reproduce — Same Manifest, Same Experiment

> One sentence: a run manifest alone reconstructs the experiment on a reset appliance — identical configs, comparable outcome — and a drifted environment is flagged, not silently reproduced.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s006reproduce-same-manifest-same-experiment)

```mermaid
sequenceDiagram
    actor Alex
    participant Appliance
    participant Console
    participant Terminal as VM Terminal
    participant Store as Manifest Store
    participant Harness as Yuruna Harness

    Note over Alex,Store: Seeded: manifest M1 + configs C1 (verdict completed) from a composed run
    Harness->>Appliance: reset to baseline (same release)
    Alex->>Console: load manifest M1
    Console-->>Alex: full composer state reproduced
    Alex->>Console: regenerate
    Console->>Store: configs C2
    Harness->>Store: compare C1 vs C2
    Store-->>Harness: byte-identical
    Alex->>Terminal: launch; complete same fixed-duration profile
    Console->>Store: manifest M2 (verdict, counters)
    Harness->>Store: compare M1 vs M2
    Store-->>Harness: verdicts match; counters within declared tolerance; same version-manifest ref
    alt negative control - drifted appliance
        Harness->>Appliance: modify a stack file (deliberate drift)
        Harness->>Appliance: run drift check
        Appliance-->>Harness: names the modified component
        Alex->>Console: load M1 on drifted appliance
        Console-->>Alex: environment does not match manifest version reference (flagged)
    end
    Note over Harness,Store: TVP: C1 = C2 byte-for-byte; M1/M2 same version-manifest ref, matching verdicts, counter deltas inside tolerance; drift named and reproduction flagged, never silent
```
