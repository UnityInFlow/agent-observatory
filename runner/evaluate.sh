#!/usr/bin/env bash
#
# Re-run the deterministic evaluator for an existing run and push the verdict.
# Useful when the evaluator itself changes: §9 keeps evaluator versions independent of
# the platform, so an old run can be re-judged by a newer evaluator.
#
#   evaluate.sh --run-id <uuid> --service <dir> --baseline <sha> [--benchmark BE-001]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="${API:-http://localhost:8080}"
BENCHMARKS_REPO="${BENCHMARKS_REPO:-$(cd "$HERE/../../agent-observatory-benchmarks" 2>/dev/null && pwd)}"
BENCHMARK_ID="BE-001"
RUN_ID=""; SERVICE=""; BASELINE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)    RUN_ID="$2"; shift 2 ;;
    --service)   SERVICE="$2"; shift 2 ;;
    --baseline)  BASELINE="$2"; shift 2 ;;
    --benchmark) BENCHMARK_ID="$2"; shift 2 ;;
    --api)       API="$2"; shift 2 ;;
    *) echo "evaluate: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$RUN_ID"   ]] || { echo "evaluate: --run-id is required" >&2; exit 2; }
[[ -n "$SERVICE"  ]] || { echo "evaluate: --service is required" >&2; exit 2; }
[[ -n "$BASELINE" ]] || { echo "evaluate: --baseline is required" >&2; exit 2; }

BENCH_DIR="$(find "$BENCHMARKS_REPO/tasks" -maxdepth 1 -name "${BENCHMARK_ID}-*" | head -1)"
[[ -d "${BENCH_DIR:-}" ]] || { echo "evaluate: benchmark $BENCHMARK_ID not found" >&2; exit 2; }

OUT="$(mktemp)"
"$BENCH_DIR/evaluator.sh" --baseline "$BASELINE" --service "$SERVICE" --out "$OUT" --run-id "$RUN_ID"
EXIT=$?

curl -fsS -X POST "${API}/api/runs/${RUN_ID}/evaluation" -H 'Content-Type: application/json' \
  -d "$(jq -c '{evaluatorVersion, completedAt, exitCode, passed, failureClass,
      correctness: {buildPassed: .correctness.buildPassed, testsPassed: .correctness.testsPassed,
                    acceptanceSuitePassed: .correctness.acceptanceSuitePassed,
                    acceptanceCriteriaPassed: .correctness.acceptanceCriteriaPassed,
                    acceptanceCriteriaTotal: .correctness.acceptanceCriteriaTotal},
      quality: {unrelatedFilesChanged: .quality.unrelatedFilesChanged,
                newDependencies: .quality.newDependencies,
                staticAnalysisPassed: .quality.staticAnalysisPassed},
      safety}' "$OUT")" >/dev/null

echo "evaluation recorded for ${RUN_ID} (exit ${EXIT})"
rm -f "$OUT"
exit "$EXIT"
