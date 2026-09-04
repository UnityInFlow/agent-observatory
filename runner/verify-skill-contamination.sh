#!/usr/bin/env bash
# verify-skill-contamination.sh — prove the contamination rule still catches a leak, and
# no longer condemns the treatment.
#
# This fixture set exists because the rule it tests was wrong in production for one run and
# nothing caught it but a human reading the runner banner. The guard fired on the FIRST
# run of E-004's matched arm — the arm whose whole purpose is to load a skill — recorded it
# F15 infrastructure, and marked it "EXCLUDE this run from comparisons". A guard that
# excludes the treatment arm does not look like a bug; it looks like a null result.
#
# Every case asserts BOTH the exit code and the reason string, because "contaminated" for
# the wrong reason is how the previous version passed review.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TOOL=./runner/lib/classify-skill-contamination.sh
pass=0; fail=0

check() { # check <label> <enable_skills> <installed> <telemetry-json> <want-exit> <want-substring>
  local label="$1" en="$2" inst="$3" tel="$4" want="$5" grepfor="$6"
  local out rc
  out="$("$TOOL" "$en" "$inst" "$tel" 2>&1)"; rc=$?
  if [[ "$rc" == "$want" ]] && grep -q -- "$grepfor" <<<"$out"; then
    pass=$((pass+1)); printf '  ok    %-62s exit %s\n' "$label" "$rc"
  else
    fail=$((fail+1)); printf '  FAIL  %-62s exit %s (want %s), missing %q\n' "$label" "$rc" "$want" "$grepfor"
    printf '        %s\n' "$out"
  fi
}

tel() { # tel <source:calls> ... -> telemetry json with matching toolBreakdown
  local acts="" total=0
  for pair in "$@"; do
    local src="${pair%%:*}" n="${pair##*:}"
    acts="${acts}${acts:+,}{\"source\":\"${src}\",\"calls\":${n}}"
    total=$((total + n))
  done
  printf '{"skillActivations":[%s],"toolBreakdown":[{"tool":"Skill","calls":%s},{"tool":"Read","calls":9}]}' \
    "$acts" "$total"
}
NO_SKILL='{"skillActivations":[],"toolBreakdown":[{"tool":"Read","calls":9}]}'
# copilot and codex emit no skill_activated records at all
NO_SOURCES='{"toolBreakdown":[{"tool":"Skill","calls":2},{"tool":"Read","calls":9}]}'

echo "verify-skill-contamination: 16 cases"

echo "  -- skills DISABLED: the default, and every run recorded before 2026-09-04 --"
check "no skill call is clean"                       false false "$NO_SKILL"           0 "clean"
check "ANY skill call is a leak"                     false false "$(tel plugin:1)"     2 "harness bug #13"
check "  even a bundled one, because none should run" false false "$(tel bundled:1)"   2 "despite --disable-slash-commands"
check "  and even one this run installed"            false true  "$(tel projectSettings:1)" 2 "harness bug #13"

echo "  -- skills ENABLED --"
# THE CASE THAT WAS BROKEN IN PRODUCTION.
check "the installed project skill is NOT contamination" true true "$(tel projectSettings:1)" 0 "clean"
check "a bundled skill is not contamination"         true  true  "$(tel bundled:2)"    0 "clean"
check "both together are clean"                      true  true  "$(tel projectSettings:1 bundled:1)" 0 "clean"
# AND THE CASE THE GUARD EXISTS FOR, which must still fire.
check "a PLUGIN skill is still a leak"               true  true  "$(tel plugin:1)"     2 "plugin(1)"
check "  and is named, with its count"               true  true  "$(tel plugin:2 projectSettings:1)" 2 "executed 2×"
# An unseen source must fail OUTSIDE the allowlist, not fall into it.
check "an UNSEEN source is a leak, not a pass"       true  true  "$(tel enterprise:1)" 2 "enterprise(1)"
# projectSettings on an arm that installed nothing is the control arm being contaminated by
# a project skill from somewhere else. It is not cleared just because the source matches.
check "projectSettings on an arm that installed none" true false "$(tel projectSettings:1)" 2 "projectSettings(1)"
# A Skill call the instrument cannot attribute is not cleared by silence.
check "unattributable Skill calls are not cleared"   true  true  "$NO_SOURCES"         2 "no skill_activated record"

# §4a round 2, at 2/2: unparseable telemetry used to come back `clean` with exit 0, because
# both jq calls discarded stderr AND status. A run whose contamination could not be assessed
# was reported as a run with no contamination.
echo "  -- input this script cannot reason about must be REFUSED, never cleared --"
check "malformed telemetry is unclassifiable, not clean"  true  true  '{'                   3 "not parseable"
check "  and the same with skills disabled"               false false '{'                   3 "not parseable"
check "an empty string is unclassifiable, not clean"      true  true  ''                     3 "telemetry is empty"
check "a non-numeric Skill count is refused, not coerced" true  true  '{"toolBreakdown":[{"tool":"Skill","calls":"lots"}]}' 3 "not yield a numeric"

echo
echo "verify-skill-contamination: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
