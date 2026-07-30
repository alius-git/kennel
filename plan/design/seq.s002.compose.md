# seq.s002.compose — Experiment Composition, Generation, and Config Round-Trip

> One sentence: a composed experiment generates exact configs, launches a live run, and loads back into a byte-identical composer state.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s002compose-experiment-composition-generation-and-config-round-trip)

```mermaid
sequenceDiagram
    actor Alex
    participant Console
    participant Store as Manifest Store
    participant Terminal as VM Terminal
    participant Stack
    participant Harness as Yuruna Harness

    Note over Alex,Console: Seeded: connected appliance; stock defaults loaded
    Alex->>Console: select obstacle terrain; adjust real-time rate
    Alex->>Console: pick Adaptive gait sequencer; switch MPC solver
    Alex->>Console: modify two MPC parameters in drawer
    Console-->>Alex: "modified" badges; raw-YAML tab reflects values
    Alex->>Console: save named preset
    Alex->>Console: Generate run
    Console->>Store: write 2 config YAMLs + run manifest (composition + version-manifest ref)
    Console-->>Alex: 3-command launch block
    Alex->>Terminal: run the three commands
    Terminal->>Stack: stack launches with composed config
    Stack-->>Console: health strip shows selected implementations
    Alex->>Console: stop run
    Console->>Store: finalize manifest (duration, verdict completed)
    Alex->>Console: reset composer to defaults
    Alex->>Console: load generated config back
    Console-->>Alex: exact prior state (map, stages, 2 badges, sim options)
    Alex->>Console: load named preset
    Console-->>Alex: identical state again
    Harness->>Store: compare serialized states + YAML contents
    Note over Harness,Store: TVP: YAMLs contain exactly the composed values; manifest records full composition + version-manifest ref; live diagnostics identify the selected stages; round-trip comparisons byte-identical
```
