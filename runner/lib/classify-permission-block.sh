#!/usr/bin/env bash
# classify-permission-block.sh — was this run's empty output caused by the HARNESS refusing
# to let the agent write, rather than by the agent failing the task?
#
#   classify-permission-block.sh <telemetry-or-run-record-json> <changed-file-count>
#
# WHY THIS IS ITS OWN FILE, AND WHY IT IS CONJUNCTIVE. obs#47 reports that a permission
# block is recorded as an ordinary capability failure: the run looks like an agent that
# could not do the work, and enters a registered analysis as one. The tempting rule —
# "permissionDenials > 0 means the run was blocked" — is WRONG ON THIS STORE'S OWN DATA,
# and it was checked before this file was written rather than after:
#
#   SIX runs of 550 have permissionDenials > 0. ALL SIX PASSED.
#   (EXP-4B-ORCH-OVERHEAD: denials 1-2, toolCalls 14-25, changedFiles 3, passed true.)
#
# A disjunctive rule would convert those six passing runs into discards. That is the exact
# failure obs#47 names in its own text — "a permission block silently converted into a
# passing-looking dataset is how this class of bug survives" — running in reverse, and it is
# how this guard would have shipped looking green.
#
# So the rule needs BOTH conjuncts:
#
#   a denial signal        `.behavior.permissionDenials > 0`
#   AND nothing produced   the changed-file count is 0
#
# WHAT THIS DOES NOT COVER, STATED HERE SO A GREEN RUN CANNOT LATER APPEAR TO HAVE SETTLED IT.
# obs#47's own observed failure is an ABSTENTION: the agent asked a human and stopped without
# calling the tool. No tool call means no `tool_decision` event, so `permissionDenials` is 0
# and the first conjunct is false. Measured on the seven F05 runs of EXP-BE002-MODEL-TIER
# that obs#47 is about: denials 0 on 7 of 7, toolCalls 11-18, changedFiles 1 on 7 of 7 — so
# BOTH conjuncts are false there, not just the telemetry one. This classifier does not close
# obs#47's case. The only vocabulary-free signal an abstention leaves is that the turn ended
# with the task unattempted, which is the completion contract (Lab 5B.4) and is not built here.
#
# Exit 0 not a permission block · 2 permission block · 3 UNCLASSIFIABLE · 1 usage.
# Reason on stdout, naming BOTH conjuncts in every case, because "blocked" for the wrong
# reason is indistinguishable from "blocked" for the right one once it is an exit code.
#
# Exit 3 is the direction this file must fail in. A missing `permissionDenials` is NOT zero
# denials: codex and copilot emit no permission telemetry at all, and a run whose block state
# could not be assessed reported as a run with no block is silence read as good news — the
# defect every other guard in this runner has had.

set -uo pipefail

[[ $# -eq 2 ]] || {
  echo "usage: classify-permission-block.sh <telemetry-or-run-record-json> <changed-file-count>" >&2
  exit 1
}
TELEMETRY="$1"
CHANGED="$2"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# Parse once and REFUSE if it does not parse, before anything is read out of it.
if [[ -z "${TELEMETRY// }" ]]; then
  echo "telemetry is empty — permission block could not be classified"
  exit 3
fi
if ! jq -e . >/dev/null 2>&1 <<<"$TELEMETRY"; then
  echo "telemetry is not parseable JSON — permission block could not be classified"
  exit 3
fi

# One path serves both call sites: `.behavior.permissionDenials` is written by
# runner/lib/claude-telemetry.sh:100-109 into the live telemetry JSON AND is the shape the
# API stores and returns, so a replay over stored evidence reads the same field as a run.
DENIALS="$(jq -r '.behavior.permissionDenials // "MISSING"' <<<"$TELEMETRY" 2>/dev/null)"
TOOLCALLS="$(jq -r '.behavior.toolCalls // "MISSING"' <<<"$TELEMETRY" 2>/dev/null)"

if [[ "$DENIALS" == "MISSING" ]]; then
  echo "behavior.permissionDenials is absent — permission block could not be classified (absent is not zero)"
  exit 3
fi
if ! [[ "$DENIALS" =~ ^[0-9]+$ ]]; then
  echo "behavior.permissionDenials is not a number (${DENIALS}) — permission block could not be classified"
  exit 3
fi
# The changed-file count comes from the caller rather than from this JSON, because the
# in-run caller counts it with git in the worktree and has no `.result` yet, while a replay
# passes `jq '.result.changedFiles | length'`. One code path, and the caller says what it
# counted. A count that is not a number is refused, never coerced to 0: coercing it would
# satisfy the second conjunct and make this guard fire on runs that produced work.
if ! [[ "$CHANGED" =~ ^[0-9]+$ ]]; then
  echo "changed-file count is not a number (${CHANGED}) — permission block could not be classified"
  exit 3
fi

if [[ "$DENIALS" -gt 0 && "$CHANGED" -eq 0 ]]; then
  echo "permission block: ${DENIALS} denial(s) and 0 changed files (toolCalls ${TOOLCALLS})"
  exit 2
fi

if [[ "$DENIALS" -gt 0 ]]; then
  echo "not a permission block: ${DENIALS} denial(s) but ${CHANGED} changed file(s) — the run produced work"
  exit 0
fi

if [[ "$CHANGED" -eq 0 ]]; then
  echo "not a permission block: 0 changed files but 0 denials — nothing was refused (toolCalls ${TOOLCALLS})"
  exit 0
fi

echo "not a permission block: 0 denials and ${CHANGED} changed file(s)"
exit 0
