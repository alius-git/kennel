# seq.s001.firstwalk — Cold Import to Walking Go2 Inside the Time Budget

> One sentence: a clean host imports the appliance and, following only the first-run checklist, reaches sustained commanded walking inside the time budget.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s001firstwalk-cold-import-to-walking-go2-inside-the-time-budget)

```mermaid
sequenceDiagram
    actor Sofia
    participant Harness as Yuruna Harness
    participant Appliance
    participant Guides
    participant Console
    participant Terminal as VM Terminal
    participant Stack
    participant Sim

    Note over Harness,Appliance: Seeded: clean host; released image + published checksum only
    Harness->>Appliance: verify image checksum vs release record
    Sofia->>Appliance: import OVA, start VM
    Appliance-->>Sofia: first boot lands at first-run checklist
    Harness->>Harness: start timer at first boot
    Sofia->>Guides: follow checklist, step by step
    Guides-->>Sofia: open console from host browser
    Sofia->>Console: open (forwarded port)
    Console-->>Sofia: stock preset + generated 3-command launch block
    Sofia->>Terminal: run command 1 (simulator)
    Terminal->>Sim: Drake sim up (Meshcat)
    Sofia->>Terminal: run command 2 (controller)
    Terminal->>Stack: controller nodes up
    Sofia->>Terminal: run command 3 (state estimation)
    Stack-->>Console: topics alive via bridge
    Console-->>Sofia: status bar connected; empty states clear panel by panel
    Sim-->>Console: robot stands, then walks (stock trot)
    Sofia->>Console: velocity command + gait change (interventions)
    Stack-->>Console: robot responds; gait timeline shows new pattern
    Harness->>Harness: stop timer after 10 s sustained commanded walking
    Harness->>Appliance: read in-VM version manifest
    Note over Harness,Sim: TVP: elapsed within budget (≈5 min, ceiling 10); zero commands from outside the checklist; status connected with live heartbeat; checksum and manifest match release; no panel in error state
```
