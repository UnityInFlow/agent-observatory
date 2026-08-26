---
name: Harness bug
about: The instrument measured the harness rather than the agent
title: "[HARNESS] "
labels: harness-bug
---

> Before blaming the agent, ask what else changed. Seven of this project's findings were
> harness bugs, and one cost a voided twenty-run experiment.

## What the data said

<!-- The number or classification as recorded. -->

## What actually happened

<!-- What the agent or the environment really did. -->

## How the two came apart

<!-- The specific mechanism. A permission block recorded as incorrect code; a gap stored as
     a zero; a flag that was trusted rather than verified. -->

## Blast radius

- Runs affected:
- Experiments affected:
- Does any published result depend on this?

## The fix, and its layer

- [ ] **L1** — the bad state can no longer be represented
- [ ] **L2** — something executes and rejects it
- [ ] **L3** — documentation only, and therefore constrains nothing

<!-- If the honest answer is L3, say so. Writing it down is not fixing it: this repository
     documented BehaviorDto's zero defaults for months while the bug stayed live. -->
