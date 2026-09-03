#!/usr/bin/env bash
#
# The review hook's own tests. `git`, `jq` and `opencode` are stubbed — no network, no
# tokens, no model call.
#
# WHY THE NEGATIVE CASES MATTER MORE THAN THE POSITIVE ONES
#
# A hook that fires on everything gets muted within a week, and a muted hook is worse than
# no hook because the repository still looks reviewed. So the cases asserting the reviewer
# was NOT called carry as much weight here as the ones asserting it was.
#
# The stub records every invocation to $CALLS, so "did it fire" and "what did it pass" are
# both assertable without a model.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/opencode-review.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/repo"
STUB="$TMP/stub"
CALLS="$TMP/calls"
mkdir -p "$STUB" "$FIXTURE/.claude/hooks" "$FIXTURE/runner/schemas" \
         "$FIXTURE/observatory-api/src/main/resources/db/migration"
cp "$HOOK" "$FIXTURE/.claude/hooks/opencode-review.sh"
chmod +x "$FIXTURE/.claude/hooks/opencode-review.sh"

# The stub records the call and writes a verdict, so the artifact check is satisfied on the
# happy path. `no-verdict` mode is how the "ran but recorded nothing" case is exercised.
cat > "$STUB/opencode" <<'STUB'
#!/usr/bin/env bash
# One line per invocation: the prompt is multi-line, and a raw "$*" would make `wc -l`
# count prompt lines instead of model calls — a counter that grows with the prompt.
printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$CALLS"
if [ "${STUB_VERDICT:-ACCEPT}" != "none" ]; then
  echo "VERDICT: ${STUB_VERDICT:-ACCEPT}"
fi
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$STUB/opencode"

# A transparent `git` shim. With STUB_EMPTY_DIFF=1 a *content* diff — the one the prompt is
# built from — comes back empty while `--name-only` still lists the files, which is exactly
# the shape `rtk git diff` produced on 2026-09-03: files matched, diff filtered away, no
# error. Without this the BLOCKED path could be deleted and every other case would still pass.
REAL_GIT="$(command -v git)"
cat > "$STUB/git" <<STUB
#!/usr/bin/env bash
if [ "\${STUB_EMPTY_DIFF:-0}" = "1" ]; then
  saw_diff=0; saw_name_only=0
  for a in "\$@"; do
    [ "\$a" = diff ] && saw_diff=1
    [ "\$a" = --name-only ] && saw_name_only=1
  done
  [ "\$saw_diff" = 1 ] && [ "\$saw_name_only" = 0 ] && exit 0
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$STUB/git"

git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email t@t
git -C "$FIXTURE" config user.name t
echo readme > "$FIXTURE/README.md"
git -C "$FIXTURE" add -A >/dev/null && git -C "$FIXTURE" commit -qm init
git -C "$FIXTURE" branch -M main
# `origin/main` without a remote: the hook only ever asks for a merge-base.
git -C "$FIXTURE" update-ref refs/remotes/origin/main refs/heads/main

PASS=0; FAIL=0
run() {  # run <name> <stdin-json> <expect-exit> <expect-calls> [env=val ...]
  local name="$1" payload="$2" want_exit="$3" want_calls="$4"; shift 4
  : > "$CALLS"
  local out; out="$(printf '%s' "$payload" | env "$@" CALLS="$CALLS" PATH="$STUB:$PATH" \
      bash "$FIXTURE/.claude/hooks/opencode-review.sh" 2>&1)"
  local got_exit=$?
  local got_calls; got_calls="$(wc -l < "$CALLS" 2>/dev/null | tr -d ' ')"
  if [ "$got_exit" = "$want_exit" ] && [ "$got_calls" = "$want_calls" ]; then
    printf 'ok    %-46s exit %s, %s reviewer call(s)\n' "$name" "$got_exit" "$got_calls"
    PASS=$((PASS+1))
  else
    printf 'FAIL  %-46s exit %s (want %s), %s call(s) (want %s)\n' \
      "$name" "$got_exit" "$want_exit" "$got_calls" "$want_calls"
    [ -n "$out" ] && printf '        %s\n' "$out"
    FAIL=$((FAIL+1))
  fi
}

PUSH='{"tool_name":"Bash","tool_input":{"command":"git push -u origin feature"}}'
PR='{"tool_name":"Bash","tool_input":{"command":"gh pr create --title x"}}'

# --- a matching command with nothing reviewable on the branch
run "push, no changes"                  "$PUSH" 0 0
run "gh pr create, no changes"          "$PR"   0 0

git -C "$FIXTURE" checkout -q -b feature
echo 'x = 1' > "$FIXTURE/runner/analyze-experiment.py"
git -C "$FIXTURE" add -A >/dev/null; git -C "$FIXTURE" commit -qm analysis

# --- commands that are not a push must not spawn a review, even now that one would match
run "git status is not a push"          '{"tool_name":"Bash","tool_input":{"command":"git status"}}'  0 0
run "pushd is not a push"               '{"tool_name":"Bash","tool_input":{"command":"pushd /tmp"}}'   0 0
run "gh pr view is not create"          '{"tool_name":"Bash","tool_input":{"command":"gh pr view 3"}}' 0 0

# --- the case the hook exists for
run "push with changed analysis"        "$PUSH" 0 1
run "gh pr create, changed analysis"    "$PR"   0 1

if grep -q 'runner/analyze-experiment.py' "$CALLS" 2>/dev/null; then
  printf 'ok    %-46s argv carries the file\n' "reviewer argv"; PASS=$((PASS+1))
else
  printf 'FAIL  %-46s argv was: %s\n' "reviewer argv" "$(cat "$CALLS" 2>/dev/null)"; FAIL=$((FAIL+1))
fi

# --- the diff must be IN the prompt, not a command the reviewer is asked to run
#
# It was a command until 2026-09-03, when the identical line in the benchmarks repo produced
# a review that looped for ten minutes and died with no verdict: opencode rewrites its bash
# through rtk, `rtk git diff` filters `.claude/` and `.github/` paths out of its output, and
# a hooks-only branch therefore reported no changes at all. Asserting the diff CONTENT rather
# than the file name is the point — a prompt naming the files while carrying none of their
# text is exactly the state that looped.
if grep -q 'BEGIN DIFF' "$CALLS" 2>/dev/null; then
  printf 'ok    %-46s the diff is inlined, not fetched\n' "reviewer prompt"; PASS=$((PASS+1))
else
  printf 'FAIL  %-46s prompt carried no diff text\n' "reviewer prompt"; FAIL=$((FAIL+1))
fi

# --- a migration is in scope; migrations are one-way
echo 'ALTER TABLE agent_run ADD COLUMN x int;' \
  > "$FIXTURE/observatory-api/src/main/resources/db/migration/V7__x.sql"
git -C "$FIXTURE" add -A >/dev/null; git -C "$FIXTURE" commit -qm migration
run "a migration is reviewed"           "$PUSH" 0 1

# --- matched files, but a diff that came back empty: a harness fault, not a clean branch
#
# The reviewer must NOT be called here. Spending a model call on an empty subject is what
# looped for ten minutes, and reporting the empty result as a review would be the
# silent-success failure this hook exists to prevent.
run "an empty diff blocks, without a call" "$PUSH" 0 0 STUB_EMPTY_DIFF=1

: > "$CALLS"
out="$(printf '%s' "$PUSH" | env STUB_EMPTY_DIFF=1 CALLS="$CALLS" PATH="$STUB:$PATH" \
    bash "$FIXTURE/.claude/hooks/opencode-review.sh" 2>&1)"
if printf '%s' "$out" | grep -q 'BLOCKED' && printf '%s' "$out" | grep -q 'harness fault'; then
  printf 'ok    %-46s named as a harness fault, not a clean branch\n' "empty diff message"; PASS=$((PASS+1))
else
  printf 'FAIL  %-46s out was: %s\n' "empty diff message" "$out"; FAIL=$((FAIL+1))
fi

# --- the disable switch
run "OBS_REVIEW_HOOK=0 disables it"     "$PUSH" 0 0 OBS_REVIEW_HOOK=0

# --- a run that records no verdict is not a review, and must say so
: > "$CALLS"
out="$(printf '%s' "$PUSH" | env STUB_VERDICT=none CALLS="$CALLS" PATH="$STUB:$PATH" \
    bash "$FIXTURE/.claude/hooks/opencode-review.sh" 2>&1)"
if printf '%s' "$out" | grep -q 'BLOCKED'; then
  printf 'ok    %-46s a verdict-less run is BLOCKED, not passed\n' "no verdict"; PASS=$((PASS+1))
else
  printf 'FAIL  %-46s out was: %s\n' "no verdict" "$out"; FAIL=$((FAIL+1))
fi

# --- REJECT is advisory by default and a control only when asked
run "REJECT is advisory by default"     "$PUSH" 0 1 STUB_VERDICT=REJECT
run "OBS_REVIEW_STRICT=1 makes it L2"   "$PUSH" 3 1 STUB_VERDICT=REJECT OBS_REVIEW_STRICT=1
run "STRICT does not fail an ACCEPT"    "$PUSH" 0 1 STUB_VERDICT=ACCEPT OBS_REVIEW_STRICT=1

# --- a reviewer that dies must not take the developer's push with it
run "a failing reviewer still exits 0"  "$PUSH" 0 1 STUB_EXIT=1 STUB_VERDICT=none

# --- files outside the globs are not worth a model call
git -C "$FIXTURE" rm -q "$FIXTURE/runner/analyze-experiment.py" \
   "$FIXTURE/observatory-api/src/main/resources/db/migration/V7__x.sql"
echo notes >> "$FIXTURE/README.md"
mkdir -p "$FIXTURE/observatory-web/src"
echo 'export const x = 1' > "$FIXTURE/observatory-web/src/api.ts"
git -C "$FIXTURE" add -A >/dev/null; git -C "$FIXTURE" commit -qm docs
run "a README change is not reviewable" "$PUSH" 0 0
run "the web layer is out of scope"     "$PUSH" 0 0

# --- malformed or absent payloads must never fire a model call
run "empty stdin"                       ''      0 0
run "not JSON"                          'nope'  0 0
run "JSON without a command"            '{"tool_name":"Bash"}' 0 0
run "JSON, wrong shape"                 '{"tool_input":{"file_path":"x"}}' 0 0

# --- and with no opencode on PATH at all, it declines rather than erroring
MINBIN="$TMP/minbin"; mkdir -p "$MINBIN"
for t in bash env git jq cat dirname date mkdir grep awk wc printf tr; do
  src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$MINBIN/$t"
done
: > "$CALLS"
out="$(printf '%s' "$PUSH" | env -i CALLS="$CALLS" HOME="$HOME" PATH="$MINBIN" \
    bash "$FIXTURE/.claude/hooks/opencode-review.sh" 2>&1)"; got=$?
if [ "$got" = 0 ] && printf '%s' "$out" | grep -q 'not installed'; then
  printf 'ok    %-46s exit 0, skipped with a reason\n' "opencode not installed"; PASS=$((PASS+1))
else
  printf 'FAIL  %-46s exit %s, out: %s\n' "opencode not installed" "$got" "$out"; FAIL=$((FAIL+1))
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "opencode-review.test: all ${PASS} cases behaved as specified."
  exit 0
fi
echo "opencode-review.test: ${FAIL} of $((PASS+FAIL)) cases misbehaved." >&2
exit 1
