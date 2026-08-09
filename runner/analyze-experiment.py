#!/usr/bin/env python3
"""
Analyse a two-arm experiment from the Observatory API.

    runner/analyze-experiment.py EXP-BE002-AGENTSMD [--api http://localhost:8081]

Written *before* the data it analyses existed, which is the point: an analysis chosen
after seeing the numbers is a way of choosing the answer. It reports medians, a
Mann-Whitney U test on the continuous metrics, and the failure-class mix, and it refuses
to call anything a finding that falls below the pre-registered minimum detectable effect.

No third-party dependencies: this machine has no scipy, and a benchmark harness should
not need one to divide two numbers.
"""
import argparse
import json
import math
import statistics as st
import sys
import urllib.request

# §23 codes that measure the harness, not the variant. The API excludes them from its own
# aggregates (#19); this script excludes them for the same reason.
INFRASTRUCTURE = {"F13", "F15"}

# Minimum detectable effect at n=10 per arm, alpha .05 two-sided, 80% power, estimated
# from the five-run BE-002 pilot. See docs/preregistration-exp-be002-agentsmd.md.
MDE = {"cost": 0.19, "duration": 0.16, "toolCalls": 0.30, "cacheTokens": 0.36}


def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def metrics(run):
    e, b = run.get("efficiency") or {}, run.get("behavior") or {}
    cache_read, cache_created = e.get("cachedTokens"), e.get("cacheCreationTokens")
    cache = None if cache_read is None and cache_created is None else (cache_read or 0) + (cache_created or 0)
    return {
        "cost": e.get("estimatedCost"),
        "duration": (e.get("durationMs") or 0) / 1000 or None,
        "toolCalls": b.get("toolCalls"),
        "modelCalls": b.get("modelCalls"),
        "cacheTokens": cache,
    }


def mann_whitney_u(a, b):
    """Two-sided U test, normal approximation with tie and continuity correction.

    Exact for these sample sizes it is not; at n=10 per arm the approximation is close
    enough to make a decision with, and the p value is reported to two figures precisely
    so nobody reads more precision into it than it has.
    """
    n1, n2 = len(a), len(b)
    if n1 == 0 or n2 == 0:
        return None, None
    combined = sorted([(v, 0) for v in a] + [(v, 1) for v in b])
    ranks, i = [0.0] * len(combined), 0
    tie_groups = []
    while i < len(combined):
        j = i
        while j + 1 < len(combined) and combined[j + 1][0] == combined[i][0]:
            j += 1
        avg = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[k] = avg
        tie_groups.append(j - i + 1)
        i = j + 1
    r1 = sum(r for r, (_, g) in zip(ranks, combined) if g == 0)
    u1 = r1 - n1 * (n1 + 1) / 2
    u = min(u1, n1 * n2 - u1)
    mu = n1 * n2 / 2
    n = n1 + n2
    tie_term = sum(t**3 - t for t in tie_groups)
    sigma_sq = (n1 * n2 / 12) * ((n + 1) - tie_term / (n * (n - 1)))
    if sigma_sq <= 0:
        return u, None
    z = (abs(u - mu) - 0.5) / math.sqrt(sigma_sq)
    p = 2 * (1 - 0.5 * (1 + math.erf(z / math.sqrt(2))))
    return u, min(1.0, p)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("experiment")
    ap.add_argument("--api", default="http://localhost:8081")
    ap.add_argument("--control", default="baseline")
    ap.add_argument("--treatment", default="instructions")
    args = ap.parse_args()

    runs = [r for r in fetch(f"{args.api}/api/runs") if r.get("experimentKey") == args.experiment]
    if not runs:
        sys.exit(f"no runs recorded for experiment '{args.experiment}'")

    arms, discarded, unevaluated = {}, {}, 0
    for r in runs:
        ev = r.get("evaluation")
        arm = r["variant"]
        arms.setdefault(arm, [])
        discarded.setdefault(arm, 0)
        if ev is None:
            unevaluated += 1
            continue
        if ev.get("failureClass") in INFRASTRUCTURE:
            discarded[arm] += 1
            continue
        arms[arm].append((r, ev))

    print(f"experiment  {args.experiment}")
    print(f"runs        {len(runs)} recorded, {unevaluated} unevaluated")
    for arm in sorted(arms):
        d = f", {discarded[arm]} discarded (F13/F15)" if discarded[arm] else ""
        print(f"  {arm:<14} {len(arms[arm])} measuring{d}")
    print()

    c, t = args.control, args.treatment
    if c not in arms or t not in arms:
        sys.exit(f"need both '{c}' and '{t}'; found {sorted(arms)}")

    def pass_rate(arm):
        rows = arms[arm]
        return (sum(1 for _, ev in rows if ev["passed"]) / len(rows)) if rows else None

    print(f"{'metric':<14}{c:>14}{t:>14}{'change':>10}{'p':>8}  verdict")
    print("-" * 78)
    for key in ("cost", "duration", "toolCalls", "cacheTokens", "modelCalls"):
        a = [m for m in (metrics(r)[key] for r, _ in arms[c]) if m is not None]
        b = [m for m in (metrics(r)[key] for r, _ in arms[t]) if m is not None]
        if not a or not b:
            print(f"{key:<14}{'—':>14}{'—':>14}")
            continue
        ma, mb = st.median(a), st.median(b)
        change = (mb - ma) / ma if ma else 0.0
        _, p = mann_whitney_u(a, b)
        mde = MDE.get(key)
        if mde is None:
            verdict = ""
        elif abs(change) < mde:
            verdict = f"below MDE ({mde:.0%}) — not a finding"
        elif p is not None and p < 0.05:
            verdict = "beyond MDE and p < .05"
        else:
            verdict = "beyond MDE but p >= .05"
        ps = f"{p:.2f}" if p is not None else "—"
        print(f"{key:<14}{ma:>14.4g}{mb:>14.4g}{change:>+9.1%}{ps:>8}  {verdict}")

    print()
    pa, pb = pass_rate(c), pass_rate(t)
    print(f"{'pass rate':<14}{pa:>14.0%}{pb:>14.0%}")
    for arm in (c, t):
        classes = {}
        for _, ev in arms[arm]:
            if not ev["passed"]:
                classes[ev.get("failureClass") or "unclassified"] = (
                    classes.get(ev.get("failureClass") or "unclassified", 0) + 1
                )
        print(f"  {arm:<12} failures: {classes or 'none'}")

    # The pre-registered rule: reject if the treatment increases F02, whatever it does to
    # the continuous metrics. A customization that harms correctness is not paid for by
    # cheaper runs.
    def f02(arm):
        return sum(1 for _, ev in arms[arm] if ev.get("failureClass") == "F02")

    print()
    print(f"pre-registered decision rule: F02 {c}={f02(c)}  {t}={f02(t)}")
    if f02(t) > f02(c):
        print("  -> REJECT: the treatment increased error-contract failures.")
    else:
        print("  -> not rejected on F02; judge on the primary metric (cost) above.")


if __name__ == "__main__":
    main()
