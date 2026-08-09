# Where this project stands

Handoff note. Read this first when picking the work back up.

## Status: instrument works, no experiment has ever produced a valid result

Chapter 00 M0–M10 is built, tested and merged. `make up && make demo` works. The instrument
was hardened substantially on 2026-08-09.

**Four experiments attempted. All four void.**

| experiment | why it is void |
|---|---|
| `EXP-BE002-AGENTSMD` | answer key in the agent's **working tree** |
| `EXP-BE002-AGENTSMD-V2` | #28 removed it from the tree, left it in **git history** |
| `EXP-BE002-AGENTSMD-V3` | **the treatment was never loaded** — see below |
| `EXP-BE002-MODEL-TIER` | permission confound, and its registration was committed after nine runs had started |

### V3 is void because Claude Code does not read `AGENTS.md`

This one was written up as a concluded result — `INCONCLUSIVE`, cost −12.8% at p = .04, pass
rate 80% → 100%. **The comparison was baseline against baseline.**

`agents-md-v1` is a Copilot-native customization. It was run against Claude, which loads
`CLAUDE.md`. Verified by controlled test: an identical file named `CLAUDE.md` is read, and
`AGENTS.md` is not. The runner installed the file, hashed it into `instructionsHash`, and
all ten B1 runs carried the same hash — so it looked perfectly applied. It was applied to
disk and never read.

That also resolves the replication anomaly logged below as unexplained: two "different"
haiku arms four hours apart differed by 8/10 vs 10/10 and 19 vs 14 tool calls, **the same
magnitude as the "effect"** — because both were in fact identical configurations.

Found in review of PR #33, not by two audit passes. The lesson is in "The thing most worth
remembering" at the bottom.

**The upside:** the AGENTS.md question has never actually been tested. Rename the file to
`CLAUDE.md` and its four predictions are live and untouched — a ~$4 experiment that would be
this project's first real result.

### Resuming mid-experiment

Run results are persisted in PostgreSQL by the runner, not held in any session, so a
batch that is still running loses nothing when a context is cleared. To pick up:

```bash
curl -fsS http://localhost:8081/api/runs \
  | jq -r '[.[]|select(.experimentKey=="EXP-BE002-AGENTSMD-V3")]
           | sort_by(.startedAt) | .[]
           | "\(.variant) pass=\(.evaluation.passed) class=\(.evaluation.failureClass // "-")"'
```

`ps -ef | grep run-agent` shows whether a batch is still going. Re-running a batch that
already completed would produce more than the registered 10 runs per arm, which the
analysis tool refuses to score — so check the count before launching anything.

## The finding that invalidates the previous results

**The benchmark's answer key reached the agent — first in the working tree, then, after
that was fixed, in git history.**

`run-agent.sh` handed the agent a `git worktree` of the benchmarks repo, which contains:

```
tasks/BE-00X-.../acceptance/*.kt        the exact tests the run is graded on
tasks/BE-00X-.../fixtures/known-good/   a model solution
tasks/BE-00X-.../evaluator.sh           the checks and their exit codes
README.md                               since 2026-08-09, the trap described in prose
```

Proof it is not theoretical: pilot run `a69933a0` ended its own summary with *"This will
run the existing OrderControllerTest suite plus the new **BE002FunctionalTest** and
**BE002ContractTest** acceptance tests."* Those filenames exist nowhere but the answer
directory.

**#28 did not close it.** It deleted those paths from the working tree and committed the
deletion, but a worktree shares its parent repository's object store, so inside the
"stripped" tree both of these still worked — and were run against the live worktree of a
run that was executing at the time:

```
git show --stat HEAD    # the setup commit's diff, naming BE002FunctionalTest.kt,
                        # BE002ContractTest.kt, evaluator.sh, fixtures/known-good/
git show HEAD^:tasks/BE-002-…/fixtures/known-good/…/OrderController.kt   # the solution
```

The setup commit's own message, *"strip benchmark authoring material from the worktree"*,
advertised that the material existed and had a previous state.

**These are harness bugs five and six, and the only two that flatter the agent.** The
other four all made runs look worse than they were, which is easy to notice. A bias toward
good results is not — and the second one survived a fix aimed directly at it.

### The symptom that was already explained, and therefore never re-checked

Median cost and tool calls across every BE-002 stage, now that a clean arm exists:

| stage | answer key reachable via | cost | tool calls | pass |
|---|---|---:|---:|---:|
| pilot (n=5) | working tree | $0.213 | 20 | 4/5 |
| post-README (n=3) | working tree + README prose | $0.115–0.143 | 9–13 | — |
| V2 baseline (n=4) | git history only | $0.108–0.174 | 11–17 | 4/4 |
| **V3 baseline (n=10)** | **nothing** | **$0.190** | **19.5** | **8/10** |

The drop from the pilot's 20 tool calls to ~13 was written up as corroboration of the
working-tree leak. It survived the fix for that leak completely, and **it did not survive
removing the git-history route either — the clean arm is back at 19.5 tool calls and
$0.190, statistically indistinguishable from the pilot.**

So the attribution was wrong twice over. The most likely cause of the dip is mundane:
#28 shrank the tree from the whole benchmarks repo to `sample-service`, and a smaller
tree takes fewer calls to explore. Nothing to do with reading the answer.

**A symptom with an explanation attached stops being treated as evidence.** The drop had a
name, so nobody asked whether it disappeared when the named cause was removed — and it
didn't, through two fixes. That check costs one query and is the only thing that would
have caught either leak earlier.

What the leaks actually cost is still unmeasured. The clean arm's pass rate is 8/10 against
the leaking arm's 4/4, and its two failures are both F07, but those are different n and
different runs; treat it as suggestive, not as a measured effect.

### What it invalidates and what survived

- The BE-002 pilot (5 runs, 4 pass / 1 F07) and the power estimates derived from it.
- **`EXP-BE002-AGENTSMD` is void** (3 of 20 runs) and **`EXP-BE002-AGENTSMD-V2` is void**
  (4 of 20 runs, all baseline, all passing).
- **`EXP-BE001-CLEAN` did not test what it claimed.** Its 5/5 pass, median 15 tool calls,
  $0.155, 103 s were measured on the stripped worktree — i.e. with the answer key still
  reachable through git. "Removing the answer key did not make BE-001 harder" was not
  tested. Whether BE-001 is genuinely easy is an open question again. Building BE-002 is
  still justified on its own merits, but that $0.75 disproof needs re-spending if the
  BE-001 claim is ever load-bearing.

## Recommended next sequence

1. ~~Fix the leak.~~ **Done twice.** #28 stripped the working tree and missed git history;
   the runner now builds the agent's tree with `git archive` of an allowlist into a fresh
   `git init`, and asserts on every run that there is exactly one commit and no object
   under `tasks/`.
2. ~~5 clean BE-001 runs.~~ **Superseded** — they were not clean. See above.
3. ~~B0 arm of `EXP-BE002-AGENTSMD-V3`.~~ **Done** — 10 runs, 8 pass / 2 F07 / 0 F02.
4. ~~Re-derive the MDE and register it before any B1 run exists.~~ **Done** — Amendment 2.
   Cost 19% → **24%**, tool calls 30% → **36%**, cache 36% → **32%**, duration
   unusable at **175%**. The clean task is more variable than the contaminated pilot
   implied, so the experiment is less sensitive than it was sold as.
5. ~~Run the B1 arm and score it.~~ **Void** — the B1 arm installed `AGENTS.md`, which
   Claude Code does not read. Both arms were baseline. The `instructionsHash` matched
   across all ten runs and certified a treatment that never reached the model.
6. ~~Commit and PR the working tree.~~ **Done** — #30, #32, #33, #44 and benchmarks#8.
7. **Run the experiment for real — this is the next action.** `agents-md-v1` renamed to
   `CLAUDE.md`, as `EXP-BE002-CLAUDEMD`. The four predictions in the registration have
   never been tested and stand unmodified; §32 still forbids editing the instruction file
   in response to results. Budget ~$4 and ~40 minutes. Do not launch before the runtime
   guard (below) is in place, or the same failure is available again.
8. **Then stop fixing the instrument.** Seven PRs' worth of hardening on 2026-08-09 was
   defensible and none of it was a result. Instrument work is unbounded and always more
   satisfying than an experiment that may conclude "no effect". Publish with the caveats
   that remain.

   The counter-argument, and the reason step 1 happened twice: two of those bugs were
   *validity* bugs, not polish, and the second was found only because someone re-checked a
   fix that had already been declared done. "Stop fixing the instrument" means stop
   polishing it. It does not mean stop verifying the claims it rests on — and the way to
   tell them apart is whether a bug changes what a number *means* or only how it looks.

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

## Uncommitted, in the working tree

Not yet committed or PR'd — do this before anything else:

| file | |
|---|---|
| `runner/run-agent.sh` | build the agent's repo from an allowlist via `git archive` + `git init`; assert one commit and no `tasks/` objects |
| `runner/derive-mde.py` | re-derive the MDE from a measured arm; refuses a partial arm |
| `runner/test_derive_mde.py` | 19 tests — the formula, the exclusions, the incomplete-arm gate |
| `runner/analyze-experiment.py` | MDE table updated to Amendment 2 (cost bar 19% → 24%) |
| `docs/preregistration-…md` | Void (2), the replacement key `-V3`, and Amendment 2 |
| `docs/STATE.md` | this file |

Full suite green: `make test-runner` → 47 tests.

Not done: a recorded UAT of the five questions; making `BehaviorDto`'s counters nullable so
a telemetry gap stops being indistinguishable from a genuine zero.

**M11 is decided** — deferred to Chapter 01, written up in
[ADR-001](adr-001-defer-codex-adapter.md). Chapter 00 closes at two runtimes. The short
version: a third adapter adds integration surface rather than answers, the bottleneck is
benchmark tasks and not runtimes, and an adapter no experiment exercises is where the
seventh harness bug would hide.

## Practical notes

- `make build-api` **before** `docker compose build` — the image copies a host-built jar,
  so rebuilding without it silently ships a stale API. Cost a confused debugging round.
- Claude/haiku BE-002 run on a clean tree: mean **$0.204**, median $0.190, SD $0.038,
  ~82–167 s (n=10). **Budget ~$4.10 for a 10+10.** The spread is wide enough that single
  runs mean nothing — the first clean run was $0.279 / 27 calls and looked like a
  discovery until nine more arrived.
- `make run-benchmark RUNTIME=claude MODEL=haiku BENCHMARK=BE-002` — Copilot's quota is
  exhausted; Claude is not rate-limited here.
- Cheapest Copilot model is `gpt-5.4-mini` (0 premium requests, verified by probing).
- Host ports are overridden in `infra/.env` (gitignored): Grafana 3001, API 8081, web 5174.
- Claude runs have `traceId: null` by design (#20 refused to fake span parity), so the
  five-questions walkthrough needs a Copilot run.

## The thing most worth remembering

Six bugs have now made the harness measure something other than the agent:

1. `AGENTS.md`, installed by the runner, counted as an agent scope violation.
2. An exhausted Copilot quota recorded as **F03, incorrect code**.
3. A background daemon's `.memdb/` files counted as unrelated production changes.
4. An acceptance suite's compiled classes, surviving in gitignored `target/`, running as
   "the existing tests" on the next evaluation of the same worktree.
5. **The answer key shipped in the agent's worktree.**
6. **The answer key stayed in the agent's git history after 5 was "fixed".**

The first four all made runs look **worse** than they were. Five and six make them look
**better**, and between them they survived every review the project has had — which is the
lesson. Errors that flatter a result do not announce themselves; nobody investigates a
pass.

Six adds a second lesson, and it is the sharper one. The evidence for five — a 35% drop in
tool calls — was still there after five was fixed, and no one looked, because that drop
already had a name. **An explained symptom stops being evidence.** A fix is not confirmed
by the story that motivated it; it is confirmed by the symptom disappearing, or by an
assertion that fails loudly when the leak returns. There is now such an assertion, and it
runs on every run.

Disbelieve a dramatic number until it is explained, and disbelieve a flattering one twice.
Then check that the explanation still predicts the number after you have acted on it.
