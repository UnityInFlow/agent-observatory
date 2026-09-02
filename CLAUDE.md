# agent-observatory

The instrument. It decides whether one way of building an agent beat another, so a bug here
does not crash — **it returns a confident wrong answer**, and every result computed
afterwards inherits it.

## Commands

```bash
make help                # every target, described
make test-runner         # seconds — the statistics that decide a verdict
make test-web            # type-check and build
make test-api            # minutes — Testcontainers starts a real PostgreSQL, needs Docker
make up / down / logs    # the full stack
make smoke               # end-to-end against a running stack
```

CI splits these into three jobs so a Python typo does not wait behind an image pull. The web
job also runs `npm run lint`, which `make test-web` does not.

**Ports:** 3000, 8080 and 5173 are taken on this machine. The API publishes on **8081**, the
web UI on **5174**. `infra/.env` is gitignored and holds the overrides; `infra/.env.example`
is the template.

## Rules that are not negotiable

**Unknown data remains unknown.** A gap is `null`, never a plausible number. A default that
reads as a measurement is worse than a missing value, because nothing downstream can tell
them apart.

**A run that fails a quality gate is unsuccessful even when it used fewer tokens.** Compare
efficiency only among runs that passed — `analyze-experiment.py` implements this as §13.1.
Without it, the arm that gave up fastest wins.

**The analysis is chosen before the data exists.** `analyze-experiment.py` fails closed and
refuses to compute anything until the dataset matches the pre-registration exactly, so it
cannot be re-run mid-batch until the p-value looks good. **Do not add an escape hatch.** If
you need one, the registration was wrong and should be amended in the open.

**The runner has no third-party dependencies, deliberately.** The Mann-Whitney implementation
is hand-written and documented as conservative at n=10 — the right direction to be wrong in.

## The standing data-integrity flaw

`Dtos.kt` — `BehaviorDto` defaults every counter to `0`, so a collector gap is stored
indistinguishable from a genuine zero. Two consumers now *infer* absence from a value
pattern (`modelCalls == 0 && toolCalls == 0`) because the fact was never recorded:
`has_behavior_telemetry` in `analyze-experiment.py:75`, and `hasBehaviorTelemetry` in
`observatory-web/src/api.ts`. Keep them in sync until a `telemetryComplete` field replaces
both. See issue #52.

All 17 affected runs are F13/F15 infrastructure failures, already excluded three ways. **No
live result depends on them** — this is a class of fabrication to remove, not damage to
repair.

Related: **the runner validates a run record; the database still does not.** Three artifacts
describe its shape. `runner/schemas/run.schema.json` used to be loaded by no code at all while
looking exactly like enforcement — and it had drifted three migrations behind the payload, so
wiring it in as it stood would have rejected every run. `run-agent.sh` now validates against it
before the POST, via the stdlib-only `runner/validate-run-record.py`.

That is L2 for every record any experiment has produced, because they all come through the
runner. It is **not** L2 for the database: a direct `POST /api/runs` still bypasses it, and
`Dtos.kt` remains the only check on that path — four `@NotBlank` strings. Closing it needs the
check inside the API. Issue #53, steps 2, 3, 4 and 6 still open.

If you add a keyword to `run.schema.json`, expect the validator to refuse it until someone
implements it. That is deliberate: it implements a subset of draft 2020-12, and a subset that
silently ignores what it does not understand reports a success it never checked.

## When changing how a metric is computed

Say so explicitly and identify every past result that used the old computation. A metric that
changes definition silently makes two experiments incomparable while both still look valid —
which is indistinguishable, later, from an effect.

## Before blaming the agent

Ask what else changed. Seven of this project's findings were harness bugs, and the two that
survived review longest were the two that made the numbers look good. Disbelieve a flattering
result twice.
