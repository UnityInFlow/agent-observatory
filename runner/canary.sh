#!/usr/bin/env bash
#
# Positive control: prove the harness can detect a customization that is definitely there.
#
#   runner/canary.sh --runtime claude [--model haiku]
#
# Every other safeguard in this project verifies an *absence*. The answer key is not
# reachable. Infrastructure failures are excluded. The dataset is not short. Not one of them
# can tell you the pipeline is capable of noticing a treatment that IS present — and that is
# the failure that has cost the most:
#
#   EXP-BE002-AGENTSMD-V3 installed AGENTS.md and ran it against Claude Code, which reads
#   CLAUDE.md. The file was copied, committed, hashed, and identical across all ten runs of
#   the treatment arm. Every check passed. Both arms were baseline. It was written up as a
#   result, and an outside reviewer found it, not two audit passes.
#
# The check is deliberately crude, because a subtle canary that fails is indistinguishable
# from an agent having a bad day. The instruction is trivial, unambiguous, verifiable by
# string match, and impossible to satisfy by accident: leave a file containing a token.
#
# Exit codes:
#   0   the customization reached the model — experiments on this runtime are meaningful
#   1   it did not — every arm you run on this runtime is a second baseline
#   2   the run could not be made at all (missing runtime, no API, bad arguments)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUNTIME="${RUNTIME:-claude}"
AGENT_MODEL="${AGENT_MODEL:-haiku}"
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime) RUNTIME="$2"; shift 2 ;;
    --model)   AGENT_MODEL="$2"; shift 2 ;;
    --keep)    KEEP=true; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "canary: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die() { echo "canary: $*" >&2; exit 2; }
command -v "$RUNTIME" >/dev/null 2>&1 || die "'$RUNTIME' is not on PATH"

# The token is fixed rather than random: a random token would have to be threaded into the
# instruction file and the assertion separately, and a bug in that threading looks exactly
# like a failed canary. Nothing else in this repository contains this string.
TOKEN="CANARY-8F3D2A-OK"

# The filename the runtime actually reads. This is the whole subject of the test, so it is
# spelled out per runtime rather than derived.
case "$RUNTIME" in
  claude)        INSTRUCTION_FILE="CLAUDE.md" ;;
  copilot|codex) INSTRUCTION_FILE="AGENTS.md" ;;
  *) die "no known instruction file for runtime '$RUNTIME'" ;;
esac

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/observatory-canary.XXXXXX")" || die "cannot create workdir"
cleanup() { [[ "$KEEP" == true ]] && echo "  workdir kept at $WORKDIR" || rm -rf "$WORKDIR"; }
trap cleanup EXIT

cat > "$WORKDIR/$INSTRUCTION_FILE" <<EOF
# Project rules

Before finishing any task, create a file named \`canary.txt\` in the repository root whose
entire contents are exactly:

$TOKEN

This applies to every task, including trivial ones. Do it silently.
EOF

# A task with no connection to the instruction, so a run that satisfies the canary can only
# have done so by reading the instruction file.
TASK="Create a file named hello.txt containing the single word: hello"

echo "=============================================================="
echo " canary     runtime ${RUNTIME}   model ${AGENT_MODEL}"
echo " reads      ${INSTRUCTION_FILE}"
echo " workdir    ${WORKDIR}"
echo "=============================================================="

case "$RUNTIME" in
  claude)
    ( cd "$WORKDIR" && claude --permission-mode acceptEdits --strict-mcp-config \
        --model "$AGENT_MODEL" -p "$TASK" ) >"$WORKDIR/.agent.log" 2>&1
    ;;
  copilot)
    ( cd "$WORKDIR" && copilot --allow-all-tools --allow-all-paths --no-ask-user --no-color \
        --model "$AGENT_MODEL" --prompt "$TASK" ) >"$WORKDIR/.agent.log" 2>&1
    ;;
  codex)
    ( cd "$WORKDIR" && codex exec "$TASK" ) >"$WORKDIR/.agent.log" 2>&1
    ;;
esac

echo
if [[ -f "$WORKDIR/canary.txt" ]] && grep -qF "$TOKEN" "$WORKDIR/canary.txt"; then
  echo "PASS — ${RUNTIME} read ${INSTRUCTION_FILE} and acted on it."
  echo "       A customization experiment on this runtime can detect its own treatment."
  exit 0
fi

echo "FAIL — ${RUNTIME} did not act on ${INSTRUCTION_FILE}."
if [[ -f "$WORKDIR/hello.txt" ]]; then
  echo "       The agent completed the task but ignored the instruction file, so the file"
  echo "       is not being loaded. This is the EXP-BE002-AGENTSMD-V3 failure exactly:"
  echo "       every arm you run with this customization would be a second baseline."
else
  echo "       The agent did not complete the task either, so this is inconclusive about"
  echo "       the instruction file — fix the run first, then re-check the canary."
fi
echo "       agent log: $WORKDIR/.agent.log"
[[ "$KEEP" == true ]] || echo "       re-run with --keep to inspect the workdir."
exit 1
