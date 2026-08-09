# Pre-registration — EXP-BE002-MODEL-TIER

**Registered before any run of this experiment was executed.** Committed on 2026-08-09,
against benchmarks `2ca08ca`. If the results disagree with this document, this document
wins the argument about what was predicted.

Deliberately lighter than [`preregistration-exp-be002-agentsmd.md`](preregistration-exp-be002-agentsmd.md).
That one earned its MDE tables and amendments because it was publishing a claim about a
customization. This one asks a purchasing question, and the ceremony that survives is the
part that pays for itself: **predictions written down before the data exists.**

## Question

On a task this benchmark can already grade, what does a bigger model actually buy?

| | A | B |
|---|---|---|
| variant | `haiku` | `sonnet` |
| model | `claude-haiku-4-5` | `sonnet` (latest alias) |
| customization | none | none |
| runs | 10 | 10 |

Everything else fixed: BE-002, Claude Code 2.1.226, same baseline commit, same evaluator,
same stripped-repository construction. `runtime.model` is the treatment, so the analysis is
run with `--vary runtime.model`, which requires that dimension to separate the arms cleanly
and keeps every other dimension gated.

## What this experiment is and is not powered to answer

Stated first, because the last experiment's honest disappointment came from testing a
subtle intervention on a coarse instrument, and repeating that would be a choice.

**Powered: the cost premium.** A model tier change moves cost by a multiple, not a few
percent. At n=10 per arm this resolves comfortably. This is the deliverable.

**Not powered: whether it buys quality.** Haiku already scores 8/10 on BE-002 baseline and
10/10 with an instruction file. The ceiling is 10/10, so the maximum observable improvement
is two runs, and 8/10 → 10/10 is Fisher p = 0.47. `acceptanceCriteriaPassed` does not
rescue this: in 20 observed runs it took exactly two values, 7 and 6.

**BE-002 is near-saturated for haiku, and that is the finding underneath the finding.** A
benchmark cannot discriminate models it is already too easy for — the same problem that
retired BE-001, one level up. If the quality result is null, the correct conclusion is
*"this task cannot tell these models apart"*, not *"these models are equivalent"*.

## Predictions

Directional, made before the data exists:

1. **Sonnet costs 2–5× more per run.** Same task, pricier tokens, and no reason to expect
   dramatically fewer of them.
2. **Sonnet uses fewer tool calls** — the usual argument for a stronger model is that it
   flails less. If tool calls do *not* fall, the entire cost premium is token price.
3. **Pass rate does not improve detectably.** 8/10 has two runs of headroom and no power.
4. **F07 scope failures do not disappear.** Leaving a stray file is a discipline failure,
   not a capability one, and an instruction file addressed it where a bigger model should
   not.

Prediction 4 is the one worth watching. If it is wrong — if the stronger model cleans up
the scope failures on its own — then `agents-md-v1`'s effect is partly a proxy for model
capability, and the previous experiment's read changes.

## Outcomes

**Primary:** median `estimatedCost`, and **cost per passing run** (arm cost ÷ runs passed),
which is the number a person actually spends to get working code.

**Secondary:** median tool calls, median duration, pass rate, failure-class mix.

## Decision rule

The `KEEP` / `REJECT` rule inside `analyze-experiment.py` belongs to the AGENTS.md question
— it gates on F02 and treats lower cost as better. **It does not apply here** and its
verdict line is to be ignored for this experiment; a model that costs more for better work
is not "rejected". The registered rule is:

- **Use the cheaper model for tasks of this difficulty** if pass rate does not improve by
  at least 2 runs *and* sonnet costs more. A null quality result plus a real cost premium
  is a purchasing answer, even though it is not a capability answer.
- **Escalate to a harder benchmark** if pass rate *does* improve, because that would mean
  BE-002 has headroom this registration argues it does not.
- Either way, **report the cost multiple with its confidence**, since that is the number
  this design can actually measure.

## Rules fixed in advance

- No run is dropped except F13/F15, which the comparison excludes automatically.
- Neither arm gets a customization; this is a model comparison, not a stacked one.
- The haiku arm is collected fresh rather than reusing the `EXP-BE002-AGENTSMD-V3`
  baseline, even though the configuration is identical. It costs $2 and it doubles as a
  **replication check**: if the fresh haiku arm does not land near the earlier arm's
  $0.1897 median and 8/10 pass, something about the rig is not stable, and that is worth
  more than the $2.

---

# Void — the sonnet arm measured the permission configuration, not the model

Both arms completed. The result was **sonnet 30% pass against haiku 100%**, with sonnet
costing 3.4× more. Taken at face value that says the stronger model is dramatically worse
at the task, which is the kind of dramatic number this project has learned to disbelieve
before publishing.

It is an artifact. **Seven of the ten sonnet runs changed no production file at all.**

| | haiku | sonnet |
|---|---:|---:|
| runs changing a production file | 10/10 | 3/10 |
| runs ending by asking for build permission | 0/10 | 5/10 |
| pass rate as recorded | 100% | 30% |

The failing runs are bimodal and unmistakable: 11–12 tool calls and 61–136 s, against
20–22 tool calls and 188–232 s for the passing ones, and every failure scores exactly 3/7.
Their only changed file is `OrderControllerTest.kt`. The agent transcript ends:

> *"I need explicit approval to run the Maven build. Could you approve running `./mvnw test`
> (or grant Bash permission), so I can verify the tests?"*

The runner launches the agent with `--permission-mode acceptEdits`, which auto-approves
file edits but not shell commands, in a headless `-p` session where there is nobody to ask.
Sonnet stops and requests approval. Haiku does not ask and proceeds. The evaluator then
records a run that never implemented the feature as **F05, incorrect code**.

## This is harness bug #7, and it is bug #2 again

> *2. An exhausted Copilot quota recorded as **F03, incorrect code**.*

Same shape: an environmental block recorded as a capability failure. Bug #2 was noticed
because a quota error is obviously not the agent's fault. This one is subtler, because
"the model produced a failing implementation" is exactly what a model comparison expects to
see, and it arrived pointing the way a reviewer might already suspect a cheaper model would
win.

Direction: **pessimistic**, like bugs 1–4. It makes the more cautious agent look
incompetent.

## What it invalidates

- **`EXP-BE002-MODEL-TIER` is void.** No verdict is drawn from it. The cost figure
  (+244%, p < .001) is *probably* sound in direction, since token pricing is real — but it
  is measured across arms where one arm mostly did not do the work, so it is not reportable
  either.
- **Not `EXP-BE002-AGENTSMD-V3`.** Both of its arms were haiku, and haiku asked for build
  permission in 0 of 20 runs. That result stands.
- **Every future cross-model or cross-runtime comparison**, until this is fixed. The
  instrument systematically penalises agents that are more conservative about permissions,
  which is a property of the harness, not of the agent's engineering ability.

This last point bears directly on [ADR-001](adr-001-defer-codex-adapter.md): a Codex
adapter would have walked straight into it, since approval behaviour is one of the things
Codex models explicitly.

## What has to happen before this experiment is re-run

The agent must be able to run the project's build non-interactively, or a run that is
blocked on permission must be classified as infrastructure (F13/F15) rather than as
incorrect code. Preferably both — the second is the safety net for the first, because a
permission block that is silently converted into a passing-looking dataset is how this
class of bug survives.

Either fix is a change to what the harness allows an agent to do, which is a deliberate
decision and not a detail to slip into a re-run.
