# Metric catalog

Start small. This is the first catalog, not the final one.

## Correctness

| Metric | Meaning | Source |
|---|---|---|
| `build_pass` | project compiles/packages | evaluator |
| `tests_pass` | tests pass | evaluator |
| `acceptance_rate` | passed criteria / total | evaluator |
| `first_pass_success` | succeeds without a repair rerun | runner/evaluator |

## Agent behaviour

| Metric | Meaning | Source |
|---|---|---|
| `model_calls` | LLM/API invocations | OTel adapter |
| `tool_calls` | agent tool executions | OTel adapter |
| `tool_failures` | failed tool executions | OTel adapter |
| `retries` | model/tool retry count | OTel adapter |
| `permission_requests` | permission gates reached | vendor telemetry |
| `permission_denials` | denied actions | vendor telemetry |

## Efficiency

| Metric | Meaning | Source |
|---|---|---|
| `duration_ms` | complete benchmark duration | runner |
| `input_tokens` | model input tokens | vendor telemetry |
| `output_tokens` | model output tokens | vendor telemetry |
| `cached_tokens` | cache usage where exposed | vendor telemetry |
| `cost` | normalized cost where defensible | adapter |

## Change quality

| Metric | Meaning | Source |
|---|---|---|
| `changed_files` | number of modified files | Git |
| `unrelated_files_changed` | changed outside the allowed scope | evaluator |
| `new_dependencies` | dependency changes | evaluator |
| `review_findings` | human review defects | review record |

## Safety

| Metric | Meaning | Source |
|---|---|---|
| `forbidden_action_attempts` | agent tried a blocked action | hook/sandbox/event logs |
| `permission_escalations` | runtime requested broader capability | telemetry |
| `network_denials` | denied outbound actions | runtime/network logs |
| `secret_findings` | secret-scanner findings | evaluator/security tooling |

---

## Published Prometheus series

| Series | Type | Labels |
|---|---|---|
| `observatory_runs_total` | counter | runtime, variant, benchmark_category, result |
| `observatory_tool_failures_total` | counter | runtime, variant |
| `observatory_run_duration` | summary (p50, p95) | runtime, variant, benchmark_category, result |
| `observatory_run_tool_calls` | summary | ″ |
| `observatory_run_model_calls` | summary | ″ |
| `observatory_run_tokens` | summary | ″ |
| `observatory_run_acceptance_rate` | summary | ″ |

Runs classified F13/F15 are counted in `observatory_runs_total` with `result=discarded`
and are recorded in **none** of the summaries: their behaviour is zeroed, not small, and
feeding those zeros into a percentile invents a run nobody made.

### Cardinality rule

**Never** put these into Prometheus labels:

```text
run_id · prompt_id · commit_sha · file_path · user_email
```

Use Tempo or PostgreSQL for individual run details. Reasonable dimensions are:

```text
runtime=github|anthropic|openai|manual     # the run's runtime.provider, not the product
variant=baseline|instructions|skill|agent
benchmark_category=bugfix|feature|review|migration
result=pass|fail|discarded                 # discarded = F13/F15 infrastructure failure
team=<small controlled set>
```

The `runtime` label carries the **provider** (`github`, `anthropic`, `openai`), not the
product name (`copilot-cli`, `claude-code`, `codex`). The product and version are on the
run record in PostgreSQL, where they cost nothing in cardinality.

Even team and user dimensions need a privacy and cardinality review. The purpose is to
evaluate the **system**, not to rank developers.

This rule is enforced by tests: `ObservatoryFlowTest` scrapes `/actuator/prometheus` and
asserts the run id is absent, and `make smoke` repeats the check against a live stack.

---

## Failure taxonomy

Every failed run is classified. This is far more useful than a generic `FAIL` counter —
if `AGENTS.md` reduces F02 but increases token use, that is actionable.

```text
F01 requirement misunderstood     F09 tool execution failure
F02 wrong architecture assumption F10 permission failure
F03 incorrect code                F11 context/retrieval failure
F04 build failure                 F12 retry loop / non-convergence
F05 test failure                  F13 timeout/rate limit
F06 insufficient tests            F14 safety/policy violation
F07 unnecessary changes           F15 evaluator/infrastructure failure
F08 hallucinated API/dependency
```

**F13 and F15 are not agent failures.** They blame the harness or the environment, so the
comparison endpoint and the Prometheus summaries exclude them — see *Reading a comparison
honestly* below. Classifying a quota exhaustion as F03 instead would silently turn a
billing problem into evidence against a variant; that mistake has already been made once.

---

## Metrics that must NOT become KPIs

```text
number of prompts          number of AI-created PRs
number of generated lines  raw token consumption
number of active users
```

These are adoption/activity metrics, not engineering impact. A team can generate more
code and become slower.

The long-term hierarchy:

```text
L1 — Agent execution     tokens, duration, tool calls, retries
L2 — Task quality        acceptance, tests, review findings, safety
L3 — Engineering impact  cycle time, rework, defects, change failure, developer effort
```

Phase 0 covers **L1 + L2 only**. Do not attempt to prove organizational ROI before the
benchmark/evaluation foundation works.

---

## Reading a comparison honestly

A run can be *fast + cheap + wrong*, or *slow + expensive + correct*. There is no single
composite score, because one number hides that trade-off.

Agent runs are non-deterministic: one successful run proves very little. The minimum
learning sample is **5 runs per variant**, and 10 is a better first comparison. The
comparison endpoint returns an explicit `warning` when a variant is below that threshold,
and the Compare page renders it.

**Not every recorded run measures the variant.** F13 (timeout/rate limit) and F15
(evaluator/infrastructure failure) blame the harness or the environment: an exhausted
quota measures the billing account, and a broken evaluator measures the instrument. The
comparison endpoint excludes those runs from `passRate`, `acceptanceRate` and every
median, and — the part that actually bit us — from the count checked against the 5-run
minimum. A run that never executed must not make a variant look worse, nor make an
under-powered arm look adequately sampled.

### Tokens are not one number

`medianTokens` is **input + output only**. On a Claude/haiku BE-002 run that is 8.8k
tokens — beside **1.03M** cache reads, so the headline figure sees under 1% of what the
model actually processed. The comparison therefore reports `medianCachedTokens` and
`medianEstimatedCost` alongside it.

This matters specifically for instruction-file experiments: an `AGENTS.md` adds context
to every request, and with prompt caching that lands almost entirely in cache creation
and reads. Comparing B0 with B1 on input+output alone would exclude the cost of the one
thing being varied. Cost is null where the runtime documents none — a variant that
reports nothing must never render as free.

They are not hidden either: each variant reports `infrastructureFailures`, shown on the
Compare page as the *discarded (F13/F15)* row. `runs` is therefore the number of
**measuring** runs, while `totalRuns` still counts everything recorded. Every other
failure class stays in the aggregates — F03 is a result, not an accident.
