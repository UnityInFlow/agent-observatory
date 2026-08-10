#!/usr/bin/env python3
"""
Correct the failure class of a run the harness classified wrongly, and record why.

    runner/reclassify-run.py RUNID --to F13 --reason "API Error: Connection closed"

This exists because the harness has repeatedly recorded an *environmental* block as a
*capability* failure — quota as F03, a permission block as F05, a dropped connection as
F03. When that happens the run's stored verdict is a false statement about the agent, and
leaving it in place poisons every comparison the run appears in.

Two rules keep this from becoming a way to edit results into a preferred shape:

  * `--reason` is required and is written to the run as a human review, so the correction
    carries its justification in the same database as the number it changed. A silent
    reclassification is indistinguishable from tampering.
  * Only the failure class and the pass flag move. Every measured field — cost, tokens,
    tool calls, acceptance counts — is read back from the API and written unchanged. This
    tool cannot alter a measurement, only the label the harness put on it.

Correcting a class is not the same as excluding a run. F13/F15 are excluded by the
comparison; every other class stays in its arm and counts. Which class applies is a
question about evidence, and the evidence belongs in `--reason`.
"""
import argparse
import json
import sys
import urllib.error
import urllib.request

# §23. F13/F15 blame the environment and are excluded from comparisons; the rest are
# statements about the agent and stay in the arm.
INFRASTRUCTURE = {"F13", "F15"}
VALID = {f"F{n:02d}" for n in range(1, 16)}


def call(url, payload=None, method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url, data=data, method=method or ("POST" if data else "GET"),
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method or 'GET'} {url} failed: {e.code} {e.read().decode()[:400]}")
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach {url}: {e.reason}")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("run_id", help="full run id, or a unique prefix of one")
    ap.add_argument("--to", required=True, help="the §23 class the evidence supports, e.g. F13")
    ap.add_argument("--reason", required=True, help="the evidence. Stored with the run.")
    ap.add_argument("--reviewer", default="handoff-review")
    ap.add_argument("--api", default="http://localhost:8081")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    if args.to not in VALID:
        sys.exit(f"'{args.to}' is not a §23 class ({', '.join(sorted(VALID))})")

    runs = [r for r in call(f"{args.api}/api/runs") if r["runId"].startswith(args.run_id)]
    if not runs:
        sys.exit(f"no run whose id starts with '{args.run_id}'")
    if len(runs) > 1:
        sys.exit(f"'{args.run_id}' matches {len(runs)} runs — give more of the id")
    run = runs[0]
    ev = run.get("evaluation")
    if ev is None:
        sys.exit(f"run {run['runId']} has no evaluation to correct")

    was = ev.get("failureClass")
    if was == args.to:
        print(f"{run['runId'][:8]} is already {args.to} — nothing to do")
        return 0

    # Rebuilt field by field from what the API returned, so a measurement cannot be
    # changed here even by accident. Only failureClass and passed differ from the original.
    payload = {
        "evaluatorVersion": ev["evaluatorVersion"],
        "completedAt": ev.get("completedAt"),
        "exitCode": ev.get("exitCode", 0),
        "passed": False if args.to else ev.get("passed"),
        "failureClass": args.to,
        "correctness": {
            "buildPassed": ev.get("buildPassed", False),
            "testsPassed": ev.get("testsPassed", False),
            "acceptanceSuitePassed": ev.get("acceptanceSuitePassed", False),
            "acceptanceCriteriaPassed": ev.get("acceptanceCriteriaPassed", 0),
            "acceptanceCriteriaTotal": ev.get("acceptanceCriteriaTotal", 0),
            "taskAttempted": ev.get("taskAttempted"),
            "productionFilesChanged": ev.get("productionFilesChanged"),
        },
        "quality": {
            "unrelatedFilesChanged": ev.get("unrelatedFilesChanged", 0),
            "newDependencies": ev.get("newDependencies", 0),
            "staticAnalysisPassed": ev.get("staticAnalysisPassed", True),
        },
        "safety": {
            "forbiddenActionAttempts": ev.get("forbiddenActionAttempts", 0),
            "secretExposureDetected": ev.get("secretExposureDetected", False),
        },
    }

    excluded = " (excluded from comparisons)" if args.to in INFRASTRUCTURE else " (still counts against its arm)"
    print(f"{run['runId'][:8]}  {run['variant']}  {was or 'none'} -> {args.to}{excluded}")
    print(f"  reason: {args.reason}")
    if args.dry_run:
        print("  --dry-run, nothing written")
        return 0

    call(f"{args.api}/api/runs/{run['runId']}/evaluation", payload)
    call(f"{args.api}/api/runs/{run['runId']}/human-review", {
        "reviewer": args.reviewer,
        "notes": f"failure class corrected {was or 'none'} -> {args.to}. {args.reason}",
    })
    print("  written, with the reason recorded as a human review")
    return 0


if __name__ == "__main__":
    sys.exit(main())
