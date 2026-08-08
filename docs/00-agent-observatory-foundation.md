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
| M10 | Claude Code adapter | same benchmark appears beside Copilot | open |
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
- [ ] We have at least five *real* clean baseline runs. — requires an agent runtime;
      `make demo` seeds synthetic teaching data, which is explicitly not a measurement.
- [ ] We know the baseline's variance and common failure modes. — follows from the above.
- [x] We have not changed agent instructions merely to make charts look better.

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
