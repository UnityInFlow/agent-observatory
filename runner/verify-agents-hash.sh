#!/usr/bin/env bash
#
# verify-agents-hash — the fixture set for `agents_hash()` in run-agent.sh.
#
# WHAT IS BEING PROVED. `agentHash` covers exactly ONE file, `.claude/agents/<AGENT_NAME>.md`.
# `agentsHash` covers the SET of `.claude/agents/*.md`, computed as `skills_hash()` computes
# the set of `SKILL.md`s: one digest over the sorted (path, content) pairs. The clause author
# decision 11 item 9 asks for, verbatim, is "a fixture set proving it tells a renamed file from
# a changed one" — cases D, E and F carry that clause, and they do NOT test the same thing:
# **D** is the rename, **E** is the edit, and **F** is the pair. They fail independently, and
# case F's own comment says which of them detects which defect.
#
# WHY IT DRIVES THE REAL RUNNER. Every case invokes `run-agent.sh --check-customization`, which
# computes the hashes on the real code path and exits before any agent is launched. A fixture
# that re-implemented the digest would be testing a copy of the control, which is this
# project's house failure mode. No model call is made and no money is spent.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Asserted at the END against what actually ran, never printed at the top from a constant.
EXPECTED_CASES=10

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
#
# THE FRONTMATTER `name:` DELIBERATELY DOES NOT MATCH THE FILENAME HERE, and it cannot. Case D
# isolates a RENAME, which means the bytes must be identical to ONE's — so `gamma.md` has to
# carry `name: alpha`, and `--agent gamma` is passed only so the run has a dispatch target.
# A reviewer flagged this as an unresolved ordering assumption: if the runner validated `--agent`
# against the frontmatter `name` before hashing, D would fail with "a rename was invisible"
# rather than with a validation error. OBSERVED, NOT ASSUMED: it does not — D passes, and the
# agentsHash it returns differs from ONE's, which is only reachable if the hash was computed.
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

# F — THE REGISTERED CLAUSE, stated as a pair: a rename and an edit must not be the same value.
#
#     *** DO NOT DELETE CASE D ON THE STRENGTH OF THIS ONE. *** An earlier version of this
#     comment claimed F was the backstop against a digest computed over CONTENT ALONE. It is
#     not, and the review caught it. Work it through: with the path left out of the digest, a
#     rename does not move the hash, so H_REN == H_ONE and **D FAILS**; an edit still moves it,
#     so E passes; and H_REN != H_CHG remains true, so **F PASSES**. **D is the case that
#     detects a content-only digest and F is not.** F earns its place by pinning the two
#     differences apart as a PAIR — a digest that folded path and content together lossily
#     could move on both and collide — but it is the second line of the guarantee, not the
#     first. A future editor removing D as redundant would leave the registered clause
#     ("tells a renamed file from a changed one", decision 11 item 9) silently unenforced.
#
#     DEMONSTRATED, not argued, on the ONE and RENAMED fixtures of this file:
#         content-only digest   one = 7256986d2a4de9aa4a7d0b1012091c2a
#                               ren = 7256986d2a4de9aa4a7d0b1012091c2a   <- EQUAL, D fails
#         with the path in it   one = b035a37b0f723a3acdcfeee078d81178
#                               ren = ea5fba4f3f610e938a6c2da36208c063   <- differ, D passes
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

# I — REMOVAL from the set. The header claims agentsHash covers the SET, and C only proves that
#     ADDING a member moves it. Nothing proved that REMOVING one does, so a digest that folded
#     new members in without re-deriving from the current file list would have passed every case
#     above. The value must return to H_ONE exactly: DEL is TWO with beta.md deleted, which is
#     ONE by construction, so this also re-pins determinism through a different edit path than G.
DEL="$TMP/deleted-member"
agent_file "$DEL/.claude/agents/alpha.md" alpha "Body A."
agent_file "$DEL/.claude/agents/beta.md"  beta  "Body B."
rm "$DEL/.claude/agents/beta.md"
H_DEL="$(agents_hash_of --customization "$DEL" --agent alpha)"
if [[ "$H_DEL" == "$H_ONE" && "$H_DEL" == sha256:* ]]; then
  ok "I: REMOVING an agent file returns agentsHash to the one-file value"
else
  bad "I: expected '$H_ONE' after removing beta.md, got '$H_DEL'"
fi

# J — the glob RECURSES, and nothing above showed it. `find .claude/agents -type f -name '*.md'`
#     descends into subdirectories, so an agent in `.claude/agents/sub/` IS part of the set — but
#     every fixture above creates top-level files only, so a runner that narrowed the glob to the
#     top level (or widened it, had it been narrow) would have passed all of them. This pins the
#     actual behaviour rather than the assumed one.
NEST="$TMP/nested"
agent_file "$NEST/.claude/agents/alpha.md"       alpha "Body A."
agent_file "$NEST/.claude/agents/sub/delta.md"   delta "Body D."
H_NEST="$(agents_hash_of --customization "$NEST" --agent alpha)"
if [[ "$H_NEST" == sha256:* && "$H_NEST" != "$H_ONE" ]]; then
  ok "J: an agent file in a SUBDIRECTORY is part of the set ($H_NEST)"
else
  bad "J: a nested agent file was invisible — got '$H_NEST' against '$H_ONE'"
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
