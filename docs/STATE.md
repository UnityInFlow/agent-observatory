# Where this project stands

Handoff note. Read this first when picking the work back up.

## Status: Chapter 00 platform complete, science blocked

Everything in Chapter 00 M0–M9 plus the Claude adapter (M10) is built, tested and merged.
`make up && make demo` brings the whole ecosystem up from a clean slate in ~40 seconds.

What is **not** done is the science, and there is exactly one reason.

## The blocker

**BE-001 cannot discriminate.** It has never produced a single genuine agent failure:

| run set | result |
|---|---|
| Copilot / `gpt-5.4-mini` baseline | 10/10 pass |
| Copilot / `gpt-5.4-mini` + `AGENTS.md` | 4/4 pass |
| Claude Code / `haiku` baseline | 3/3 pass |

The only failure ever recorded was a Copilot quota exhaustion (F13). So the AGENTS.md
experiment could not conclude anything, and the F01–F15 taxonomy has never been exercised.

→ Tracked as **[benchmarks#6 — BE-002, a benchmark that can actually discriminate](https://github.com/UnityInFlow/agent-observatory-benchmarks/issues/6)**.

## Recommended next sequence

1. ~~**[#19](https://github.com/UnityInFlow/agent-observatory/issues/19)** — exclude F13/F15
   runs from aggregates and the sample-size warning.~~ **Done.** `ComparisonService` now
   partitions infrastructure failures out of every aggregate and out of the 5-run minimum,
   and reports them as `infrastructureFailures` (Compare page: *discarded (F13/F15)*).
   No more hand-correction of published numbers.
2. **[benchmarks#6](https://github.com/UnityInFlow/agent-observatory-benchmarks/issues/6)** — BE-002. Authoring costs no agent quota.
3. Re-run B0 vs B1 on BE-002 at **10 runs per variant** (§20) for the first evidence-based keep/reject decision.

Also open: [#10](https://github.com/UnityInFlow/agent-observatory/issues/10) Codex adapter, [#11](https://github.com/UnityInFlow/agent-observatory/issues/11) governance checklist. Neither unblocks anything.

## Results recorded so far

Full detail in [`00-agent-observatory-foundation.md`](00-agent-observatory-foundation.md).

- **Baseline variance (Copilot, n=5):** 100% pass, but **1.9× spread** in tool calls
  (9–17) and 1.8× in tokens. Correctness stable, cost is not. Any customization must beat
  this spread before a result means anything.
- **B0 vs B1 (`AGENTS.md`):** no detectable effect. Every instructions value fell inside
  the baseline range; tokens went slightly *up*. Rejected on this evidence — the honest
  conclusion is "this benchmark cannot tell", not "AGENTS.md does not help".
- **Runtime comparison (BE-001):** Copilot/gpt-5.4-mini 10/10 vs Claude/haiku 3/3. Median
  model calls 9 vs 20; duration 40 s vs 93 s. This measures the whole harness + model
  combination, never the model alone.

## Practical notes for the next session

- **Copilot quota was exhausted** during this work. Claude Code is not rate-limited here
  and is the runtime to use meanwhile: `make run-benchmark RUNTIME=claude MODEL=haiku`.
- **Cheapest Copilot model is `gpt-5.4-mini`** — 0 premium requests, verified by probing.
  `gpt-5-mini` costs 0.33. `claude-haiku-4-5` and `gemini-2.5-flash-lite` are unavailable.
- **Host ports are overridden locally** in `infra/.env` (gitignored) because 3000, 8080 and
  5173 are taken on this machine by other services. Local: Grafana 3001, API 8081, web 5174.
  A fresh clone uses the committed defaults.
- `make demo` seeds **synthetic** data under `DEMO-001`/`EXP-DEMO`, never under a real
  benchmark id. It is teaching material, not measurement.

## The thing most worth remembering

Three separate bugs made the harness blame the **agent** for something the harness or the
environment did:

1. `AGENTS.md`, installed by the runner, counted as an agent scope violation — failed an
   entire treatment arm and would have read as a 100% → 0% collapse caused by AGENTS.md.
2. An exhausted Copilot quota recorded as **F03, incorrect code**.
3. A background indexing daemon's files (`.memdb/`) counted as unrelated production changes.

All three are fixed. All three failed in the **same direction — making runs look worse
than they were**. A measurement tool whose errors are one-directional is worse than a
noisy one, because the bias survives averaging. Treat every future result from this
harness with that in mind, and prefer disbelieving a dramatic number until it is explained.
