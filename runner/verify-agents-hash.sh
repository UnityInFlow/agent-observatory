#!/usr/bin/env bash
#
# verify-agents-hash — the fixture set for `agents_hash()` in run-agent.sh.
#
# WHAT IS BEING PROVED. `agentHash` covers exactly ONE file, `.claude/agents/<AGENT_NAME>.md`.
# `agentsHash` covers the SET of `.claude/agents/*.md`, computed as `skills_hash()` computes
# the set of `SKILL.md`s: one digest over the sorted (path, content) pairs. The clause author
# decision 11 item 9 asks for, verbatim, is "a fixture set proving it tells a renamed file from
# a changed one" — cases D, E and F below are that clause and nothing else.
#
# WHY IT DRIVES THE REAL RUNNER. Every case invokes `run-agent.sh --check-customization`, which
# computes the hashes on the real code path and exits before any agent is launched. A fixture
# that re-implemented the digest would be testing a copy of the control, which is this
# project's house failure mode. No model call is made and no money is spent.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Asserted at the END against what actually ran, never printed at the top from a constant.
EXPECTED_CASES=8

RUNNER="${RUNNER_UNDER_TEST:-./runner/run-agent.sh}"
API_PORT="8080"
[[ -f infra/.env ]] && API_PORT="$(sed -n 's/^API_PORT=//p' infra/.env | tail -1)"
API_URL="${API:-http://localhost:${API_PORT:-8080}}"
curl -fsS "${API_URL}/actuator/health" >/dev/null 2>&1 \
  || { echo "Observatory API not reachable at ${API_URL} — run 'make up' first." >&2
       echo "Every check below drives the real runner, which refuses to start without it." >&2
       exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL — $1"; fail=$((fail + 1)); }

agent_file() {  # agent_file <path> <name> <body>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
---
name: $2
description: A fixture agent. Not the shipped overlay.
tools: Read, Edit, Write, Bash
---

$3
EOF
}

run() { "$RUNNER" --runtime claude --benchmark BE-003 --experiment EXP-VERIFY-AGENTS-HASH \
                  --api "$API_URL" "$@" --check-customization 2>&1; }
# The value, or the literal string `ERROR:<exit>` so a failed invocation can never be compared
# as if it were a hash. Two broken runs must not look equal to each other.
agents_hash_of() {
  local out rc
  out="$(run "$@")"; rc=$?
  [[ $rc -eq 0 ]] || { echo "ERROR:$rc"; return; }
  grep -o '"agentsHash":[^,}]*' <<<"$out" | head -1 | cut -d: -f2- | tr -d '"'
}

# --- fixtures ---------------------------------------------------------------
ONE="$TMP/one";      agent_file "$ONE/.claude/agents/alpha.md"  alpha  "Body A."
TWO="$TMP/two";      agent_file "$TWO/.claude/agents/alpha.md"  alpha  "Body A."
                     agent_file "$TWO/.claude/agents/beta.md"   beta   "Body B."
# RENAMED: identical content, different path.
REN="$TMP/renamed";  agent_file "$REN/.claude/agents/gamma.md"  alpha  "Body A."
# CHANGED: identical path, different content.
CHG="$TMP/changed";  agent_file "$CHG/.claude/agents/alpha.md"  alpha  "Body A, edited."
# A COPY of ONE, byte-identical, built independently — determinism.
CPY="$TMP/copy";     agent_file "$CPY/.claude/agents/alpha.md"  alpha  "Body A."
PLAIN="$TMP/plain";  mkdir -p "$PLAIN"; printf 'Be concise.\n' > "$PLAIN/CLAUDE.md"

echo "== agents_hash: the SET of .claude/agents/*.md =="

H_ONE="$(agents_hash_of --customization "$ONE" --agent alpha)"
H_TWO="$(agents_hash_of --customization "$TWO" --agent alpha)"
H_REN="$(agents_hash_of --customization "$REN" --agent gamma)"
H_CHG="$(agents_hash_of --customization "$CHG" --agent alpha)"
H_CPY="$(agents_hash_of --customization "$CPY" --agent alpha)"

# A — a run with no agent overlay records null. Without this, every case below is satisfied by
#     a hash that is non-null on everything, which distinguishes nothing.
out="$(run --customization "$PLAIN")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q '"agentsHash":null' <<<"$out"; then
  ok "A: an overlay with no .claude/agents records agentsHash null"
else
  bad "A: expected agentsHash null, got exit $rc: $(grep -o 'customization hashes: .*' <<<"$out" | head -1)"
fi

# B — and it is non-null when there IS one.
if [[ "$H_ONE" == sha256:* ]]; then
  ok "B: a one-file agent overlay records a non-null agentsHash ($H_ONE)"
else
  bad "B: expected sha256:…, got '$H_ONE'"
fi

# C — the SET, not the dispatched file: adding a second agent changes the value even though
#     --agent still names the first.
if [[ "$H_TWO" == sha256:* && "$H_TWO" != "$H_ONE" ]]; then
  ok "C: adding a second agent file changes agentsHash ($H_ONE -> $H_TWO)"
else
  bad "C: expected a different non-null hash, got '$H_TWO' against '$H_ONE'"
fi

# D — RENAMED. Same content, different filename. The path is in the digest, so this is a
#     difference and not a collision.
if [[ "$H_REN" == sha256:* && "$H_REN" != "$H_ONE" ]]; then
  ok "D: a RENAMED agent file (same content) changes agentsHash ($H_REN)"
else
  bad "D: a rename was invisible — got '$H_REN' against '$H_ONE'"
fi

# E — CHANGED. Same filename, different content.
if [[ "$H_CHG" == sha256:* && "$H_CHG" != "$H_ONE" ]]; then
  ok "E: a CHANGED agent file (same path) changes agentsHash ($H_CHG)"
else
  bad "E: an edit was invisible — got '$H_CHG' against '$H_ONE'"
fi

# F — THE REGISTERED CLAUSE. D and E must not be the same value. A digest over content alone
#     would pass D and E separately and fail here, and that is exactly the defect being
#     excluded: "tells a renamed file from a changed one" (decision 11 item 9).
if [[ "$H_REN" != "$H_CHG" && "$H_REN" == sha256:* && "$H_CHG" == sha256:* ]]; then
  ok "F: a rename and an edit produce DIFFERENT hashes — the two are distinguishable"
else
  bad "F: rename and edit are indistinguishable — both '$H_REN' / '$H_CHG'"
fi

# G — determinism. An independently built, byte-identical overlay hashes the same, or the
#     value carries something other than (path, content) and no comparison above means
#     anything.
if [[ "$H_CPY" == "$H_ONE" && "$H_CPY" == sha256:* ]]; then
  ok "G: a byte-identical overlay built separately hashes identically"
else
  bad "G: expected '$H_ONE', got '$H_CPY'"
fi

# H — agentsHash is not agentHash. On the two-file overlay the dispatched file is `alpha`, so
#     agentHash covers one file and agentsHash covers two; equal values would mean one of the
#     two columns is measuring the other.
out="$(run --customization "$TWO" --agent alpha)"; rc=$?
one_file="$(grep -o '"agentHash":[^,}]*' <<<"$out" | head -1 | cut -d: -f2- | tr -d '"')"
if [[ $rc -eq 0 && "$one_file" == sha256:* && "$one_file" != "$H_TWO" ]]; then
  ok "H: agentHash ($one_file) and agentsHash ($H_TWO) are different measurements"
else
  bad "H: expected two different non-null hashes, got agentHash '$one_file' agentsHash '$H_TWO' (exit $rc)"
fi

echo
ran=$((pass + fail))
if [[ "$ran" -ne "$EXPECTED_CASES" ]]; then
  echo "verify-agents-hash: ${ran} cases ran, ${EXPECTED_CASES} registered — the announced"
  echo "scope and the executed scope disagree, which is the failure this line exists to catch."
  exit 1
fi
echo "verify-agents-hash: ${pass} passed, ${fail} failed, ${ran} of ${EXPECTED_CASES} cases ran."
[[ "$fail" -eq 0 ]] || exit 1
