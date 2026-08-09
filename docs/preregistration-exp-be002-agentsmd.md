# Pre-registration — EXP-BE002-AGENTSMD

**Registered before any run of this experiment was executed.** Committed on 2026-08-09,
against benchmarks `2ca08ca` and observatory `77d481f`. If the results below disagree with
this document, this document wins the argument about what was predicted.

## Question

Does adding `experiments/agents-md-v1/AGENTS.md` — unchanged, exactly as it was written
for BE-001 months before BE-002 existed — improve a plain agent's work on BE-002?

## Design

| | B0 | B1 |
|---|---|---|
| variant | `baseline` | `instructions` |
| customization | none | `experiments/agents-md-v1/` |
| runs | 10 | 10 |

Everything else fixed: benchmark BE-002, runtime Claude Code 2.1.226, model
`claude-haiku-4-5`, same baseline commit, same evaluator. Experiment key
`EXP-BE002-AGENTSMD`. The five earlier BE-002 runs are a **pilot**, used to design this
experiment and estimate its power; they are not pooled into it.

## The instruction file contains one line that should help and one that should hurt

This is why the experiment is worth running rather than a formality.

**Should help** — §Constraints:

> Keep changes inside the feature you were asked to change. Do not reformat, tidy or
> "improve" unrelated files.

The pilot's only failure was exactly this: an agent left a `run_tests.sh` in the
repository root (F07).

**Should hurt** — §Conventions:

> Request validation belongs at the API boundary, using `jakarta.validation` annotations
> on the request DTO plus `@Valid` on the controller parameter. Spring translates a
> violation into HTTP 400 automatically; do not hand-roll error handling for it.

That sentence describes BE-002's `fixtures/known-bad-annotation` submission almost
exactly. It was correct for BE-001's customer feature; on BE-002 it points away from the
service's error envelope, which is what AC4 checks.

## Predictions

Directional, made before the data exists:

1. **F02 error-contract failures increase in B1.** The pilot produced zero in five runs.
   If B1 produces two or more, the stale convention is actively harming.
2. **F07 scope failures decrease in B1**, or stay at zero.
3. **Cost increases slightly in B1** — the instruction file is extra context on every
   request, and cache creation carries it.
4. **Net pass rate is not obviously better in B1**, because 1 and 2 pull in opposite
   directions.

## Outcomes

**Primary:** median `estimatedCost` (USD). Chosen because it had the tightest relative
spread in the pilot, so it is the metric with the best chance of resolving anything.

**Secondary:** median tool calls, median cache tokens, pass rate, and the failure-class
mix (F02 vs F07), which is the qualitative result this experiment is really about.

**Power.** From the pilot (n=5), at α = 0.05 two-sided and 80% power, n=10 per arm can
only detect:

| metric | minimum detectable effect |
|---|---:|
| duration | 16% |
| cost | 19% |
| tool calls | 30% |
| cache tokens | 36% |

**The comparison is therefore exploratory on the continuous metrics.** Anything smaller
than the thresholds above is a direction to investigate at larger n, not a finding. The
failure-class mix is not subject to this caveat in the same way: a jump from 0 to several
F02s is a qualitative change, not a shift in a mean.

## Decision rule

- **Keep** `AGENTS.md` for this task if B1 improves the primary metric beyond its MDE and
  does not increase F02.
- **Reject** if F02 increases — a customization that makes correctness worse is not paid
  for by cheaper runs.
- **Inconclusive** otherwise, which is a legitimate outcome and must be reported as such.

## Rules fixed in advance

- `AGENTS.md` is **not edited** during or after this experiment. Editing it in response to
  results and re-running is what §32 forbids.
- No run is dropped except F13/F15, which the comparison excludes automatically.
- If a run has to be discarded for any other reason, the reason is written here before the
  analysis is published.
