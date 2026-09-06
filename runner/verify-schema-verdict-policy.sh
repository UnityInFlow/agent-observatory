#!/usr/bin/env bash
# Does the schema-verdict policy still REFUSE?
#
#   ./runner/verify-schema-verdict-policy.sh
#
# `runner/lib/schema-verdict-policy.sh` makes exactly one previously-fatal outcome
# non-fatal: exit 6, "same set, different order". A change of that shape is indistinguishable
# from quietly disabling the check unless something EXECUTES the cases that must still fail.
# A control that has never been shown to reject anything is indistinguishable from one that
# rejects nothing — this project has paid for that sentence three times — so every registered
# exit code is driven here, including the four that must still void a batch.
#
# The last two cases are end-to-end: the REAL check-init-schema.sh is run over a REAL probe
# transcript and its exit code is fed to the policy, so the pair is proved to agree rather
# than each being proved against a remembered number.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

POLICY="./runner/lib/schema-verdict-policy.sh"
CHECK="./runner/lib/check-init-schema.sh"
LAB="../agent-learning-lab"

[[ -x "$POLICY" ]] || { echo "verify-schema-verdict-policy: $POLICY missing or not executable"; exit 2; }
[[ -x "$CHECK" ]]  || { echo "verify-schema-verdict-policy: $CHECK missing or not executable"; exit 2; }

EXPECTED_CASES=16
pass=0
fail=0

# run <label> <expected_rc> <expected_decision_substring> -- <args...>
run() {
  local label="$1" want_rc="$2" want_dec="$3"; shift 4   # the literal `--`
  local out rc
  out="$("$POLICY" "$@" 2>&1)"
  rc=$?
  if [[ "$rc" == "$want_rc" && "$out" == *"$want_dec"* ]]; then
    pass=$((pass + 1))
    printf '  ok    %-34s rc=%s  %s\n' "$label" "$rc" "$out"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-34s rc=%s (want %s)  out=%s (want %s)\n' \
      "$label" "$rc" "$want_rc" "$out" "$want_dec"
  fi
}

echo "verify-schema-verdict-policy: declaring arm — the four that must still VOID"
run "mismatch (set differs)"      9 "decision=void-mismatch"       -- 5 agent
run "no init record"              9 "decision=void-unobserved"     -- 3 agent
run "no tools key"                9 "decision=void-unobserved"     -- 4 agent
run "checker could not run"       9 "decision=void-checker-failed" -- 2 agent
run "unregistered future code"    9 "decision=void-unknown-code"   -- 7 agent

echo "verify-schema-verdict-policy: declaring arm — the two that proceed"
run "declared == delivered"       0 "decision=proceed-match"       -- 0 agent
run "same set, different order"   0 "decision=proceed-order"       -- 6 agent

echo "verify-schema-verdict-policy: control arm — a control cannot fail a check it never took"
run "control, match"              0 "decision=record-only"         -- 0 no-agent
run "control, mismatch code"      0 "decision=record-only"         -- 5 no-agent
run "control, no init record"     0 "decision=record-only"         -- 3 no-agent
run "control, order differs"      0 "decision=record-only"         -- 6 no-agent

echo "verify-schema-verdict-policy: usage"
run "no arguments"                2 ""                             -- ""  ""
run "bad arm name"                2 ""                             -- 0 orchestrator
run "non-numeric rc"              2 ""                             -- six agent

# --- end to end: the real checker's code, fed to the real policy -------------
# A unit test of the policy proves the table. It does not prove the table is keyed to the
# codes the checker actually emits — the exact gap that let run-agent.sh and
# check-init-schema.sh disagree about exit 6 without anything noticing.
echo "verify-schema-verdict-policy: end to end, real checker over real transcripts"

P1_LOG="$LAB/evidence/p04b/lab-4b4/probe-20260906T050917Z/P1-1.jsonl"
P1_OVERLAY="$LAB/build/customizations/orchestration-4b4-P1/.claude/agents/orchestrator.md"
if [[ -r "$P1_LOG" && -r "$P1_OVERLAY" ]]; then
  "$CHECK" "$P1_LOG" "$P1_OVERLAY" >/dev/null 2>&1
  e2e_rc=$?
  out="$("$POLICY" "$e2e_rc" agent 2>&1)"; prc=$?
  if [[ "$e2e_rc" == "6" && "$prc" == "0" && "$out" == *"decision=proceed-order"* ]]; then
    pass=$((pass + 1))
    printf '  ok    %-34s checker rc=6 -> %s\n' "P1 probe: order differs" "$out"
  else
    fail=$((fail + 1))
    printf '  FAIL  %-34s checker rc=%s policy rc=%s out=%s\n' \
      "P1 probe: order differs" "$e2e_rc" "$prc" "$out"
  fi
else
  fail=$((fail + 1))
  printf '  FAIL  %-34s fixture unreadable: %s\n' "P1 probe: order differs" "$P1_LOG"
fi

# A synthesised init record whose delivered SET differs from the declared one. This is the
# case that must still void, driven through the same two scripts as the case that must not.
TMPD="$(mktemp -d)" || { echo "cannot mktemp"; exit 2; }
trap 'rm -rf "$TMPD"' EXIT
printf '%s\n' '{"type":"system","subtype":"init","tools":["Read","Bash"]}' > "$TMPD/mismatch.jsonl"
printf '%s\n' '---' 'name: probe' 'tools: Read, Grep, Glob, Task' '---' 'body' > "$TMPD/overlay.md"
"$CHECK" "$TMPD/mismatch.jsonl" "$TMPD/overlay.md" >/dev/null 2>&1
e2e_rc=$?
out="$("$POLICY" "$e2e_rc" agent 2>&1)"; prc=$?
if [[ "$e2e_rc" == "5" && "$prc" == "9" && "$out" == *"decision=void-mismatch"* ]]; then
  pass=$((pass + 1))
  printf '  ok    %-34s checker rc=5 -> %s\n' "synthetic: set differs" "$out"
else
  fail=$((fail + 1))
  printf '  FAIL  %-34s checker rc=%s policy rc=%s out=%s\n' \
    "synthetic: set differs" "$e2e_rc" "$prc" "$out"
fi

echo
echo "verify-schema-verdict-policy: ${pass} passed, ${fail} failed"

# The count is ASSERTED, not announced. A verifier that silently runs fewer cases than it
# claims is the house failure mode wearing a test harness, and this project has already
# shipped one that printed "0 of 27" from the top of the file.
if [[ "$((pass + fail))" -ne "$EXPECTED_CASES" ]]; then
  echo "verify-schema-verdict-policy: EXECUTED $((pass + fail)) cases, REGISTERED $EXPECTED_CASES" >&2
  exit 1
fi
[[ "$fail" -eq 0 ]] || exit 1
echo "verify-schema-verdict-policy: all ${EXPECTED_CASES} cases behaved as specified"
exit 0
