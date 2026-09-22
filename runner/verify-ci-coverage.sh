#!/usr/bin/env bash
# Is every check script in this runner either RUN BY CI or exempt for a named reason?
#
#   ./runner/verify-ci-coverage.sh
#
# WHY THIS EXISTS. A verifier that nothing runs is L3 — words a human chooses to execute.
# Six of this runner's check scripts were L3 for months without anyone noticing, because
# nothing compared the set of scripts against the set of CI steps. The comparison is the
# control; this script is that comparison, and the table it reads makes each gap a written
# claim about a live dependency rather than an oversight.
#
# WHAT IT LOOKS AT, EXACTLY. The tracked CHECK SCRIPTS, and nothing else:
#
#     runner/verify-*.sh   runner/smoke-test.sh   runner/send-test-trace.sh
#
# These are the files whose job is to check something, so "CI does not run it" is a
# statement about a control. The population is read from `git ls-files`, so a new
# verify-*.sh is in scope the moment it is added.
#
# WHAT IT SAYS NOTHING ABOUT. `runner/run-agent.sh`, `runner/evaluate.sh`,
# `runner/seed-demo.sh`, `runner/backfill-telemetry.sh`, `runner/canary.sh`, the ten
# sourced libraries under `runner/lib/`, and the fixture stubs under `runner/fixtures/`.
# Those are part of a run, or sourced by one, or deliberate stubs — none of them is a check,
# so "is it run by CI?" is the wrong question and an exempt row for one of them would assert
# something nothing here verifies. The exempt table refuses such a row, because a path that
# is not in the population is an error, not a permission.
#
# THE RULE. For every check script: it is named in `.github/workflows/ci.yml`, OR it has a
# row in `runner/ci-exempt.tsv` of the form `<path><TAB><the live thing it needs>`. Both is
# an error too — an exempt row that CI contradicts is a stale claim, and a reader who trusts
# the table would be told a running check cannot run.
#
# OVERRIDES, which is also how this script proves it REFUSES. Setting any of
#
#     CI_COVERAGE_POPULATION   a file, one path per line, instead of the `git ls-files` set
#     CI_COVERAGE_WORKFLOW     a workflow file instead of .github/workflows/ci.yml
#     CI_COVERAGE_EXEMPT       an exempt table instead of runner/ci-exempt.tsv
#
# puts the script in SINGLE-CHECK mode: it runs that one comparison and exits 0 (covered)
# or 1 (refused, offending paths on stdout). With none of them set it runs the live
# repository as case 1 and then re-invokes ITSELF once per fixture under
# `runner/fixtures/ci-coverage/`, through those same variables, so the refusals below are
# demonstrated by the same code path that guards the repository — not by a second
# implementation that could drift from it.
#
# Exit 0 every case behaved as registered · 1 SINGLE-CHECK MODE REFUSED · 2 A CASE FAILED,
# or a usage error.
set -uo pipefail
# Resolved BEFORE the cd, because the fixture cases re-invoke this same file and a relative
# $0 stops resolving the moment the working directory moves.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.." || exit 1

DEFAULT_WORKFLOW=".github/workflows/ci.yml"
DEFAULT_EXEMPT="runner/ci-exempt.tsv"
FIXTURES="runner/fixtures/ci-coverage"

# The count is asserted at the END, against the cases that actually ran, for the reason
# runner/verify-init-schema-check.sh gives: a number announced before any case has executed
# is a number no case has to agree with.
EXPECTED_CASES=8

# --------------------------------------------------------------------------------------
# The comparison itself. 0 covered · 1 refused (offenders on stdout) · 2 usage error.
# --------------------------------------------------------------------------------------
check_coverage() {
  local pop="$1" workflow="$2" exempt="$3"
  local line path reason lineno=0 offenders=0
  local ex_paths="" pop_paths=""

  [[ -r "$pop" ]]      || { echo "verify-ci-coverage: cannot read population file $pop" >&2; return 2; }
  [[ -r "$workflow" ]] || { echo "verify-ci-coverage: cannot read workflow file $workflow" >&2; return 2; }
  [[ -r "$exempt" ]]   || { echo "verify-ci-coverage: cannot read exempt table $exempt" >&2; return 2; }

  # Membership is tested with bash pattern matching against these newline-delimited lists,
  # NOT with `printf ... | grep -Fxq`. Under `set -o pipefail` that pipeline reports failure
  # whenever grep -q exits on the first match before printf has finished writing, which is a
  # race: it answered "not present" for a different exempt row on each run, and the first
  # version of this script passed and then failed with nothing changed in between.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    pop_paths="$pop_paths$line"$'\n'
  done < "$pop"

  # Pass 1 — the exempt table. Every row is checked before anything is exempted by it, so a
  # malformed table cannot quietly cover a script.
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    [[ "$line" == "#"* ]] && continue
    path="${line%%$'\t'*}"
    reason=""
    [[ "$line" == *$'\t'* ]] && reason="${line#*$'\t'}"

    if [[ -z "${path//[[:space:]]/}" ]]; then
      echo "  $exempt:$lineno names no path"
      offenders=$((offenders + 1))
      continue
    fi
    if [[ -z "${reason//[[:space:]]/}" ]]; then
      echo "  $exempt:$lineno exempts $path for no stated reason"
      offenders=$((offenders + 1))
    fi
    if [[ $'\n'"$ex_paths" == *$'\n'"$path"$'\n'* ]]; then
      echo "  $exempt:$lineno lists $path a second time"
      offenders=$((offenders + 1))
      continue
    fi
    if [[ $'\n'"$pop_paths" != *$'\n'"$path"$'\n'* ]]; then
      echo "  $exempt:$lineno exempts $path, which is not a tracked check script"
      offenders=$((offenders + 1))
    elif grep -Fq -- "$path" "$workflow"; then
      echo "  $exempt:$lineno exempts $path, which $workflow already runs"
      offenders=$((offenders + 1))
    fi
    ex_paths="$ex_paths$path"$'\n'
  done < "$exempt"

  # Pass 2 — the population. Neither in the workflow nor in the table is the gap this
  # whole script exists to make visible.
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -z "${path//[[:space:]]/}" ]] && continue
    grep -Fq -- "$path" "$workflow" && continue
    [[ $'\n'"$ex_paths" == *$'\n'"$path"$'\n'* ]] && continue
    echo "  $path is run by neither $workflow nor exempted in $exempt"
    offenders=$((offenders + 1))
  done < "$pop"

  [[ "$offenders" -eq 0 ]] && return 0
  return 1
}

# --------------------------------------------------------------------------------------
# Single-check mode: any override set means "compare exactly this and tell me the answer".
# --------------------------------------------------------------------------------------
TMP="$(mktemp -d)" || exit 2
trap 'rm -rf "$TMP"' EXIT

population_of_this_checkout() {
  git ls-files 'runner/verify-*.sh' 'runner/smoke-test.sh' 'runner/send-test-trace.sh' > "$1" 2>/dev/null || return 2
  [[ -s "$1" ]] || return 2
  return 0
}

if [[ -n "${CI_COVERAGE_POPULATION:-}${CI_COVERAGE_WORKFLOW:-}${CI_COVERAGE_EXEMPT:-}" ]]; then
  single_pop="${CI_COVERAGE_POPULATION:-}"
  if [[ -z "$single_pop" ]]; then
    single_pop="$TMP/population.txt"
    population_of_this_checkout "$single_pop" || {
      echo "verify-ci-coverage: git ls-files found no check script — is this a checkout?" >&2
      exit 2
    }
  fi
  check_coverage "$single_pop" \
    "${CI_COVERAGE_WORKFLOW:-$DEFAULT_WORKFLOW}" \
    "${CI_COVERAGE_EXEMPT:-$DEFAULT_EXEMPT}"
  exit $?
fi

# --------------------------------------------------------------------------------------
# Full run: the live repository, then every fixture.
# --------------------------------------------------------------------------------------
pass=0
fail=0

echo "verify-ci-coverage: the live repository, then the fixtures that prove it refuses"
echo

LIVE_POP="$TMP/population.txt"
if ! population_of_this_checkout "$LIVE_POP"; then
  echo "verify-ci-coverage: git ls-files found no check script — is this a checkout?" >&2
  exit 2
fi

live_out="$(check_coverage "$LIVE_POP" "$DEFAULT_WORKFLOW" "$DEFAULT_EXEMPT" 2>&1)"
live_rc=$?
if [[ "$live_rc" -eq 0 ]]; then
  echo "  ok   — 1 every tracked check script is run by ci.yml or exempt for a named reason ($(grep -c . "$LIVE_POP") scripts)"
  pass=$((pass + 1))
else
  echo "  FAIL — 1 the live repository is not covered (exit $live_rc):"
  printf '%s\n' "$live_out"
  fail=$((fail + 1))
fi

# fixture_case <number> <directory> <expected exit> <what it proves>
fixture_case() {
  local n="$1" dir="$FIXTURES/$2" want="$3" desc="$4"
  local out rc

  if [[ ! -d "$dir" ]]; then
    echo "  FAIL — $n $desc: fixture $dir is missing"
    fail=$((fail + 1))
    return
  fi

  out="$(CI_COVERAGE_POPULATION="$dir/population.txt" \
         CI_COVERAGE_WORKFLOW="$dir/ci.yml" \
         CI_COVERAGE_EXEMPT="$dir/ci-exempt.tsv" \
         "$SELF" 2>&1)"
  rc=$?

  if [[ "$rc" -ne "$want" ]]; then
    echo "  FAIL — $n $desc: expected exit $want, got $rc: $(tr '\n' '|' <<<"$out")"
    fail=$((fail + 1))
    return
  fi
  if [[ "$want" -eq 1 && -z "${out//[[:space:]]/}" ]]; then
    echo "  FAIL — $n $desc: refused with exit 1 but named no offending path"
    fail=$((fail + 1))
    return
  fi
  if [[ "$want" -eq 0 && -n "${out//[[:space:]]/}" ]]; then
    echo "  FAIL — $n $desc: admitted but still complained: $(tr '\n' '|' <<<"$out")"
    fail=$((fail + 1))
    return
  fi
  echo "  ok   — $n $desc"
  pass=$((pass + 1))
}

fixture_case 2 clean               0 "a population wholly covered by ci.yml and the table is admitted"
fixture_case 3 uncovered           1 "a check script in neither ci.yml nor the table is refused"
fixture_case 4 exempt-unknown-path 1 "an exempt row naming no tracked check script is refused"
fixture_case 5 exempt-empty-reason 1 "an exempt row whose reason column is empty is refused"
fixture_case 6 exempt-no-tab       1 "an exempt row with no reason column at all is refused"
fixture_case 7 exempt-duplicate    1 "a path listed twice in the table is refused"
fixture_case 8 exempt-and-ci       1 "a path both exempted and run by ci.yml is refused"

echo
ran=$((pass + fail))
if [[ "$ran" -ne "$EXPECTED_CASES" ]]; then
  echo "verify-ci-coverage: ${ran} cases ran, ${EXPECTED_CASES} registered — the announced"
  echo "scope and the executed scope disagree, which is the failure this line exists to catch."
  exit 2
fi
echo "verify-ci-coverage: ${pass} passed, ${fail} failed, of ${EXPECTED_CASES} registered cases"
[[ "$fail" -eq 0 ]] || exit 2
