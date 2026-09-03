# The review hook

Anyone who clones this repo gets it. It lives here, not in a personal config — the same
choice `agent-learning-lab` made, for the same reason: a reviewer configured on one laptop
reviews one person's work and silently reviews nobody else's.

| File | Role |
|---|---|
| [`../settings.json`](../settings.json) | the wiring — `PostToolUse` on `Bash` |
| [`opencode-review.sh`](opencode-review.sh) | the hook, `chmod +x` |
| [`opencode-review.test.sh`](opencode-review.test.sh) | 25 cases with `git`, `jq` and `opencode` stubbed — no network, no tokens, no model call |
| [`../../.opencode/agent/obs-critic.md`](../../.opencode/agent/obs-critic.md) | the reviewer's prompt |

CI runs the test file, because a reviewer that cannot be reviewed is the thing it warns about.

## What it does

On `git push` and `gh pr create`, the changed files that match the globs go to `obs-critic`
on `ollama-cloud/glm-5.2`, and the review lands in `findings/opencode/review-<timestamp>.md`
with a header recording the head, the base, the model and the agent.

**The diff is inlined into the prompt rather than fetched by the reviewer**, and that is a
fix rather than a preference. `opencode` rewrites its bash through an rtk plugin, and
`rtk git diff` filters `.claude/`, `.opencode/`, `.github/` and `findings/` paths out of its
output. On a branch that changes only the hook — which is every branch that touches this
directory — the reviewer asked what had changed, was told **nothing**, and looped on the same
command for ten minutes until it was killed, leaving no verdict. The tool never errored: it
exited 0 with an empty answer, and empty is indistinguishable from *"no changes"*. Inlining
removes the command, so there is nothing left for an environment to filter. If the hook
cannot produce a diff for files it has already matched, it prints `BLOCKED` and does not
spend a model call. Found in `agent-observatory-benchmarks` on 2026-09-03; this hook had the
identical line and was fixed before it could reproduce it.

**A different model family is the whole point.** Its blind spots are not the author's, and
neither are they Claude's. A review by the same model that wrote the code is a spellcheck.

## What is in scope, and why not everything

```
runner/*.py                    the statistics that decide a verdict
observatory-api/…/migration/*.sql   one-way, against data that cannot be re-collected
runner/schemas/*.json          the run-record contract
.claude/hooks/*.sh             this hook and its neighbours
```

A reviewer that fires on everything gets muted within a week, and a muted hook is worse than
no hook because the repository still *looks* reviewed. The web and API layers are out of
scope for now on purpose: they render and store, they do not decide. A README or a dashboard
tweak does not need a model call.

`runner/schemas/` is in the list because of what happened without it. `run.schema.json`
described the run-record payload for months while being loaded by no code, and drifted three
migrations behind it — far enough that wiring it in would have rejected every run (#53).

## The gate is advisory

A `REJECT` is recorded and printed to stderr; the hook still exits 0. That makes the verdict
**L3 — words a human reads and chooses to act on.**

This is deliberate, not an oversight. A reviewer that can break `git push` gets deleted
within a day, and a control nobody keeps is worth less than a warning everybody reads.

`OBS_REVIEW_STRICT=1` is the L2 version: a `REJECT` exits 3. Note what that does and does not
do — the push has *already happened* by the time a `PostToolUse` hook runs, so strict mode
fails the **hook**, not the push. It is a louder signal, not a rollback. **Nothing in this
repo sets it**, and this README should not be edited to imply otherwise.

## A zero exit is not proof of a review

The sibling repo learned this expensively: a review ran to completion, exited 0, and had
written its verdict somewhere the runtime then refused — so nothing was recorded while the
run looked successful, and the head was marked reviewed.

So this checks for the artifact rather than the status. A run that writes no
`VERDICT: ACCEPT|REJECT` line is reported as **BLOCKED**, and the head is to be treated as
unreviewed. A process that ran is not a review that happened.

## Knobs

| Variable | Default | |
|---|---|---|
| `OBS_REVIEW_HOOK=0` | on | turn the hook off entirely |
| `OBS_REVIEW_STRICT=1` | off | `REJECT` exits 3 instead of 0 |
| `OBS_REVIEW_MAX_FILES` | `4` | budget. Files over it are **named** on stderr, never dropped silently |
| `OBS_REVIEW_MODEL` | `ollama-cloud/glm-5.2` | |
| `OBS_REVIEW_AGENT` | `obs-critic` | |

Changing the model mid-experiment invalidates comparisons that span the change, which is why
the model is recorded in every findings header rather than assumed.
