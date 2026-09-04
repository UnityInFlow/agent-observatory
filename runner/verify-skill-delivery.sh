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
#   F. an overlay at a path the benchmark IGNORES is still tracked          (no model call)
#   G. NO customization at all still gets through — the control arm's path   (no model call)
#   D. positive control: the FIXTURE skill activates with skills enabled   (one model call)
#   E. negative:         the same skill does NOT activate with them off    (one model call)
#
# D and E identify the skill BY NAME and require both probes to have completed. Counting
# `Skill` tool calls alone let an unrelated bundled skill satisfy the positive control, and
# ignoring the probe exit status let a probe that never started satisfy the negative one —
# both found by the §4a gate at 2/2, and both fail in the direction that reports success.
#
# A, B, C, F and G are free and run everywhere. D and E cost two small claude calls and need
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

# F — the root skill path is gitignored in the benchmarks repo (`.gitignore:19` is
# `.claude/*`), so `git add -A` staged nothing and the setup commit failed outright. The
# runner now force-adds the overlay's OWN paths. This asserts what the commit TRACKS, which
# is the only version of the claim that means anything — "the file is in the worktree" is
# what Phase 1 believed for twenty runs.
ROOT_OVERLAY="$TMP/root-skill"
mkdir -p "$ROOT_OVERLAY/.claude/skills/probe-fixture"
cp "$SKILL_OVERLAY/sample-service/.claude/skills/probe-fixture/SKILL.md" \
   "$ROOT_OVERLAY/.claude/skills/probe-fixture/SKILL.md"
out=$("$RUNNER" --runtime claude --benchmark BE-003 --experiment EXP-VERIFY-SKILL --api "$API_URL" \
        --customization "$ROOT_OVERLAY" --enable-skills --check-customization 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q "force-added into the setup commit" <<<"$out" \
   && grep -q "tracked overlay files in the setup commit: 1 of 1" <<<"$out"; then
  ok "F: an overlay at the ignored root skill path is force-added and tracked 1 of 1"
else
  bad "F: expected the force-add line and 1 of 1 tracked, got exit $rc: $(grep -E 'tracked|force-added|run-agent:' <<<"$out" | tr '\n' ' ')"
fi

# G — the control arm passes no --customization, so it skips the whole block above. The
# overlay path array is only populated inside that block, and this script runs with `set -u`:
# a reference to it on the control path would abort with "unbound variable". That failure
# would land on the CONTROL ARM ONLY, which is the arm least likely to be watched and the
# direction that quietly shrinks an experiment's n.
out=$("$RUNNER" --runtime claude --benchmark BE-003 --experiment EXP-VERIFY-SKILL --api "$API_URL" \
        --check-customization 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q "customization checks passed" <<<"$out" \
   && ! grep -q "unbound variable" <<<"$out"; then
  ok "G: a run with no customization passes the same checks (the control arm's path)"
else
  bad "G: expected exit 0 and no unbound-variable error, got exit $rc: $(tail -3 <<<"$out" | tr '\n' ' ')"
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

  # Counts a `Skill` tool_use FOR THE FIXTURE SKILL BY NAME. §4a round 2, at 2/2: counting
  # the tool name alone meant an unrelated bundled skill firing once made the positive
  # control pass while the installed fixture was never activated at all. `skill` counts only
  # `probe-fixture`; `other` counts any other skill so the substitution stays visible instead
  # of being silently excluded.
  #
  # Also reports whether SKILL.md was merely READ, because that is the false positive a
  # text-marker detector cannot see, and `ok` — whether the transcript contains a terminal
  # `result` record at all. A probe that failed to start produces an empty or error file,
  # and `activated` would read `0 0` from it and report the NEGATIVE control as passing
  # without the negative control ever having run.
  activated() { # $1 = transcript
    python3 -c '
import json,sys
skill=other=read=0
ok=0
for ln in open(sys.argv[1]):
    try: d=json.loads(ln)
    except: continue
    if d.get("type")=="result": ok=1
    if d.get("type")=="assistant":
        for c in d.get("message",{}).get("content",[]):
            if c.get("type")=="tool_use":
                if c.get("name")=="Skill":
                    if c.get("input",{}).get("skill")=="probe-fixture": skill+=1
                    else: other+=1
                elif "SKILL.md" in json.dumps(c.get("input","")): read+=1
print(f"{skill} {read} {other} {ok}")' "$1"
  }

  run_probe() { # $1 = out file, $2 = extra flag ("" or --disable-slash-commands)
    # shellcheck disable=SC2086
    ( cd "$REPO" && claude --permission-mode acceptEdits --strict-mcp-config $2 \
        --setting-sources project --model "${VERIFY_MODEL:-claude-haiku-4-5-20251001}" \
        --output-format stream-json --verbose -p "$PROMPT" </dev/null ) > "$1" 2>&1
  }

  run_probe "$TMP/on.jsonl" ""
  on_rc=$?
  read -r on_skill on_read on_other on_ok < <(activated "$TMP/on.jsonl")
  run_probe "$TMP/off.jsonl" "--disable-slash-commands"
  off_rc=$?
  read -r off_skill off_read off_other off_ok < <(activated "$TMP/off.jsonl")

  # BOTH probes must have completed before either result means anything. A probe that failed
  # to start yields an empty transcript, which is indistinguishable from "no activation" —
  # and that is the direction that reports the negative control as a pass without running it.
  if [[ "$on_rc" -ne 0 || "$off_rc" -ne 0 || "$on_ok" -ne 1 || "$off_ok" -ne 1 ]]; then
    echo "  INCONCLUSIVE — a probe did not complete (enabled rc=$on_rc result=$on_ok,"
    echo "  disabled rc=$off_rc result=$off_ok). An absent transcript reads as 'no activation',"
    echo "  so neither control is reported either way."
    echo ""
    echo "$pass passed, $fail failed, $skipped skipped, a probe FAILED TO RUN"
    exit 1
  fi

  if [[ "$on_skill" -ge 1 ]]; then
    ok "D: positive control — probe-fixture activated with skills enabled (x$on_skill, other skills x$on_other)"
    if [[ "$off_skill" -eq 0 ]]; then
      ok "E: probe-fixture did not activate with --disable-slash-commands (x0, other skills x$off_other, SKILL.md read x$off_read)"
    else
      bad "E: it activated anyway with --disable-slash-commands (x$off_skill)"
    fi
  else
    echo "  INCONCLUSIVE — the positive control did not activate probe-fixture (x0,"
    echo "  other skills x$on_other, SKILL.md read x$on_read). Nothing is proved about the"
    echo "  negative case, so it is not reported as a pass."
    echo ""
    echo "$pass passed, $fail failed, $skipped skipped, positive control FAILED"
    exit 1
  fi
fi

echo ""
echo "$pass passed, $fail failed, $skipped skipped"
[[ $fail -eq 0 ]] || exit 2
exit 0
