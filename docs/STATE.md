# Where this project stands

Handoff note. Read this first when picking the work back up.

## Status: the instrument was measuring itself

Chapter 00 M0–M10 is built, tested and merged. `make up && make demo` works. The
instrument was hardened substantially on 2026-08-09 (six PRs, below).

**No experiment has ever concluded.** One was attempted on 2026-08-09 and voided after
three runs. Read the next section before trusting any recorded number.

## The finding that invalidates the previous results

**The benchmark's answer key ships inside the repository the agent is given.**

`run-agent.sh` creates a worktree of the benchmarks repo and points the agent at it. That
worktree contains:

```
tasks/BE-00X-.../acceptance/*.kt        the exact tests the run is graded on
tasks/BE-00X-.../fixtures/known-good/   a model solution
tasks/BE-00X-.../evaluator.sh           the checks and their exit codes
README.md                               since 2026-08-09, the trap described in prose
```

Proof it is not theoretical: pilot run `a69933a0` ended its own summary with *"This will
run the existing OrderControllerTest suite plus the new **BE002FunctionalTest** and
**BE002ContractTest** acceptance tests."* Those filenames exist nowhere but the answer
directory. Corroborating: the three runs after the README gained a BE-002 section used
9–13 tool calls at $0.115–0.143, against pilot medians of 20 and $0.213.

**This is the fifth harness bug, and the first that flatters the agent.** The other four
all made runs look worse than they were, which is easy to notice. A bias toward good
results is not.

### What it invalidates

- The BE-002 pilot (5 runs, 4 pass / 1 F07) and the power estimates derived from it.
- **`EXP-BE002-AGENTSMD` is void.** 3 of 20 runs completed; the batch was stopped.
- Plausibly the entire BE-001 record. Its `fixtures/known-good/` was equally visible for
  all 17 runs. "BE-001 is too easy" may be the wrong diagnosis — it may simply have had
  its answer in the worktree.

## Recommended next sequence

1. **Fix the leak.** Strip the worktree to an allowlist — `sample-service/` only — as a
   setup commit, exactly the pattern `run-agent.sh` already uses to install and commit an
   `AGENTS.md` overlay so the harness's own edits are not blamed on the agent. An
   allowlist, not a denylist: a denylist rots the moment a benchmark adds a file. Safe,
   because the evaluator runs from `BENCH_DIR` in the main repo and copies the acceptance
   suites in at evaluation time — it never reads them from the worktree.
2. **Then 5 clean BE-001 runs, before anything else.** ~$1. If BE-001 starts failing once
   the answer key is gone, that is a better finding than anything BE-002 has produced, and
   it means the benchmark that already exists is usable. If it still passes 5/5, BE-002 is
   the way forward and nothing is lost.
3. **Then 10 + 10 on whichever benchmark discriminates**, per
   [`preregistration-exp-be002-agentsmd.md`](preregistration-exp-be002-agentsmd.md).
   Re-derive the MDE from the clean B0 arm and register it **before** any B1 run exists.
   Predictions are unchanged; they never depended on the pilot's variance.
4. **Then stop fixing the instrument.** Six PRs on 2026-08-09 were all defensible and none
   was a result. Instrument work is unbounded and always more satisfying than an
   experiment that may conclude "no effect". Publish with the caveats that remain.

## Merged on 2026-08-09

| PR | |
|---|---|
| [#21](https://github.com/UnityInFlow/agent-observatory/pull/21) | F13/F15 excluded from aggregates, the §20 minimum, and Prometheus summaries |
| [#22](https://github.com/UnityInFlow/agent-observatory/pull/22) | comparison reports cache tokens (reads + creations) and vendor cost |
| [#23](https://github.com/UnityInFlow/agent-observatory/pull/23) | BE-002 pilot written up, incl. the criterion it missed |
| [#24](https://github.com/UnityInFlow/agent-observatory/pull/24) | stop tracking the Memtrace daemon's state and PID |
| [#25](https://github.com/UnityInFlow/agent-observatory/pull/25) | pre-registration of EXP-BE002-AGENTSMD |
| [bench#7](https://github.com/UnityInFlow/agent-observatory-benchmarks/pull/7) | BE-002 |

Open: [#26](https://github.com/UnityInFlow/agent-observatory/pull/26) — `runner/analyze-experiment.py`,
which fails closed unless the dataset matches the registration and emits exactly
REJECT/KEEP/INCONCLUSIVE. 28 tests via `make test-runner`. Review addressed; ready to merge.

Not done: a recorded UAT of the five questions; a decision on M11 (recommend descoping the
Codex adapter to Chapter 01 **in writing**); making `BehaviorDto`'s counters nullable so a
telemetry gap stops being indistinguishable from a genuine zero.

## Practical notes

- `make build-api` **before** `docker compose build` — the image copies a host-built jar,
  so rebuilding without it silently ships a stale API. Cost a confused debugging round.
- Claude/haiku BE-002 run: ~130 s, ~$0.21 in the pilot, ~$0.12 in the later contaminated
  runs. Budget ~$4 for a 10+10.
- `make run-benchmark RUNTIME=claude MODEL=haiku BENCHMARK=BE-002` — Copilot's quota is
  exhausted; Claude is not rate-limited here.
- Cheapest Copilot model is `gpt-5.4-mini` (0 premium requests, verified by probing).
- Host ports are overridden in `infra/.env` (gitignored): Grafana 3001, API 8081, web 5174.
- Claude runs have `traceId: null` by design (#20 refused to fake span parity), so the
  five-questions walkthrough needs a Copilot run.

## The thing most worth remembering

Five bugs have now made the harness measure something other than the agent:

1. `AGENTS.md`, installed by the runner, counted as an agent scope violation.
2. An exhausted Copilot quota recorded as **F03, incorrect code**.
3. A background daemon's `.memdb/` files counted as unrelated production changes.
4. An acceptance suite's compiled classes, surviving in gitignored `target/`, running as
   "the existing tests" on the next evaluation of the same worktree.
5. **The answer key shipped in the agent's worktree.**

The first four all made runs look **worse** than they were. The fifth makes them look
**better**, and it survived far longer than any of the others — which is the lesson.
Errors that flatter a result do not announce themselves; nobody investigates a pass.

Disbelieve a dramatic number until it is explained, and disbelieve a flattering one twice.
