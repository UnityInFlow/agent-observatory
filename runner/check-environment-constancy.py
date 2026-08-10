#!/usr/bin/env python3
"""Verify the operator's environment did not vary across an experiment's runs.

    runner/check-environment-constancy.py EXP-BE002-CLAUDEMD-V2

Issue #49. `--setting-sources project` removes user-scope hooks while leaving CLAUDE.md
auto-discovery and keychain auth intact; the runner exposes it as `--isolate-user-settings`.
An earlier version of this docstring said no flag could do that. It was wrong — the probes
behind that claim covered `--bare`, `--safe-mode`, `CLAUDE_CONFIG_DIR` and `--settings`, and
simply missed `--setting-sources`. Those four findings still hold and are worth keeping:

    --bare             skips hooks and CLAUDE.md discovery — switches off the treatment
    --safe-mode        disables all customizations, CLAUDE.md included
    CLAUDE_CONFIG_DIR  relocates the account store, breaking keychain OAuth
    --settings         merges rather than replaces; an empty hooks block subtracts nothing

Counting is still required, because isolation is off by default so "baseline" is not silently
redefined between experiments, and because a flag believed to work is not a flag observed to
have worked on the run in hand. EXP-BE002-NOHOOKS is the demonstration: hooks were worth ~13%
of every run and sat on both arms equally, so the premium moved 0.9pp when they were removed.

This script asserts the environment *composition* was identical on every measuring run. A
constant offset shifts both arms and cannot manufacture a difference between them, so a
contaminated-but-constant experiment is still interpretable; a drifting one is not.

Two things it deliberately does not do:

  - It does not assert hook *executions* are equal across arms. Those fire per tool call, so
    they track whatever the treatment does to tool use; demanding equality would demand the
    treatment have no effect. They are reported so the size is visible.
  - It does not treat hooksRegistered as the isolation symptom. Registration events still
    emit under --isolate-user-settings while nothing executes — the observed signature is
    20 registered, 0 executed. Executions are what a manipulation check should assert on.

Exit 0 if composition is constant, 1 if it drifted — drift means the runs were not comparable
and the experiment needs re-collecting, not re-interpreting.
"""
import argparse
import collections
import json
import os
import sys
import urllib.request

DEFAULT_API = os.environ.get("OBSERVATORY_API", "http://localhost:8081")
DEFAULT_EVENTS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "infra", "telemetry-out", "events.jsonl",
)

# Events that describe what the operator's machine loaded, as opposed to what the agent did.
COMPOSITION = ("hook_registered", "plugin_loaded")
EXECUTION = ("hook_execution_start",)


def event_name(record):
    for a in record.get("attributes") or []:
        if a.get("key") == "event.name":
            return (a.get("value") or {}).get("stringValue")
    return None


def run_id_of(record):
    for a in record.get("attributes") or []:
        if a.get("key") == "observatory.run.id":
            return (a.get("value") or {}).get("stringValue")
    return None


def counts_by_run(events_path, wanted_ids):
    """One pass over the events file, counting event types per run id.

    The file is append-only and reaches tens of megabytes, so it is streamed rather than
    parsed whole, and lines that do not parse are skipped rather than fatal — a partially
    flushed final line is normal while a run is still in flight.
    """
    counts = collections.defaultdict(collections.Counter)
    if not os.path.exists(events_path):
        sys.exit(f"events file not found: {events_path}")
    with open(events_path, "r", errors="replace") as fh:
        for line in fh:
            if not any(rid in line for rid in wanted_ids):
                continue
            try:
                batch = json.loads(line)
            except json.JSONDecodeError:
                continue
            for rl in batch.get("resourceLogs") or []:
                for sl in rl.get("scopeLogs") or []:
                    for rec in sl.get("logRecords") or []:
                        rid = run_id_of(rec)
                        if rid in wanted_ids:
                            name = event_name(rec)
                            if name:
                                counts[rid][name] += 1
    return counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("experiment_key")
    ap.add_argument("--api", default=DEFAULT_API)
    ap.add_argument("--events", default=DEFAULT_EVENTS)
    args = ap.parse_args()

    with urllib.request.urlopen(f"{args.api}/api/runs", timeout=15) as resp:
        runs = json.load(resp)

    measuring = [
        r for r in runs
        if r.get("experimentKey") == args.experiment_key
        and not (r.get("evaluation") or {}).get("infrastructureFailure")
    ]
    if not measuring:
        sys.exit(f"no measuring runs found for {args.experiment_key}")

    ids = {r["runId"] for r in measuring}
    variant = {r["runId"]: r.get("variant", "?") for r in measuring}
    counts = counts_by_run(args.events, ids)

    missing = sorted(ids - set(counts))
    signatures = collections.defaultdict(list)
    executions = collections.defaultdict(list)
    for rid, c in counts.items():
        signatures[tuple(c[name] for name in COMPOSITION)].append(rid)
        executions[variant[rid]].append(sum(c[name] for name in EXECUTION))

    print(f"experiment  {args.experiment_key}")
    print(f"  measuring runs   {len(measuring)}")
    print(f"  with events      {len(counts)}")
    if missing:
        # Absent telemetry is not evidence of a clean environment. It is no evidence at all,
        # and reporting it as a pass is exactly the skillsHash mistake.
        print(f"  ⚠️  {len(missing)} run(s) have no events — composition unverifiable for them")

    print()
    print("  composition (" + " · ".join(COMPOSITION) + ")")
    for sig, rids in sorted(signatures.items(), key=lambda kv: -len(kv[1])):
        shown = ", ".join(sorted(r[:8] for r in rids)[:4])
        more = f" +{len(rids) - 4} more" if len(rids) > 4 else ""
        print(f"    {sig}  ×{len(rids)}   {shown}{more}")

    print()
    print("  executions per arm (reported, not asserted — these track the treatment)")
    total_exec = 0
    for arm in sorted(executions):
        vals = sorted(executions[arm])
        # True median, averaging the two middle values on an even count. Taking the upper
        # one instead reported 25/33 where the arm medians are 24.5/31.5 — small, but these
        # numbers get published, and a median that rounds itself up is a wrong median.
        mid = len(vals) // 2
        median = vals[mid] if len(vals) % 2 else (vals[mid - 1] + vals[mid]) / 2
        total_exec += sum(vals)
        print(f"    {arm:<14} n={len(vals):<3} median={median:<7} range={vals[0]}–{vals[-1]}")

    print()
    if len(signatures) > 1:
        print("VERDICT: DRIFT — the environment was not constant across runs.")
        print("The arms are not comparable. Re-collect; do not reinterpret.")
        return 1
    if missing:
        print("VERDICT: UNVERIFIED — composition is constant where observed, but some runs")
        print("have no events at all, so the claim does not cover them.")
        return 1
    sig = next(iter(signatures))
    print(f"VERDICT: CONSTANT — every run loaded {sig[0]} hooks and {sig[1]} plugins.")
    if total_exec == 0:
        # Registration without execution is what isolation looks like: the events still emit,
        # nothing runs. Reporting "contamination" here would be reporting the wrong symptom.
        print("No hook executed on any run, so the arms carry no hook overhead at all —")
        print("consistent with --isolate-user-settings. This is the clean case.")
    else:
        print("Hooks executed on these runs, so both arms carry that overhead. Being constant,")
        print("it cannot manufacture a difference between them, but it does inflate absolute")
        print("cost — EXP-BE002-NOHOOKS measured that at ~13% per run. See issue #49.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
