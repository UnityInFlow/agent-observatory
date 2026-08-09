# Where this project stands

Handoff note. Read this first when picking the work back up.

## Status: platform complete, first real agent failure recorded, no conclusion yet

Chapter 00 M0–M10 is built, tested and merged. `make up && make demo` brings the whole
ecosystem up from a clean slate in ~40 seconds.

BE-002 now exists and **has produced the first genuine agent failure in this project's
history**. What is still missing is a comparison that concludes anything.

## Where the science actually is

| benchmark | runtime | runs | result |
|---|---|---:|---|
| BE-001 | Copilot / `gpt-5.4-mini` | 10 + 4 | all pass |
| BE-001 | Claude Code / `haiku` | 3 | all pass |
| **BE-002** | **Claude Code / `haiku`** | **5** | **4 pass, 1 fail (F07)** |

The BE-002 failure is real and was verified by reading the diff: the agent wrote
`run_tests.sh` into the repository root and left it there. Build, tests and both
acceptance suites passed; the scope guard rejected it.

Two honest caveats on BE-002, both written up in
[`00-agent-observatory-foundation.md`](00-agent-observatory-foundation.md):

- **It missed its own exit criterion.** benchmarks#6 asked for a baseline failing 30–70%
  of runs. It failed 20%.
- **Its designed discriminator never fired.** BE-002 was built around an error-contract
  trap; the agent matched the envelope in every run that reached that check. The F02 exit
  path is decoration so far.

## Recommended next sequence

1. ~~Merge the instrument fixes~~ **Done** — [#21](https://github.com/UnityInFlow/agent-observatory/pull/21)
   (F13/F15 excluded from aggregates) and [#22](https://github.com/UnityInFlow/agent-observatory/pull/22)
   (cache tokens + cost) are merged. **Rebuild the API image before measuring anything** —
   a container started before #21 still counts F13/F15 toward aggregates.
2. **Run B0 vs B1 on BE-002 at 10 runs per variant** with `experiments/agents-md-v1/`
   **unchanged**. It already forbids exactly the behaviour that failed run 3, and it was
   written before BE-002 existed — instructions that pre-date the benchmark are much
   stronger evidence than a variant authored after seeing the failures (§32).
3. **Treat that comparison as exploratory, and say so before running it.** At n=10 per
   arm a pass rate of 80% → 100% is p ≈ 0.47 — invisible. The continuous metrics are
   better but not by much: the minimum detectable effect is **16% on duration, 19% on
   cost, 30% on tool calls, 36% on cache tokens**. Primary metric is median cost. Anything
   smaller is a direction to investigate at larger n, not a finding.

Also open: [#10](https://github.com/UnityInFlow/agent-observatory/issues/10) Codex adapter,
[#11](https://github.com/UnityInFlow/agent-observatory/issues/11) governance checklist.
Neither unblocks anything.

## Known gaps in the instrument

- **The web app has no tests.** `make test-web` is `tsc -b && vite build` plus a linter —
  no component tests, no e2e, and no recorded UAT of the Compare page, which §18 calls the
  most important screen.
- **No human review has ever been recorded.** 21 runs, 21 evaluations, 0 reviews, although
  every `evaluation.json` says `humanReview.required: true`. The L2 review dimension is
  unexercised.
- **Claude runs have no trace.** Claude Code emits log events, not spans, so `traceId` is
  null and the five-questions walkthrough (§ "the agent loop we are observing") cannot be
  done on the only runtime that is not rate-limited. Deliberate — #20 refused to fake span
  parity — but it means the teaching flow currently needs Copilot.

## Practical notes for the next session

- **Copilot quota was exhausted** during earlier work. Claude Code is not rate-limited
  here: `make run-benchmark RUNTIME=claude MODEL=haiku BENCHMARK=BE-002`.
- A BE-002 Claude/haiku run costs about **$0.21** and takes ~130 s, so a 10+10 comparison
  is roughly **$4 and 45 minutes**.
- **Cheapest Copilot model is `gpt-5.4-mini`** — 0 premium requests, verified by probing.
  `gpt-5-mini` costs 0.33. `claude-haiku-4-5` and `gemini-2.5-flash-lite` are unavailable.
- **Host ports are overridden locally** in `infra/.env` (gitignored) because 3000, 8080 and
  5173 are taken on this machine. Local: Grafana 3001, API 8081, web 5174. A fresh clone
  uses the committed defaults.
- `make demo` seeds **synthetic** data under `DEMO-001`/`EXP-DEMO`, never under a real
  benchmark id. It is teaching material, not measurement.

## The thing most worth remembering

Four separate bugs made the harness blame the **agent** for something the harness or the
environment did:

1. `AGENTS.md`, installed by the runner, counted as an agent scope violation.
2. An exhausted Copilot quota recorded as **F03, incorrect code**.
3. A background indexing daemon's files (`.memdb/`) counted as unrelated production changes.
4. An acceptance suite's compiled classes, surviving in gitignored `target/`, running as
   "the existing tests" on the next evaluation of the same worktree.

All four are fixed. All four failed in the **same direction — making runs look worse than
they were**. A measurement tool whose errors are one-directional is worse than a noisy one,
because the bias survives averaging.

The corollary earned its keep this week: run 3 of BE-002 was checked against the actual
diff before being called an agent failure. It survived that check — which is why it can be
believed.
