#!/usr/bin/env bash
#
# Claude Code telemetry adapter.
#
#   claude-telemetry.sh <run-id> [events-file]
#
# Claude Code reports agent activity as OpenTelemetry **log events** (§25), and this reads
# the events the collector persisted and normalizes them into the same internal
# BehaviorMetrics / EfficiencyMetrics as every other runtime.
#
# This header used to open "Claude Code does not emit traces", and every run inherited that
# sentence as a hardcoded `traceId: null`. It was false. Claude Code emits spans whenever
# CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1 is set, which telemetry-env.sh now does; the flag
# was simply never on. The claim was never tested against a Tempo query before being
# written down, and it then explained away its own symptom for every run that followed.
#
# The measurements below still come from events rather than spans. Events remain the
# richer source here — cost_usd, cache split and tool_decision have no span equivalent —
# so the trace is used for correlation, not for metrics. No span hierarchy is fabricated,
# which §26 warns against; the traceId is read from the records themselves.
#
# The architecture still tolerates asymmetry between runtimes:
#   Copilot → rich traces + metrics
#   Claude  → metrics + events + (with the beta flag) correlating spans
#   Codex   → structured agent-aware events
#
# Emits on stdout: { "traceId": string|null, "behavior": {...}, "efficiency": {...} }
set -uo pipefail

RUN_ID="${1:?usage: claude-telemetry.sh <run-id> [events-file]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVENTS_FILE="${2:-${EVENTS_FILE:-$(cd "$HERE/../.." && pwd)/infra/telemetry-out/events.jsonl}}"
ATTEMPTS="${TELEMETRY_ATTEMPTS:-20}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# The collector batches, and Claude flushes on its own export interval, so a run's events
# are not on disk the instant it exits.
found=false
for _ in $(seq 1 "$ATTEMPTS"); do
  if [ -f "$EVENTS_FILE" ] && grep -q "$RUN_ID" "$EVENTS_FILE" 2>/dev/null; then
    found=true
    sleep 2   # let the tail of the run flush too, not just the first matching record
    break
  fi
  sleep 3
done

if [ "$found" != true ]; then
  echo "claude-telemetry: no events found for run ${RUN_ID} in ${EVENTS_FILE}" >&2
  echo 'null'
  exit 0   # Missing telemetry must not invalidate the correctness verdict.
fi

jq -s -c --arg runId "$RUN_ID" '
  # Attribute lookup on a single log record.
  def attr($key): (.attributes // []) | map(select(.key == $key)) | .[0].value // null;
  def str($key):  attr($key) | (.stringValue // null);
  def num($key):  attr($key) | ((.intValue // .doubleValue // .stringValue) // 0) | tonumber? // 0;
  def bool($key): attr($key) | (.boolValue // (.stringValue == "true"));

  # Every log record belonging to this run, across every batch the collector wrote.
  [ .[]?.resourceLogs[]?.scopeLogs[]?.logRecords[]?
    | select(str("observatory.run.id") == $runId) ] as $records

  | ($records | map(select(str("event.name") == "api_request")))   as $api
  | ($records | map(select(str("event.name") == "tool_result")))   as $tools
  | ($records | map(select(str("event.name") == "tool_decision"))) as $decisions
  | ($tools     | map(select(bool("success") == false)))           as $toolErrors
  | ($decisions | map(select(str("decision") != "accept")))        as $denials

  # The local environment, counted rather than assumed. No flag combination removes
  # user hooks while keeping CLAUDE.md auto-discovery and keychain auth (issue #49), so the
  # next best thing is to record what actually loaded and let the analysis prove it did not
  # vary between arms. An uncontrolled variable that is measured and constant is survivable;
  # one that is merely hoped to be constant is what voided five experiments.
  | ($records | map(select(str("event.name") == "hook_registered")))       as $hooksReg
  | ($records | map(select(str("event.name") == "hook_execution_start")))  as $hookExec
  | ($records | map(select(str("event.name") == "plugin_loaded")))         as $plugins

  | {
      # Only some records carry a trace context — the pre-session ones (plugin_loaded,
      # hook_registered) are emitted before a span is open and serialize traceId as "".
      # Empty is not a trace id, so it is filtered rather than stored as a truthy string
      # that would deep-link the UI to nothing. Null when the beta flag was off, which is
      # every run recorded before 2026-08-10; the UI still falls back to the run-id key.
      traceId: ($records | map(.traceId? // empty) | map(select(. != "")) | (.[0] // null)),
      behavior: {
        modelCalls:   ($api | length),
        toolCalls:    ($tools | length),
        toolFailures: ($toolErrors | length),
        # Not exposed as a distinct event; left 0 rather than inferred.
        retries: 0,
        # Copilot exposes neither of these — Claude does, which is the whole point of
        # normalizing above the vendor layer instead of levelling down to the weakest.
        permissionRequests: ($decisions | length),
        permissionDenials:  ($denials | length)
      },
      efficiency: {
        inputTokens:  ($api | map(num("input_tokens"))      | add // 0),
        outputTokens: ($api | map(num("output_tokens"))     | add // 0),
        cachedTokens:        ($api | map(num("cache_read_tokens"))     | add // 0),
        # Kept apart from reads: a freshly installed AGENTS.md is *written* to the cache on
        # the first request of a run and only read afterwards, so folding the two together
        # would blur the one component a B0/B1 comparison moves most directly.
        cacheCreationTokens: ($api | map(num("cache_creation_tokens")) | add // 0),
        # Unlike Copilot, Claude documents this in USD, so it is defensible as a cost.
        estimatedCost: (($api | map(num("cost_usd")) | add // 0) as $c
                        | if $c > 0 then ($c * 1000000 | round) / 1000000 else null end)
      },
      model: ($api | map(str("model")) | map(select(. != null)) | (.[0] // null)),
      # Counted per run so drift is detectable. hookExecutions scales with tool calls and so
      # tracks the treatment; hooksRegistered and pluginsLoaded are the composition and must
      # be identical across every run of an experiment for its comparison to mean anything.
      environment: {
        hooksRegistered: ($hooksReg | length),
        hookExecutions:  ($hookExec | length),
        pluginsLoaded:   ($plugins  | length)
      },
      toolBreakdown: (
        $tools | map(str("tool_name") // "unknown")
        | group_by(.) | map({tool: .[0], calls: length}) | sort_by(-.calls)
      )
    }
' "$EVENTS_FILE"
