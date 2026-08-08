#!/usr/bin/env bash
#
# Telemetry environment for an agent run. Source this, do not execute it.
#
#   RUN_ID=... BENCHMARK_ID=BE-001 VARIANT=baseline source runner/lib/telemetry-env.sh copilot
#
# Chapter 00 §5 is the reason this file exists as one reviewed place: for a bank,
# observability can accidentally become a data-exfiltration mechanism. Every runtime
# below is configured metadata-only, and the collector scrubs content attributes again
# as defence in depth.

: "${RUN_ID:?RUN_ID must be set}"
: "${BENCHMARK_ID:=BE-001}"
: "${VARIANT:=baseline}"
: "${OTLP_HTTP_ENDPOINT:=http://localhost:4318}"
: "${OTLP_GRPC_ENDPOINT:=http://localhost:4317}"

RUNTIME="${1:-copilot}"

# §17: the correlation key that lets the Observatory UI deep-link into Tempo.
export OTEL_RESOURCE_ATTRIBUTES="observatory.run.id=${RUN_ID},benchmark.id=${BENCHMARK_ID},experiment.variant=${VARIANT}"

case "$RUNTIME" in
  copilot)
    export COPILOT_OTEL_ENABLED=true
    export OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_HTTP_ENDPOINT"
    export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
    export OTEL_SERVICE_NAME=github-copilot
    # Never capture prompt/response bodies.
    export OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false
    ;;

  claude)
    export CLAUDE_CODE_ENABLE_TELEMETRY=1
    export OTEL_METRICS_EXPORTER=otlp
    export OTEL_LOGS_EXPORTER=otlp
    export OTEL_TRACES_EXPORTER=otlp
    export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
    export OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_GRPC_ENDPOINT"
    export OTEL_SERVICE_NAME=claude-code
    # Short intervals so a 40-second benchmark run has actually flushed its events by
    # the time the adapter reads them.
    export OTEL_METRIC_EXPORT_INTERVAL=3000
    export OTEL_LOGS_EXPORT_INTERVAL=3000
    # Claude Code redacts these by default; the bank baseline keeps them off explicitly.
    export OTEL_LOG_USER_PROMPTS=0
    export OTEL_LOG_ASSISTANT_RESPONSES=0
    export OTEL_LOG_TOOL_CONTENT=0
    ;;

  codex)
    export OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_HTTP_ENDPOINT"
    export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
    export OTEL_SERVICE_NAME=openai-codex
    # Codex OTel export is configured in ~/.codex/config.toml; see docs/architecture.md.
    ;;

  manual|none)
    export OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_HTTP_ENDPOINT"
    ;;

  *)
    echo "telemetry-env: unknown runtime '$RUNTIME' (copilot|claude|codex|manual)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

echo "telemetry configured for '${RUNTIME}'"
echo "  observatory.run.id  ${RUN_ID}"
echo "  benchmark.id        ${BENCHMARK_ID}"
echo "  experiment.variant  ${VARIANT}"
echo "  content capture     disabled"
