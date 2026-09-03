#!/usr/bin/env bash
#
# Adversarial review of the code that decides a verdict, fired on `git push` and
# `gh pr create`. Wired as a Claude Code PostToolUse hook in .claude/settings.json.
#
# WHY THIS REPO NEEDS ONE AT ALL
#
# CLAUDE.md opens with the reason: this is the instrument, so "a bug here does not crash —
# it returns a confident wrong answer, and every result computed afterwards inherits it."
# A crash gets noticed. A p-value computed from a subtly wrong median does not, and by the
# time anyone doubts it, the runs it was computed from are gone.
#
# Seven of this project's findings were harness bugs, and the two that survived review
# longest were the two that made the numbers look good. That is the failure this reviewer
# exists for: it is a second model family, so its blind spots are not the author's.
#
# WHY NOT EVERY CHANGED FILE
#
# A reviewer that fires on everything gets muted. The globs below are the files where being
# wrong is expensive and silent:
#
#   runner/*.py        the statistics that decide a verdict. analyze-experiment.py fails
#                      closed by design; derive-mde.py sets the bar a later comparison is
#                      judged against. A quiet change to either moves the bar after the fact.
#   migration/*.sql    schema changes are one-way against a database holding measurements
#                      that cannot be re-collected — every run's worktree is already gone.
#   runner/schemas/    the run-record contract. It spent months describing a payload nothing
#                      checked it against, and drifted three migrations behind it (#53).
#   .claude/hooks/     this file and its neighbours. A reviewer that cannot be reviewed is
#                      the thing it warns about.
#
# A README, a dashboard tweak or a test-only change does not need a model call. The web and
# API layers are deliberately out of scope for now: they render and store, they do not decide.
#
# WHY IT IS ADVISORY, AND WHAT WOULD MAKE IT A CONTROL
#
# A REJECT is printed and recorded; the hook still exits 0. That makes it **L3 — words a
# human reads**. This is deliberate and it is the honest label: a reviewer that can break
# `git push` gets deleted within a day, and a control nobody keeps is worth less than a
# warning everybody reads.
#
# `OBS_REVIEW_STRICT=1` is the L2 version — a REJECT exits 3 and the push has already
# happened, so it fails the *hook*, not the push. Nothing in this repo sets it. Do not
# describe this hook as a gate in a PR while that is still true.
#
# WHY A ZERO EXIT FROM THE REVIEWER IS NOT PROOF OF A REVIEW
#
# Learned in the sibling repo the expensive way: a review ran to completion, exited 0, and
# had written its verdict to a file the runtime then refused, so nothing was recorded while
# the run looked successful. So this checks for the artifact it is supposed to produce
# rather than trusting the exit code, and says so when there is none.

set -uo pipefail

# Files where being wrong is expensive and silent. Order is priority: if the budget cannot
# cover everything, the earlier globs are reviewed and the rest are NAMED, never dropped
# quietly — a partial review reported as a review is the failure this whole repo is about.
REVIEW_GLOBS=(
  'runner/*.py'
  'observatory-api/src/main/resources/db/migration/*.sql'
  'runner/schemas/*.json'
  '.claude/hooks/*.sh'
)

MAX_FILES="${OBS_REVIEW_MAX_FILES:-4}"
MODEL="${OBS_REVIEW_MODEL:-ollama-cloud/glm-5.2}"
AGENT="${OBS_REVIEW_AGENT:-obs-critic}"

[ "${OBS_REVIEW_HOOK:-1}" = "0" ] && exit 0

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
cd "$repo_root" || exit 0

payload="$(cat 2>/dev/null || true)"
command_line="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$command_line" ] || exit 0

case "$command_line" in
  *"git push"*|*"gh pr create"*) ;;
  *) exit 0 ;;
esac

command -v opencode >/dev/null 2>&1 || {
  echo "opencode-review hook: opencode not installed, skipping" >&2; exit 0
}

base="$(git merge-base HEAD origin/main 2>/dev/null || true)"
[ -n "$base" ] || exit 0
changed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
[ -n "$changed" ] || exit 0

ranked=()
while IFS= read -r f; do
  [ -f "$f" ] || continue          # a deleted file has nothing to review
  for glob in "${REVIEW_GLOBS[@]}"; do
    if [[ "$f" == $glob ]]; then ranked+=("$f"); break; fi
  done
done <<< "$changed"
[ ${#ranked[@]} -gt 0 ] || exit 0

files=("${ranked[@]}")
dropped=()
if [ "$MAX_FILES" -gt 0 ] && [ ${#ranked[@]} -gt "$MAX_FILES" ]; then
  files=("${ranked[@]:0:$MAX_FILES}")
  dropped=("${ranked[@]:$MAX_FILES}")
fi
if [ ${#dropped[@]} -gt 0 ]; then
  echo "opencode-review hook: PARTIAL REVIEW — ${#files[@]} of ${#ranked[@]} files." >&2
  echo "  NOT reviewed (raise OBS_REVIEW_MAX_FILES or review them by hand):" >&2
  printf '    %s\n' "${dropped[@]}" >&2
fi

mkdir -p findings/opencode
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="findings/opencode/review-${stamp}.md"

{
  echo "# opencode review — ${stamp}"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| head | \`$(git rev-parse --short HEAD)\` |"
  echo "| base | \`$(git rev-parse --short "$base")\` |"
  echo "| model | \`${MODEL}\` |"
  echo "| agent | \`${AGENT}\` |"
  echo "| reviewed | ${#files[@]} of ${#ranked[@]} |"
  [ ${#dropped[@]} -gt 0 ] && printf '| NOT reviewed | `%s` |\n' "$(printf '%s ' "${dropped[@]}")"
  echo
} > "$out"

echo "opencode-review hook: reviewing ${#files[@]} of ${#ranked[@]} file(s) — ${AGENT} on ${MODEL}" >&2

# THE REVIEWER MUST NOT HAVE TO ASK WHAT CHANGED
#
# This said "read the diff with: git diff <base>...HEAD -- <files>" until 2026-09-03, when the
# same line in the benchmarks repo produced a review that ran for ten minutes, wrote 71k of
# transcript and never reached a verdict.
#
# The cause is below the reviewer. `opencode` rewrites its bash through an rtk plugin, and
# `rtk git diff` filters `^\.(claude|opencode|github)/` and `^findings/` out of its output.
# Every file this hook reviews on a hooks-only branch — which is every branch that touches
# this directory — is under one of those, so the reviewer asked what had changed, was told
# NOTHING, and re-ran the same command until it was killed.
#
# The tool did not error. It exited 0 with an empty answer, and empty is indistinguishable
# from "no changes". So the diff is INLINED: there is no command left for an environment to
# filter, which makes it structural rather than a warning about a command not to run.
MAX_DIFF_LINES="${OBS_REVIEW_MAX_DIFF_LINES:-1200}"
diff_text="$(git diff "${base}...HEAD" -- "${files[@]}" 2>/dev/null || true)"
diff_lines="$(printf '%s\n' "$diff_text" | wc -l | tr -d ' ')"

# A diff the hook could not produce is that same silent-empty failure one layer up, so it is
# named rather than spent on a model call that has nothing to read.
if [ -z "$diff_text" ]; then
  echo "opencode-review hook: BLOCKED — ${#files[@]} file(s) matched but the diff came back empty." >&2
  echo "  That is a harness fault, not a clean branch. Not calling the reviewer." >&2
  echo "**BLOCKED — the hook could not produce a diff for the matched files. No review ran.**" >> "$out"
  exit 0
fi

diff_note=""
if [ "$diff_lines" -gt "$MAX_DIFF_LINES" ]; then
  diff_text="$(printf '%s\n' "$diff_text" | awk -v n="$MAX_DIFF_LINES" 'NR<=n')"
  diff_note="

[TRUNCATED at ${MAX_DIFF_LINES} of ${diff_lines} diff lines. Read the files on disk for the
rest, and say in your review which parts you read that way.]"
fi

prompt="Review these changed files in agent-observatory, diffed against ${base}.

$(printf -- '- %s\n' "${files[@]}")

The diff is inlined below. Do not run git to fetch it: this shell filters dotfile paths out
of git output, so 'git diff ${base}...HEAD -- .' returns EMPTY here even though the files
above changed. A previous review read that emptiness as 'nothing changed' and looped until
it was killed. Read the files on disk if you want more context than the diff gives.

--- BEGIN DIFF ---
${diff_text}
--- END DIFF ---${diff_note}

End with a line 'VERDICT: ACCEPT' or 'VERDICT: REJECT' and one sentence of reason."

if opencode run --agent "$AGENT" -m "$MODEL" "$prompt" >> "$out" 2>&1; then
  :
else
  echo "opencode-review hook: reviewer exited non-zero; the push already happened and is unaffected" >&2
fi

# THE EXIT CODE IS NOT THE EVIDENCE. THE FILE IS.
# A run that produced no verdict is BLOCKED, whatever it exited. Checking the artifact rather
# than the status is the difference between "a review happened" and "a process ran".
if ! grep -qE '^VERDICT: (ACCEPT|REJECT)' "$out"; then
  echo "opencode-review hook: BLOCKED — the reviewer wrote no verdict to $out." >&2
  echo "  Treat this head as UNREVIEWED. A run that records nothing is not a review." >&2
  exit 0
fi

verdict="$(grep -oE '^VERDICT: (ACCEPT|REJECT)' "$out" | tail -1 | awk '{print $2}')"
echo "opencode-review hook: ${verdict} — $out" >&2

if [ "$verdict" = "REJECT" ] && [ "${OBS_REVIEW_STRICT:-0}" = "1" ]; then
  echo "  OBS_REVIEW_STRICT=1: failing the hook. The push already happened; this is a signal, not a rollback." >&2
  exit 3
fi
exit 0
