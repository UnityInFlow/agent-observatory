#!/usr/bin/env bash
#
# verify-knowledge-hash — the fixture set for `knowledge_hash()` in run-agent.sh.
#
# WHAT IS BEING PROVED. The record already carried four customization hashes — an instruction
# file, the set of SKILL.md, the one dispatched agent file, the set of agent files — and NONE of
# them covers a knowledge CORPUS, because a corpus is a directory. `knowledgeHash` is the SET of
# files under `.ai/knowledge/`, computed exactly as `skills_hash()` and `agents_hash()` are: one
# digest over the sorted (path, content) pairs. Sorted so the value does not depend on find
# order; the path included so a RENAMED document is a difference rather than a collision.
#
# THE TWO SENTENCES THAT MATTER MOST AND WHICH CASE CARRIES EACH. "A rename is visible" is
# case D and only case D: with the path left out of the digest a rename does not move the value,
# so D fails while E and F still pass — the same trap V7's verifier had to have pointed out to it
# by a review. "The set descends into subdirectories" is case I, and at this stop that is not a
# hypothetical: the shipped corpus puts its two documents in `summaries/` and `documents/`, so a
# top-level-only glob would hash the index and the router and MISS THE ENTIRE PAYLOAD while still
# returning a plausible non-null value.
#
# WHY IT DRIVES THE REAL RUNNER. Every case invokes `run-agent.sh --check-customization`, which
# computes the hashes on the real code path and exits before any agent is launched. A fixture that
# re-implemented the digest would be testing a copy of the control, which is this project's house
# failure mode. No model call is made and no money is spent.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Asserted at the END against what actually ran, never printed at the top from a constant.
EXPECTED_CASES=13

RUNNER="${RUNNER_UNDER_TEST:-./runner/run-agent.sh}"
API_PORT="8080"
[[ -r infra/.env ]] && API_PORT="$(sed -n 's/^API_PORT=//p' infra/.env | tail -1)"
API_URL="${API:-http://localhost:${API_PORT:-8080}}"
curl -fsS "${API_URL}/actuator/health" >/dev/null 2>&1 \
  || { echo "Observatory API not reachable at ${API_URL} — run 'make up' first." >&2
       echo "Every check below drives the real runner, which refuses to start without it." >&2
       exit 1; }

LAB="${LAB_DIR:-../agent-learning-lab}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "  ok   — $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL — $1"; fail=$((fail + 1)); }

corpus() {  # corpus <root> <index-body> [<relpath> <body>]...
  local root="$1" idx="$2"; shift 2
  mkdir -p "$root/.ai/knowledge"
  printf '%s' "$idx" > "$root/.ai/knowledge/index.yaml"
  while [[ $# -ge 2 ]]; do
    mkdir -p "$(dirname "$root/.ai/knowledge/$1")"
    printf '%s' "$2" > "$root/.ai/knowledge/$1"
    shift 2
  done
}

run() { "$RUNNER" --runtime claude --benchmark BE-003 --experiment EXP-VERIFY-KNOWLEDGE-HASH \
                  --api "$API_URL" "$@" --check-customization 2>&1; }
# The value, or the literal string `ERROR:<exit>` so a failed invocation can never be compared as
# if it were a hash. Two broken runs must not look equal to each other.
hash_of() {  # hash_of <json-key> <runner args...>
  local key="$1"; shift
  local out rc
  out="$(run "$@")"; rc=$?
  [[ $rc -eq 0 ]] || { echo "ERROR:$rc"; return; }
  grep -o "\"${key}\":[^,}]*" <<<"$out" | head -1 | cut -d: -f2- | tr -d '"'
}
kh() { hash_of knowledgeHash "$@"; }

IDX='topics:
  alpha:
    triggers:
      - widget
    summary: summaries/a.md
    details: documents/a.md
'

# --- fixtures ---------------------------------------------------------------
ONE="$TMP/one";     corpus "$ONE"  "$IDX"
TWO="$TMP/two";     corpus "$TWO"  "$IDX" "summaries/a.md" "Summary body."
CPY="$TMP/copy";    corpus "$CPY"  "$IDX"
# RENAMED: the same bytes at a different path.
REN="$TMP/renamed"; mkdir -p "$REN/.ai/knowledge"; printf '%s' "$IDX" > "$REN/.ai/knowledge/idx.yaml"
# CHANGED: the same path, different bytes.
CHG="$TMP/changed"; corpus "$CHG"  "${IDX}# edited
"
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"; printf 'Be concise.\n' > "$PLAIN/CLAUDE.md"

echo "== knowledge_hash: the SET of files under .ai/knowledge/ =="

H_ONE="$(kh --customization "$ONE")"
H_TWO="$(kh --customization "$TWO")"
H_CPY="$(kh --customization "$CPY")"
H_REN="$(kh --customization "$REN")"
H_CHG="$(kh --customization "$CHG")"

# A — no corpus records null. Without this every case below is satisfied by a value that is
#     non-null on everything, which distinguishes nothing — and `null` is exactly what this
#     stop's CONTROL arm must read from the record.
out="$(run --customization "$PLAIN")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q '"knowledgeHash":null' <<<"$out"; then
  ok "A: an overlay with no .ai/knowledge records knowledgeHash null"
else
  bad "A: expected knowledgeHash null, got exit $rc: $(grep -o 'customization hashes: .*' <<<"$out" | head -1)"
fi

# B — and non-null when there is one.
if [[ "$H_ONE" == sha256:* ]]; then
  ok "B: a one-file corpus records a non-null knowledgeHash ($H_ONE)"
else
  bad "B: expected sha256:…, got '$H_ONE'"
fi

# C — the SET: adding a member moves the value.
if [[ "$H_TWO" == sha256:* && "$H_TWO" != "$H_ONE" ]]; then
  ok "C: adding a second corpus file changes knowledgeHash ($H_ONE -> $H_TWO)"
else
  bad "C: expected a different non-null hash, got '$H_TWO' against '$H_ONE'"
fi

# D — RENAMED. Identical content at a different path. THIS is the case that detects a digest
#     computed over content alone; F does not (see the header).
if [[ "$H_REN" == sha256:* && "$H_REN" != "$H_ONE" ]]; then
  ok "D: a RENAMED corpus file (same content) changes knowledgeHash ($H_REN)"
else
  bad "D: a rename was invisible — got '$H_REN' against '$H_ONE'"
fi

# E — CHANGED. Identical path, different content.
if [[ "$H_CHG" == sha256:* && "$H_CHG" != "$H_ONE" ]]; then
  ok "E: an EDITED corpus file (same path) changes knowledgeHash ($H_CHG)"
else
  bad "E: an edit was invisible — got '$H_CHG' against '$H_ONE'"
fi

# F — the pair: a rename and an edit must not produce the same value. Second line of the
#     guarantee, not the first — do not delete D on the strength of this one.
if [[ "$H_REN" != "$H_CHG" && "$H_REN" == sha256:* && "$H_CHG" == sha256:* ]]; then
  ok "F: a rename and an edit produce DIFFERENT hashes"
else
  bad "F: rename and edit are indistinguishable — '$H_REN' / '$H_CHG'"
fi

# G — determinism. An independently built, byte-identical corpus must hash the same, or none of
#     the comparisons above mean anything.
if [[ "$H_CPY" == "$H_ONE" && "$H_CPY" == sha256:* ]]; then
  ok "G: a byte-identical corpus built separately hashes identically"
else
  bad "G: expected '$H_ONE', got '$H_CPY'"
fi

# H — REMOVAL. C proves an addition moves the value; nothing above proves a removal does, so a
#     digest that folded new members in without re-deriving from the current file list would pass
#     every case so far. DEL is TWO with its summary deleted, which is ONE by construction.
DEL="$TMP/deleted"; corpus "$DEL" "$IDX" "summaries/a.md" "Summary body."
rm "$DEL/.ai/knowledge/summaries/a.md"
H_DEL="$(kh --customization "$DEL")"
if [[ "$H_DEL" == "$H_ONE" && "$H_DEL" == sha256:* ]]; then
  ok "H: REMOVING a corpus file returns knowledgeHash to the one-file value"
else
  bad "H: expected '$H_ONE' after removing summaries/a.md, got '$H_DEL'"
fi

# I — IT DESCENDS. The shipped corpus keeps its documents in `summaries/` and `documents/`, so a
#     top-level-only glob would hash the index alone and miss the entire payload while still
#     returning a plausible non-null value. NEST differs from ONE only by a file two levels down.
NEST="$TMP/nested"; corpus "$NEST" "$IDX" "documents/deep/d.md" "Deep body."
H_NEST="$(kh --customization "$NEST")"
if [[ "$H_NEST" == sha256:* && "$H_NEST" != "$H_ONE" ]]; then
  ok "I: a corpus file in a SUBDIRECTORY is part of the set ($H_NEST)"
else
  bad "I: a nested corpus file was invisible — got '$H_NEST' against '$H_ONE'"
fi

# J — knowledgeHash is not instructionsHash. An overlay carrying BOTH a CLAUDE.md and a corpus
#     must report two different non-null values; equal ones would mean one field is measuring the
#     other, which is the defect V7's note warns about between agentHash and agentsHash.
BOTH="$TMP/both"; corpus "$BOTH" "$IDX"; printf 'Consult the router.\n' > "$BOTH/CLAUDE.md"
out="$(run --customization "$BOTH")"; rc=$?
ins="$(grep -o '"instructionsHash":[^,}]*' <<<"$out" | head -1 | cut -d: -f2- | tr -d '"')"
kno="$(grep -o '"knowledgeHash":[^,}]*'    <<<"$out" | head -1 | cut -d: -f2- | tr -d '"')"
if [[ $rc -eq 0 && "$ins" == sha256:* && "$kno" == sha256:* && "$ins" != "$kno" ]]; then
  ok "J: instructionsHash ($ins) and knowledgeHash ($kno) are different measurements"
else
  bad "J: expected two different non-null hashes, got instructions '$ins' knowledge '$kno' (exit $rc)"
fi

# K — THE TWO ARMS THIS STOP ACTUALLY RUNS, asserted here with no benchmark run and no money:
#     the treated overlay reports a non-null knowledgeHash and the control reports null. Skipped
#     with a stated reason, never silently, when the lab checkout is not beside this one.
T_OVL="$LAB/build/customizations/agent-v1.2-knowledge"
C_OVL="$LAB/build/customizations/agent-v1.1"
if [[ -d "$T_OVL" && -d "$C_OVL" ]]; then
  H_T="$(kh --customization "$T_OVL" --agent backend-feature-phases)"
  out_c="$(run --customization "$C_OVL" --agent backend-feature-phases)"
  if [[ "$H_T" == sha256:* ]] && grep -q '"knowledgeHash":null' <<<"$out_c"; then
    ok "K: the SHIPPED treated overlay reports $H_T and the control reports null"
  else
    bad "K: treated '$H_T' / control $(grep -o '"knowledgeHash":[^,}]*' <<<"$out_c" | head -1)"
  fi
else
  bad "K: the lab overlays are not at $LAB — case not run, and that is reported as a failure
        rather than skipped, because a case that quietly does not run is a case nobody checks"
fi

# L — FORWARD COMPATIBILITY with an API that predates the migration, which is obs#88's own check
#     and the reason a runner ahead of an API restart records null instead of failing. Posts a
#     minimal record carrying knowledgeHash and asserts the API accepts it.
#
#     THE PAYLOAD SHAPE IS NOT DECORATION AND THE FIRST VERSION OF IT WAS WRONG. `RuntimeDto`
#     requires `provider` and `product` (Dtos.kt:16-18), not `name`; with `name` the API answers
#     **400**, which is byte-for-byte what "the API rejected the new field" looks like. Diagnosed
#     rather than assumed, by posting the same body with `agentsHash` — a field the running API
#     has had since V7 — and getting the same 400. A forward-compatibility check that cannot tell
#     a malformed fixture from a rejected field proves nothing about either.
RID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
code="$(curl -s -o "$TMP/post.json" -w '%{http_code}' -m 20 -X POST \
  -H 'Content-Type: application/json' "$API_URL/api/runs" -d "{
    \"runId\": \"$RID\", \"benchmarkId\": \"BE-003\", \"variant\": \"verify-knowledge-hash\",
    \"experimentKey\": \"EXP-VERIFY-KNOWLEDGE-HASH\",
    \"startedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"finishedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
    \"runtime\": {\"provider\": \"anthropic\", \"product\": \"claude\", \"version\": \"0.0.0-fixture\", \"model\": \"fixture\"},
    \"customization\": {\"knowledgeHash\": \"sha256:0123456789abcdef0123456789abcdef\"}
  }")"
if [[ "$code" == "201" || "$code" == "200" ]]; then
  back="$(curl -s -m 15 "$API_URL/api/runs/$RID" | grep -o '"knowledgeHash":[^,}]*' | head -1)"
  ok "L: the API accepted a record carrying knowledgeHash (HTTP $code); it reads back as ${back:-absent}"
else
  bad "L: the API answered HTTP $code to a record carrying knowledgeHash — a runner ahead of an
        API restart would fail rather than record null"
fi

# M — THE REGRESSION CASE L CAUSED, and it is here because it actually happened rather than
#     because it was imagined. Case L's record has NO efficiency values at all. JPA materializes
#     an embeddable whose columns are all null as a NULL EMBEDDABLE, `RunService.toResponse`
#     dereferenced `run.efficiency` directly, and the first such row in the table made
#     `GET /api/runs` answer **500 for every caller** — the list the batch driver, the report and
#     the web UI all read. Fixed by giving `efficiency` the `behaviorOrNull` treatment this entity
#     already documents for `behavior`. This case asserts the list endpoint answers 200 AFTER case
#     L has inserted its row, which is the only ordering in which it proves anything.
code="$(curl -s -o /dev/null -w '%{http_code}' -m 30 "$API_URL/api/runs?limit=5")"
if [[ "$code" == "200" ]]; then
  ok "M: GET /api/runs answers 200 with case L's efficiency-free record in the table"
else
  bad "M: GET /api/runs answered HTTP $code after case L — one malformed row must not take out
        the list endpoint every reader of this API depends on"
fi

echo
ran=$((pass + fail))
if [[ "$ran" -ne "$EXPECTED_CASES" ]]; then
  echo "verify-knowledge-hash: ${ran} cases ran, ${EXPECTED_CASES} registered — the announced"
  echo "scope and the executed scope disagree, which is the failure this line exists to catch."
  exit 1
fi
echo "verify-knowledge-hash: ${pass} passed, ${fail} failed, ${ran} of ${EXPECTED_CASES} cases ran."
[[ "$fail" -eq 0 ]] || exit 1
