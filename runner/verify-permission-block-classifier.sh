#!/usr/bin/env bash
# verify-permission-block-classifier.sh — prove the permission-block rule fires on a block,
# and prove it REFUSES on the runs that would make it a disaster.
#
# A classifier that has never been shown to refuse is indistinguishable from one that
# refuses nothing. The refusal cases here are not invented: they are the shapes of real runs
# in this store, read out of the API before the classifier was written, and each is cited by
# run id so a stranger can re-derive it:
#
#   curl -s "$API/api/runs?limit=2000" \
#     | jq -r '[.[] | select((.behavior.permissionDenials // 0) > 0)] | .[]
#              | "\(.runId[0:8]) \(.experimentKey) \(.behavior.permissionDenials) \(.result.changedFiles|length) \(.evaluation.passed)"'
#
# SIX of 550 stored runs have permissionDenials > 0 and ALL SIX PASSED. If this classifier
# fired on them, six passing runs would become infrastructure discards. That is the control
# this fixture set exists to be.
#
# Every case asserts BOTH the exit code and the reason string. "Blocked" for the wrong reason
# is how the previous generation of guards in this runner passed review.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TOOL=./runner/lib/classify-permission-block.sh
pass=0; fail=0

check() { # check <label> <telemetry-json> <changed-count> <want-exit> <want-substring>
  local label="$1" tel="$2" changed="$3" want="$4" grepfor="$5"
  local out rc
  out="$("$TOOL" "$tel" "$changed" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]] && grep -q -- "$grepfor" <<<"$out"; then
    pass=$((pass+1)); printf '  ok    %-64s exit %s\n' "$label" "$rc"
  else
    fail=$((fail+1)); printf '  FAIL  %-64s exit %s (want %s), missing %q\n' "$label" "$rc" "$want" "$grepfor"
    printf '        %s\n' "$out"
  fi
}

checkargs() { # checkargs <label> <want-exit> <want-substring> [args...]
  local label="$1" want="$2" grepfor="$3"; shift 3
  local out rc
  out="$("$TOOL" "$@" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]] && grep -q -- "$grepfor" <<<"$out"; then
    pass=$((pass+1)); printf '  ok    %-64s exit %s\n' "$label" "$rc"
  else
    fail=$((fail+1)); printf '  FAIL  %-64s exit %s (want %s), missing %q\n' "$label" "$rc" "$want" "$grepfor"
    printf '        %s\n' "$out"
  fi
}

beh() { # beh <denials> <toolCalls> -> the .behavior shape both the live telemetry and the API use
  printf '{"behavior":{"modelCalls":20,"toolCalls":%s,"toolFailures":0,"retries":0,"permissionRequests":%s,"permissionDenials":%s}}' \
    "$2" "$2" "$1"
}

echo "verify-permission-block-classifier: 29 cases"

echo "  -- the thing this classifier is FOR: a denial signal AND nothing produced --"
check "1 denial, 0 changed files is a block"            "$(beh 1 12)"  0  2 "permission block: 1 denial(s) and 0 changed files"
check "2 denials, 0 changed files is a block"           "$(beh 2 14)"  0  2 "permission block: 2 denial(s) and 0 changed files"
check "  the reason names the tool-call count too"      "$(beh 1 12)"  0  2 "toolCalls 12"
check "many denials, 0 changed files is a block"        "$(beh 9 30)"  0  2 "9 denial(s)"

echo "  -- THE SIX REAL PASSING RUNS WITH DENIALS. Firing on any of these is the disaster. --"
check "c0b6721e EXP-4B-ORCH-OVERHEAD d=1 tc=25 ch=3"    "$(beh 1 25)"  3  0 "the run produced work"
check "2744a92c EXP-4B-ORCH-OVERHEAD d=1 tc=19 ch=3"    "$(beh 1 19)"  3  0 "not a permission block"
check "fb894d7d EXP-4B-ORCH-OVERHEAD d=2 tc=14 ch=3"    "$(beh 2 14)"  3  0 "2 denial(s) but 3 changed file(s)"
check "beae5092 EXP-4B-ORCH-OVERHEAD d=1 tc=19 ch=3"    "$(beh 1 19)"  3  0 "not a permission block"
check "1f806f3d EXP-4B-ORCH-OVERHEAD d=1 tc=22 ch=3"    "$(beh 1 22)"  3  0 "not a permission block"
check "4d7c537d EXP-4B-ORCH-OVERHEAD d=1 tc=23 ch=3"    "$(beh 1 23)"  3  0 "not a permission block"
check "  one changed file is still work, not a block"   "$(beh 1 25)"  1  0 "1 changed file(s)"

echo "  -- obs#47's OWN seven F05 runs: the case this fix provably does NOT close --"
# EXP-BE002-MODEL-TIER, sonnet: denials 0 on 7 of 7, toolCalls 11-18, changedFiles 1 on 7 of 7.
# Registered as E-017 P6: replaying over these must reclassify 0 of 7. Both conjuncts are
# false here, not just the telemetry one — measured, and stronger than the design assumed.
check "4d0246d7 F05 d=0 tc=12 ch=1 stays unclassified"  "$(beh 0 12)"  1  0 "0 denials and 1 changed file(s)"
check "ca952174 F05 d=0 tc=12 ch=1"                     "$(beh 0 12)"  1  0 "not a permission block"
check "344274bf F05 d=0 tc=11 ch=1"                     "$(beh 0 11)"  1  0 "not a permission block"
check "b32a4396 F05 d=0 tc=18 ch=1"                     "$(beh 0 18)"  1  0 "not a permission block"

echo "  -- an empty result with NO denial is somebody else's case, not this one --"
# The existing pre-evaluator guard (run-agent.sh:1203) owns PRODUCED_NOTHING && toolCalls == 0.
check "0 denials, 0 changed is not claimed by this rule" "$(beh 0 8)"  0  0 "nothing was refused"
check "0 denials, 0 changed, 0 tool calls either"        "$(beh 0 0)"  0  0 "nothing was refused"
check "an ordinary passing run"                          "$(beh 0 26)" 7  0 "0 denials and 7 changed file(s)"

echo "  -- input this script cannot reason about must be REFUSED, never cleared --"
check "malformed JSON is unclassifiable, not clean"      '{'            0  3 "not parseable"
check "an empty string is unclassifiable, not clean"     ''             0  3 "telemetry is empty"
check "whitespace only is unclassifiable"                '   '          0  3 "telemetry is empty"
# codex and copilot emit no permission telemetry at all. Absent must not read as zero.
check "ABSENT permissionDenials is NOT zero denials"     '{"behavior":{"toolCalls":12}}' 0 3 "absent is not zero"
check "  and an absent behavior block is refused too"    '{"efficiency":{"inputTokens":1}}' 0 3 "absent is not zero"
check "non-numeric permissionDenials is refused"         '{"behavior":{"permissionDenials":"some"}}' 0 3 "is not a number"
check "non-numeric changed count is refused, not coerced" "$(beh 1 12)" "lots" 3 "changed-file count is not a number"
check "  an empty changed count is refused, not 0"       "$(beh 1 12)" ""     3 "changed-file count is not a number"

echo "  -- usage --"
checkargs "no arguments"   1 "usage:"
checkargs "one argument"   1 "usage:" '{"behavior":{"permissionDenials":0}}'
checkargs "three arguments" 1 "usage:" '{"behavior":{"permissionDenials":0}}' 0 extra

echo
echo "verify-permission-block-classifier: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
