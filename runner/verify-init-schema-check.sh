#!/usr/bin/env bash
# Does check-init-schema.sh actually REFUSE, and does it tell its five outcomes apart?
#
#   ./runner/verify-init-schema-check.sh
#
# A control that has never been shown to reject anything is indistinguishable from one that
# rejects nothing. This drives every registered exit code of `runner/lib/check-init-schema.sh`
# through a fixture, including the two that are easiest to get wrong in the direction that
# manufactures a pass:
#
#   - a `tools:` line in the overlay's BODY must not be read as its declaration (case 10);
#     B4's own overlay explains Grep and Glob in prose, and reading that as the contract
#     would compare the runtime against a sentence
#   - a transcript with NO init record must not report a match (cases 5 and 14); a run that
#     never started and a run whose schema was rewritten are different events, and the whole
#     point of five exit codes is that they cannot be collapsed
#
# No model call, no network, no API. Runs anywhere jq does.
#
# Exit 0 every case behaved as registered · 2 A CASE FAILED.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CHECK="./runner/lib/check-init-schema.sh"
[[ -x "$CHECK" ]] || { echo "verify-init-schema-check: $CHECK is missing or not executable" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "verify-init-schema-check: jq is required" >&2; exit 2; }

# The count is asserted at the END, against the cases that actually ran. Announcing it at
# the top prints a number computed before any case has executed, which is how a stale count
# once told a reader that 27 cases had passed while 26 ran.
EXPECTED_CASES=17

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

# expect <case> <wanted-exit> <wanted-verdict|-> <transcript> [overlay]
expect() {
  local name="$1" want_rc="$2" want_verdict="$3" transcript="$4" overlay="${5:-}"
  local out rc
  out=$("$CHECK" "$transcript" ${overlay:+"$overlay"} 2>&1); rc=$?
  if [[ "$rc" != "$want_rc" ]]; then
    echo "  FAIL — $name: expected exit $want_rc, got $rc"
    echo "         $(tr '\n' '|' <<<"$out")"
    fail=$((fail + 1)); return
  fi
  if [[ "$want_verdict" != "-" ]] && ! grep -q "verdict=${want_verdict}\$" <<<"$out"; then
    echo "  FAIL — $name: exit $rc was right but verdict was not '$want_verdict'"
    echo "         $(tr '\n' '|' <<<"$out")"
    fail=$((fail + 1)); return
  fi
  echo "  ok   — $name (exit $rc${want_verdict:+, verdict=$want_verdict})"
  pass=$((pass + 1))
}

init_line() { printf '{"type":"system","subtype":"init","tools":%s}\n' "$1"; }

# --- transcripts -----------------------------------------------------------
init_line '["Read","Edit","Write","Bash"]'          > "$TMP/exact.jsonl"
init_line '["Read","Bash"]'                          > "$TMP/dropped.jsonl"   # E-005 arm F, verbatim
init_line '["Read","Edit","Write","Bash","Grep"]'    > "$TMP/extra.jsonl"
init_line '["Bash","Read","Write","Edit"]'           > "$TMP/reordered.jsonl"
printf '{"type":"assistant","message":{"content":[]}}\n'        > "$TMP/no-init.jsonl"
printf '{"type":"system","subtype":"compact_boundary"}\n'       > "$TMP/other-system.jsonl"
printf '{"type":"system","subtype":"init","model":"x"}\n'       > "$TMP/no-tools-key.jsonl"
{ printf 'warning: something on stderr got interleaved\n'
  init_line '["Read","Edit","Write","Bash"]'; }      > "$TMP/stray-line.jsonl"
{ init_line '["Read","Edit","Write","Bash"]'
  init_line '["Read"]'; }                            > "$TMP/two-init.jsonl"

# --- overlays --------------------------------------------------------------
printf -- '---\nname: fixture\ndescription: A fixture.\ntools: Read, Edit, Write, Bash\n---\n\nBody.\n' \
  > "$TMP/declared.md"
printf -- '---\nname: fixture\ndescription: A fixture.\n---\n\nBody.\n' \
  > "$TMP/no-tools-line.md"
printf -- '---\nname: fixture\ndescription: A fixture.\ntools: Read, Grep, Glob, Bash\n---\n\nBody.\n' \
  > "$TMP/armf.md"
printf -- '---\nname: fixture\ndescription: A fixture.\n---\n\ntools: Read, Grep, Glob\n\nThat line above is prose, not a declaration.\n' \
  > "$TMP/tools-in-body.md"
printf -- '---\nname: fixture\ndescription: A fixture.\ntools: Read, Edit, Write, Bash,\n---\n\nBody.\n' \
  > "$TMP/trailing-comma.md"
printf -- '---\nname: fixture\ndescription: A fixture.\ntools:   Read ,Edit,   Write,Bash  \n---\n\nBody.\n' \
  > "$TMP/ragged-spacing.md"

echo "== check-init-schema.sh, every registered exit code =="

expect "1  exact match is a match"                        0 match          "$TMP/exact.jsonl"     "$TMP/declared.md"
expect "2  E-005 arm F verbatim: Grep and Glob dropped"   5 mismatch       "$TMP/dropped.jsonl"   "$TMP/armf.md"
expect "3  a tool delivered but not declared is row 0a"   5 mismatch       "$TMP/extra.jsonl"     "$TMP/declared.md"
expect "4  same set, different order is its own code"     6 order-differs  "$TMP/reordered.jsonl" "$TMP/declared.md"
expect "5  no init record is NOT a mismatch"              3 no-init-record "$TMP/no-init.jsonl"   "$TMP/declared.md"
expect "6  an init record with no tools key"              4 no-tools-key   "$TMP/no-tools-key.jsonl" "$TMP/declared.md"
expect "7  a stray non-JSON line does not hide the init"  0 match          "$TMP/stray-line.jsonl" "$TMP/declared.md"
expect "8  no overlay given asserts nothing"              0 recorded-only  "$TMP/exact.jsonl"
expect "9  an overlay with no tools: line asserts nothing" 0 recorded-only "$TMP/exact.jsonl"     "$TMP/no-tools-line.md"
expect "10 tools: in the BODY is prose, not a contract"   0 recorded-only  "$TMP/exact.jsonl"     "$TMP/tools-in-body.md"
expect "11 a trailing comma adds no empty tool"           0 match          "$TMP/exact.jsonl"     "$TMP/trailing-comma.md"
expect "12 ragged spacing still matches"                  0 match          "$TMP/exact.jsonl"     "$TMP/ragged-spacing.md"
expect "13 another system record is not an init record"   3 no-init-record "$TMP/other-system.jsonl" "$TMP/declared.md"
expect "14 the FIRST init record decides"                 0 match          "$TMP/two-init.jsonl"  "$TMP/declared.md"
expect "15 an unreadable transcript is a usage error"     2 -              "$TMP/does-not-exist.jsonl" "$TMP/declared.md"
expect "16 an unreadable overlay is a usage error"        2 -              "$TMP/exact.jsonl"     "$TMP/does-not-exist.md"

out=$("$CHECK" 2>&1); rc=$?
if [[ $rc -eq 2 ]]; then
  echo "  ok   — 17 no arguments at all is a usage error (exit 2)"
  pass=$((pass + 1))
else
  echo "  FAIL — 17 no arguments: expected exit 2, got $rc: $(tr '\n' '|' <<<"$out")"
  fail=$((fail + 1))
fi

echo
ran=$((pass + fail))
if [[ "$ran" -ne "$EXPECTED_CASES" ]]; then
  echo "verify-init-schema-check: ${ran} cases ran, ${EXPECTED_CASES} registered — the announced"
  echo "scope and the executed scope disagree, which is the failure this line exists to catch."
  exit 2
fi
echo "verify-init-schema-check: ${pass} passed, ${fail} failed, of ${EXPECTED_CASES} registered cases"
[[ "$fail" -eq 0 ]] || exit 2
