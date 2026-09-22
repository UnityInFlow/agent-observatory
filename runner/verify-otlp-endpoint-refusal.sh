#!/usr/bin/env bash
# verify-otlp-endpoint-refusal.sh — prove the runner's OTLP preflight REFUSES an endpoint that
# does not answer, with no collector, no model call and no network beyond 127.0.0.1.
#
# run-agent.sh section 6 dies before the model call when `otlp_preflight` returns non-zero.
# That refusal exists because a run whose telemetry never arrives exits 0 and records null
# overhead, and nothing goes red (see runner/lib/otlp-preflight.sh for the two batches it
# cost). Until this script ran in CI, nothing executed that refusal: it was a sentence.
#
# This covers the refusal half only. The admit half — a live receiver answering 200 — needs a
# collector and is runner/verify-otlp-preflight.sh's job, which this script does not replace.
#
# A verifier that has never been shown to fail is L3. So the library under test is
# overridable, and CI also points it at a stub that admits everything and asserts this
# script then FAILS:
#
#   OTLP_PREFLIGHT_LIB=runner/fixtures/otlp-preflight-always-admits.sh \
#     ./runner/verify-otlp-endpoint-refusal.sh      # must exit non-zero
#
# Every refusal case asserts BOTH the return code and OTLP_PREFLIGHT_CODE, because 000 is the
# diagnosis the refusal message prints to the reader.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1

LIB="${OTLP_PREFLIGHT_LIB:-runner/lib/otlp-preflight.sh}"
[[ "$LIB" == /* ]] || LIB="$ROOT/$LIB"
RUNNER="$ROOT/runner/run-agent.sh"

[[ -r "$LIB" ]] || { echo "verify-otlp-endpoint-refusal: cannot read library $LIB" >&2; exit 1; }
# shellcheck disable=SC2034 # read by the sourced runner/lib/otlp-preflight.sh
OTLP_PREFLIGHT_TIMEOUT=2
# shellcheck source=lib/otlp-preflight.sh
source "$LIB"
declare -F otlp_preflight >/dev/null \
  || { echo "verify-otlp-endpoint-refusal: $LIB defines no otlp_preflight" >&2; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %-64s %s\n' "$1" "$2"; }
bad() { fail=$((fail+1)); printf '  FAIL  %-64s %s\n' "$1" "$2"; }

# A port on 127.0.0.1 that refuses a TCP connect right now. Starts high to stay clear of the
# observatory's own ports (4317/4318, 14317/14318, 8081).
closed_port() {
  local p
  for p in $(seq 47631 47730); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return 0; fi
  done
  return 1
}

refused() { # refused <label> <protocol> <endpoint> <want-code or empty to skip>
  local label="$1" protocol="$2" endpoint="$3" want="$4" rc
  OTLP_PREFLIGHT_CODE=""
  otlp_preflight "$protocol" "$endpoint" >/dev/null 2>&1; rc=$?
  if [[ "$rc" == 0 ]]; then
    bad "$label" "admitted (code ${OTLP_PREFLIGHT_CODE:-<none>}), want refused"
  elif [[ -n "$want" && "$OTLP_PREFLIGHT_CODE" != "$want" ]]; then
    bad "$label" "refused, but code ${OTLP_PREFLIGHT_CODE:-<none>} (want $want)"
  else
    ok "$label" "refused, code ${OTLP_PREFLIGHT_CODE:-<none>}"
  fi
}

PORT="$(closed_port)" || { echo "verify-otlp-endpoint-refusal: no closed 127.0.0.1 port in 47631-47730" >&2; exit 1; }

echo "verify-otlp-endpoint-refusal: 4 cases (library ${LIB#"$ROOT"/}, closed port $PORT)"

refused "an empty endpoint is refused" "http/protobuf" "" ""
refused "http/protobuf on a closed 127.0.0.1 port is refused, code 000" \
  "http/protobuf" "http://127.0.0.1:$PORT" "000"
refused "grpc on a closed 127.0.0.1 port is refused, code 000" \
  "grpc" "http://127.0.0.1:$PORT" "000"

# The endpoint line of the refusal message must name the variable a reader has to fix — as
# literal text, not only inside the ${...} expansion, which the reader never sees.
label="run-agent.sh's refusal names OTEL_EXPORTER_OTLP_ENDPOINT"
line="$(grep -E '^  endpoint   ' "$RUNNER" | head -1)"
if [[ -z "$line" ]]; then
  bad "$label" "no endpoint line found in runner/run-agent.sh"
elif sed -E 's/\$\{[^}]*\}//g' <<<"$line" | grep -q 'OTEL_EXPORTER_OTLP_ENDPOINT'; then
  ok "$label" "yes"
else
  bad "$label" "only inside the expansion: $line"
fi

echo "verify-otlp-endpoint-refusal: $pass passed, $fail failed"
[[ "$fail" == 0 ]]
