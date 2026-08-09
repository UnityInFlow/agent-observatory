# Chapter 00 — Foundation

The mental model, the milestones and the discipline this repository encodes.

## The agent loop we are observing

A coding agent is not simply "a model answering a prompt".

```text
USER TASK → CONTEXT ASSEMBLY (files · instructions · tools) → LLM
   → chooses next action → TOOL CALL (read · edit · shell) → TOOL RESULT → LLM → repeat
   → FINAL RESULT
```

Observable: session identity, runtime and version, model, LLM calls, token counts, tool
calls, command execution, file reads/writes, approvals and denials, failures, retries,
duration, traces, the final diff, and build/test/static-analysis results.

**Not** observable: the model's private chain-of-thought. We evaluate externally
observable actions and results.

For Track B, the vocabulary that matters:

```text
trace      = one execution story
span       = one timed operation inside the story
metric     = numeric measurement over time
log/event  = discrete recorded fact
evaluation = independent correctness check
```

And the five questions a student should be able to answer from one run: what did the
agent try first, which tool failed, did it recover, did it test the result, and did the
evaluator agree it was correct.

---

## Milestones and their exit criteria

| | Deliverable | Exit criterion | State |
|---|---|---|---|
| **M0** | BE-001 task, `benchmark.yaml`, clean baseline commit | requirement is deterministic enough to evaluate | done |
| **M1** | `evaluator.sh`, machine-readable `evaluation.json` | known-good passes; known-bad fails | done |
| **M2** | Collector, Tempo, Prometheus, Grafana | test trace visible in Grafana | done |
| **M3** | telemetry env + synthetic trace | student can explain the model/tool loop from evidence | done |
| **M4** | normalized run record + schema | vendor-neutral, reproducible via customization hashes | done |
| **M5** | evaluation result model | correctness/quality/safety kept separate, no single score | done |
| **M6** | Spring Boot API + PostgreSQL schema | normalized runs queryable independent of telemetry backend | done |
| **M7** | Web MVP: Runs, Detail, Compare, Benchmark | baseline and customized runs comparable in a browser | done |
| **M8** | benchmark runner + one-command ecosystem | a clean machine reaches a working stack with `make up` | done |
| **M9** | Grafana dashboard + metric catalog | seven panels, low cardinality, documented non-KPIs | done |
| **M10** | Claude Code adapter | same benchmark appears beside Copilot | done |
| M11 | Codex adapter | same comparison model despite different native telemetry | open |

---

## What we deliberately did NOT build

Organization-wide dashboards. Seven-team rollout. Custom MCP servers. Model-routing
logic. LLM-as-a-judge. Automatic PR generation. Plugin distribution. Long-term memory.
Complex cost forecasting. OpenShift deployment. Custom React trace visualization.

The first milestone was deliberately tiny:

> Run one plain agent task and see its execution trace in a browser.

---

## Experiment design — how we avoid fooling ourselves

AI agent runs are non-deterministic. One successful run proves very little.

1. **Plain baseline** — same repository state, task, runtime, model; no instructions, no
   skills, no custom agent. Minimum 5 runs, better 10. The goal is not statistical
   publication quality; it is to expose variance early.
2. **Add only `AGENTS.md`** — everything else fixed. Compare B0 vs B1. Do not
   simultaneously add a skill and change the model, or the result cannot be attributed.
3. **Skills** — B0 plain vs B1 instructions vs B2 lean instructions + testing skill.
4. **Model** — only after the harness comparison is stable.
5. **Runtime/harness** — Copilot vs Claude Code vs Codex. This measures the whole
   harness + model combination, never "the model" alone.

Then every later customization uses the same pattern:

```text
hypothesis → change one variable → run benchmark suite → observe → evaluate → compare
→ keep or reject
```

That experimental discipline matters more than any specific vendor feature.

---

## Human review rubric

Some quality cannot be captured by tests alone. Score 1–5 on four axes:

- **Correctness** — 1 wrong/incomplete · 3 works but has defects/edge gaps · 5 fully satisfies.
- **Scope discipline** — 1 widespread unnecessary changes · 3 some avoidable · 5 minimal cohesive diff.
- **Maintainability** — 1 poor/unidiomatic · 3 acceptable · 5 aligns with repository conventions.
- **Test quality** — 1 missing/misleading · 3 happy-path adequate · 5 useful behavioural coverage.

Where practical, reviewers should not know which experimental variant produced the
change. Blind review reduces confirmation bias.

---

## Definition of done for Chapter 00

- [x] We can explain the generic agent loop.
- [x] We can distinguish observation, metrics, evaluation and impact.
- [x] We have one deterministic Kotlin/Spring benchmark.
- [x] We can start the local OTel stack from Git.
- [x] An execution appears as a trace in Grafana/Tempo.
- [x] Raw prompt/source content is not captured by default.
- [x] We have a stable normalized run schema.
- [x] The evaluator independently marks runs pass/fail.
- [x] The first Observatory API persists run/evaluation metadata.
- [x] The web app can compare at least two variants.
- [x] We have at least five *real* clean baseline runs. — see below.
- [x] We know the baseline's variance. Failure modes are now **partly** known: BE-001
      never failed in 17 runs, and BE-002 has produced exactly one real agent failure
      (F07, scope) in five — enough to exercise the taxonomy, not enough to compare on.
- [x] We have not changed agent instructions merely to make charts look better.

---

## The first real baseline (EXP-BASELINE-COPILOT)

Five runs of BE-001 against **GitHub Copilot CLI 1.0.74 / `gpt-5.4-mini`**, plain agent —
`--no-custom-instructions`, no skills, no custom agent, no MCP. Same baseline commit,
same task, same model.

| | min | median | max | spread |
|---|---:|---:|---:|---:|
| pass rate | | **5/5** | | — |
| tool calls | 9 | 13 | 17 | **1.9×** |
| model calls | 6 | 8 | 11 | **1.8×** |
| input tokens | 154,893 | 193,344 | 276,882 | **1.8×** |
| duration | 35 s | 38 s | 43 s | 1.2× |
| changed files | 2 | 2 | 3 | 1.5× |

**This is the point of the whole chapter.** Correctness was perfectly stable — every run
satisfied all six acceptance criteria, changed no unrelated file and added no dependency.
Resource consumption was not: the same agent, on the same task, from the same commit,
used nearly **twice** as many tool calls and tokens on one run as on another.

The consequence is concrete: a single A/B run showing "20% fewer tool calls after adding
`AGENTS.md`" would be **inside this baseline's noise** and would prove nothing. Any future
customization has to beat a ~1.9× spread before the result means anything, which is
exactly why §20 asks for 5–10 runs per variant rather than one.

Two honest gaps:

- **No failure modes observed.** BE-001 is easy for this model, so the §23 taxonomy is
  still untested against real data. A harder benchmark is needed before failure-class
  comparisons carry weight.
- **Retries and permission decisions read 0** — Copilot's trace does not expose them, and
  the adapter records what exists rather than inventing plausible numbers.

---

## Experiment 2 — B0 plain vs B1 `+ AGENTS.md`

Same runtime, same model, same benchmark, same baseline commit. One variable changed:
an `AGENTS.md` describing the repository layout, build commands, validation convention
and scope constraints (`experiments/agents-md-v1/`, hash recorded on every run).

Raw values, one per run:

```text
baseline (n=6)      tool calls  [ 9, 12, 13, 13, 15, 17]   median 13
                    input tok   [155k, 171k, 193k, 223k, 244k, 277k]   median 208k
                    pass        6/6

instructions (n=4)  tool calls  [10, 11, 12, 13]           median 11.5
                    input tok   [169k, 219k, 220k, 246k]   median 219k
                    pass        4/4
```

### Verdict: no detectable effect. Do not keep on this evidence.

- **Correctness is unchanged** — both arms pass every acceptance criterion. There was no
  headroom to improve; BE-001 is too easy for this model to show a correctness effect.
- **Tool calls look ~12% lower** (13 → 11.5) — but *every one of the four instructions
  values falls inside the baseline's observed range of 9–17*. This is what "inside the
  noise" looks like in practice.
- **Tokens went slightly up**, not down (208k → 219k). If the tool-call drop were a real
  efficiency gain, tokens would be expected to follow it down. They did not.
- **The narrower instructions range is not evidence of stability.** Four draws will
  usually span less than six draws from the same distribution. Comparing a range across
  unequal sample sizes is a trap, not a finding.

A hypothesis worth testing later: both arms wrote a test on every run, so the
instruction "add new tests next to the existing ones" changed nothing that was not
already happening. `AGENTS.md` may simply have had nothing left to fix on this task.

**Decision: reject for now, re-run at 10 per variant on a harder benchmark.** The honest
conclusion is not "AGENTS.md does not help" — it is "this benchmark cannot tell".

### Caveats on this experiment

- The instructions arm has **4 valid runs, below the 5-run minimum of §20**. A fifth run
  aborted with `You have no quota` and is recorded as **F13** (rate limit), not F03. It is
  excluded from every number above.
- `ComparisonService` used to count that F13 run toward its minimum-sample warning, so the
  API reported no warning for an arm that is in fact under-powered, and dragged its pass
  rate to 80% for a reason unrelated to `AGENTS.md`. The analysis above was computed by
  hand with F13 filtered out. **Fixed in #19**: F13/F15 runs are now excluded from every
  aggregate and from the 5-run minimum, and reported as `infrastructureFailures`. Re-run
  the comparison and the API produces the corrected numbers itself.
- Two harness bugs were found *by this experiment* and fixed before the numbers above
  were taken; the first set of treatment runs was discarded. See the PR for detail.

---

## Experiment 3 — BE-002 plain baseline (EXP-BE002-B0)

Five runs of BE-002 against **Claude Code 2.1.226 / `claude-haiku-4-5`**, plain agent, no
customization installed. BE-002 was built to fail where BE-001 could not: the ticket asks
only for HTTP 400, while the service answers every error with an `ApiError` envelope that
the obvious `@Positive` + `@Valid` solution bypasses.

| run | verdict | class | tool calls | model calls | duration |
|---|---|---|---:|---:|---:|
| 1 | pass | — | 27 | 29 | 150 s |
| 2 | pass | — | 19 | 24 | 133 s |
| 3 | **fail** | **F07** | 20 | 26 | 127 s |
| 4 | pass | — | 16 | 20 | 112 s |
| 5 | pass | — | 27 | 33 | 150 s |

| | min | median | max | spread |
|---|---:|---:|---:|---:|
| pass rate | | **4/5 (80%)** | | — |
| tool calls | 16 | 20 | 27 | 1.7× |
| model calls | 20 | 26 | 33 | 1.7× |
| output tokens | 6,734 | 8,594 | 10,030 | 1.5× |
| **cached tokens** | 764,558 | **1,025,390** | 1,486,414 | **1.9×** |
| cost (USD) | 0.179 | 0.213 | 0.263 | 1.5× |
| duration | 112 s | 133 s | 150 s | 1.3× |

### The exit criterion was not met

benchmarks#6 asked for a plain baseline that fails **30–70%** of runs. BE-002 failed
**20%**. It is better than BE-001, which failed 0% of 17 runs, but it is below the bar and
must be reported as such rather than rounded up into a success.

### The designed discriminator never fired

Not one run failed AC4, the error-contract check — and **all five reached it**, run 3
included. Its verdict was exit 21, the scope guard, which the evaluator checks *after* the
acceptance suites; it passed both of them first. So the agent matched the envelope in
every single run. The premise — "the obvious answer wins" — is simply weaker than assumed
for this model on this task, and the F02 exit path is so far decoration.

### What did fail is more useful than what was designed

Run 3 wrote **`run_tests.sh` into the repository root** and left it there. Build passed,
existing tests passed, both acceptance suites passed; the submission was rejected by the
scope guard as F07, unnecessary changes.

This is the **first genuine agent failure this project has ever recorded** — the three
previous ones were harness bugs. It was verified by reading the diff before being
believed, per the standing rule about dramatic numbers.

It also happens to be directly addressable by an instruction file: `agents-md-v1`
already says *"Keep changes inside the feature you were asked to change"* — written long
before BE-002 existed. A B0-vs-B1 result driven by **unmodified, pre-dating** instructions
is far stronger evidence than one driven by a variant authored after seeing which failures
occur. §32 forbids the second; this is the first.

### Consequences for the next experiment

- Run B0 vs B1 with `agents-md-v1` **unchanged**. Do not write a v2 that mentions the
  error envelope until after this comparison; that is tuning instructions to the metric.
- A binary pass rate at n=10 per arm is near powerless — 80% → 100% is p ≈ 0.47 by
  Fisher's exact test.
- The continuous metrics are better, but **spread is dispersion, not power**: a wide
  baseline makes a shift *harder* to resolve, not easier. Pre-specifying what n=10 per arm
  could actually detect, at α = 0.05 two-sided and 80% power (d ≈ 1.32 for a rank test):

  | metric | baseline mean | SD | minimum detectable effect |
  |---|---:|---:|---:|
  | duration | 134.4 s | 16.2 s | 21.3 s (**16%**) |
  | cost | $0.215 | $0.030 | $0.040 (**19%**) |
  | tool calls | 21.8 | 4.97 | 6.6 (**30%**) |
  | cache tokens | 1.04 M | 284 k | 374 k (**36%**) |

  > **Superseded — this table is void.** It was estimated from runs that could read the
  > benchmark's answer key, and it used `d = 1.31` where the rank-test correction gives
  > 1.28. The table that governs is Amendment 2 of
  > [`preregistration-exp-be002-agentsmd.md`](preregistration-exp-be002-agentsmd.md),
  > derived from a clean 10-run arm: cost **24%**, tool calls **36%**, cache tokens
  > **32%**, duration unusable at **175%**. It is left in place rather than edited because
  > the reasoning below is what the numbers were used for, and rewriting history would
  > hide that the contaminated estimate made the experiment look better powered than it
  > was. Read the paragraph that follows with the corrected figures.

  So a 10 + 10 comparison can only resolve a *large* effect: roughly a fifth off cost or a
  third off tool calls. An instruction file plausibly moves things by less than that.

  **The comparison is therefore declared exploratory before it is run.** Primary metric:
  median cost, chosen because it has the tightest relative spread of the metrics a
  customization should affect. Anything below the thresholds above is a direction to
  investigate at a larger n, not a result — and saying so now is what stops a 15%
  improvement being written up as a finding after the fact.
- Compare cost and cache tokens, not input+output. On these runs cache reads outnumber
  input+output **117:1**, and an instruction file's entire footprint is context.

---

## Reading list

1. [How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works) — context gathering, action/tool loop, verification.
2. [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) — receiver, processor, exporter.
3. [GitHub Copilot CLI reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference) — search for *OpenTelemetry monitoring*.
4. [Grafana Tempo](https://grafana.com/docs/tempo/latest/set-up-for-tracing/) and [visualizing traces](https://grafana.com/docs/tempo/latest/visualize-traces/).
5. [Claude Code monitoring](https://code.claude.com/docs/en/monitoring-usage) — metrics, events, traces, token/cache attributes, privacy gates.
6. [Running Codex safely](https://openai.com/index/running-codex-safely/) and [Codex config](https://learn.chatgpt.com/docs/config-file/config-basic).
7. [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/concepts/semantic-conventions/) — why we normalize instead of inventing names.

---

## What comes next

Chapter 01 — the base-instructions experiment: B0 plain agent vs B1 + `AGENTS.md` vs
B2 + a tool-specific instruction adapter. Only after Chapter 00 is genuinely complete,
which means real baseline runs with known variance — not seeded demo data.
