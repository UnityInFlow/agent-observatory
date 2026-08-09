#!/usr/bin/env python3
"""
Re-derive an experiment's minimum detectable effect from a measured arm.

    runner/derive-mde.py EXP-BE002-AGENTSMD-V2 --arm baseline

The registered MDE table for EXP-BE002-AGENTSMD came from a five-run pilot that was later
found to have run with the benchmark's answer key inside the agent's worktree, so its
spread describes a task the agent could partly read the solution to. This recomputes the
table from a clean arm, using the same formula the original used, so the amendment is
comparable to the thing it replaces rather than a second method arriving at a second
number.

    MDE_rel = D * SD / mean          D = (z(1-a/2) + z(1-b)) * sqrt(2/n) / 0.955

D is the effect size, in baseline SDs, that n runs per arm can detect at alpha .05
two-sided and 80% power. The correction is the asymptotic relative efficiency of a rank
test against the t test on normal data (ARE = 3/pi = 0.955), because the registered
analysis is Mann-Whitney. It enters as sqrt(ARE), not ARE: efficiency is a ratio of
*sample sizes*, and an effect size scales with sqrt(n), so n_eff = n * ARE becomes
D = D_t / sqrt(ARE). At n=10 that is D = 1.28.

The original pilot table divided by ARE itself and got 1.31, which overstates the effect
n=10 needs by 2.3%. Amendment 2 corrects it and says so, because the correction lowers
the bar for KEEP and a change in that direction has to be visible.

Like `analyze-experiment.py`, this refuses an incomplete arm: an MDE derived from the
first few runs of a batch would move as the batch continued, and a threshold that moves
while you watch is a threshold you chose.
"""
import argparse
import importlib.util
import math
import pathlib
import statistics as st
import sys

spec = importlib.util.spec_from_file_location(
    "analyze_experiment", pathlib.Path(__file__).with_name("analyze-experiment.py")
)
ae = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ae)

# Metrics the customization could plausibly move, in the order the registration lists them.
METRICS = ("duration", "cost", "toolCalls", "cacheTokens")

UNITS = {"duration": "s", "cost": "$", "toolCalls": "", "cacheTokens": ""}

# Normal quantiles for the registered alpha and power. Hardcoded because this machine has
# no scipy and a benchmark harness should not need one.
Z_ALPHA_TWO_SIDED_05 = 1.959964
Z_POWER_80 = 0.841621

# Asymptotic relative efficiency of the Mann-Whitney U test vs the t test on normal data.
RANK_TEST_ARE = 3 / math.pi


def effect_size(n, z_alpha=Z_ALPHA_TWO_SIDED_05, z_beta=Z_POWER_80):
    """Detectable effect in SDs, for a rank test with n per arm."""
    return (z_alpha + z_beta) * math.sqrt(2 / n) / math.sqrt(RANK_TEST_ARE)


def measuring_runs(runs, experiment, arm):
    """The runs of one arm that measure the variant, by the rules already registered.

    Same exclusions as the analysis: F13/F15 measure the harness, and a run with no model
    calls and no tool calls is missing telemetry rather than efficient (Amendment 1.3).
    """
    kept, discarded, unevaluated = [], 0, 0
    for r in runs:
        if r.get("experimentKey") != experiment or r.get("variant") != arm:
            continue
        ev = r.get("evaluation")
        if ev is None:
            unevaluated += 1
            continue
        if ev.get("failureClass") in ae.INFRASTRUCTURE:
            discarded += 1
            continue
        kept.append(r)
    return kept, discarded, unevaluated


def derive(runs, n):
    """Per-metric mean, SD and MDE. Returns rows and any metric that could not be derived."""
    d, rows, missing = effect_size(n), [], []
    for key in METRICS:
        values = [m for m in (ae.metrics(r)[key] for r in runs) if m is not None]
        if len(values) < 2:
            missing.append(f"{key}: {len(values)} usable value(s), need at least 2 for an SD")
            continue
        mean, sd = st.fmean(values), st.stdev(values)
        if mean == 0:
            missing.append(f"{key}: mean is 0, a relative MDE is undefined")
            continue
        rows.append({
            "metric": key, "n": len(values), "mean": mean, "sd": sd,
            "absolute": d * sd, "relative": d * sd / mean,
        })
    return rows, missing


def fmt(key, value):
    if key == "cost":
        return f"${value:.3f}"
    if key == "duration":
        return f"{value:.1f} s"
    if key == "cacheTokens":
        return f"{value / 1000:.0f} k"
    return f"{value:.2f}"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("experiment")
    ap.add_argument("--api", default="http://localhost:8081")
    ap.add_argument("--arm", default="baseline", help="the arm to estimate spread from")
    ap.add_argument("--n", type=int, default=ae.EXPECTED_MEASURING_RUNS,
                    help="planned runs per arm in the comparison the MDE describes")
    ap.add_argument("--expect-n", type=int, default=ae.EXPECTED_MEASURING_RUNS,
                    help="measuring runs the arm must already have")
    ap.add_argument("--exploratory", action="store_true",
                    help="derive from an incomplete arm. Stamps the output NOT REGISTRABLE.")
    args = ap.parse_args(argv)

    runs, discarded, unevaluated = measuring_runs(
        ae.fetch(f"{args.api}/api/runs"), args.experiment, args.arm
    )

    problems = []
    if unevaluated:
        problems.append(f"{unevaluated} run(s) in this arm have no evaluation yet")
    if len(runs) != args.expect_n:
        problems.append(
            f"arm '{args.arm}' has {len(runs)} measuring runs, expected {args.expect_n}"
            + (f" ({discarded} discarded as F13/F15 — replace them with fresh runs)" if discarded else "")
        )
    if problems and not args.exploratory:
        print(f"REFUSING to derive an MDE for '{args.experiment}' / '{args.arm}'.\n")
        for p in problems:
            print(f"  - {p}")
        print(
            "\nAn MDE taken from a partial arm changes as the batch continues, so it is a\n"
            "threshold chosen rather than registered. Finish the arm, or pass --exploratory\n"
            "to look at a number that must not be written into the registration."
        )
        return 2
    if problems:
        print("*** NOT REGISTRABLE — incomplete arm, exploratory view only ***")
        for p in problems:
            print(f"  - {p}")
        print()

    rows, missing = derive(runs, args.n)
    d = effect_size(args.n)

    print(f"experiment  {args.experiment}")
    print(f"arm         {args.arm} — {len(runs)} measuring runs"
          + (f", {discarded} discarded (F13/F15)" if discarded else ""))
    print(f"design      n={args.n} per arm, alpha .05 two-sided, 80% power, rank test (d = {d:.2f})")
    print()
    print(f"| metric | baseline mean | SD | minimum detectable effect |")
    print(f"|---|---:|---:|---:|")
    for r in rows:
        print(f"| {r['metric']} | {fmt(r['metric'], r['mean'])} | {fmt(r['metric'], r['sd'])} "
              f"| {fmt(r['metric'], r['absolute'])} (**{r['relative']:.0%}**) |")
    for m in missing:
        print(f"| {m} | — | — | — |")
    print()
    print("MDE = {" + ", ".join(
        f'"{r["metric"]}": {r["relative"]:.2f}' for r in rows
    ) + "}")
    if args.exploratory and problems:
        print("\nNot registrable: the arm is incomplete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
