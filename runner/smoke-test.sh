#!/usr/bin/env bash
#
# End-to-end check of a running ecosystem. Verifies the chapter 00 definition-of-done
# items that can be checked mechanically.
set -uo pipefail

API="${API:-http://localhost:8080}"
WEB="${WEB:-http://localhost:5173}"
GRAFANA="${GRAFANA:-http://localhost:3000}"
PROM="${PROM:-http://localhost:9090}"
TEMPO="${TEMPO:-http://localhost:3200}"
OTLP="${OTLP:-http://localhost:4318}"

PASS=0
FAIL=0

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n' "$name"; FAIL=$((FAIL + 1))
  fi
}

http() { curl -fsS --max-time 10 "$1" >/dev/null; }

json_has() {  # url jq-filter
  curl -fsS --max-time 10 "$1" | jq -e "$2" >/dev/null
}

grep_body() {  # url pattern
  curl -fsS --max-time 10 "$1" | grep -q "$2"
}

echo "Agent Observatory — smoke test"
echo
echo "Infrastructure"
# Identity, not just HTTP 200: a port can easily be shadowed by an unrelated service
# already running on the developer's machine, which would otherwise pass silently.
check "API is ours and healthy"            json_has "${API}/actuator/health" '.status == "UP"'
check "Tempo ready"                        http "${TEMPO}/ready"
check "Prometheus is ours"                 json_has "${PROM}/api/v1/targets" '[.data.activeTargets[].labels.job] | index("observatory-api") != null'
check "Grafana healthy"                    http "${GRAFANA}/api/health"
check "Web app is ours"                    grep_body "${WEB}/" "Agent Observatory"
check "OTLP HTTP port open"                bash -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST '"${OTLP}"'/v1/traces -H "Content-Type: application/json" -d "{}" | grep -qE "200|202|400"'

echo
echo "Grafana provisioning"
check "Tempo datasource provisioned"       json_has "${GRAFANA}/api/datasources" '[.[] | select(.uid=="tempo")] | length > 0'
check "Prometheus datasource provisioned"  json_has "${GRAFANA}/api/datasources" '[.[] | select(.uid=="prometheus")] | length > 0'
check "Overview dashboard provisioned"     json_has "${GRAFANA}/api/search?query=Agent%20Observatory" 'length > 0'

echo
echo "Prometheus scraping"
check "collector target up"                json_has "${PROM}/api/v1/targets" '[.data.activeTargets[] | select(.labels.job=="otel-collector")] | length > 0'
check "API target up"                      json_has "${PROM}/api/v1/targets" '[.data.activeTargets[] | select(.labels.job=="observatory-api" and .health=="up")] | length > 0'

echo
echo "API contract"
check "GET /api/runs"                      http "${API}/api/runs"
check "GET /api/benchmarks"                http "${API}/api/benchmarks"
check "GET /api/experiments"               http "${API}/api/experiments"
check "prometheus endpoint exposed"        http "${API}/actuator/prometheus"
check "unknown run returns 404"            bash -c 'test "$(curl -s -o /dev/null -w "%{http_code}" '"${API}"'/api/runs/00000000-0000-0000-0000-000000000000)" = 404'

echo
echo "Cardinality rule (§15)"
# The body is captured and checked for emptiness first. `! curl ... | grep -q` would
# report success whenever curl itself failed (grep on empty input exits 1, and `!`
# inverts that) — so a down or port-shadowed API would "prove" the cardinality rule.
metrics_lack() {  # pattern
  local body
  body="$(curl -fsS --max-time 10 "${API}/actuator/prometheus")" || return 1
  [ -n "$body" ] || return 1
  ! printf '%s' "$body" | grep -q "$1"
}
check "no run_id label in metrics"         metrics_lack "run_id="
check "no commit_sha label in metrics"     metrics_lack "commit_sha="

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All ${PASS} checks passed."
  exit 0
fi
echo "${FAIL} of $((PASS + FAIL)) checks failed."
exit 1
