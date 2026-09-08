#!/usr/bin/env bash
# Does this runner REFUSE to start a run whose telemetry has nowhere to go?
#
#   ./runner/verify-otlp-preflight.sh
#   API=http://127.0.0.1:18081 OTLP_GRPC_ENDPOINT=http://localhost:14317 \
#     OTLP_HTTP_ENDPOINT=http://localhost:14318 ./runner/verify-otlp-preflight.sh
#
# WHY THIS EXISTS. A run whose events never arrive exits 0, passes its acceptance criteria,
# and records null modelCalls / toolCalls / tokens / cost. Nothing goes red. It has happened
# to two batches — stop 11's deliberate-failure batch (OTLP_HTTP_PORT exported, OTLP_GRPC_PORT
# not, and claude exports over gRPC) and three of stop 12's preflight runs (neither exported,
# so both defaulted to this host's dead colima forward). Both were found by reading a field
# days later. `lib/otlp-preflight.sh` is the refusal; this drives it through fixtures.
#
# CHECKS — A through I cost no model call and no run record. J drives the real runner, which
# builds a worktree and then dies before section 7, so it costs no model call either.
#   A  http probe, a live receiver .................... admitted
#   B  http probe, nothing listening .................. refused
#   C  http probe, a listener that never answers ...... refused   (the half-open forward)
#   D  grpc probe, nothing listening .................. refused
#   E  grpc probe, a listener that never answers ...... refused
#   F  http probe, no endpoint at all ................. refused
#   G  grpc probe, the real collector's gRPC port ..... admitted
#   H  grpc probe, the collector's HTTP port .......... refused   (right host, wrong port)
#   I  http probe, the collector's gRPC port .......... refused   (what an HTTP-only check
#                                                                  gets WRONG: this is stop
#                                                                  11's batch, and an
#                                                                  HTTP-only probe passes it)
#   J  the runner refuses before the task is printed, and names the endpoint
#
# C and E are the cases a TCP connect cannot make. `nc -z 127.0.0.1 4317` reports OPEN on
# this host's dead colima forward — a port check answering over a smaller scope than it
# claims, which is the failure mode this project keeps finding. H and I are the cases an
# always-HTTP probe cannot make.
#
# THE NEGATIVE CONTROL. A fixture set that has only ever run against a working guard proves
# the cases pass, not that they would catch a broken runner. Strip ONLY the wiring and case J
# must go red:
#
#   sed '/^otlp_preflight /,/to discover afterwards\."$/d' \
#     runner/run-agent.sh > runner/run-agent-stripped.sh
#   chmod +x runner/run-agent-stripped.sh
#   RUNNER_UNDER_TEST=./runner/run-agent-stripped.sh ./runner/verify-otlp-preflight.sh
#   rm runner/run-agent-stripped.sh
#
# INSIDE runner/, not /tmp: the runner resolves its libraries from $HERE, so a copy anywhere
# else dies at `lib/evaluation-payload.sh: No such file or directory` before it reaches the
# guard — and case J goes red for a reason that has nothing to do with the guard. That is what
# happened on this file's first control run, and it is why J now requires the log to show
# section 6 was reached.
#
# With the block gone the runner walks past a dead endpoint and prints the task, which is
# exactly the silent path this control exists to close. A–I are unaffected: they drive the
# library directly and RUNNER_UNDER_TEST does not reach them.
#
# Exit 0 every case behaved as registered · 1 a precondition was unavailable · 2 A CASE FAILED.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

RUNNER="${RUNNER_UNDER_TEST:-./runner/run-agent.sh}"

# Short, because C and E deliberately wait out the timeout twice.
export OTLP_PREFLIGHT_TIMEOUT="${OTLP_PREFLIGHT_TIMEOUT:-3}"

# shellcheck source=lib/otlp-preflight.sh
source ./runner/lib/otlp-preflight.sh

# The count is asserted at the END against what actually ran, not announced at the top from
# a number computed before any case executed.
EXPECTED_CASES=10

TMP="$(mktemp -d)"
STUB_PID=""; NC_PIDS=()
cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null
  for p in ${NC_PIDS+"${NC_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL — $1"; fail=$((fail + 1)); }

# --- endpoints of the real stack -------------------------------------------
# Same resolution order the other verifiers use: an explicit override, then infra/.env, then
# the compose defaults. On a host whose colima forwards are dead these MUST be the tunnels,
# and the point of G/H/I is that pointing them at the wrong one is caught rather than passed.
OTLP_GRPC_PORT_D="4317"; OTLP_HTTP_PORT_D="4318"
if [[ -f infra/.env ]]; then
  v="$(sed -n 's/^OTLP_GRPC_PORT=//p' infra/.env | tail -1)"; [[ -n "$v" ]] && OTLP_GRPC_PORT_D="$v"
  v="$(sed -n 's/^OTLP_HTTP_PORT=//p' infra/.env | tail -1)"; [[ -n "$v" ]] && OTLP_HTTP_PORT_D="$v"
fi
GRPC_EP="${OTLP_GRPC_ENDPOINT:-http://localhost:${OTLP_GRPC_PORT_D}}"
HTTP_EP="${OTLP_HTTP_ENDPOINT:-http://localhost:${OTLP_HTTP_PORT_D}}"

if [[ "$(otlp_preflight_code grpc "$GRPC_EP")" != 2* ]]; then
  echo "The collector's gRPC endpoint ${GRPC_EP} does not answer." >&2
  echo "G, H and I compare a LIVE receiver against the ways of missing it; without one" >&2
  echo "they would pass vacuously. Run 'make up', or point OTLP_GRPC_ENDPOINT at the" >&2
  echo "tunnel (e.g. http://localhost:14317) and OTLP_HTTP_ENDPOINT at its pair." >&2
  exit 1
fi

# --- free ports and fixtures ------------------------------------------------
free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}

DEAD_PORT="$(free_port)"          # allocated, then released: nothing is listening there
STUB_PORT="$(free_port)"
HALF_PORT_A="$(free_port)"
HALF_PORT_B="$(free_port)"

# A receiver that answers 200 to POST /v1/logs. Hermetic — the point of A is that the
# admitting branch is exercised without the stack.
python3 - "$STUB_PORT" >/dev/null 2>&1 <<'PY' &
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
STUB_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ "$(otlp_preflight_code http/protobuf "http://127.0.0.1:${STUB_PORT}")" == 2* ]] && break
  sleep 0.3
done

# Listeners that accept the connection and never say anything — the half-open forward, the
# shape `nc -z` calls healthy.
nc -l 127.0.0.1 "$HALF_PORT_A" >/dev/null 2>&1 & NC_PIDS+=("$!")
nc -l 127.0.0.1 "$HALF_PORT_B" >/dev/null 2>&1 & NC_PIDS+=("$!")
sleep 0.5

# --- the library, both polarities ------------------------------------------
probe() { # name expected(admit|refuse) protocol endpoint
  local name="$1" expected="$2" protocol="$3" endpoint="$4" code rc
  code="$(otlp_preflight_code "$protocol" "$endpoint")"
  otlp_preflight "$protocol" "$endpoint" >/dev/null 2>&1; rc=$?
  if [[ "$expected" == admit && "$rc" -eq 0 ]] || [[ "$expected" == refuse && "$rc" -ne 0 ]]; then
    ok "$name (answered ${code})"
  else
    bad "$name — expected to $expected, got rc=${rc} code=${code}"
  fi
}

echo "verify-otlp-preflight: the library, on fixtures it carries itself"
probe "A  http, a live receiver"              admit  http/protobuf "http://127.0.0.1:${STUB_PORT}"
probe "B  http, nothing listening"            refuse http/protobuf "http://127.0.0.1:${DEAD_PORT}"
probe "C  http, a listener that never answers" refuse http/protobuf "http://127.0.0.1:${HALF_PORT_A}"
probe "D  grpc, nothing listening"            refuse grpc          "http://127.0.0.1:${DEAD_PORT}"
probe "E  grpc, a listener that never answers" refuse grpc          "http://127.0.0.1:${HALF_PORT_B}"
probe "F  http, no endpoint at all"           refuse http/protobuf ""

echo "verify-otlp-preflight: the real collector, and the two ways of missing it"
probe "G  grpc, the collector's gRPC port"    admit  grpc          "$GRPC_EP"
probe "H  grpc, the collector's HTTP port"    refuse grpc          "$HTTP_EP"
probe "I  http, the collector's gRPC port"    refuse http/protobuf "$GRPC_EP"

# --- J: is it WIRED IN, and does it fire before the model call? -------------
# Driven with --runtime manual on purpose. manual never calls a model, so when this case is
# run against a stripped runner — the negative control, where it is SUPPOSED to walk past the
# refusal — the worst case is a prompt this script kills, not a paid run.
echo "verify-otlp-preflight: the runner"

API_PORT="8080"
[[ -f infra/.env ]] && API_PORT="$(sed -n 's/^API_PORT=//p' infra/.env | tail -1)"
API_URL="${API:-http://localhost:${API_PORT:-8080}}"
if ! curl -fsS "${API_URL}/actuator/health" >/dev/null 2>&1; then
  echo "Observatory API not reachable at ${API_URL} — case J drives the real runner, which" >&2
  echo "refuses to start without it. Run 'make up' or pass API=http://127.0.0.1:18081." >&2
  exit 1
fi

J_LOG="$TMP/j.log"
# stdin is a FIFO this script holds open at BOTH ends, so a runner that walks past the
# refusal blocks at manual's "Press ENTER" prompt and is killed there. It never reaches the
# evaluator and never records a run. An earlier draft used `sleep N |` instead: the sleep
# eventually exited, the prompt read EOF, and the stripped runner ran on into gradle. A
# control whose safety depends on a race is not a control.
mkfifo "$TMP/hold" 2>/dev/null
exec 9<>"$TMP/hold"

set -m   # each background job in its own process group, so the kill below reaches children
OTLP_HTTP_ENDPOINT="http://127.0.0.1:${DEAD_PORT}" \
OTLP_GRPC_ENDPOINT="http://127.0.0.1:${DEAD_PORT}" \
API="$API_URL" \
  "$RUNNER" --runtime manual --benchmark BE-001 --variant baseline \
            --experiment EXP-VERIFY-OTLP-PREFLIGHT --api "$API_URL" \
  <&9 >"$J_LOG" 2>&1 &
J_PID=$!
set +m

# Killed the moment it prints the task, not after a fixed wait: past that line the runner is
# committed, and on a runtime that calls a model it would be committed to spending.
reached_task=0; waited=0
while (( waited < 480 )); do
  if grep -q -- "--- task ---" "$J_LOG" 2>/dev/null; then reached_task=1; break; fi
  kill -0 "$J_PID" 2>/dev/null || break
  sleep 0.25; waited=$((waited + 1))
done
if kill -0 "$J_PID" 2>/dev/null; then
  kill -TERM -- -"$J_PID" 2>/dev/null; sleep 1; kill -KILL -- -"$J_PID" 2>/dev/null
  J_RC=124
else
  wait "$J_PID"; J_RC=$?
fi
exec 9>&-
# A runner killed at the prompt does not run its own cleanup trap.
WT="$(grep -o 'observatory-run-[0-9a-f-]\{36\}' "$J_LOG" | head -1)"
[[ -n "$WT" ]] && rm -rf "${TMPDIR:-/tmp}/${WT}" "${TMPDIR:-/tmp}/${WT}.codex-home"

# `telemetry configured for` is section 6, immediately above the refusal. Requiring it is
# what stops this case from passing because the runner fell over somewhere else entirely --
# which is how the first negative-control run of this file went green: the stripped copy was
# written outside runner/, so $HERE missed lib/, and it died before reaching the guard at all.
# A case that cannot tell "refused" from "never got there" is not evidence of a refusal.
if [[ "$J_RC" -ne 0 && "$J_RC" -ne 124 ]] \
   && grep -q "telemetry configured for" "$J_LOG" \
   && grep -q "did not answer" "$J_LOG" \
   && grep -q "127.0.0.1:${DEAD_PORT}" "$J_LOG" \
   && [[ "$reached_task" -eq 0 ]]; then
  ok "J  the runner refuses a dead endpoint, names it, and never prints the task"
else
  got="rc=${J_RC}"
  [[ "$reached_task" -eq 1 ]] && got="$got, WALKED PAST THE REFUSAL AND PRINTED THE TASK"
  grep -q "telemetry configured for" "$J_LOG" \
    || got="$got, never reached section 6 — it failed for some other reason"
  bad "J  the runner did not refuse before the run started ($got)"
  cp "$J_LOG" "${TMPDIR:-/tmp}/verify-otlp-preflight-j.log" 2>/dev/null
  echo "       log copied to ${TMPDIR:-/tmp}/verify-otlp-preflight-j.log"
fi

echo
echo "verify-otlp-preflight: ${pass} passed, ${fail} failed, of $((pass + fail))"
if [[ "$((pass + fail))" -ne "$EXPECTED_CASES" ]]; then
  echo "verify-otlp-preflight: EXECUTED $((pass + fail)) cases, REGISTERED $EXPECTED_CASES" >&2
  exit 2
fi
[[ "$fail" -eq 0 ]] || exit 2
exit 0
