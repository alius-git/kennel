# seq.s007.bridge — The DataSource Seam: Scripted Demo and Live Swap

> One sentence: the full dashboard runs a scripted demo with no stack at all, then swaps to the live bridge with nothing changing but the data.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s007bridge-the-datasource-seam--scripted-demo-and-live-swap)

```mermaid
sequenceDiagram
    actor Devon
    actor Alex
    participant Console
    participant Mock as MockDataSource
    participant Bridge as RosbridgeDataSource
    participant Stack
    participant Harness as Yuruna Harness

    Note over Devon,Mock: Seeded: no VM stack running; scripted demo run in MockDataSource
    Devon->>Console: open in mock mode
    Console->>Mock: subscribe streams
    Mock-->>Console: 30 s trot, degrading MPC solve times, fall
    Console-->>Devon: every panel exercises its purpose (strip, timeline, sparklines, feed, banner)
    Console-->>Devon: status bar labels session mock/demo
    Devon->>Console: switch data source to live bridge (stack down)
    Console->>Bridge: connect
    Bridge-->>Console: disconnected
    Console-->>Devon: every panel shows empty state naming its missing launch command
    Alex->>Stack: launch stack in the VM
    Stack-->>Bridge: topics appear
    Bridge-->>Console: streams alive
    Console-->>Alex: panels populate one by one, no reload, same behavior as mock
    Harness->>Console: compare panel/interaction inventory across sources
    Harness->>Bridge: measure plot update rates vs throttling ceiling
    Note over Harness,Stack: TVP: mock demo drives every panel with zero stack processes; mode always labeled; empty states name launch commands; live panels populate without reload; identical panel inventory; throttling ceiling respected
```
