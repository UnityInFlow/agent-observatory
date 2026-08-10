#!/usr/bin/env python3
"""Verify the operator's environment did not vary across an experiment's runs.

    runner/check-environment-constancy.py EXP-BE002-CLAUDEMD-V2

Issue #49: no flag combination removes user-scope hooks while keeping CLAUDE.md
auto-discovery and keychain auth. `--bare` and `--safe-mode` both disable CLAUDE.md, which
is the treatment; `CLAUDE_CONFIG_DIR` relocates the account store and breaks keychain OAuth;
`--settings` merges rather than replaces, so an empty hooks block does not subtract anything.
All four were probed against 2.1.226 on 2026-08-10.

So the hooks cannot currently be removed. They can be *counted*, and that is the difference
between an uncontrolled variable and a controlled one. This script reads the collector's
events and asserts that the environment composition — hooks registered, plugins loaded — was
identical on every measuring run. If it was, the comparison survives the contamination: a
constant offset shifts both arms and cannot manufacture a difference between them.

It deliberately does NOT assert on hook *executions*. Those fire per tool call, so they track
whatever the treatment does to tool use; demanding they be equal would be demanding the
treatment have no effect. They are reported so the size of the effect is visible.

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
    for arm in sorted(executions):
        vals = sorted(executions[arm])
        median = vals[len(vals) // 2] if vals else 0
        print(f"    {arm:<14} n={len(vals):<3} median={median:<5} range={vals[0]}–{vals[-1]}")

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
    print("The contamination is a fixed offset on both arms, so it cannot manufacture a")
    print("difference between them. It still inflates absolute cost — see issue #49.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
