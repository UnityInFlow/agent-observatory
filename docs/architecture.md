# Architecture

## Three stores, three jobs

The first architecture deliberately separates **raw vendor telemetry** from **our
evaluation model**.

```text
Copilot CLI / Claude Code / Codex
       │  OTLP traces + metrics + logs (metadata only)
       ▼
OpenTelemetry Collector  ── attributes/scrub ──┐
       │                                       │
       ├──────────────► Tempo ────────► Grafana Trace UI
       └──────────────► Prometheus ───► Grafana Metrics UI

Benchmark Runner
       ├── launches the agent run
       ├── records run metadata + customization hashes
       ├── executes the deterministic evaluator
       └── writes the evaluation result
                       │
                       ▼
                 Observatory API  (Kotlin / Spring Boot)
                       │
                       ▼
                  PostgreSQL  ──►  React Web App
```

| Store | Holds | Why |
|---|---|---|
| **Tempo** | trace ids, span ids, model calls, tool spans, durations, vendor attributes | high-cardinality, per-run detail |
| **Prometheus** | run counts, pass/fail rate, duration/token distributions, tool-failure rate | low-cardinality aggregates only |
| **PostgreSQL** | benchmark definitions, run metadata, customization hashes, evaluations, human review, failure classification | experiment truth |

Do not put everything in one database simply because the first prototype allows it.

The web app does **not** replace Grafana or Tempo:

- **Tempo/Grafana** — inspect what technically happened during a run.
- **Observatory UI** — compare runs, experiments, correctness and quality.

---

## Why OpenTelemetry is the common foundation

All three runtimes expose useful agent telemetry through OpenTelemetry or an
OTLP-compatible mechanism, but they do **not** agree on semantics. We normalize *above*
the raw telemetry layer instead of forcing false parity.

```text
Copilot → rich traces + metrics          (invoke_agent → chat / execute_tool)
Claude  → metrics / events / traces      (sessions, tokens, retries, permissions)
Codex   → structured agent-aware events  (approvals, tool results, MCP, network policy)
```

The comparison layer sits above these differences. Do not fabricate a span hierarchy
merely to make Codex look identical to Copilot.

### Correlation

The runner generates `observatory.run.id` **before** the agent starts and passes it via
`OTEL_RESOURCE_ATTRIBUTES`, which Copilot CLI and Claude Code both support:

```bash
OTEL_RESOURCE_ATTRIBUTES="observatory.run.id=${RUN_ID},benchmark.id=BE-001,experiment.variant=baseline"
```

Each run row therefore stores `run_id`, `trace_id` (when available) and a
`telemetry_query_key`. The run-detail page renders an **Open trace in Grafana** deep link
rather than trying to recreate a distributed tracing viewer.

---

## Domain model

Vendor telemetry must never become the domain model.

```text
Experiment ──< AgentRun >── Benchmark
                  │
                  ├── AgentRuntime          (provider, product, version, model)
                  ├── CustomizationSnapshot  (instructions/skills/agent/hooks/mcp hashes)
                  ├── BehaviorMetrics        (model calls, tool calls, failures, retries, permissions)
                  ├── EfficiencyMetrics      (duration, input/output/cached tokens, cost)
                  ├── ChangeSummary          (changed files, added/deleted lines)
                  ├── Evaluation             (1:1, deterministic verdict + failure class)
                  └── HumanReview            (0..n, 1–5 rubric)
```

Adapters produce the *same* `BehaviorMetrics` and `EfficiencyMetrics` regardless of
native field names. The first one, `runner/lib/copilot-telemetry.sh`, reads the run's
trace back out of Tempo and maps it:

| Copilot telemetry | Internal field |
|---|---|
| spans named `chat *` | `behavior.modelCalls` |
| spans named `execute_tool *` | `behavior.toolCalls` |
| `execute_tool` spans with `status.code == 2` | `behavior.toolFailures` |
| `gen_ai.usage.input_tokens` (summed) | `efficiency.inputTokens` |
| `gen_ai.usage.output_tokens` (summed) | `efficiency.outputTokens` |
| `gen_ai.usage.cache_read.input_tokens` (summed) | `efficiency.cachedTokens` |
| `github.copilot.cost` | **not** mapped to `estimatedCost` — see below |

It is the only file that knows Copilot's span names, and it emits nothing
Copilot-specific. Fields Copilot does not expose — retries, permission decisions — stay
`0` rather than being invented.

`github.copilot.cost` is deliberately left out of `estimatedCost`. Copilot does not
document its unit, and §14 only admits a normalized cost "where defensible"; writing an
unverified number into a currency field would silently poison every cost comparison built
on top of it. The raw value is surfaced separately as `vendorCostRaw`.

`null` in `EfficiencyMetrics` is meaningful: it means the runtime does not expose the
value, which is different from zero.

### Why hashes matter

Comparing `baseline` vs `AGENTS.md v1` vs `AGENTS.md v2` is not reproducible if the run
only records `variant = instructions`. Each run references a `customization_snapshot`
holding a hash of the exact files used.

---

## API

```text
POST /api/benchmarks              register/update a benchmark contract
GET  /api/benchmarks
GET  /api/benchmarks/{id}

POST /api/runs                    persist a normalized run record
GET  /api/runs                    ?benchmarkId= &variant= &runtime=
GET  /api/runs/{id}
POST /api/runs/{id}/evaluation    deterministic verdict (idempotent: re-running overwrites)
POST /api/runs/{id}/human-review  1–5 rubric

GET  /api/experiments
GET  /api/experiments/{ref}/comparison   ref = UUID or human key such as EXP-001
```

`GET /actuator/prometheus` exposes the aggregated experiment metrics.

A run for an unregistered benchmark is rejected with 404 — the benchmark contract must
exist before results can be attributed to it.

---

## Evaluation boundary

The evaluator lives in the benchmark repository and is versioned independently
(`evaluatorVersion`), so an old run can be re-judged by a newer evaluator without
touching the platform. Its exit codes carry meaning:

```text
0   all acceptance criteria passed
10  build failure                     (F04)
11  existing tests failed             (F05)
12  acceptance suite failed           (F03)
20  new dependency introduced         (F07)
21  unrelated production files changed (F07)
30  evaluator/infrastructure failure  (F15)
```

An LLM judge is never the correctness gate.
