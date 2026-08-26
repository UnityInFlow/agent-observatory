# Contributing

This repository is the instrument. It decides whether one way of building an agent beat
another, so a bug here does not crash — it returns a confident wrong answer, and every
result computed afterwards inherits it.

## The rules that are not negotiable

**Unknown data remains unknown.** A gap is `null`, never a plausible number. A default that
reads as a measurement is worse than a missing value, because nothing downstream can tell
them apart. `BehaviorDto` defaulting to `0` is the standing example: a collector gap becomes
a genuine zero at write time, and two separate consumers now have to *infer* absence from a
value pattern because the fact was never recorded.

**A run that fails a quality gate is unsuccessful even when it used fewer tokens.** Compare
efficiency only among runs that passed. Without it, the arm that gave up fastest wins.

**Analysis is chosen before the data exists.** `analyze-experiment.py` fails closed and
refuses to compute anything until the dataset matches the pre-registration exactly, so it
cannot be re-run during a batch until the p-value looks good. Do not add an escape hatch. If
you need one, the registration was wrong and should be amended in the open.

**Documenting a bug is not fixing it.** A schema note constrains nothing until something
executes and rejects the bad value. Classify every fix by layer and be honest when the
answer is L3.

## Before you open a PR

```bash
make test-runner    # seconds — the statistics that decide a verdict
make test-web       # type-check, lint, build
make test-api       # minutes — Testcontainers starts a real PostgreSQL, needs Docker
```

CI runs these as three separate jobs so a Python typo does not wait behind an image pull.

## Changing how a metric is computed

Say so explicitly in the PR, and identify every past result that used the old computation.
A metric that changes definition silently makes two experiments incomparable while both
still look valid — which is indistinguishable, later, from an effect.

## The runner has no dependencies, deliberately

> "No third-party dependencies: this machine has no scipy, and a benchmark harness should
> not need one."

The Mann-Whitney implementation is hand-written and documented as conservative at n=10,
which is the right direction to be wrong in. Adding a dependency to `runner/` needs an
argument, not just a convenience.

## Commit messages

Explain what changed and why it is now correct. Where a fix corrects an earlier mistake,
leave the mistake legible — a future reader needs to know the trap was there. Name the
affected runs or experiments when there are any.

## What does not belong here

Tasks, evaluators and fixtures live in
[`agent-observatory-benchmarks`](https://github.com/UnityInFlow/agent-observatory-benchmarks).
Curriculum, labs and findings live in
[`agent-learning-lab`](https://github.com/UnityInFlow/agent-learning-lab). This repository
holds the runner, the evaluator plumbing, the analyzer, the API and the dashboards.
