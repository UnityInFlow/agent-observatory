#!/usr/bin/env bash
#
# M2 exit criterion: "test trace visible in Grafana."
#
# Sends a synthetic OTLP/HTTP trace shaped like the Copilot CLI span tree documented by
# GitHub (invoke_agent → chat / execute_tool), then queries Tempo to prove it was stored.
# This validates collector → Tempo → Grafana *before* any agent is involved (§31 action 10).
set -uo pipefail

OTLP_ENDPOINT="${OTLP_ENDPOINT:-http://localhost:4318}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
RUN_ID="${RUN_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
BENCHMARK_ID="${BENCHMARK_ID:-BE-001}"
VARIANT="${VARIANT:-baseline}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

TRACE_ID="$(hex 16)"
ROOT_SPAN="$(hex 8)"

NOW_NS=$(( $(date +%s) * 1000000000 ))
START=$(( NOW_NS - 8000000000 ))

# One jq program builds the whole payload. Assembling it from nested command
# substitutions is fragile shell quoting; this keeps the JSON in one place.
PAYLOAD=$(jq -nc \
  --arg traceId "$TRACE_ID" \
  --arg rootSpan "$ROOT_SPAN" \
  --arg s1 "$(hex 8)" --arg s2 "$(hex 8)" --arg s3 "$(hex 8)" --arg s4 "$(hex 8)" \
  --arg runId "$RUN_ID" \
  --arg benchmarkId "$BENCHMARK_ID" \
  --arg variant "$VARIANT" \
  --argjson start "$START" '
  def str($k; $v): {key: $k, value: {stringValue: $v}};
  def int($k; $v): {key: $k, value: {intValue: ($v | tostring)}};
  def span($id; $parent; $name; $offsetMs; $durMs; $attrs):
    {
      traceId: $traceId,
      spanId: $id,
      parentSpanId: $parent,
      name: $name,
      kind: 1,
      startTimeUnixNano: (($start + $offsetMs * 1000000) | tostring),
      endTimeUnixNano:   (($start + ($offsetMs + $durMs) * 1000000) | tostring),
      attributes: $attrs
    };

  {
    resourceSpans: [{
      resource: {
        attributes: [
          str("service.name"; "github-copilot"),
          str("observatory.run.id"; $runId),
          str("benchmark.id"; $benchmarkId),
          str("experiment.variant"; $variant)
        ]
      },
      scopeSpans: [{
        scope: { name: "agent-observatory.synthetic" },
        spans: [
          {
            traceId: $traceId,
            spanId: $rootSpan,
            name: "invoke_agent",
            kind: 1,
            startTimeUnixNano: ($start | tostring),
            endTimeUnixNano: (($start + 7800000000) | tostring),
            attributes: [str("gen_ai.agent.name"; "copilot-cli")]
          },
          span($s1; $rootSpan; "chat"; 100; 2400; [
            str("gen_ai.system"; "github-copilot"),
            int("gen_ai.usage.input_tokens"; 20431),
            int("gen_ai.usage.output_tokens"; 1892)
          ]),
          span($s2; $rootSpan; "execute_tool"; 2600; 900; [
            str("gen_ai.tool.name"; "str_replace_editor")
          ]),
          span($s3; $rootSpan; "chat"; 3600; 2100; [
            str("gen_ai.system"; "github-copilot"),
            int("gen_ai.usage.input_tokens"; 22110),
            int("gen_ai.usage.output_tokens"; 640)
          ]),
          span($s4; $rootSpan; "execute_tool"; 5800; 1600; [
            str("gen_ai.tool.name"; "bash")
          ])
        ]
      }]
    }]
  }')

if [ -z "$PAYLOAD" ]; then
  echo "failed to build the OTLP payload" >&2
  exit 1
fi

echo "==> sending synthetic trace"
echo "    run id   ${RUN_ID}"
echo "    trace id ${TRACE_ID}"

RESPONSE_FILE="$(mktemp)"
code=$(curl -s -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST "${OTLP_ENDPOINT}/v1/traces" \
  -H 'Content-Type: application/json' \
  --data-binary "$PAYLOAD")

if [ "$code" != "200" ] && [ "$code" != "202" ]; then
  echo "OTLP export failed (HTTP $code):" >&2
  cat "$RESPONSE_FILE" >&2
  rm -f "$RESPONSE_FILE"
  exit 1
fi
rm -f "$RESPONSE_FILE"
echo "    accepted by collector (HTTP $code)"

echo "==> waiting for Tempo to index it"
for _ in $(seq 1 30); do
  if curl -fsS "${TEMPO_URL}/api/traces/${TRACE_ID}" 2>/dev/null \
       | jq -e '(.batches // .resourceSpans) | length > 0' >/dev/null 2>&1; then
    echo "    Tempo returned the trace."
    echo
    echo "  Grafana:      ${GRAFANA_URL}/explore  →  Tempo  →  paste ${TRACE_ID}"
    echo "  Search by run: { resource.observatory.run.id = \"${RUN_ID}\" }"
    exit 0
  fi
  sleep 2
done

echo "Trace was accepted but did not appear in Tempo within 60s." >&2
echo "Check: docker compose -f infra/compose.yaml logs otel-collector tempo" >&2
exit 1
