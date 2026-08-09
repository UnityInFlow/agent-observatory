#!/usr/bin/env python3
"""
Analyse a two-arm experiment from the Observatory API and emit the registered verdict.

    runner/analyze-experiment.py EXP-BE002-AGENTSMD [--api http://localhost:8081]

Written before the data it analyses existed, which is the point: an analysis chosen after
seeing the numbers is a way of choosing the answer. For the same reason it **fails closed**
— it refuses to compute anything until the dataset matches the pre-registration exactly,
so it cannot be run repeatedly during a batch until the p value looks good.

Emits exactly one of REJECT / KEEP / INCONCLUSIVE, by the rule registered in
docs/preregistration-exp-be002-agentsmd.md. No third-party dependencies: this machine has
no scipy, and a benchmark harness should not need one.
"""
import argparse
import json
import math
import statistics as st
import sys
import urllib.request

# §23 codes that measure the harness, not the variant (#19).
INFRASTRUCTURE = {"F13", "F15"}

# The registered design. Both arms must reach this many *measuring* runs before any number
# is printed; a discarded run must be replaced by another run, not silently tolerated.
EXPECTED_MEASURING_RUNS = 10

# Minimum detectable effect at n=10 per arm, alpha .05 two-sided, 80% power, rank test.
#
# Amendment 2: derived by derive-mde.py from the clean B0 arm of EXP-BE002-AGENTSMD-V3,
# replacing a table estimated from a pilot that ran with the benchmark's answer key
# visible. The clean task is more variable than the pilot implied, so every threshold that
# matters got harder: cost 19% -> 24%, tool calls 30% -> 36%.
#
# duration is 175% because one run of the arm stalled at 1063 s against 82-167 s for the
# rest. It is registered at that value deliberately. The run passed, so the F13/F15 rule
# cannot exclude it, and inventing an outlier rule after seeing the outlier would be
# choosing the analysis. A 175% threshold simply means duration decides nothing here,
# which is the honest consequence and not a bug to route around.
MDE = {"cost": 0.24, "duration": 1.75, "toolCalls": 0.36, "cacheTokens": 0.32}

# Every metric here is lower-is-better. Direction is explicit because abs(change) would
# give a 20% cost *increase* the same verdict as a 20% decrease.
LOWER_IS_BETTER = {"cost", "duration", "toolCalls", "cacheTokens", "modelCalls"}

PRIMARY = "cost"

# Dimensions that must be identical across every run, or the arms are not comparable.
FIXED_DIMENSIONS = ("benchmarkId", "runtime.provider", "runtime.model", "repository.commitSha")


class NotTheRegisteredDataset(Exception):
    """Raised instead of printing numbers for a dataset the registration does not describe."""


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def dig(obj, dotted):
    for part in dotted.split("."):
        obj = (obj or {}).get(part)
    return obj


def has_behavior_telemetry(run):
    """
    The API serializes BehaviorDto with 0 defaults, so a collector or adapter gap is
    indistinguishable from a genuine zero. An agent run with no model calls and no tool
    calls did not happen, so treat that combination as missing telemetry rather than as a
    very efficient run — otherwise an outage concentrated in one arm reads as an
    improvement, which is the direction of error this project keeps making.
    """
    b = run.get("behavior") or {}
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


def mann_whitney_u(a, b):
    """Two-sided U test: normal approximation with tie and continuity correction.

    Not exact. At n=10 per arm it is conservative — fully separated samples give
    p = 1.8e-4 against an exact 1.1e-5 — which is the right direction to be wrong in.
    """
    n1, n2 = len(a), len(b)
    if n1 == 0 or n2 == 0:
        return None, None
    combined = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks, ties, i = [0.0] * len(combined), [], 0
    while i < len(combined):
        j = i
        while j + 1 < len(combined) and combined[j + 1][0] == combined[i][0]:
            j += 1
        avg = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[k] = avg
        ties.append(j - i + 1)
        i = j + 1
    r1 = sum(r for r, (_, g) in zip(ranks, combined) if g == 0)
    u1 = r1 - n1 * (n1 + 1) / 2
    u = min(u1, n1 * n2 - u1)
    n = n1 + n2
    sigma_sq = (n1 * n2 / 12) * ((n + 1) - sum(t**3 - t for t in ties) / (n * (n - 1)))
    if sigma_sq <= 0:                       # every value tied: no evidence of difference
        return u, 1.0
    z = (abs(u - n1 * n2 / 2) - 0.5) / math.sqrt(sigma_sq)
    return u, min(1.0, 2 * (1 - 0.5 * (1 + math.erf(z / math.sqrt(2)))))


def relative_change(control_median, treatment_median):
    """Signed relative change, or None when the baseline is zero and a ratio is undefined."""
    if control_median == 0:
        return None
    return (treatment_median - control_median) / control_median


def partition(runs, control, treatment):
    arms, discarded, unevaluated = {control: [], treatment: []}, {control: 0, treatment: 0}, []
    unexpected = set()
    for r in runs:
        arm = r["variant"]
        if arm not in arms:
            unexpected.add(arm)
            continue
        ev = r.get("evaluation")
        if ev is None:
            unevaluated.append(r)
            continue
        if ev.get("failureClass") in INFRASTRUCTURE:
            discarded[arm] += 1
            continue
        arms[arm].append((r, ev))
    return arms, discarded, unevaluated, unexpected


def validate(runs, arms, discarded, unevaluated, unexpected, expected_n):
    """Refuse to produce numbers for anything but the registered dataset."""
    problems = []
    if unexpected:
        problems.append(f"unexpected variants present: {sorted(unexpected)}")
    if unevaluated:
        problems.append(f"{len(unevaluated)} run(s) have no evaluation yet")
    for arm, rows in arms.items():
        if len(rows) != expected_n:
            problems.append(
                f"arm '{arm}' has {len(rows)} measuring runs, expected {expected_n}"
                + (f" ({discarded[arm]} discarded — replace them with fresh runs)" if discarded[arm] else "")
            )
    for dim in FIXED_DIMENSIONS:
        seen = {json.dumps(dig(r, dim)) for r in runs}
        if len(seen) > 1:
            problems.append(f"'{dim}' differs across runs: {sorted(seen)}")
    for arm, rows in arms.items():
        for key in ("toolCalls", "cost"):
            n = sum(1 for r, _ in rows if metrics(r)[key] is not None)
            if rows and n != len(rows):
                problems.append(f"arm '{arm}' has {len(rows) - n} run(s) missing {key} telemetry")
    return problems


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("experiment")
    ap.add_argument("--api", default="http://localhost:8081")
    ap.add_argument("--control", default="baseline")
    ap.add_argument("--treatment", default="instructions")
    ap.add_argument("--expect-n", type=int, default=EXPECTED_MEASURING_RUNS)
    ap.add_argument(
        "--exploratory",
        action="store_true",
        help="analyse an incomplete dataset. Stamps the output NOT A RESULT and emits no verdict.",
    )
    args = ap.parse_args(argv)

    runs = [r for r in fetch(f"{args.api}/api/runs") if r.get("experimentKey") == args.experiment]
    if not runs:
        sys.exit(f"no runs recorded for experiment '{args.experiment}'")

    arms, discarded, unevaluated, unexpected = partition(runs, args.control, args.treatment)
    problems = validate(runs, arms, discarded, unevaluated, unexpected, args.expect_n)

    if problems and not args.exploratory:
        print(f"REFUSING to analyse '{args.experiment}': this is not the registered dataset.\n")
        for p in problems:
            print(f"  - {p}")
        print(
            "\nRunning an analysis on a partial batch and stopping when the p value looks\n"
            "good is optional stopping, and it invalidates the result. Complete the runs,\n"
            "or pass --exploratory to look without producing a verdict."
        )
        return 2
    if problems:
        print("*** NOT A RESULT — incomplete dataset, exploratory view only ***")
        for p in problems:
            print(f"  - {p}")
        print()

    c, t = args.control, args.treatment
    print(f"experiment  {args.experiment}")
    for arm in (c, t):
        d = f", {discarded[arm]} discarded (F13/F15)" if discarded[arm] else ""
        print(f"  {arm:<14} {len(arms[arm])} measuring{d}")
    print()

    print(f"{'metric':<13}{'n':>5}{c:>13}{t:>13}{'change':>10}{'p':>7}  note")
    print("-" * 82)
    results = {}
    for key in ("cost", "duration", "toolCalls", "cacheTokens", "modelCalls"):
        a = [m for m in (metrics(r)[key] for r, _ in arms[c]) if m is not None]
        b = [m for m in (metrics(r)[key] for r, _ in arms[t]) if m is not None]
        if not a or not b:
            print(f"{key:<13}{0:>5}{'—':>13}{'—':>13}")
            continue
        ma, mb = st.median(a), st.median(b)
        change = relative_change(ma, mb)
        _, p = mann_whitney_u(a, b)
        results[key] = {"change": change, "p": p, "control": ma, "treatment": mb}
        mde = MDE.get(key)
        if change is None:
            note = f"baseline median is 0 — absolute change {mb - ma:+.4g}, ratio undefined"
            change_s = "n/a"
        else:
            change_s = f"{change:+.1%}"
            better = (change < 0) if key in LOWER_IS_BETTER else (change > 0)
            direction = "better" if better else "worse"
            if mde is None:
                note = direction
            elif abs(change) < mde:
                note = f"below MDE ({mde:.0%}) — not a finding"
            elif p is not None and p < 0.05:
                note = f"{direction}, beyond MDE, p < .05"
            else:
                note = f"{direction}, beyond MDE, p >= .05"
        ps = f"{p:.2f}" if p is not None else "—"
        print(f"{key:<13}{min(len(a), len(b)):>5}{ma:>13.4g}{mb:>13.4g}{change_s:>10}{ps:>7}  {note}")

    print()
    for arm in (c, t):
        rows = arms[arm]
        rate = (sum(1 for _, ev in rows if ev["passed"]) / len(rows)) if rows else 0
        classes = {}
        for _, ev in rows:
            if not ev["passed"]:
                k = ev.get("failureClass") or "unclassified"
                classes[k] = classes.get(k, 0) + 1
        print(f"  {arm:<14} pass {rate:>4.0%}   failures: {classes or 'none'}")

    if args.exploratory and problems:
        print("\nNo verdict: the dataset is incomplete.")
        return 0

    # ---- the registered decision rule -------------------------------------------------
    def f02(arm):
        return sum(1 for _, ev in arms[arm] if ev.get("failureClass") == "F02")

    primary = results.get(PRIMARY)
    print()
    print(f"F02 error-contract failures: {c}={f02(c)}  {t}={f02(t)}")
    if f02(t) > f02(c):
        verdict, why = "REJECT", "the treatment increased error-contract failures"
    elif primary is None or primary["change"] is None:
        verdict, why = "INCONCLUSIVE", f"no usable {PRIMARY} measurement"
    elif primary["change"] <= -MDE[PRIMARY] and primary["p"] is not None and primary["p"] < 0.05:
        verdict, why = "KEEP", f"{PRIMARY} improved {abs(primary['change']):.0%} (p={primary['p']:.2f}) and F02 did not rise"
    else:
        verdict, why = "INCONCLUSIVE", f"{PRIMARY} change {primary['change']:+.0%} (p={primary['p']:.2f}) does not clear the registered bar"
    print(f"VERDICT: {verdict} — {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
