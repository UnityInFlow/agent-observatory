#!/usr/bin/env bash
# Did the runtime deliver the tool list the overlay asked for?
#
#   ./runner/lib/check-init-schema.sh <transcript.jsonl> [<agent-overlay.md>]
#
# WHY THIS EXISTS, AND WHY IT EXECUTES RATHER THAN BEING A SCRIPT SOMEONE REMEMBERS TO RUN.
# A `tools:` line in an agent overlay is a REQUEST, not the treatment. On Claude Code
# 2.1.260 the runtime resolves it and the resolution is not the identity function: with
# `Bash` present in a subagent allowlist, `Grep` and `Glob` are REMOVED from the delivered
# set; without `Bash` the list arrives verbatim. 36 observations, no exception — 16 of 16
# dropped, 20 of 20 verbatim — across E-005's arms F and T and B4's six probe cells. The
# file said one thing and the model was handed another, and nothing in this harness could
# see the difference: the overlay is copied, committed and hashed identically either way.
#
# That is the house failure mode with a new costume — a control reporting success over a
# scope smaller than it claims — and it is why author decision 8 (2026-09-04) requires the
# delivered schema to be READ FROM THE RUN'S OWN `system`/`init` RECORD and diffed against
# the file, per arm, before any B step registers a `tools:` allowlist. The decision named
# the promotion this script is: from a probe script into an executing check.
#
# THE COMPARISON IS AGAINST THE FILE, NOT AGAINST A REMEMBERED LIST. The expected set is
# parsed out of the overlay's own frontmatter, so an edit to the overlay cannot drift away
# from what this asserts.
#
# EXIT CODES — five outcomes, five codes, deliberately. "Nothing" was five different things
# once in this project and collapsing them threw away the strongest signal in an experiment
# (E-001). A mismatch and a missing record are not the same event and must not share a code:
# one voids a batch, the other says the run never started.
#
#   0  the delivered list equals the declared list, in order
#      — or no `tools:` line was declared, in which case NOTHING IS ASSERTED and the
#        delivered set is recorded only. Printed as such; not offered as a pass of a check
#        that did not run
#   2  usage, or the transcript cannot be read
#   3  NO `init` RECORD in the transcript — infrastructure. The run did not start, or the
#      runtime did not emit one. NOT a mismatch, and must never be reported as one
#   4  an `init` record exists but carries no `tools` key — the runtime's own schema moved
#   5  MISMATCH — the delivered SET differs from the declared set. This is row 0a
#   6  same set, DIFFERENT ORDER. Reported, never silently passed: it is a change in what
#      the runtime does with the list, and the next thing it changes might not be the order
set -uo pipefail

TRANSCRIPT="${1:-}"
OVERLAY="${2:-}"

usage() {
  sed -n '2,4p' "${BASH_SOURCE[0]}"
  exit 2
}

[[ -n "$TRANSCRIPT" ]] || usage
command -v jq >/dev/null 2>&1 || { echo "check-init-schema: jq is required" >&2; exit 2; }
[[ -r "$TRANSCRIPT" ]] || { echo "check-init-schema: cannot read '$TRANSCRIPT'" >&2; exit 2; }

# --- the delivered list ----------------------------------------------------
# `fromjson?` swallows a line that is not JSON rather than aborting the whole read: a
# transcript can carry a stray warning line ahead of the stream, and a parse error there
# would otherwise look exactly like "no init record", which is a different finding.
INIT="$(jq -c -R 'fromjson? | select(type == "object" and .type == "system" and .subtype == "init")' \
        "$TRANSCRIPT" 2>/dev/null | head -1)"

if [[ -z "$INIT" ]]; then
  echo "init-schema: NO INIT RECORD in $(basename "$TRANSCRIPT") — the run did not start, or emitted none"
  echo "init-schema: verdict=no-init-record"
  exit 3
fi

if ! jq -e 'has("tools")' <<<"$INIT" >/dev/null 2>&1; then
  echo "init-schema: an init record exists but has NO 'tools' key — the runtime's schema moved"
  echo "init-schema: verdict=no-tools-key"
  exit 4
fi

DELIVERED_JSON="$(jq -c '.tools' <<<"$INIT")"
DELIVERED_N="$(jq -r '.tools | length' <<<"$INIT")"
echo "init-schema: delivered n=${DELIVERED_N} ${DELIVERED_JSON}"

# --- the declared list -----------------------------------------------------
# Nothing to compare against is a legitimate state — an overlay may deliberately omit
# `tools:` (E-005's arm C did, and was handed all 29). It is reported as "nothing asserted"
# so that a reader cannot mistake it for a comparison that passed.
if [[ -z "$OVERLAY" ]]; then
  echo "init-schema: no overlay given — NOTHING ASSERTED, delivered set recorded only"
  echo "init-schema: verdict=recorded-only"
  exit 0
fi
[[ -r "$OVERLAY" ]] || { echo "check-init-schema: cannot read overlay '$OVERLAY'" >&2; exit 2; }

# ONLY the frontmatter block, and this matters. A `tools:` string in the BODY of an agent
# overlay is prose — B4's own overlay explains in its body why Grep and Glob are absent —
# and reading one as the declaration would compare the runtime against a sentence.
# awk state machine: start counting `---` fences at line 1; the block is between fence 1
# and fence 2; stop reading at fence 2.
DECLARED_LINE="$(awk '
  NR == 1 && $0 ~ /^---[[:space:]]*$/ { infm = 1; next }
  infm && $0 ~ /^---[[:space:]]*$/    { exit }
  infm && $0 ~ /^tools:[[:space:]]/   { sub(/^tools:[[:space:]]*/, ""); print; exit }
' "$OVERLAY")"

if [[ -z "$DECLARED_LINE" ]]; then
  echo "init-schema: overlay $(basename "$OVERLAY") declares no 'tools:' line — NOTHING ASSERTED"
  echo "init-schema: verdict=recorded-only"
  exit 0
fi

# `Read, Edit, Write, Bash` -> a JSON array, trimming whitespace and dropping empty entries
# so a trailing comma cannot silently add a "" tool to the expectation.
DECLARED_JSON="$(jq -c -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' \
                 <<<"$DECLARED_LINE")"
DECLARED_N="$(jq -r 'length' <<<"$DECLARED_JSON")"
echo "init-schema: declared  n=${DECLARED_N} ${DECLARED_JSON}"

if [[ "$DELIVERED_JSON" == "$DECLARED_JSON" ]]; then
  echo "init-schema: verdict=match"
  exit 0
fi

# Set equality is checked SEPARATELY from order, because they are different findings with
# different consequences. A dropped tool changes what the agent can do; a reordered list
# does not, and reporting them under one code would hide the cheap one behind the expensive
# one — or, worse, let the cheap one be waved through as "basically the same".
DELIVERED_SET="$(jq -c 'sort' <<<"$DELIVERED_JSON")"
DECLARED_SET="$(jq -c 'sort' <<<"$DECLARED_JSON")"
if [[ "$DELIVERED_SET" == "$DECLARED_SET" ]]; then
  echo "init-schema: SAME SET, DIFFERENT ORDER — reported, not passed"
  echo "init-schema: verdict=order-differs"
  exit 6
fi

MISSING="$(jq -c --argjson d "$DELIVERED_JSON" '. - $d' <<<"$DECLARED_JSON")"
EXTRA="$(jq -c --argjson c "$DECLARED_JSON" '. - $c' <<<"$DELIVERED_JSON")"
echo "init-schema: MISMATCH — declared but NOT delivered: ${MISSING}; delivered but not declared: ${EXTRA}"
echo "init-schema: this is row 0a. The file is not the treatment. VOID, redesign, do not score."
echo "init-schema: verdict=mismatch"
exit 5
