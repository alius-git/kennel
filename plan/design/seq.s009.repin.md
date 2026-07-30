# seq.s009.repin — Upstream Update, Repin, and Regression Gate

> One sentence: a new upstream revision becomes a new pin and a new image, gated by the P0 scenarios, with the mapping layer absorbing the contract change and zero console changes.

**Companion documents:** [design.md](../design.md) · [scenarios.md](../scenarios.md#s009repin-upstream-update-repin-and-regression-gate)

```mermaid
sequenceDiagram
    actor Theo
    actor Elif
    participant Harness as Yuruna Harness
    participant Stack as Stack Pin
    participant Console
    participant Appliance as Appliance Build
    participant Gate as Regression Gate

    Note over Harness,Stack: Seeded: staged upstream revision where a stage type key replaces a launch-arg mapping
    Harness->>Stack: stage the upstream update
    Theo->>Stack: update pin + mapping-layer notes
    Theo->>Console: rebind affected composer choice to new mechanism (mapping layer only)
    Elif->>Appliance: rebuild image from new pin
    Appliance-->>Elif: new version manifest (differs only in repinned components)
    Elif->>Gate: run P0 scenarios against candidate
    Gate->>Gate: s001.firstwalk, s002.compose, s003.diagnose
    Gate-->>Elif: pass; s002 confirms new config mechanism + round-trip intact
    Elif->>Appliance: record candidate releasable; manifest supersedes old
    Harness->>Console: load a previous-release run manifest on new image
    Console-->>Harness: flagged version-manifest mismatch (not silently reproduced)
    alt negative control - breaking upstream change
        Harness->>Stack: stage breaking revision
        Elif->>Gate: run P0 scenarios
        Gate-->>Elif: fail on a named scenario; candidate not releasable
    end
    Note over Harness,Gate: TVP: new manifest differs in exactly the repinned components; gate passes good candidate, fails broken one by name; mapping change lands with console version identical across the repin; cross-release manifest loads flagged
```
