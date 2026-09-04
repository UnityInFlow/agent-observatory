#!/usr/bin/env bash
# Can this runner deliver a skill to the agent, and does it REFUSE when it cannot?
#
#   ./runner/verify-skill-delivery.sh
#
# WHY THIS EXISTS. On 2026-09-04 a Phase 3 lab was halted on the diagnosis that a Claude
# Code project skill "cannot be delivered to a benchmark run" because of where the file has
# to sit. That diagnosis was wrong, and it was wrong in the direction that manufactures a
# result. The real cause was this runner's own `--disable-slash-commands`, whose help text
# is "Disable all skills" — so the file was installed, committed, hashed and never loaded,
# and every check the harness had reported success. Fifteen runs at that setting would have
# produced three arms in perfect agreement and a confident conclusion that a skill's
# description does not matter, drawn from runs with skills switched off.
#
# TWO-SIDED, LIKE verify-codex-isolation.sh, AND FOR THE SAME REASON. A test that only
# checks "no activation when skills are disabled" passes when claude is broken, when auth
# fails, when the model ignores the skill, and when the skill was never reachable. The
# positive control — ACTIVATION PRESENT when skills are enabled — is what makes the negative
# result mean anything. If the positive control fails, this exits 1 and reports inconclusive
# rather than pass.
#
# THE DETECTOR IS A `Skill` tool_use IN THE STREAM, NOT A MARKER IN THE TEXT. The skill body
# can be read off disk as an ordinary tracked file: measured 2026-09-04, 1 of 6 runs with
# skills DISABLED emitted the body's marker after reading SKILL.md itself. Scoring on the
# marker reports a false activation. Scoring on the tool_use cannot.
#
# CHECKS
#   A. the guard REFUSES a skill overlay when skills would be disabled     (no model call)
#   B. the guard ADMITS the same overlay when --enable-skills is passed    (no model call)
#   C. the guard stays silent for a customization with no skill in it      (no model call)
#   D. positive control: the skill ACTIVATES with skills enabled           (one model call)
#   E. negative:         the same skill does NOT activate with them off    (one model call)
#
# A, B and C are free and run everywhere. D and E cost two small claude calls and need
# authentication, so they are skipped with a stated reason when claude is absent — skipped,
# and reported as skipped, never silently passed.
#
# Exit 0 every check held · 1 inconclusive (a positive control failed) · 2 A CHECK FAILED.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

RUNNER="./runner/run-agent.sh"

# The host ports live in infra/.env because 8080 and 5173 are taken on this machine, and
# run-agent.sh refuses to start when the API is unreachable. Resolve the port the same way
# the Makefile does rather than assuming the default — a verifier that fails because it
# looked at the wrong port reports "the guard is broken" when the guard was never reached.
API_PORT="8080"
[[ -f infra/.env ]] && API_PORT="$(sed -n 's/^API_PORT=//p' infra/.env | tail -1)"
API_URL="${API:-http://localhost:${API_PORT:-8080}}"
curl -fsS "${API_URL}/actuator/health" >/dev/null 2>&1 \
  || { echo "Observatory API not reachable at ${API_URL} — run 'make up' first." >&2
       echo "Checks A-C drive the real runner, which refuses to start without it." >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skipped=0
ok()   { echo "  ok   — $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL — $1"; fail=$((fail+1)); }
skip() { echo "  skip — $1"; skipped=$((skipped+1)); }

# --- fixtures --------------------------------------------------------------
SKILL_OVERLAY="$TMP/with-skill"
mkdir -p "$SKILL_OVERLAY/sample-service/.claude/skills/probe-fixture"
cat > "$SKILL_OVERLAY/sample-service/.claude/skills/probe-fixture/SKILL.md" <<'EOF'
---
name: probe-fixture
description: Conventions for confirming a shipment in this Kotlin Spring backend. Use when changing shipment confirmation logic.
---

## Mandatory first step

State on its own line: SKILL-FIXTURE-MARKER
EOF

PLAIN_OVERLAY="$TMP/no-skill"
mkdir -p "$PLAIN_OVERLAY"
printf 'Be concise.\n' > "$PLAIN_OVERLAY/CLAUDE.md"

echo "== the runner's guard =="

# A — refuses
out=$("$RUNNER" --runtime claude --benchmark BE-003 --experiment EXP-VERIFY-SKILL --api "$API_URL" \
        --customization "$SKILL_OVERLAY" --check-customization 2>&1); rc=$?
if [[ $rc -eq 1 ]] && grep -q "would disable skills" <<<"$out"; then
  ok "A: skill overlay without --enable-skills is refused (exit 1, names the switch)"
else
  bad "A: expected exit 1 and 'would disable skills', got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# B — admits
out=$("$RUNNER" --runtime claude --benchmark BE-003 --experiment EXP-VERIFY-SKILL --api "$API_URL" \
        --customization "$SKILL_OVERLAY" --enable-skills --check-customization 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q "customization checks passed" <<<"$out" \
   && grep -q "installs 1 SKILL.md" <<<"$out"; then
  ok "B: the same overlay with --enable-skills is admitted, and the count is reported"
else
  bad "B: expected exit 0 and the SKILL.md count, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

# C — no skill, no opinion. Guards the regression that matters most: every run recorded
# before this flag existed must keep its exact meaning.
out=$("$RUNNER" --runtime claude --benchmark BE-003 --experiment EXP-VERIFY-SKILL --api "$API_URL" \
        --customization "$PLAIN_OVERLAY" --check-customization 2>&1); rc=$?
if [[ $rc -eq 0 ]] && ! grep -q "SKILL.md" <<<"$out"; then
  ok "C: a customization with no skill is untouched by the guard"
else
  bad "C: expected exit 0 and no mention of SKILL.md, got exit $rc: $(head -3 <<<"$out" | tr '\n' ' ')"
fi

echo "== does the flag actually decide it? two model calls =="

if ! command -v claude >/dev/null 2>&1; then
  skip "D and E: claude is not installed, so the flag's effect is UNPROVEN here, not proven"
  skip "E: see above"
else
  REPO="$TMP/repo"
  mkdir -p "$REPO/sub"
  cp -R "$SKILL_OVERLAY/sample-service/.claude" "$REPO/sub/.claude"
  cat > "$REPO/sub/ShipmentController.kt" <<'EOF'
package demo
class ShipmentController { fun confirm(id: String) {} }
EOF
  ( cd "$REPO" && git init -q . \
      && git add -A -f . >/dev/null 2>&1 \
      && git -c user.email=v@v -c user.name=v commit -qm fixture >/dev/null 2>&1 )

  PROMPT="I need to change the shipment confirmation logic in this Kotlin Spring backend. Read sub/ShipmentController.kt first, then tell me what conventions apply."

  # Counts a `Skill` tool_use. Also reports whether SKILL.md was merely READ, because that
  # is the false positive a text-marker detector cannot see.
  activated() { # $1 = transcript
    python3 -c '
import json,sys
skill=read=0
for ln in open(sys.argv[1]):
    try: d=json.loads(ln)
    except: continue
    if d.get("type")=="assistant":
        for c in d.get("message",{}).get("content",[]):
            if c.get("type")=="tool_use":
                if c.get("name")=="Skill": skill+=1
                elif "SKILL.md" in json.dumps(c.get("input","")): read+=1
print(f"{skill} {read}")' "$1"
  }

  run_probe() { # $1 = out file, $2 = extra flag ("" or --disable-slash-commands)
    # shellcheck disable=SC2086
    ( cd "$REPO" && claude --permission-mode acceptEdits --strict-mcp-config $2 \
        --setting-sources project --model "${VERIFY_MODEL:-claude-haiku-4-5-20251001}" \
        --output-format stream-json --verbose -p "$PROMPT" </dev/null ) > "$1" 2>&1
  }

  run_probe "$TMP/on.jsonl" ""
  read -r on_skill on_read < <(activated "$TMP/on.jsonl")
  run_probe "$TMP/off.jsonl" "--disable-slash-commands"
  read -r off_skill off_read < <(activated "$TMP/off.jsonl")

  if [[ "$on_skill" -ge 1 ]]; then
    ok "D: positive control — the skill activated with skills enabled (Skill tool_use x$on_skill)"
    if [[ "$off_skill" -eq 0 ]]; then
      ok "E: it did not activate with --disable-slash-commands (Skill tool_use x0, SKILL.md read x$off_read)"
    else
      bad "E: it activated anyway with --disable-slash-commands (Skill tool_use x$off_skill)"
    fi
  else
    echo "  INCONCLUSIVE — the positive control did not activate (Skill tool_use x0, SKILL.md read x$on_read)."
    echo "  Nothing is proved about the negative case, so it is not reported as a pass."
    echo ""
    echo "$pass passed, $fail failed, $skipped skipped, positive control FAILED"
    exit 1
  fi
fi

echo ""
echo "$pass passed, $fail failed, $skipped skipped"
[[ $fail -eq 0 ]] || exit 2
exit 0
