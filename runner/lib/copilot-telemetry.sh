#!/usr/bin/env bash
#
# Copilot CLI telemetry adapter.
#
#   copilot-telemetry.sh <run-id> [tempo-url]
#
# Reads the run's trace back out of Tempo and normalizes it into the Observatory's
# internal BehaviorMetrics / EfficiencyMetrics shape. Chapter 00 §35: vendor telemetry
# is normalized *into* our model, never allowed to become it — so this file is the only
# place that knows Copilot's span names, and it emits nothing Copilot-specific.
#
# Emits on stdout:
#   { "traceId": "...", "behavior": {...}, "efficiency": {...} }
#
# Every field is derived from spans that actually exist. Where Copilot exposes nothing
# (retries, permission decisions) the value stays 0 rather than being invented — §12
# treats "not exposed" and "zero" as different facts.
set -uo pipefail

RUN_ID="${1:?usage: copilot-telemetry.sh <run-id> [tempo-url]}"
TEMPO_URL="${2:-${TEMPO_URL:-http://localhost:3200}}"
ATTEMPTS="${TELEMETRY_ATTEMPTS:-20}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# Tempo indexes asynchronously; a trace queried the instant a run ends is often not
# searchable yet, so poll rather than concluding there was no telemetry.
TRACE_ID=""
for _ in $(seq 1 "$ATTEMPTS"); do
  TRACE_ID=$(curl -fsS --get "${TEMPO_URL}/api/search" \
      --data-urlencode "q={ resource.observatory.run.id = \"${RUN_ID}\" }" \
      --data-urlencode "limit=1" 2>/dev/null \
    | jq -r '.traces[0].traceID // empty' 2>/dev/null)
  [ -n "$TRACE_ID" ] && break
  sleep 3
done

if [ -z "$TRACE_ID" ]; then
  echo "copilot-telemetry: no trace found for run ${RUN_ID}" >&2
  echo 'null'
  exit 0   # A missing trace must not fail the run; the verdict is still valid.
fi

TRACE_JSON="$(curl -fsS "${TEMPO_URL}/api/traces/${TRACE_ID}" 2>/dev/null)" || {
  echo "copilot-telemetry: could not fetch trace ${TRACE_ID}" >&2
  echo 'null'
  exit 0
}

printf '%s' "$TRACE_JSON" | jq -c --arg traceId "$TRACE_ID" '
  # Flatten every span in the trace, whichever batch/scope it arrived in.
  def spans: [.batches[]?.scopeSpans[]?.spans[]?];

  # Numeric span attribute. OTLP JSON encodes integers as strings, so coerce.
  def attrnum($key):
    (.attributes // [])
    | map(select(.key == $key) | (.value.intValue // .value.doubleValue // .value.stringValue))
    | (.[0] // 0) | tonumber? // 0;

  spans as $all
  | ($all | map(select(.name | startswith("chat")))) as $chat
  | ($all | map(select(.name | startswith("execute_tool")))) as $tools
  # Tempo returns status.code 2 for ERROR; absent status means unset/OK.
  | ($tools | map(select((.status.code // 0) == 2))) as $toolErrors
  | ($chat  | map(attrnum("gen_ai.usage.input_tokens"))            | add // 0) as $inTok
  | ($chat  | map(attrnum("gen_ai.usage.output_tokens"))           | add // 0) as $outTok
  | ($chat  | map(attrnum("gen_ai.usage.cache_read.input_tokens")) | add // 0) as $cacheTok
  | ($chat  | map(attrnum("github.copilot.cost"))                  | add // 0) as $cost
  | {
    traceId: $traceId,
    behavior: {
      modelCalls:   ($chat | length),
      toolCalls:    ($tools | length),
      toolFailures: ($toolErrors | length),
      retries: 0,
      permissionRequests: 0,
      permissionDenials: 0
    },
    efficiency: {
      inputTokens:  $inTok,
      outputTokens: $outTok,
      cachedTokens: $cacheTok,
      # estimatedCost stays null on purpose. Copilot exposes `github.copilot.cost`
      # (summed below as vendorCostRaw) but does not document its unit, and §14 only
      # admits a normalized cost "where defensible". Writing an unverified number into
      # a currency field would silently poison every cost comparison built on it.
      estimatedCost: null
    },
    vendorCostRaw: (if $cost > 0 then $cost else null end),
    toolBreakdown: (
      $tools | map(.name | sub("^execute_tool +"; ""))
      | group_by(.) | map({tool: .[0], calls: length})
      | sort_by(-.calls)
    )
  }
'
