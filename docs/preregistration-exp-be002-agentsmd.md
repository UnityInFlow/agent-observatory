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

---

## Amendment 1 — 2026-08-09, before any B1 run existed

Three gaps in the registration above, closed while the treatment arm was still empty. All
three were raised in review of the analysis tool, not discovered by looking at data.

**1. `KEEP` requires statistical significance, not just a large median shift.** The
original rule said "improves the primary metric beyond its MDE", which left open whether
p < .05 was also needed. It is: `KEEP` requires the cost median to fall by at least the
MDE **and** p < .05 on the Mann-Whitney U, **and** no increase in F02. Anything else that
is not a `REJECT` is `INCONCLUSIVE`. Deciding this after seeing a borderline p value would
have been choosing the answer.

**2. The analysis fails closed on anything but the registered dataset.** It refuses to
print a p value unless both arms have exactly the registered number of measuring runs,
every run is evaluated, no unexpected variant is present, and benchmark, runtime, model
and baseline commit are identical across all runs. A discarded F13/F15 run must be
*replaced* by another run, not tolerated as a short arm. Without this the tool could be
re-run during a batch until the number looked good, which is optional stopping.

**3. A run with zero model calls and zero tool calls is missing telemetry, not an
efficient run.** The API serialises those fields with `0` defaults, so a collector gap is
indistinguishable from a genuine zero. Such runs are excluded and the arm is flagged;
otherwise an outage concentrated in one arm reads as an efficiency improvement.

## Void — this experiment must be re-run

The first batch was stopped after three runs. The benchmark repository handed to the agent
contains `tasks/BE-002-order-amount-validation/`, which holds the graded acceptance
suites and a `fixtures/known-good/` model solution, plus a `README.md` that now describes
the trap in prose. Pilot run `a69933a0` named `BE002FunctionalTest` and `BE002ContractTest`
in its own summary — filenames that exist nowhere else — so at least one agent read the
answer key.

Every BE-002 number recorded so far, including the five-run pilot this registration draws
its power estimates from, was measured with the answer visible. The MDE table above is
therefore not trustworthy, and will be re-derived from a clean B0 arm and registered here
before any B1 run of the replacement experiment.

The predictions are unchanged. They were never based on the pilot's variance.
