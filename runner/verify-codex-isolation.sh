#!/usr/bin/env bash
# Does the codex arm's isolation actually isolate? Answered by measurement, twice.
#
#   ./runner/verify-codex-isolation.sh
#
# WHY THIS EXISTS AS A SCRIPT RATHER THAN A PARAGRAPH. `codex exec --help` says
# `--ignore-user-config` means "Do not load $CODEX_HOME/config.toml". It says nothing about
# $CODEX_HOME/AGENTS.md, and reading it either way is a guess. Measured 2026-08-28 with a
# marker instruction: the flag does NOT drop global instructions — the model still emitted
# the marker. A clean CODEX_HOME does.
#
# That distinction decides whether B2's codex arm is a plain baseline or a treatment. On
# this operator's machine ~/.codex/AGENTS.md imports a 32-line shell-routing instruction
# file, so an unisolated codex run ships B3's treatment inside B2's control.
#
# THE TEST IS TWO-SIDED ON PURPOSE. A test that only checks "marker absent under isolation"
# passes when codex is broken, when auth fails, when the model ignores instructions, and
# when the marker was never reachable. The positive control — marker PRESENT without
# isolation — is what makes the negative result mean something. If the positive control
# fails, this exits 1 and reports the test as inconclusive rather than as a pass.
#
# Costs two small codex calls. Not in CI: it needs authentication and spends quota.
#
# TWO CHECKS, TWO DIFFERENT CLAIMS, AND THEY ARE NOT THE SAME CLAIM.
#   A. AUTO-LOADING — does a global AGENTS.md reach the model on its own?
#      Closed by a clean CODEX_HOME. This is what the file originally tested.
#   B. DELIBERATE READING — will the agent go and read the operator's instructions itself?
#      NOT closed by A, and observatory#65 is the record of finding that out the hard way:
#      all seven codex runs on 2026-08-30 opened by reading ~/.agents/skills/*/SKILL.md
#      before touching their worktree. Closed — at L2 — by redirecting HOME.
#
# Measured 2026-09-01: `--sandbox workspace-write` does NOT close B. It restricts writes,
# not reads. Do not substitute it for the HOME redirection.
#
# Exit 0 both hold · 1 inconclusive (a positive control failed) · 2 ISOLATION LEAKS.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MARKER="ZEBRAFISH-7741"
REAL_HOME="${CODEX_HOME:-$HOME/.codex}"

command -v codex >/dev/null 2>&1 || { echo "codex not installed" >&2; exit 1; }
[[ -r "$REAL_HOME/auth.json" ]] || { echo "no auth.json under $REAL_HOME" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/work" "$tmp/dirty" "$tmp/clean"

# The dirty home is what an operator machine looks like: auth plus global instructions.
cp "$REAL_HOME/auth.json" "$tmp/dirty/auth.json"
cat > "$tmp/dirty/AGENTS.md" <<EOF
# Global operator instructions

IMPORTANT: Whenever you answer anything at all, you MUST begin your reply with the exact
token ${MARKER} on its own line. This applies to every response without exception.
EOF

# The clean home is exactly what run-agent.sh builds under --isolate-user-settings.
cp "$REAL_HOME/auth.json" "$tmp/clean/auth.json"

ask() { # $1 = CODEX_HOME
  ( cd "$tmp/work" \
    && CODEX_HOME="$1" codex exec --skip-git-repo-check --sandbox read-only --color never \
         "Say the word ready." ) 2>&1
}

echo "positive control — global AGENTS.md present, no isolation ..."
dirty_out="$(ask "$tmp/dirty")"
if ! grep -q "$MARKER" <<<"$dirty_out"; then
  echo
  echo "INCONCLUSIVE: the marker did not appear even WITHOUT isolation."
  echo "The test cannot detect a leak it cannot first produce, so a clean result below"
  echo "would mean nothing. Check auth, the model, and that global AGENTS.md is still read."
  exit 1
fi
echo "  marker present, as it must be — the test can see a leak"

echo "isolated run — CODEX_HOME holding auth.json alone ..."
clean_out="$(ask "$tmp/clean")"
if grep -q "$MARKER" <<<"$clean_out"; then
  echo
  echo "ISOLATION LEAKS: the marker survived a clean CODEX_HOME."
  echo "run-agent.sh's --isolate-user-settings does not isolate this codex version."
  echo "Every codex run recorded as isolated since the last passing check is suspect."
  exit 2
fi
echo "  marker absent — global instructions did not reach the model"
echo "  check A holds: nothing AUTO-LOADS. That is not the same as check B below."

# --- B. does the agent go and READ the operator's instructions itself? ------------------
# Everything above proves only that nothing auto-loads. observatory#65 is what that misses.
#
# The prompt below hands the agent NO path. It has to discover one, which is what the runs
# in #65 actually did. HOME_REAL is the operator's home as this script sees it.

echo
echo "--- check B: deliberate reading (observatory#65) ---"

mkdir -p "$tmp/fakehome"

seek() { # $1 = HOME
  ( cd "$tmp/work" \
    && HOME="$1" CODEX_HOME="$tmp/clean" codex exec --skip-git-repo-check \
         --sandbox workspace-write --color never \
         "Look for globally-installed agent skill or instruction files on this machine, for
          example under ~/.agents/skills or ~/.codex/skills. List any full paths you find.
          If you find none, reply with exactly NONE FOUND." ) 2>&1
}

# The positive control is the operator's real home. If there is nothing there to find, this
# check cannot detect a leak and must say so rather than pass.
echo "positive control — real HOME, agent free to look ..."
seen_out="$(seek "$HOME")"
if ! grep -qE "SKILL\.md|/\.agents/|/\.codex/skills" <<<"$seen_out"; then
  echo
  echo "INCONCLUSIVE: the agent found no operator instruction files even with a real HOME."
  echo "Either this machine has none installed, or the agent declined to look. Either way a"
  echo "clean result below would mean nothing. Check ~/.agents/skills and ~/.codex/skills."
  exit 1
fi
echo "  operator instruction files found, as they must be — the test can see a leak"

echo "redirected HOME — what run-agent.sh --isolate-user-settings now builds ..."
hidden_out="$(seek "$tmp/fakehome")"
if grep -qE "$HOME/\.agents/|$HOME/\.codex/skills" <<<"$hidden_out"; then
  echo
  echo "ISOLATION LEAKS: the agent reached the operator's instruction files with HOME redirected."
  echo "run-agent.sh's HOME redirection is not doing what observatory#65 requires."
  exit 2
fi
echo "  operator instruction files not reached"
echo
echo "ok: BOTH checks hold for $(codex --version 2>/dev/null | head -1)"
echo
echo "SCOPE, SAID PLAINLY: check B closes DISCOVERABILITY, not reachability. \`~\` no longer"
echo "resolves into the operator's home; /Users/<op>/... still exists and is still readable"
echo "by an agent that constructs the path another way. This is an L2 control. Do not let a"
echo "later reader take it for isolation."
