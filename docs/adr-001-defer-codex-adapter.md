# ADR-001 — Defer the Codex adapter (M11) to Chapter 01

**Status:** accepted, 2026-08-09
**Decision:** M11 moves from *open* to *deferred*. Chapter 00 closes with two runtimes.
**Supersedes:** the standing verbal recommendation recorded in `STATE.md` as "not done".

## Context

M11 is the last open milestone of Chapter 00. It calls for an OpenAI Codex adapter, so
that "the same comparison model" holds across a third runtime despite different native
telemetry.

This is not blocked on capability. `codex-cli 0.147.0` is installed, and `run-agent.sh`
already has a `codex` branch that launches it and records the run. What is missing is the
telemetry normalization: Codex emits structured agent-aware events (approvals, tool
results, MCP calls, network policy) where Copilot emits traces and metrics. Making those
comparable is the actual work, and `architecture.md` is explicit that we normalize *above*
the raw layer rather than fabricating parity.

Chapter 00's stated purpose is to *learn how coding agents actually behave before
customizing them*. **The pipeline has been exercised end to end** — it runs agents, grades
them deterministically, records cost and behaviour, and refuses datasets it cannot trust.

That is a claim about the harness, not about what has been learned. It is deliberately
weaker than the earlier draft of this ADR, which said the purpose was served because one
experiment had concluded. `EXP-BE002-AGENTSMD-V3` placed `AGENTS.md` in the repository, but
**Claude Code does not load `AGENTS.md`** — verified by controlled test: an identical file
named `CLAUDE.md` is read, `AGENTS.md` is not. The intended treatment was never applied, so
that experiment does not support its stated conclusion about instruction effectiveness and
is reclassified as void.

Whether Chapter 00's *learning* purpose is served therefore remains open until a
customization experiment runs with a treatment the runtime actually reads. The decision
below does not depend on it.

## Decision

**Defer M11 to Chapter 01, and close Chapter 00 at two runtimes.**

Chapter 01 is about creating and customizing agents. A cross-runtime comparison is a
distinct question — dimension 5 in the foundation doc, *"Runtime/harness: this measures the
whole harness"* — and it deserves to be built when it is about to be used, not banked in
advance.

## Why

**A third adapter adds integration surface, not scientific capability.** The comparison
layer already spans two runtimes with genuinely different telemetry shapes. That is the
architectural claim being tested. A third instance of the same pattern mostly repeats work
already done.

**The bottleneck moved, and it is not runtimes.** Chapter 00 ends with two benchmark tasks.
BE-001 is too easy — and the experiment establishing that turns out to have run on a
leaking worktree, so even that is unsettled. BE-002 is near-saturated for haiku at 8–10 out
of 10. Adding a third runtime multiplies comparisons across a benchmark suite that cannot
currently discriminate the two runtimes we already have. **More rows against too few
columns.**

**The existing two-runtime comparison is itself incomplete.** Claude runs carry
`traceId: null` by design — #20 refused to fake span parity — and Copilot's quota is
exhausted, which is why the five-questions walkthrough is still unrecorded. Adding a third
partial picture before the first pairing can be demonstrated end to end would be building
on an unfinished floor.

**Unused adapters rot.** An adapter written now, against a benchmark suite that cannot use
it, would sit untested across every change to the runner until Chapter 01 picks it up. The
runner has produced six harness bugs in its short life, two of which survived review by
looking correct. Code that nothing exercises is where the next one hides.

## The strongest argument against this, and why it does not change the decision

The normalized run schema's central claim is **vendor neutrality**. Two runtimes is a weak
test of that claim, and the third is exactly where a leaky abstraction would show up — a
schema that fits Copilot and Claude may simply be a schema shaped like those two.

That argument is correct, and it is a reason to build the adapter *eventually*, not to
build it now. The claim gets tested properly when a real comparison depends on it, because
that is when a mismatch is visible and consequential. Building it now tests the schema
against a runtime no experiment uses, which detects the mismatch without creating any
pressure to resolve it well.

## Consequences

- Chapter 00 closes with M0–M10 done and M11 deferred. **Deferred is not abandoned**, and
  the milestone table should say so rather than showing an open item indefinitely.
- The `codex` branch in `run-agent.sh` stays. It launches Codex and records a run; it
  simply has no normalized telemetry behind it. That is honest and already the documented
  position — do not fabricate a span hierarchy to make Codex look like Copilot.
- Cross-runtime claims stay out of Chapter 00's write-up. Nothing published so far depends
  on a three-runtime comparison.

## What would trigger building it

Any one of these, and the decision should be revisited:

1. **A benchmark task that discriminates.** Once a task exists where the runtimes we
   already support diverge meaningfully, a third becomes informative rather than decorative.
2. **A cross-runtime question someone actually needs answered** — e.g. "does our `AGENTS.md`
   transfer across harnesses?", which is a Chapter 01 question and would need all three.
3. **Evidence the schema is not vendor-neutral.** If normalizing Claude or Copilot ever
   requires a runtime-specific escape hatch in the schema, the neutrality claim is already
   in doubt and Codex becomes the test that settles it.

## Alternatives considered

**Build M11 now and close Chapter 00 complete.** Rejected: it buys a tidy milestone table
at the cost of untested code and no new answers. Completeness on paper is not the goal;
Chapter 00's purpose is met.

**Drop M11 permanently.** Rejected: the vendor-neutrality claim is real and worth testing,
and Codex is the natural test. Deleting the milestone would lose that thread.

**Build a minimal Codex adapter — launch and cost only, no event normalization.** Tempting,
and close to what already exists. Rejected because a half-adapter is the worst option for
this project specifically: it would produce runs that *look* comparable in the API and the
UI while missing the behaviour data every comparison depends on. This codebase's recurring
failure mode is a measurement that looks valid and is not, and it has cost two voided
experiments. A partial adapter is that failure mode, pre-installed.
