#!/usr/bin/env bash
#
# Seeds one complete experiment so the Compare screen is meaningful immediately:
# 5 baseline runs vs 5 "+ AGENTS.md" runs of BE-001, each with an evaluation.
#
# These are synthetic teaching numbers, NOT measurements. They exist so a student can
# read the four pages before waiting on ten real agent runs. Real data comes from
# `make run-benchmark`.
set -uo pipefail

API="${API:-http://localhost:8080}"
EXPERIMENT="${EXPERIMENT:-EXP-001}"
BENCHMARK="${BENCHMARK:-BE-001}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

curl -fsS "${API}/actuator/health" >/dev/null 2>&1 || {
  echo "Observatory API is not reachable at ${API}. Run 'make up' first." >&2
  exit 1
}

# Seeding twice silently doubles the sample and re-weights every median, which is
# exactly the wrong lesson for a tool about not fooling yourself with numbers.
EXISTING=$(curl -fsS "${API}/api/experiments/${EXPERIMENT}/comparison" 2>/dev/null \
  | jq -r '.totalRuns // 0' 2>/dev/null || echo 0)
if [ "${EXISTING:-0}" -gt 0 ] && [ "${FORCE:-0}" != "1" ]; then
  echo "Experiment ${EXPERIMENT} already has ${EXISTING} runs."
  echo "Seeding again would double the sample and change every median."
  echo "  re-seed anyway:  FORCE=1 make demo"
  echo "  or start clean:  make clean && make up && make demo"
  exit 0
fi

echo "==> registering benchmark ${BENCHMARK}"
curl -fsS -X POST "${API}/api/benchmarks" -H 'Content-Type: application/json' -d "$(jq -nc \
  --arg id "$BENCHMARK" '{
    id: $id,
    name: "customer-id-validation",
    category: "bugfix",
    repository: "sample-service",
    prompt: "When POST /customers receives an empty or blank customerId, return HTTP 400.",
    constraints: "Kotlin + Spring Boot architecture must be preserved.\nDo not add new dependencies.\nDo not modify files outside the customer feature except tests if required.",
    acceptanceCriteria: "1. Existing build passes.\n2. Existing tests pass.\n3. New blank-ID test passes.\n4. Valid customer creation still succeeds.\n5. No new Maven dependency appears.\n6. No unrelated production file changes.",
    evaluatorVersion: "1.0.0",
    baselineCommit: "seed-demo"
  }')" >/dev/null
echo "    ok"

# variant | toolCalls | modelCalls | retries | inTok | outTok | durationMs | passed | unrelated | failureClass
RUNS=(
  "baseline|23|9|4|31000|3400|182000|true|1|"
  "baseline|27|11|5|34500|3900|205000|false|3|F02"
  "baseline|21|8|3|29800|3100|171000|true|0|"
  "baseline|31|12|6|37200|4400|228000|false|2|F06"
  "baseline|25|10|4|32100|3600|193000|true|2|"
  "instructions|17|7|2|26400|2900|151000|true|0|"
  "instructions|19|7|1|27800|3000|158000|true|1|"
  "instructions|15|6|1|24900|2700|142000|true|0|"
  "instructions|22|8|3|29100|3300|169000|false|1|F05"
  "instructions|16|6|2|25600|2800|147000|true|0|"
)

echo "==> seeding ${#RUNS[@]} runs into ${EXPERIMENT}"
i=0
for spec in "${RUNS[@]}"; do
  IFS='|' read -r variant tools models retries intok outtok duration passed unrelated fclass <<EOF
$spec
EOF
  i=$((i + 1))
  started="$(date -u -v-"${i}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -d "-${i} hours" +%Y-%m-%dT%H:%M:%SZ)"

  # §12: the variant is recorded together with a hash of the exact customization used,
  # otherwise the comparison is not reproducible.
  if [ "$variant" = "baseline" ]; then
    customization='{}'
  else
    customization='{"instructionsHash":"sha256:3f1c9ab27e5d40c8bb1e7a2d9f04c6e8"}'
  fi

  run_payload=$(jq -nc \
    --arg exp "$EXPERIMENT" --arg bench "$BENCHMARK" --arg variant "$variant" \
    --arg started "$started" \
    --argjson tools "$tools" --argjson models "$models" --argjson retries "$retries" \
    --argjson intok "$intok" --argjson outtok "$outtok" --argjson duration "$duration" \
    --argjson customization "$customization" \
    '{
      experimentId: $exp, benchmarkId: $bench, variant: $variant, startedAt: $started,
      runtime: { provider: "github", product: "copilot-cli", version: "0.0.340", model: "claude-sonnet-4.5" },
      repository: { commitSha: "9fc2212", dirtyBeforeRun: false },
      customization: $customization,
      behavior: { modelCalls: $models, toolCalls: $tools, toolFailures: 1, retries: $retries,
                  permissionRequests: 3, permissionDenials: 0 },
      efficiency: { durationMs: $duration, inputTokens: $intok, outputTokens: $outtok, cachedTokens: 0 },
      result: { changedFiles: ["sample-service/src/main/kotlin/com/unityinflow/sample/customer/Customer.kt",
                               "sample-service/src/main/kotlin/com/unityinflow/sample/customer/CustomerController.kt"],
                addedLines: 14, deletedLines: 2 }
    }')

  run_id=$(curl -fsS -X POST "${API}/api/runs" -H 'Content-Type: application/json' \
             -d "$run_payload" | jq -r '.runId')
  [ -n "$run_id" ] && [ "$run_id" != "null" ] || { echo "failed to create run" >&2; exit 1; }

  if [ "$passed" = "true" ]; then exit_code=0; ac_passed=6; else exit_code=12; ac_passed=4; fi

  eval_payload=$(jq -nc \
    --argjson exitCode "$exit_code" --argjson passed "$passed" \
    --argjson acPassed "$ac_passed" --argjson unrelated "$unrelated" \
    --arg fclass "$fclass" \
    '{
      evaluatorVersion: "1.0.0",
      exitCode: $exitCode,
      passed: $passed,
      failureClass: (if $fclass == "" then null else $fclass end),
      correctness: { buildPassed: true, testsPassed: true, acceptanceSuitePassed: $passed,
                     acceptanceCriteriaPassed: $acPassed, acceptanceCriteriaTotal: 6 },
      quality: { unrelatedFilesChanged: $unrelated, newDependencies: 0, staticAnalysisPassed: true },
      safety: { forbiddenActionAttempts: 0, secretExposureDetected: false }
    }')

  curl -fsS -X POST "${API}/api/runs/${run_id}/evaluation" -H 'Content-Type: application/json' \
    -d "$eval_payload" >/dev/null
  printf '    %-13s %s  %s\n' "$variant" "${run_id:0:8}" "$([ "$passed" = true ] && echo PASS || echo "FAIL ${fclass}")"
done

echo
echo "==> comparison"
curl -fsS "${API}/api/experiments/${EXPERIMENT}/comparison" \
  | jq '{totalRuns, variants: [.variants[] | {variant, runs, passRate, acceptanceRate, medianToolCalls, medianTokens}], warning}'

echo
echo "  Open ${WEB:-http://localhost:5173}/compare"
