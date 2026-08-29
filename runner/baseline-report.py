#!/usr/bin/env python3
"""
Report a SINGLE-ARM baseline from the Observatory API — median and spread, never a mean alone.

    ./runner/baseline-report.py EXP-B2-BASELINE-CLAUDE
    ./runner/baseline-report.py EXP-B2-BASELINE-CLAUDE EXP-B2-BASELINE-CODEX
    ./runner/baseline-report.py EXP-B2-BASELINE-CLAUDE --min-n 5

WHY THIS EXISTS AND IS NOT analyze-experiment.py.

`analyze-experiment.py` analyses a TWO-ARM experiment and emits a verdict: it needs a control
and a treatment, refuses below the registered n per arm, and its whole apparatus — Mann-
Whitney, MDE thresholds, optional-stopping guards — is about deciding whether a *difference*
is real. B2 has no treatment. It is the baseline every later phase is compared against, and
asking the comparison tool to describe one arm gets you `arm 'instructions' has 0 measuring
runs, expected 10` and no report.

So B2's exit gate — "a baseline report with median and range, never an average alone" —
had no tool, and the phase that most needs discipline about summary statistics was the one
where someone would open a spreadsheet and type AVERAGE().

THIS PRINTS NO MEAN. Not as a formatting choice — it does not compute one.

A baseline over 3-5 runs of a stochastic agent is a small sample from a skewed distribution.
One stalled run at 1063 s against 82-167 s for the rest is already on record in this project;
a mean would move ~180 s on that single run while the median moves ~5. The registered MDE for
duration is 175% *because* of that run, which is to say: this project has already paid for
believing a mean.

Where a mean is genuinely wanted — total spend across a batch, say — sum the column. That is
an aggregate, not a central tendency, and it does not pretend to describe a typical run.

WHAT IT SHARES WITH analyze-experiment.py, deliberately, so the two cannot disagree:

  the exclusion rule   F13/F15 are harness failures, not agent behaviour. Discarded from
                       every statistic and reported by name, never silently dropped
  the telemetry rule   a run missing a measurement is excluded from THAT metric and counted,
                       rather than contributing a zero. Since API V4 the record says `null`
                       itself; before V4 the all-zero heuristic is the fallback
  the metric shape     the same five outcomes, read through the same accessors

Exit 0 a report · 1 not enough runs to report anything · 2 the experiment does not exist.
"""
import argparse
import json
import sys
import urllib.request

INFRASTRUCTURE = {"F13", "F15"}

# Fewer than this and a "baseline" is a story. The build track says >=3 runs, ideally 5.
MIN_RUNS = 3

OUTCOMES = [
    ("duration", "duration (s)", "{:.0f}"),
    ("cost", "estimated cost", "{:.4f}"),
    ("toolCalls", "tool calls", "{:.0f}"),
    ("modelCalls", "model calls", "{:.0f}"),
    ("cacheTokens", "cache tokens", "{:.0f}"),
]


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def has_behavior_telemetry(run):
    """Same rule as analyze-experiment.py. See its docstring — the two must not diverge."""
    b = run.get("behavior") or {}
    if b.get("modelCalls") is None and b.get("toolCalls") is None:
        return False
    return not (b.get("modelCalls", 0) == 0 and b.get("toolCalls", 0) == 0)


def metrics(run):
    e, b = run.get("efficiency") or {}, run.get("behavior") or {}
    read, created = e.get("cachedTokens"), e.get("cacheCreationTokens")
    cache = None if read is None and created is None else (read or 0) + (created or 0)
    telemetry = has_behavior_telemetry(run)
    return {
        "cost": e.get("estimatedCost"),
        "duration": ((e.get("durationMs") or 0) / 1000) or None,
        "toolCalls": b.get("toolCalls") if telemetry else None,
        "modelCalls": b.get("modelCalls") if telemetry else None,
        "cacheTokens": cache,
    }


def quantile(sorted_values, q):
    """Linear interpolation between order statistics — no numpy dependency."""
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return sorted_values[0]
    pos = q * (len(sorted_values) - 1)
    low = int(pos)
    high = min(low + 1, len(sorted_values) - 1)
    return sorted_values[low] + (sorted_values[high] - sorted_values[low]) * (pos - low)


def spread(values):
    """Median, quartiles and the full range. Deliberately no mean."""
    xs = sorted(v for v in values if v is not None)
    if not xs:
        return None
    return {
        "n": len(xs),
        "min": xs[0],
        "p25": quantile(xs, 0.25),
        "median": quantile(xs, 0.5),
        "p75": quantile(xs, 0.75),
        "max": xs[-1],
    }


def partition(runs, experiment):
    """Measuring runs, harness discards and unevaluated runs — the same split as the comparison."""
    measuring, discarded, unevaluated = [], [], []
    for r in runs:
        if r.get("experimentKey") != experiment:
            continue
        ev = r.get("evaluation")
        if ev is None:
            unevaluated.append(r)
        elif ev.get("failureClass") in INFRASTRUCTURE:
            discarded.append((r, ev))
        else:
            measuring.append((r, ev))
    return measuring, discarded, unevaluated


def report_arm(experiment, runs, min_n):
    measuring, discarded, unevaluated = partition(runs, experiment)

    print(f"\n=== {experiment} ===")
    if not measuring and not discarded and not unevaluated:
        print("  no runs recorded under this experiment key.")
        return 2

    print(f"  {len(measuring)} measuring run(s)")
    if discarded:
        classes = sorted({ev.get("failureClass") for _, ev in discarded})
        print(f"  {len(discarded)} discarded as harness failure ({', '.join(classes)}) — "
              f"not agent behaviour, excluded from every number below")
    if unevaluated:
        print(f"  {len(unevaluated)} run(s) with NO evaluation record — excluded. "
              f"An unevaluated run is not a passing one.")

    if len(measuring) < min_n:
        print(f"\n  REFUSING to report: {len(measuring)} measuring run(s), minimum {min_n}.")
        print("  Fewer than three runs of a stochastic agent is a story, not a baseline.")
        return 1

    passed = sum(1 for _, ev in measuring if ev.get("passed"))
    print(f"\n  pass rate   {passed}/{len(measuring)}")

    failures = {}
    for _, ev in measuring:
        if not ev.get("passed"):
            failures[ev.get("failureClass") or "unclassified"] = \
                failures.get(ev.get("failureClass") or "unclassified", 0) + 1
    if failures:
        print("  failures    " + ", ".join(f"{k}×{v}" for k, v in sorted(failures.items())))

    rows = [metrics(r) for r, _ in measuring]
    print()
    print(f"  {'outcome':<16} {'n':>3}  {'min':>10} {'p25':>10} {'median':>10} "
          f"{'p75':>10} {'max':>10}")
    print(f"  {'-' * 16} {'-' * 3}  {'-' * 10} {'-' * 10} {'-' * 10} {'-' * 10} {'-' * 10}")
    for key, label, fmt in OUTCOMES:
        s = spread(r[key] for r in rows)
        if s is None:
            print(f"  {label:<16} {0:>3}  {'not measured on any run':>54}")
            continue
        missing = len(rows) - s["n"]
        line = (f"  {label:<16} {s['n']:>3}  "
                + " ".join(fmt.format(s[k]).rjust(10)
                           for k in ("min", "p25", "median", "p75", "max")))
        if missing:
            line += f"   ({missing} run(s) missing this measurement, excluded)"
        print(line)

    models = sorted({(r.get("runtime") or {}).get("model") or "?" for r, _ in measuring})
    versions = sorted({(r.get("runtime") or {}).get("version") or "?" for r, _ in measuring})
    if len(models) > 1:
        print(f"\n  WARNING: this arm mixes {len(models)} models: {', '.join(models)}.")
        print("  A baseline over more than one model is not a baseline for either of them.")
    if len(versions) > 1:
        print(f"\n  WARNING: this arm mixes {len(versions)} runtime versions: {', '.join(versions)}.")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Single-arm baseline report — median and range, never a mean alone.")
    ap.add_argument("experiment", nargs="+", help="one or more experiment keys, one per arm")
    ap.add_argument("--api", default="http://localhost:8081")
    ap.add_argument("--min-n", type=int, default=MIN_RUNS,
                    help=f"refuse to report below this many measuring runs (default {MIN_RUNS})")
    args = ap.parse_args(argv)

    runs = fetch(f"{args.api}/api/runs")
    worst = 0
    for experiment in args.experiment:
        worst = max(worst, report_arm(experiment, runs, args.min_n))

    if len(args.experiment) > 1:
        print("\nThese arms are reported side by side, NOT compared.")
        print("A difference you read off two medians is not a result — use analyze-experiment.py,")
        print("which registers the effect size it can detect before it looks.")
    print()
    return worst


if __name__ == "__main__":
    sys.exit(main())
