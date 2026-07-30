# seq.s004.disturb — Interventions: Commands, Disturbance Injection, and Recovery

> One sentence: every intervention is a service call or topic publish with an observable effect — and the stack's process set never changes.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s004disturb-interventions--commands-disturbance-injection-and-recovery)

```mermaid
sequenceDiagram
    actor Alex
    participant Console
    participant Bridge
    participant Stack
    participant Sim
    participant Harness as Yuruna Harness

    Note over Alex,Sim: Seeded: stock run walking on flat plane; harness snapshots VM process table
    Alex->>Console: joystick velocity change
    Console->>Bridge: publish /quad_control_target
    Stack-->>Console: commanded vs actual plots converge
    Alex->>Console: inject moderate push (vector, magnitude, duration)
    Console->>Bridge: DisturbSim service call
    Sim-->>Console: stagger + recovery; event feed logs disturbance and recovery
    Alex->>Console: inject severe push
    Console->>Bridge: DisturbSim service call
    Sim-->>Console: fall; banner + pinned post-mortem (disturbance event just before fall)
    Alex->>Console: sim reset
    Console->>Bridge: /reset_sim service call
    Sim-->>Console: standing restored; plots and counters cleared; prior record kept
    Alex->>Console: enable manual stepping; single-step N times
    Console->>Bridge: /step_sim service calls
    Sim-->>Console: scene and plots advance N discrete increments
    Harness->>Harness: compare VM process table before / during / after
    Note over Harness,Sim: TVP: each intervention maps to a recorded call/publish and its effect; disturbance appears in the fall post-mortem window; N steps yield N advances; process set unchanged by any console action
```
