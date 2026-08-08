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

# shellcheck source=lib/evaluation-payload.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/evaluation-payload.sh"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

"$BENCH_DIR/evaluator.sh" --baseline "$BASELINE" --service "$SERVICE" --out "$OUT" --run-id "$RUN_ID"
EXIT=$?

# mktemp leaves an empty file behind, so an evaluator that died before writing would
# otherwise POST an empty body, get a 400 and still report success.
[[ -s "$OUT" ]] || { echo "evaluate: evaluator produced no evaluation.json" >&2; exit 30; }

curl -fsS -X POST "${API}/api/runs/${RUN_ID}/evaluation" -H 'Content-Type: application/json' \
  -d "$(jq -c "$EVALUATION_PAYLOAD_FILTER" "$OUT")" >/dev/null \
  || { echo "evaluate: failed to persist the evaluation to ${API}" >&2; exit 30; }

echo "evaluation recorded for ${RUN_ID} (exit ${EXIT})"
exit "$EXIT"
