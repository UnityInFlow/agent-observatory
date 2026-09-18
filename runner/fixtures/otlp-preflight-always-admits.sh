#!/usr/bin/env bash
#
# A BROKEN preflight library, kept on purpose. Source this, do not execute it.
#
# It has the same two functions as runner/lib/otlp-preflight.sh and admits every endpoint:
# empty, closed, wrong protocol, all of them answer 200. verify-otlp-endpoint-refusal.sh must
# FAIL when pointed at it (OTLP_PREFLIGHT_LIB=runner/fixtures/otlp-preflight-always-admits.sh),
# and CI asserts that it does. A verifier that has never been shown to fail is L3.

otlp_preflight_code() {
  echo "200"
}

otlp_preflight() {
  local protocol="${1:-http/protobuf}" endpoint="${2:-}"
  # shellcheck disable=SC2034  # read by the verifier, as run-agent.sh reads the real one
  OTLP_PREFLIGHT_CODE="200"
  echo "  otlp preflight      ${protocol} ${endpoint} answered 200"
  return 0
}
