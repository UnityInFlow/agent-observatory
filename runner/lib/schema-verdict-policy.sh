#!/usr/bin/env bash
# What should a run DO about its delivered-tool-schema verdict?
#
#   ./runner/lib/schema-verdict-policy.sh <schema_rc> <agent|no-agent>
#
# WHY THIS EXISTS AS A SEPARATE, TESTABLE THING. `runner/lib/check-init-schema.sh` answers a
# question of fact — is the delivered tool list the declared one? — and it deliberately
# returns FIVE different non-zero codes because "not equal" was five different events and
# collapsing them is how this project has twice thrown away its strongest signal. Its own
# header assigns the words "VOID, redesign, do not score" to exit 5 ALONE, and to exit 6 the
# words "Reported, never silently passed".
#
# `run-agent.sh` section 12b then collapsed all five back into one: `SCHEMA_RC -ne 0` on a
# declaring arm meant exit 9, "the batch is VOID pending a redesign". So the caller was
# stricter than the check it calls, in a way nothing executed to reveal, and the two
# disagreed about the meaning of exit 6.
#
# THAT DISAGREEMENT IS NOT ACADEMIC AND IT WAS FOUND BY IT BITING. Lab 4B.4's orchestrator
# overlay declares `tools: Read, Grep, Glob, Task`; Claude Code 2.1.261 delivers
# ["Read","Task","Grep","Glob"] — the same four tools, permuted — on 3 of 3 probe streams
# (agent-learning-lab/evidence/p04b/lab-4b4/probe-20260906T050917Z/). check-init-schema.sh
# calls that `order-differs`, exit 6, by design. Under the old mapping every run of that arm
# would have exited 9 and declared its own batch void, for a treatment that HAD arrived
# intact.
#
# THE HONEST STATEMENT OF WHAT THIS CHANGES, because loosening a control to let one's own arm
# pass is precisely this project's house failure mode and saying so is not optional:
# EXACTLY ONE EXIT CODE MOVES. 6 stops being fatal and becomes loudly recorded. 5, 4, 3 and 2
# are fatal before and after, and `verify-schema-verdict-policy.sh` proves that by executing
# every one of them rather than by asserting it here. The capability set — which is what a
# `tools:` allowlist is FOR, and the only thing E-005 measured it doing — is unchanged under a
# permutation. The alternative fix, rewriting the overlay's `tools:` line into the delivered
# order so the strings match, was rejected: it would make the runtime's rewriting invisible by
# construction, which is the defect author decision 8 exists to expose, not a fix for it.
#
# `Decided by Claude Opus 5 (claude-opus-5), autonomous, 2026-09-06.` Disclosed as a harness
# move in experiments/E-007-orchestration-overhead.md and in HANDOFF.md. It touches the
# RUNNER's batch-stop signal only: the evaluator's exit-code mapping, the benchmark, the
# fixtures, the rubric and the model are untouched, which is why it is not a §7 halt.
#
# DECISIONS, one per line of output, and the exit code is what run-agent.sh should exit with:
#
#   decision=proceed-match        rc 0  · declared == delivered, or nothing was asserted
#   decision=proceed-order        rc 0  · same SET, different ORDER. RECORDED, not waved past
#   decision=void-mismatch        rc 9  · the delivered SET differs — row 0a, do not score
#   decision=void-unobserved      rc 9  · no init record / no tools key — delivery is ABSENT,
#                                         not proven equal, and an unobserved treatment on a
#                                         declaring arm may not be scored (author decision 8)
#   decision=void-checker-failed  rc 9  · the check itself could not run
#   decision=record-only          rc 0  · a non-declaring arm: nothing is asserted, and this
#                                         is never fatal, because a control cannot fail a
#                                         check it never took
#   usage                         rc 2  · bad arguments
set -uo pipefail

RC="${1:-}"
ARM="${2:-}"

usage() {
  sed -n '2,4p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

[[ -n "$RC" && -n "$ARM" ]] || usage
[[ "$RC" =~ ^[0-9]+$ ]] || usage
case "$ARM" in
  agent | no-agent) ;;
  *) usage ;;
esac

# A non-declaring arm — no --agent, so no overlay file to assert against. check-init-schema.sh
# records the delivered set and asserts nothing; the control's set is evidence, never a gate.
# This branch comes FIRST so that no fatal code can reach a control arm by any path.
if [[ "$ARM" == "no-agent" ]]; then
  if [[ "$RC" == "0" ]]; then
    echo "decision=record-only reason=no-declaring-overlay schema_rc=$RC"
  else
    # Unobserved on a control is a real gap in the evidence and is said out loud; it is not a
    # reason to stop, because the control asserts nothing that could have failed.
    echo "decision=record-only reason=unobserved-on-control schema_rc=$RC"
  fi
  exit 0
fi

case "$RC" in
  0)
    echo "decision=proceed-match reason=declared-equals-delivered-or-nothing-asserted schema_rc=$RC"
    exit 0
    ;;
  6)
    echo "decision=proceed-order reason=same-set-different-order schema_rc=$RC"
    exit 0
    ;;
  5)
    echo "decision=void-mismatch reason=delivered-set-differs-row-0a schema_rc=$RC"
    exit 9
    ;;
  3 | 4)
    echo "decision=void-unobserved reason=no-init-record-or-no-tools-key schema_rc=$RC"
    exit 9
    ;;
  2)
    echo "decision=void-checker-failed reason=check-init-schema-could-not-run schema_rc=$RC"
    exit 9
    ;;
  *)
    # An unknown code is FATAL, not permissive. check-init-schema.sh may grow a sixth
    # outcome; the failure mode to avoid is a new code arriving and being silently treated as
    # a pass because nobody updated this table.
    echo "decision=void-unknown-code reason=unregistered-schema-exit-code schema_rc=$RC"
    exit 9
    ;;
esac
