#!/usr/bin/env bash
# Can this runner make an agent overlay THE AGENT, and does it REFUSE when it cannot?
#
#   ./runner/verify-agent-delivery.sh
#
# WHY THIS EXISTS. An agent overlay is the third treatment class in this project whose
# delivery every check reported as working while the model never saw it, and the first two
# each cost a comparison:
#
#   Phase 1  an instruction file under a name the runtime does not read — installed,
#            committed, hashed, never opened. Twenty runs, written up as a result.
#   Phase 3  a skill under `--disable-slash-commands`, whose help text is "Disable all
#            skills" — 6 of 6 activations without the flag, 0 of 6 with it, p = 0.0022.
#            Fifteen runs of three arms would have agreed perfectly, about nothing.
#   B4       a `.claude/agents/*.md` file with no `--agent` flag. The file registers a
#            SUBAGENT THE MAIN SESSION MAY DELEGATE TO. The session keeps all 29 tools, the
#            overlay's tools: line constrains something never invoked, and the arm is a
#            second baseline carrying a customization hash.
#
# The shape is identical all three times: copied, committed, tracked, hashed — and none of
# that is the treatment. So the guard is the same guard, written a third time, and this
# drives it through fixtures rather than trusting that it is there.
#
# CHECKS — every one of them costs no model call and no network beyond the API health probe.
#   A  an agent overlay with NO --agent is refused, and names the files
#   B  the same overlay WITH --agent is admitted
#   C  --agent naming a file the overlay does not install is refused
#   D  --agent with no --customization at all is refused
#   E  --agent on a non-claude runtime is refused rather than silently dropped
#   F  a customization with no agent file is untouched by the guard (no regression)
#   G  no customization at all still passes — the control arm's path, under `set -u`
#   H  an agent overlay AND a skill together need both switches, and say so
#   I  the overlay is force-added into the setup commit and TRACKED, not merely copied
#   J  an agent overlay written for ANOTHER runtime (.github/agents on claude) is refused
#   K  a portable bundle shipping BOTH directories still runs, and says which one is inert
#   L  .claude/agents on codex is refused too — it reads no agent directory at all
#   M  .github/agents on COPILOT is refused — the gap pass 18 found and halted on
#   N  a dispatched agent overlay records agentHash = THAT FILE, not null
#   O  the control arm records agentHash null — the two are distinguishable in the record
#   P  an installed skill records a non-null skillsHash
#
# N, O and P are about the RECORD rather than the refusal, and they are here because until
# 2026-09-08 agentHash hashed `.github/copilot-instructions.md` and skillsHash hashed
# `.github/skills.md` — neither of which exists in this repo, so both were null on every run
# ever recorded, including every run whose treatment WAS an agent file. A-M prove the runner
# refuses what it cannot deliver; N-P prove the run record can afterwards say which arm a run
# was in. Without them arm membership rests on `--variant`, a string typed at launch, and
# 2026-09-08 is a live demonstration of three runs typed wrong in one morning.
#
# Exit 0 every case behaved as registered · 1 the API was not reachable · 2 A CASE FAILED.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# RUNNER_UNDER_TEST exists so this verifier can itself be shown to FAIL. A fixture set that
# has only ever been run against a working guard proves that the cases pass, not that they
# would catch a broken one — the same gap as a control that has never been shown to reject
# anything. Point it at a copy of run-agent.sh with the guard deleted and cases A, C, D and
# H must go red. Defaults to the real runner; nothing in normal use sets it.
RUNNER="${RUNNER_UNDER_TEST:-./runner/run-agent.sh}"

# The count is asserted at the END against what actually ran. A total printed at the top is
# computed before any case has executed, and this project has already shipped one that said
# 27 while 26 ran.
EXPECTED_CASES=16

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

# --- fixtures --------------------------------------------------------------
agent_file() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
---
name: $2
description: A fixture agent. Not the shipped overlay.
tools: Read, Edit, Write, Bash
---

Fixture body.
EOF
}

AGENT_OVERLAY="$TMP/with-agent"
agent_file "$AGENT_OVERLAY/.claude/agents/fixture-implementer.md" fixture-implementer

BOTH_OVERLAY="$TMP/agent-and-skill"
agent_file "$BOTH_OVERLAY/.claude/agents/fixture-implementer.md" fixture-implementer
mkdir -p "$BOTH_OVERLAY/.claude/skills/fixture-skill"
cat > "$BOTH_OVERLAY/.claude/skills/fixture-skill/SKILL.md" <<'EOF'
---
name: fixture-skill
description: A fixture skill, present only so the two guards can be shown to compose.
---
Body.
EOF

PLAIN_OVERLAY="$TMP/no-agent"
mkdir -p "$PLAIN_OVERLAY"
printf 'Be concise.\n' > "$PLAIN_OVERLAY/CLAUDE.md"

run() { "$RUNNER" --runtime "$1" --benchmark BE-003 --experiment EXP-VERIFY-AGENT \
                  --api "$API_URL" "${@:2}" --check-customization 2>&1; }

echo "== the runner's agent-delivery guard =="

# A — the failure this guard exists for
out=$(run claude --customization "$AGENT_OVERLAY"); rc=$?
if [[ $rc -eq 1 ]] && grep -q "passes no --agent" <<<"$out" \
   && grep -q "fixture-implementer.md" <<<"$out"; then
  ok "A: an agent overlay with no --agent is refused, and the file is named (exit 1)"
else
  bad "A: expected exit 1 naming the overlay file, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# B — and it admits the correct invocation, which is the half that makes A mean something.
# A guard that refuses everything is not a control either.
out=$(run claude --customization "$AGENT_OVERLAY" --agent fixture-implementer); rc=$?
if [[ $rc -eq 0 ]] && grep -q "customization checks passed" <<<"$out" \
   && grep -q "installs 1 agent overlay file" <<<"$out"; then
  ok "B: the same overlay with --agent is admitted, and the count is reported"
else
  bad "B: expected exit 0 and the overlay count, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# C — a name that resolves to nothing leaves the session unbounded. claude itself would
# exit 1 later and print its registry; this fails before a run id exists and says which
# file was expected instead of which names are known.
out=$(run claude --customization "$AGENT_OVERLAY" --agent no-such-agent); rc=$?
if [[ $rc -eq 1 ]] && grep -q "names no file this customization installs" <<<"$out"; then
  ok "C: --agent naming a file the overlay does not install is refused"
else
  bad "C: expected exit 1 and 'names no file', got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# D — no overlay at all means the boundary would come from outside the experiment, from
# something this run neither controls nor hashes.
out=$(run claude --agent fixture-implementer); rc=$?
if [[ $rc -eq 1 ]] && grep -q "with no --customization" <<<"$out"; then
  ok "D: --agent with no --customization is refused"
else
  bad "D: expected exit 1 and 'with no --customization', got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# E — THE --model BUG, PRE-EMPTED. Until 2026-08-28 the codex arm accepted --model and never
# forwarded it, so a run recorded a model that never ran. `--agent` exists on claude and
# nowhere else here; accepting and dropping it would record a bounded arm that was not one.
out=$(run codex --customization "$AGENT_OVERLAY" --agent fixture-implementer); rc=$?
if [[ $rc -eq 1 ]] && grep -q "is not forwarded to runtime 'codex'" <<<"$out"; then
  ok "E: --agent on a runtime that has no such flag is refused, not silently dropped"
else
  bad "E: expected exit 1 and 'not forwarded to runtime', got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# F — the regression that matters most: every run recorded before this flag existed must
# keep its exact meaning.
out=$(run claude --customization "$PLAIN_OVERLAY"); rc=$?
if [[ $rc -eq 0 ]] && ! grep -q "agent overlay" <<<"$out"; then
  ok "F: a customization with no agent file is untouched by the guard"
else
  bad "F: expected exit 0 and no mention of an agent overlay, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# G — the control arm enters neither block. The --agent/--customization check therefore sits
# OUTSIDE the customization block, because a `set -u` reference on the control path aborts
# the arm least likely to be watched, which is the quietest way to shrink an experiment.
out=$(run claude); rc=$?
if [[ $rc -eq 0 ]] && grep -q "customization checks passed" <<<"$out" \
   && ! grep -q "unbound variable" <<<"$out"; then
  ok "G: a run with no customization and no --agent passes (the control arm's path)"
else
  bad "G: expected exit 0 and no unbound-variable error, got exit $rc: $(tail -3 <<<"$out" | tr '\n' ' ')"
fi

# H — the two guards must compose. An overlay carrying both an agent and a skill needs both
# switches, and getting one is not getting both.
out=$(run claude --customization "$BOTH_OVERLAY" --agent fixture-implementer); rc=$?
if [[ $rc -eq 1 ]] && grep -q "would disable skills" <<<"$out"; then
  ok "H: --agent alone does not satisfy the skill guard; both switches are required"
else
  bad "H: expected exit 1 on the skill guard, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# I — "the file is in the worktree" is the claim Phase 1 believed for twenty runs. The
# benchmarks repo ignores `.claude/*`, so an agent overlay lands on exactly the path that
# `git add -A` skips; what the setup commit TRACKS is the only version of the claim that
# means anything.
out=$(run claude --customization "$AGENT_OVERLAY" --agent fixture-implementer); rc=$?
if [[ $rc -eq 0 ]] && grep -q "tracked overlay files in the setup commit: 1 of 1" <<<"$out"; then
  ok "I: the agent overlay is tracked 1 of 1 by the setup commit, not merely copied"
else
  bad "I: expected 1 of 1 tracked, got exit $rc: $(grep -E 'tracked|force-added' <<<"$out" | tr '\n' ' ')"
fi

# J — the gap this project found by being handed an overlay from outside it. A Copilot-shaped
# bundle (.github/agents/) run on claude matched NO glob in this runner until 2026-09-07: it
# installed, committed, tracked and hashed, and defined nothing. Same shape as the AGENTS.md
# arm that cost twenty runs, one directory further down.
FOREIGN_OVERLAY="$TMP/foreign-agent-dir"
agent_file "$FOREIGN_OVERLAY/.github/agents/fixture-implementer.md" fixture-implementer
out=$(run claude --customization "$FOREIGN_OVERLAY"); rc=$?
if [[ $rc -eq 1 ]] && grep -q "does not read" <<<"$out" \
   && grep -q ".github/agents/fixture-implementer.md" <<<"$out"; then
  ok "J: a .github/agents overlay on claude is refused, and the file is named (exit 1)"
else
  bad "J: expected exit 1 naming the foreign file, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# K — refusing a portable bundle would be wrong. When the native directory is present the
# treatment DOES reach the model, and the foreign copy is baggage. It must still be named,
# because an unmentioned inert file is how a reader concludes both arms were configured.
PORTABLE_OVERLAY="$TMP/portable-agent-dirs"
agent_file "$PORTABLE_OVERLAY/.claude/agents/fixture-implementer.md" fixture-implementer
agent_file "$PORTABLE_OVERLAY/.github/agents/fixture-implementer.md" fixture-implementer
out=$(run claude --customization "$PORTABLE_OVERLAY" --agent fixture-implementer); rc=$?
if [[ $rc -eq 0 ]] && grep -q "inert, not the treatment" <<<"$out"; then
  ok "K: an overlay carrying both directories runs, and the inert one is named"
else
  bad "K: expected exit 0 naming the inert directory, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# L — codex dispatches no agent overlay at all, so BOTH directories are foreign there. Without
# this case the guard would be asserted only where a native glob exists, which is the smaller
# scope reported as the larger one.
out=$(run codex --customization "$AGENT_OVERLAY"); rc=$?
if [[ $rc -eq 1 ]] && grep -q "does not read" <<<"$out" \
   && grep -q "no agent directory at all" <<<"$out"; then
  ok "L: a .claude/agents overlay on codex is refused — it reads no agent directory"
else
  bad "L: expected exit 1 saying codex reads no agent directory, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# M — the case pass 18 found by RUNNING the runtime nobody's fixture ran. Until 2026-09-07 the
# copilot arm of the guard gave copilot a native agent directory, so a .github/agents overlay
# there passed every check, was tracked 1 of 1, and could never be dispatched because --agent is
# refused on copilot. A-L run claude ten times and codex twice; the verifier asserted the guard
# exactly where it worked, which is the failure its own header names.
out=$(run copilot --customization "$FOREIGN_OVERLAY"); rc=$?
if [[ $rc -eq 1 ]] && grep -q "does not read" <<<"$out" \
   && grep -q "no agent directory at all" <<<"$out"; then
  ok "M: a .github/agents overlay on copilot is refused — it dispatches no agent either"
else
  bad "M: expected exit 1 refusing the copilot overlay, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# N — the provenance half. The overlay is delivered (case B says so); this asks whether the
# RECORD can say so afterwards. Expected: the hash of the very file --agent dispatches.
EXPECTED_AGENT_HASH="sha256:$(shasum -a 256 "$AGENT_OVERLAY/.claude/agents/fixture-implementer.md" | cut -c1-32)"
out=$(run claude --customization "$AGENT_OVERLAY" --agent fixture-implementer); rc=$?
got=$(grep -o '"agentHash":"[^"]*"' <<<"$out" | tail -1 | cut -d'"' -f4)
if [[ $rc -eq 0 && "$got" == "$EXPECTED_AGENT_HASH" ]]; then
  ok "N: a dispatched agent overlay records agentHash of the file it dispatches"
else
  bad "N: expected agentHash ${EXPECTED_AGENT_HASH}, got '${got}' (exit $rc)"
fi

# O — the other side of N, and the one that makes N mean anything. A hash that is non-null on
# BOTH arms distinguishes nothing. The control arm installs no overlay and must record null.
out=$(run claude); rc=$?
if [[ $rc -eq 0 ]] && grep -q '"agentHash":null' <<<"$out"; then
  ok "O: the control arm records agentHash null — the arms are distinguishable in the record"
else
  bad "O: expected agentHash null on a run with no customization, got exit $rc: $(grep -o 'customization hashes: .*' <<<"$out" | head -1)"
fi

# P — skills had the same defect and the same fix. Hashed as a SET over sorted (path, content)
# pairs, since a skill has no single path; the assertion is only that an installed skill is no
# longer invisible in the record.
out=$(run claude --customization "$BOTH_OVERLAY" --agent fixture-implementer --enable-skills); rc=$?
if [[ $rc -eq 0 ]] && grep -q '"skillsHash":"sha256:' <<<"$out"; then
  ok "P: an installed skill records a non-null skillsHash"
else
  bad "P: expected a non-null skillsHash, got exit $rc: $(grep -o 'customization hashes: .*' <<<"$out" | head -1)"
fi

echo
ran=$((pass + fail))
if [[ "$ran" -ne "$EXPECTED_CASES" ]]; then
  echo "verify-agent-delivery: ${ran} cases ran, ${EXPECTED_CASES} registered — the announced"
  echo "scope and the executed scope disagree, which is the failure this line exists to catch."
  exit 2
fi
echo "verify-agent-delivery: ${pass} passed, ${fail} failed, of ${EXPECTED_CASES} registered cases"
[[ "$fail" -eq 0 ]] || exit 2
