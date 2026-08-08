#!/usr/bin/env bash
#
# Re-read a run's trace from Tempo and backfill its behaviour/efficiency metrics.
#
#   backfill-telemetry.sh <run-id> [more run ids...]
#   backfill-telemetry.sh --experiment EXP-001        # every run missing telemetry
#
# Needed because a run recorded while the collector was down — or before an adapter
# existed — otherwise contributes zeros to every aggregate. A missing measurement
# averaged as zero makes the agent look cheaper than it was, which is the worst
# direction for a bias to run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="${API:-http://localhost:8080}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

RUN_IDS=()
if [[ "${1:-}" == "--experiment" ]]; then
  EXPERIMENT="${2:?usage: backfill-telemetry.sh --experiment <key>}"
  while IFS= read -r id; do
    [ -n "$id" ] && RUN_IDS+=("$id")
  done < <(curl -fsS "${API}/api/runs" \
            | jq -r --arg exp "$EXPERIMENT" \
                '.[] | select(.experimentKey == $exp and .behavior.toolCalls == 0) | .runId')
  echo "found ${#RUN_IDS[@]} run(s) without telemetry in ${EXPERIMENT}"
else
  [[ $# -gt 0 ]] || { sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 2; }
  RUN_IDS=("$@")
fi

[[ ${#RUN_IDS[@]} -gt 0 ]] || { echo "nothing to backfill"; exit 0; }

FAILED=0
for run_id in "${RUN_IDS[@]}"; do
  printf '  %s  ' "${run_id:0:8}"
  telemetry="$(TEMPO_URL="$TEMPO_URL" TELEMETRY_ATTEMPTS=3 \
                "$HERE/lib/copilot-telemetry.sh" "$run_id" 2>/dev/null || echo null)"

  if [[ -z "$telemetry" || "$telemetry" == "null" ]]; then
    echo "no trace in Tempo — left untouched"
    FAILED=$((FAILED + 1))
    continue
  fi

  payload="$(jq -c '{behavior, efficiency, traceId}' <<<"$telemetry")"
  if curl -fsS -X PATCH "${API}/api/runs/${run_id}/telemetry" \
       -H 'Content-Type: application/json' -d "$payload" >/dev/null; then
    jq -r '"model calls \(.behavior.modelCalls)  tool calls \(.behavior.toolCalls)  " +
           "tokens ↑\(.efficiency.inputTokens)"' <<<"$telemetry"
  else
    echo "PATCH failed"
    FAILED=$((FAILED + 1))
  fi
done

[[ "$FAILED" -eq 0 ]] || { echo "${FAILED} run(s) could not be backfilled" >&2; exit 1; }
echo "backfill complete"
