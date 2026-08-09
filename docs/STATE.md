# Where this project stands

Handoff note. Read this first when picking the work back up.

## Status: instrument fixed, one arm of the real experiment running

Chapter 00 M0–M10 is built, tested and merged. `make up && make demo` works. The
instrument was hardened substantially on 2026-08-09 (six PRs, below).

**No experiment has ever concluded.** One was attempted on 2026-08-09 and voided after
three runs, because of the leak described below. The leak is now fixed (#28) and the
replacement experiment is under way.

### Resuming mid-experiment

Run results are persisted in PostgreSQL by the runner, not held in any session, so a
batch that is still running loses nothing when a context is cleared. To pick up:

```bash
curl -fsS http://localhost:8081/api/runs \
  | jq -r '[.[]|select(.experimentKey=="EXP-BE002-AGENTSMD-V2")]
           | sort_by(.startedAt) | .[]
           | "\(.variant) pass=\(.evaluation.passed) class=\(.evaluation.failureClass // "-")"'
```

`ps -ef | grep run-agent` shows whether a batch is still going. Re-running a batch that
already completed would produce more than the registered 10 runs per arm, which the
analysis tool refuses to score — so check the count before launching anything.

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

### What it invalidates and what survived

- The BE-002 pilot (5 runs, 4 pass / 1 F07) and the power estimates derived from it.
- **`EXP-BE002-AGENTSMD` is void.** 3 of 20 runs completed; the batch was stopped.
- **Not** the BE-001 diagnosis, as it turns out. Five clean BE-001 runs on a stripped
  worktree (`EXP-BE001-CLEAN`, 2026-08-09) passed **5/5**: median 15 tool calls, $0.155,
  103 s. Removing the answer key did not make BE-001 harder, so "BE-001 is too easy" was
  the right call all along and building BE-002 was justified. The hypothesis that the
  answer key had been doing the work was worth $0.75 to disprove rather than carry.

## Recommended next sequence

1. ~~Fix the leak.~~ **Done** — #28 strips the worktree to `sample-service` + `.gitignore`
   as a setup commit, allowlist not denylist.
2. ~~5 clean BE-001 runs.~~ **Done** — 5/5 pass, see above.
3. **10 + 10 on BE-002** as `EXP-BE002-AGENTSMD-V2`, per
   [`preregistration-exp-be002-agentsmd.md`](preregistration-exp-be002-agentsmd.md).
   The B0 arm was launched on 2026-08-09 and may still be running — check before starting
   anything. **Re-derive the MDE from the clean B0 arm and register it as Amendment 2
   before any B1 run exists**; that ordering is the point. Then run 10 B1 with
   `CUSTOMIZATION=experiments/agents-md-v1` **unchanged**, and score with
   `runner/analyze-experiment.py EXP-BE002-AGENTSMD-V2`, which refuses anything but the
   registered dataset. Predictions are unchanged; they never depended on the pilot.
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
| [#26](https://github.com/UnityInFlow/agent-observatory/pull/26) | `analyze-experiment.py` — fails closed, emits REJECT/KEEP/INCONCLUSIVE, 28 tests |
| [#27](https://github.com/UnityInFlow/agent-observatory/pull/27) | handoff rewritten after the answer-key finding |
| [#28](https://github.com/UnityInFlow/agent-observatory/pull/28) | **strip the answer key from the agent's worktree** |
| [bench#7](https://github.com/UnityInFlow/agent-observatory-benchmarks/pull/7) | BE-002 |

No PRs open.

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
