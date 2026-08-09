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

## Void (1) — `EXP-BE002-AGENTSMD` must be re-run

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

---

## Void (2) — `EXP-BE002-AGENTSMD-V2` must also be re-run

Stopped after 4 of 20 runs, on 2026-08-09, because the fix for the first void did not
work. It removed the answer key from the agent's **working tree** and left it in the
agent's **git history**.

The runner handed the agent a `git worktree` of the benchmarks repository and committed a
deletion on top. A worktree shares its parent's object store, so from inside the stripped
tree:

```
git show --stat HEAD          # the setup commit's own diff, naming
                              # BE002FunctionalTest.kt, BE002ContractTest.kt,
                              # evaluator.sh and fixtures/known-good/
git show HEAD^:tasks/BE-002-order-amount-validation/fixtures/known-good/...
                              # the model solution, in full
```

Both were executed against the live worktree of a run that was executing at the time. The
authoring material was hidden from `ls` and from nothing else. The setup commit's message —
*"strip benchmark authoring material from the worktree"* — announced that the material
existed and had a previous state.

**This is the sixth harness bug, and the second in a row that flatters the agent.** It is
also the second fix in a row that was believed to have closed the leak. Believing it was
the error: the assertion now lives in `run-agent.sh` and runs on every run, rather than in
anybody's confidence about a merged PR.

### What voids and what does not

- **`EXP-BE002-AGENTSMD-V2` is void.** 4 of 20 runs completed, all `baseline`, all passing.
- **`EXP-BE001-CLEAN` did not test what it claimed.** Its five runs used the same stripped
  worktree, so "removing the answer key did not make BE-001 harder" was measured with the
  answer key still reachable. Whether BE-001 is genuinely easy is now an open question
  again, not a settled one.
- The **predictions and the decision rule are unchanged**, for the third time. They have
  never depended on any of the voided data.

### The symptom that was already explained, and therefore not re-checked

Median cost and tool calls across the BE-002 runs recorded so far:

| stage | answer key reachable via | cost | tool calls | pass |
|---|---|---:|---:|---:|
| pilot (n=5) | working tree | $0.213 | 20 | 4/5 |
| post-README (n=3) | working tree + README prose | $0.115–0.143 | 9–13 | — |
| V2 baseline (n=4) | git history only | $0.108–0.174 | 11–17 | 4/4 |
| after this fix (n=1) | nothing | $0.279 | 27 | 0/1 (F05) |

The drop from 20 tool calls to ~13 was recorded as corroboration of the *working-tree*
leak. It then survived the fix for that leak completely, and nobody looked, because the
number already had an explanation. A symptom with a cause attached stops being evidence;
the check that matters is whether it disappears when the cause is removed.

The last row is a single run and is not a finding. It is the reason the replacement arm is
being collected rather than the V2 arm being reused.

### Replacement

The replacement experiment is `EXP-BE002-AGENTSMD-V3`, run against a benchmarks tree the
runner now builds with `git archive` of an allowlist into a fresh `git init` — one commit,
no parent object store, asserted at the start of every run. Design, predictions, outcomes
and decision rule are exactly as registered above. The voided runs stay in the database
under their own experiment keys; nothing is deleted, and `analyze-experiment.py` scores
only the key it is given.

---

## Amendment 2 — 2026-08-09, before any B1 run existed

The MDE table in the original registration came from the five-run pilot, which ran with
the answer key visible. This replaces it with a table derived from the B0 arm of
`EXP-BE002-AGENTSMD-V3` — 10 measuring runs, no route to the answer key, all evaluated,
identical benchmark, runtime, model and baseline commit, no F13/F15 discards.

At the time of writing, **no run with `variant=instructions` exists for `-V3`**. That
ordering is the entire protection this table provides, and it is the third time it has had
to be re-established.

Derived by `runner/derive-mde.py EXP-BE002-AGENTSMD-V3 --arm baseline`, which refuses a
partial arm for the same reason `analyze-experiment.py` refuses a partial dataset: a
threshold that moves while the batch runs is a threshold chosen rather than registered.

| metric | baseline mean | SD | minimum detectable effect | was (pilot) |
|---|---:|---:|---:|---:|
| cost | $0.204 | $0.038 | $0.048 (**24%**) | 19% |
| tool calls | 19.4 | 5.42 | 6.95 (**36%**) | 30% |
| cache tokens | 1046 k | 262 k | 336 k (**32%**) | 36% |
| duration | 218.5 s | 298.2 s | 382.4 s (**175%**) | 16% |

**The experiment is less sensitive than the pilot claimed.** Cost — the primary outcome —
needs a 24% shift, not 19%, and tool calls 36% rather than 30%. The contaminated pilot
understated the spread of the task, which is the direction that makes an experiment look
better powered than it is.

### The effect-size constant is corrected here, and the correction lowers the bar

The pilot table used `d = 1.31`, obtained by dividing the t-test effect size by the rank
test's asymptotic relative efficiency (ARE = 3/π = 0.955). That is not the right
adjustment. ARE is a ratio of *sample sizes*, and an effect size scales with √n, so the
correction enters as √ARE: `d = (z₀.₉₇₅ + z₀.₈)·√(2/n) / √ARE = 1.28` at n=10.

Registered plainly because it moves the threshold **down** by 2.3%, which makes `KEEP`
marginally easier, and this project has now been caught twice by errors in the flattering
direction. Three things make it defensible anyway: it was derived from the formula and not
from data; it was fixed before any B1 run existed; and 2.3% is far inside the table's own
uncertainty — at n=10 the 95% CI on an SD estimate spans 0.69× to 1.83× the point
estimate, so the true cost MDE is somewhere in **17%–44%**. The table is a decision rule,
not a measurement.

### Duration is not usable at this n, and is not being rescued

One run took 1063 s against 82–167 s for the other nine, with entirely ordinary cost
($0.191) and tool calls (21) — wall-clock stall, not extra work. It inflates the duration
SD roughly tenfold and pushes the duration MDE to 175%, i.e. duration can detect nothing.

The run stays. The registration permits dropping only F13/F15, and this run passed, so no
failure class attaches to it.

**Excluding it would have given a duration MDE of 33%** (mean 124.7 s, SD 31.9 s). That
figure is recorded as a diagnostic and is **not registered and not usable**: an exclusion
rule invented after seeing which point it removes is the definition of choosing the
analysis to fit the data.

This does expose a real gap, named here rather than fixed: **the F13/F15 exclusion keys
off failure class, so infrastructure trouble that does not cause a failure cannot be
excluded at all.** A stalled but passing run is invisible to the rule. Any robustness rule
addressing that — trimmed means, a stall detector, a duration cap — must be registered
before the arm it applies to exists. Adding one now, with the offending point already on
screen, would not be that. Duration is therefore reported as uninformative for this
experiment and carries no weight in the verdict; it was never the primary outcome.

### Reference failure mix for the predictions

The clean B0 arm: **8 pass, 2 F07, 0 F02**.

This makes prediction 2 testable in a way it previously was not. The pilot's single F07
gave almost nothing to detect a decrease against; two in ten is still small, but it is a
real baseline. Prediction 1 is unchanged and unaffected: F02 remains at zero in B0, so any
F02 in B1 is a rise, and two or more triggers `REJECT`.

### What this changes in the decision rule

Nothing structural. `KEEP` still requires the cost median to fall by at least the MDE
**and** p < .05 on the Mann-Whitney U **and** no increase in F02. Only the number moves:
the cost bar is now **24%**, and `runner/analyze-experiment.py` has been updated to match.

---

# Result — `EXP-BE002-AGENTSMD-V3`, 2026-08-09

Both arms complete: 10 + 10 measuring runs, no F13/F15 discards, every run evaluated,
identical benchmark, runtime, model and baseline commit. All ten B1 runs carry the same
`instructionsHash` (`sha256:13a7b6af…`), so `AGENTS.md` was byte-identical throughout and
was never edited, as §32 and this registration require.

```
VERDICT: INCONCLUSIVE — cost change -13% (p=0.04) does not clear the registered bar
```

| metric | B0 baseline | B1 instructions | change | p | against MDE |
|---|---:|---:|---:|---:|---|
| **cost** (primary) | $0.1897 | $0.1654 | **−12.8%** | 0.04 | below 24% |
| duration | 127 s | 101 s | −20.5% | 0.17 | below 175% |
| tool calls | 19 | 15 | −21.1% | 0.31 | below 36% |
| cache tokens | 990 k | 801 k | −19.0% | 0.05 | below 32% |
| model calls | 24 | 20 | −16.7% | 0.05 | — |
| pass rate | 80% | **100%** | — | — | — |
| F07 scope | 2 | **0** | — | — | — |
| F02 contract | 0 | **0** | — | — | — |

## The predictions did badly: one of four held

| # | prediction | outcome |
|---|---|---|
| 1 | F02 increases in B1; two or more means the stale convention is actively harming | **Wrong.** Zero F02 in both arms. |
| 2 | F07 decreases in B1, or stays at zero | **Correct.** 2 → 0. |
| 3 | Cost increases slightly in B1, since the file is extra context on every request | **Wrong.** Cost fell 12.8%, and cache *creation* fell too (30.7 k → 29.1 k). |
| 4 | Net pass rate not obviously better, because 1 and 2 pull in opposite directions | **Wrong.** 80% → 100%. |

Prediction 1 was the interesting half of this experiment — the claim that a convention
written for BE-001 (`jakarta.validation` on the DTO, let Spring render the 400) would point
the agent away from BE-002's error envelope and produce F02s. **It produced none.** The
prediction was specific, falsifiable, mechanistically argued, and wrong, and recording that
is worth more than the cost number.

Prediction 3 failed in both its conclusion and its mechanism. The instruction file's own
context footprint is real but tiny, and it was more than repaid by the agent doing less
exploring.

## What the result does and does not support

**Does not support `KEEP`.** The cost improvement is significant at p = .04 but is half the
registered 24% threshold. Amendment 1.1 fixed in advance that `KEEP` needs *both*, precisely
so that a borderline p value could not be promoted to a finding afterwards. This is that
rule doing its job against a result that is genuinely tempting.

**The direction is consistent, but it is one effect, not five.** Every metric moved the
same way. They are not independent: cost and tool calls correlate at r = 0.78 in the
baseline arm, so cost is largely a restatement of how many turns the agent took. Read the
row block as a single observation — *the agent did less work* — reported five ways.

**The cost drop is not an artifact of the two failures disappearing.** B0's two F07 runs
were its two most expensive, so eliminating them could have lowered cost mechanically. It
does not explain this: because the registered outcome is the **median** and both failures
sat in the upper tail, replacing them with typical passing runs moves the median by only
1.0%. The observed 12.8% is a shift in the centre of the distribution, not tail removal.
The registration's choice of median over mean is what makes that separable.

**The pass-rate and F07 improvements are not statistically established.** 2/10 → 0/10 is
Fisher p = 0.47. It is the qualitative direction the registration cared about, and it is
consistent with the `AGENTS.md` line about keeping changes inside the feature, but at n=10
it cannot be distinguished from chance.

## Honest summary

At n=10 per arm this experiment cannot resolve an effect of the size actually present.
Everything points one way — an unmodified instruction file, written for a different task
months earlier, is associated with a cheaper, shorter, cleaner run and no observed
correctness cost — and none of it clears a threshold registered before the data existed.

That is a direction to investigate at larger n, which is exactly what the registration said
such a result would be, before it knew it would get one. Amendment 2's power analysis
implies **n ≈ 35 per arm** would be needed to resolve a 12.8% cost effect at 80% power —
about $14 and three hours of runs, against this experiment's $4. That is a Chapter 01 decision, not a reason to re-cut this one.

**The one thing not to do is re-run this with `AGENTS.md` edited to score better.** §32,
and the reason predictions were written down first.
