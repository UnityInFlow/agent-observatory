#!/usr/bin/env bash
#
# The benchmark runner — the reproducibility engine of chapter 00 §24.
#
#   1. select benchmark          7. start agent
#   2. create clean worktree     8. wait for completion
#   3. generate run id           9. record diff
#   4. capture tool versions    10. execute deterministic evaluator
#   5. hash customization       11. persist normalized run + evaluation
#   6. set OTel correlation     12. clean worktree
#
# Step 7 defaults to `--runtime manual`: §24 says do not automate the agent launch until
# several runs have been watched by hand, and §11 says the first run should be interactive
# so students see permissions and actions happen.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

RUNTIME="manual"
BENCHMARK_ID="BE-001"
VARIANT="baseline"
EXPERIMENT="${EXPERIMENT:-EXP-001}"
BENCHMARKS_REPO="${BENCHMARKS_REPO:-$(cd "$REPO_ROOT/../agent-observatory-benchmarks" 2>/dev/null && pwd)}"
API="${API:-http://localhost:8080}"
KEEP_WORKTREE=false

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)    RUNTIME="$2"; shift 2 ;;
    --benchmark)  BENCHMARK_ID="$2"; shift 2 ;;
    --variant)    VARIANT="$2"; shift 2 ;;
    --experiment) EXPERIMENT="$2"; shift 2 ;;
    --repo)       BENCHMARKS_REPO="$2"; shift 2 ;;
    --api)        API="$2"; shift 2 ;;
    --keep)       KEEP_WORKTREE=true; shift ;;
    -h|--help)    usage ;;
    *) echo "run-agent: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die() { echo "run-agent: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

[[ -n "${BENCHMARKS_REPO:-}" && -d "$BENCHMARKS_REPO" ]] \
  || die "benchmarks repo not found; clone agent-observatory-benchmarks next to this repo or pass --repo"

case "$BENCHMARK_ID" in
  BE-001) BENCH_DIR="$BENCHMARKS_REPO/tasks/BE-001-customer-validation" ;;
  *)      BENCH_DIR="$(find "$BENCHMARKS_REPO/tasks" -maxdepth 1 -name "${BENCHMARK_ID}-*" | head -1)" ;;
esac
[[ -d "${BENCH_DIR:-}" ]] || die "benchmark '$BENCHMARK_ID' not found under $BENCHMARKS_REPO/tasks"

curl -fsS "${API}/actuator/health" >/dev/null 2>&1 \
  || die "Observatory API not reachable at ${API}; run 'make up' first"

# --- 3. run id -------------------------------------------------------------
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

# --- 2. clean worktree -----------------------------------------------------
BASELINE_SHA="$(git -C "$BENCHMARKS_REPO" rev-parse HEAD)" || die "cannot resolve baseline commit"
WORKTREE="${TMPDIR:-/tmp}/observatory-run-${RUN_ID}"
git -C "$BENCHMARKS_REPO" worktree add -q --detach "$WORKTREE" "$BASELINE_SHA" \
  || die "cannot create worktree"

cleanup() {
  if [[ "$KEEP_WORKTREE" == true ]]; then
    echo "  worktree kept at $WORKTREE"
  else
    git -C "$BENCHMARKS_REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "=============================================================="
echo " run        ${RUN_ID}"
echo " benchmark  ${BENCHMARK_ID}   variant ${VARIANT}   experiment ${EXPERIMENT}"
echo " runtime    ${RUNTIME}"
echo " worktree   ${WORKTREE}"
echo " baseline   ${BASELINE_SHA:0:12}"
echo "=============================================================="

# --- 4. capture tool/runtime versions --------------------------------------
case "$RUNTIME" in
  copilot) PROVIDER=github;  PRODUCT=copilot-cli; RUNTIME_VERSION="$(copilot --version 2>/dev/null | head -1)" ;;
  claude)  PROVIDER=anthropic; PRODUCT=claude-code; RUNTIME_VERSION="$(claude --version 2>/dev/null | head -1)" ;;
  codex)   PROVIDER=openai;  PRODUCT=codex;       RUNTIME_VERSION="$(codex --version 2>/dev/null | head -1)" ;;
  manual)  PROVIDER=manual;  PRODUCT=human;       RUNTIME_VERSION="n/a" ;;
  *) die "unknown runtime '$RUNTIME' (copilot|claude|codex|manual)" ;;
esac
RUNTIME_VERSION="${RUNTIME_VERSION:-unknown}"

# --- 5. customization hashes (§12) -----------------------------------------
hash_of() {
  local path="$WORKTREE/$1"
  [[ -f "$path" ]] || { echo "null"; return; }
  printf '"sha256:%s"' "$(shasum -a 256 "$path" | cut -c1-32)"
}
CUSTOMIZATION=$(jq -nc \
  --argjson instructions "$(hash_of AGENTS.md)" \
  --argjson agent "$(hash_of .github/copilot-instructions.md)" \
  '{instructionsHash: $instructions, agentHash: $agent}')

# --- 6. OTel correlation ---------------------------------------------------
# shellcheck source=/dev/null
RUN_ID="$RUN_ID" BENCHMARK_ID="$BENCHMARK_ID" VARIANT="$VARIANT" \
  source "$HERE/lib/telemetry-env.sh" "$RUNTIME"

# --- 7/8. start the agent and wait -----------------------------------------
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_MS=$(( $(date +%s) * 1000 ))

echo
echo "--- task ------------------------------------------------------"
cat "$BENCH_DIR/task.md"
echo "---------------------------------------------------------------"
echo

case "$RUNTIME" in
  manual)
    echo "Manual run. In another terminal:"
    echo "  cd $WORKTREE/sample-service"
    echo "Apply the task above by hand (or drive an agent yourself), then return here."
    read -r -p "Press ENTER when the run is complete... " _
    ;;
  copilot)
    ( cd "$WORKTREE" && copilot ) || echo "run-agent: copilot exited non-zero — recording the run anyway"
    ;;
  claude)
    ( cd "$WORKTREE" && claude ) || echo "run-agent: claude exited non-zero — recording the run anyway"
    ;;
  codex)
    ( cd "$WORKTREE" && codex ) || echo "run-agent: codex exited non-zero — recording the run anyway"
    ;;
esac

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DURATION_MS=$(( $(date +%s) * 1000 - START_MS ))

# --- 9. record diff --------------------------------------------------------
CHANGED_FILES=$(git -C "$WORKTREE" status --porcelain \
  | awk '{print $NF}' | jq -R . | jq -sc 'map(select(length>0))')
read -r ADDED DELETED <<<"$(git -C "$WORKTREE" diff --numstat \
  | awk '{a+=$1; d+=$2} END {print (a+0), (d+0)}')"

echo
echo "--- diff ------------------------------------------------------"
git -C "$WORKTREE" diff --stat || true
echo "---------------------------------------------------------------"

# --- 10. deterministic evaluator -------------------------------------------
EVALUATION_JSON="${WORKTREE}/evaluation.json"
echo
"$BENCH_DIR/evaluator.sh" \
  --baseline "$BASELINE_SHA" \
  --service "$WORKTREE/sample-service" \
  --out "$EVALUATION_JSON" \
  --run-id "$RUN_ID"
EVAL_EXIT=$?
echo "evaluator exit code: ${EVAL_EXIT}"

# --- 11. persist -----------------------------------------------------------
echo
echo "==> registering benchmark and run with the Observatory"

BENCH_YAML="$BENCH_DIR/benchmark.yaml"
BENCH_NAME=$(awk -F': *' '/^name:/{print $2; exit}' "$BENCH_YAML")
BENCH_CATEGORY=$(awk -F': *' '/^category:/{print $2; exit}' "$BENCH_YAML")
EVALUATOR_VERSION=$(awk -F': *' '/^evaluator_version:/{print $2; exit}' "$BENCH_YAML")

curl -fsS -X POST "${API}/api/benchmarks" -H 'Content-Type: application/json' -d "$(jq -nc \
  --arg id "$BENCHMARK_ID" --arg name "${BENCH_NAME:-$BENCHMARK_ID}" \
  --arg category "${BENCH_CATEGORY:-bugfix}" \
  --arg prompt "$(cat "$BENCH_DIR/task.md")" \
  --arg evaluatorVersion "${EVALUATOR_VERSION:-1.0.0}" \
  --arg baseline "$BASELINE_SHA" \
  '{id:$id, name:$name, category:$category, repository:"sample-service",
    prompt:$prompt, evaluatorVersion:$evaluatorVersion, baselineCommit:$baseline}')" >/dev/null

RUN_PAYLOAD=$(jq -nc \
  --arg runId "$RUN_ID" --arg exp "$EXPERIMENT" --arg bench "$BENCHMARK_ID" \
  --arg variant "$VARIANT" --arg started "$STARTED_AT" --arg finished "$FINISHED_AT" \
  --arg provider "$PROVIDER" --arg product "$PRODUCT" --arg version "$RUNTIME_VERSION" \
  --arg model "${AGENT_MODEL:-unknown}" --arg sha "$BASELINE_SHA" \
  --argjson customization "$CUSTOMIZATION" \
  --argjson duration "$DURATION_MS" --argjson changed "$CHANGED_FILES" \
  --argjson added "${ADDED:-0}" --argjson deleted "${DELETED:-0}" \
  '{
    runId:$runId, experimentId:$exp, benchmarkId:$bench, variant:$variant,
    startedAt:$started, finishedAt:$finished,
    runtime:{provider:$provider, product:$product, version:$version, model:$model},
    repository:{commitSha:$sha, dirtyBeforeRun:false},
    customization:$customization,
    behavior:{},
    efficiency:{durationMs:$duration},
    result:{changedFiles:$changed, addedLines:$added, deletedLines:$deleted},
    telemetryQueryKey:("{ resource.observatory.run.id = \"" + $runId + "\" }")
  }')

curl -fsS -X POST "${API}/api/runs" -H 'Content-Type: application/json' \
  -d "$RUN_PAYLOAD" >/dev/null || die "failed to persist the run"

if [[ -f "$EVALUATION_JSON" ]]; then
  curl -fsS -X POST "${API}/api/runs/${RUN_ID}/evaluation" -H 'Content-Type: application/json' \
    -d "$(jq -c '{
        evaluatorVersion, completedAt, exitCode, passed, failureClass,
        correctness: {
          buildPassed: .correctness.buildPassed,
          testsPassed: .correctness.testsPassed,
          acceptanceSuitePassed: .correctness.acceptanceSuitePassed,
          acceptanceCriteriaPassed: .correctness.acceptanceCriteriaPassed,
          acceptanceCriteriaTotal: .correctness.acceptanceCriteriaTotal
        },
        quality: {
          unrelatedFilesChanged: .quality.unrelatedFilesChanged,
          newDependencies: .quality.newDependencies,
          staticAnalysisPassed: .quality.staticAnalysisPassed
        },
        safety
      }' "$EVALUATION_JSON")" >/dev/null || die "failed to persist the evaluation"
fi

echo
echo "  run recorded:  ${API}/api/runs/${RUN_ID}"
echo "  UI:            http://localhost:5173/runs/${RUN_ID}"
echo "  trace search:  { resource.observatory.run.id = \"${RUN_ID}\" }"
exit "$EVAL_EXIT"
