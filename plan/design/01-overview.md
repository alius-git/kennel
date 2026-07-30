# POC Overview

> One sentence: the Kennel POC is one pinned VM appliance (stack + bridge + console + guides) driven from a host browser and verified by Yuruna sequences.

**Companion documents:** [design.md](../design.md) · [applications.md](../applications.md) · [scenarios.md](../scenarios.md)

## Top-level blocks

```mermaid
flowchart LR
    Console[Kennel Console SPA]
    DS[DataSource seam]
    Bridge[rosbridge WS]
    Stack[dfki-quad stack pinned]
    Sim[Drake sim + Meshcat]
    Guides[Guides + safety gate]
    Manifests[Version + run manifests]

    Console --> DS
    DS --> Bridge
    Bridge --> Stack
    Stack --> Sim
    Console --> Manifests
    Console --> Guides
    Guides --> Manifests
```

The DataSource seam has two implementations: `MockDataSource` (scripted demo, no stack needed) and the rosbridge client — swapping them changes no console panel ([design.md §4](../design.md)).

## Deployment topology

```mermaid
flowchart TB
    subgraph Host
        Browser[Host browser]
        Runner[Yuruna runner]
        Release[Release image + checksum]
    end
    subgraph KennelVM[kennel-vm — the appliance]
        VMConsole[Console static server + bridge + stack + sim]
        Tools[Reset / drift tools + guides]
    end
    SeatB[kennel-vm-b second seat]

    Release --> KennelVM
    Browser --> VMConsole
    Runner --> KennelVM
    Runner -.s008 only.-> SeatB
    Release -.same image.-> SeatB
```

The user's VM terminal is part of the product: the console generates launch commands; a person (or the harness, over the shell channel) runs them. Nothing orchestrates processes on the user's behalf.

## Scenario coverage

All ten sequences traverse this topology; s007.bridge (mock half) runs with no VM at all, and s008.classroom is the only sequence provisioning the second seat. See [scenarios.md](../scenarios.md).
