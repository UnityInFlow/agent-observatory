#!/usr/bin/env bash
#
# Does the collector this run will export to actually ANSWER? Source this, do not execute it.
#
#   source runner/lib/otlp-preflight.sh
#   otlp_preflight "$OTEL_EXPORTER_OTLP_PROTOCOL" "$OTEL_EXPORTER_OTLP_ENDPOINT"
#
# WHY THIS EXISTS. A run whose telemetry never arrives does not fail. It exits 0, evaluates,
# passes its acceptance criteria, and records `modelCalls`, `toolCalls`, `inputTokens` and
# `estimatedCost` as null. Nothing in the harness goes red. The adapter even says so out loud
# -- "no telemetry found -- behaviour metrics stay empty rather than guessed", which is the
# correct refusal -- but it says it AFTER the model call, when the run is already paid for and
# the record is already written. A green run with an empty overhead column is this project's
# house failure mode with a socket in it: a control reporting success over a smaller scope than
# it claims.
#
# It has now happened twice, both times to a batch, both times found by reading a field
# afterwards rather than by anything refusing:
#
#   stop 11   the deliberate-failure batch exported OTLP_HTTP_PORT and not OTLP_GRPC_PORT.
#             claude exports over gRPC (telemetry-env.sh:53), so every event went to a port
#             nothing was forwarding. The batch has no telemetry at all.
#   stop 12   three preflight runs (a997bd30, bb0d731d, aa548920) exported NEITHER, so both
#             endpoints defaulted to localhost:4317/4318 -- the dead colima forward on this
#             host -- and all three recorded null behaviour and efficiency metrics.
#
# `TRACK-B-STATE.md` has carried "run-agent.sh refusing to start a claude run whose OTLP
# endpoint does not answer" in STILL OWED AND NOT WAIVED since stop 11. This is that.
#
# WHAT IT PROBES, AND WHY NOT SOMETHING CHEAPER.
#
# It probes THE ENDPOINT THE RUNTIME WILL ACTUALLY EXPORT TO, taken from the two variables
# telemetry-env.sh exports for that runtime, so this cannot drift from what the runtime reads.
# For claude that is gRPC; for copilot, codex and manual it is http/protobuf.
#
# Two weaker checks were measured on this host on 2026-09-08 and both are unsafe:
#
#   a TCP connect          `nc -z 127.0.0.1 4317` reports OPEN on the dead colima forward.
#                          A half-open forward is WORSE than a closed port because a port
#                          check calls it healthy -- see TRACK-B-STATE.md's stack row.
#   an HTTP POST, always   an empty POST to /v1/logs answers 200 on the live HTTP tunnel
#                          (14318) and 000 on the dead one (4318) -- but it answers 000 on
#                          the LIVE gRPC tunnel (14317) too, identically to the dead gRPC
#                          port. An HTTP-only probe would have passed stop 11's batch, whose
#                          HTTP tunnel was up and whose gRPC port was the dead default. It
#                          would have certified the exact failure it is meant to catch.
#
# So gRPC is probed as gRPC: one correctly framed, zero-length `ExportLogsServiceRequest`
# (the five-byte gRPC message frame `00 00 00 00 00`) over h2c prior knowledge. Logs, not
# traces, because logs are the signal `lib/claude-telemetry.sh` reads back out of
# `events.jsonl` for the overhead fields this check exists to protect.
#
# MEASURED TRUTH TABLE, 2026-09-08, this host. 200 only when the right protocol reaches a
# live OTLP receiver on the right port; every failure mode measured returns 000.
#
#   grpc  -> 14317 live tunnel .......... 200      http -> 14318 live tunnel ......... 200
#   grpc  ->  4317 dead colima forward .. 000      http ->  4318 dead colima forward .. 000
#   grpc  -> 14318 right host, HTTP port  000      http -> 14317 right host, gRPC port  000
#   grpc  -> nothing listening .......... 000      http -> nothing listening ......... 000
#   grpc  -> accepts TCP, never answers . 000      http -> accepts TCP, never answers  000
#
# THE PROBE IS NOT A WRITE. Both forms carry an EMPTY payload, so a receiver that accepts one
# ingests zero records: `infra/telemetry-out/events.jsonl` was 1907 lines before and 1907
# after, checked for both forms. This matters because that file's GROWTH is the evidence a
# batch reads to decide telemetry arrived, and a preflight that added a line to it would be
# contaminating the measurement it is protecting.
#
# WHAT IT STILL DOES NOT PROVE, stated because a check that oversells its scope is the thing
# this file is arguing against: that the answering collector is THE one whose `events.jsonl`
# the adapter reads. Two stacks on one host, or a tunnel pointed at a second VM, both answer
# 200 and neither is caught here. The check that closes that is a post-run assertion on the
# recorded metrics, which is a separate control and is not implemented here.

OTLP_PREFLIGHT_TIMEOUT="${OTLP_PREFLIGHT_TIMEOUT:-6}"

# Prints the HTTP status the endpoint gave, or 000 for "no HTTP answer at all" -- which
# covers a closed port, a listener that never speaks, and the wrong protocol on the right
# host. Never fails the caller; the classification is the caller's.
otlp_preflight_code() {
  local protocol="${1:-http/protobuf}" endpoint="${2:-}"
  [[ -n "$endpoint" ]] || { echo "000"; return 0; }
  local base="${endpoint%/}"

  case "$protocol" in
    grpc)
      # Five zero bytes: gRPC's message frame header for a zero-length message, which is a
      # valid empty ExportLogsServiceRequest. Piped rather than written to a file because a
      # command substitution would eat the NULs.
      printf '\x00\x00\x00\x00\x00' | curl -s -o /dev/null \
        --max-time "$OTLP_PREFLIGHT_TIMEOUT" \
        --http2-prior-knowledge \
        -w '%{http_code}' \
        -X POST \
        -H 'content-type: application/grpc' \
        -H 'te: trailers' \
        --data-binary @- \
        "${base}/opentelemetry.proto.collector.logs.v1.LogsService/Export" 2>/dev/null
      ;;
    *)
      curl -s -o /dev/null \
        --max-time "$OTLP_PREFLIGHT_TIMEOUT" \
        -w '%{http_code}' \
        -X POST \
        -H 'Content-Type: application/json' \
        -d '{}' \
        "${base}/v1/logs" 2>/dev/null
      ;;
  esac
}

# 0 when the collector answered 2xx, 1 otherwise. Echoes one line either way, because the
# status code is the whole diagnosis: 000 is "nothing answered", anything else is "something
# answered and it was not an OTLP receiver expecting this signal".
otlp_preflight() {
  local protocol="${1:-http/protobuf}" endpoint="${2:-}" code
  code="$(otlp_preflight_code "$protocol" "$endpoint")"
  # shellcheck disable=SC2034  # read by run-agent.sh's refusal message
  OTLP_PREFLIGHT_CODE="$code"

  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    echo "  otlp preflight      ${protocol} ${endpoint} answered ${code}"
    return 0
  fi

  echo "  otlp preflight      ${protocol} ${endpoint} answered ${code}" >&2
  return 1
}
