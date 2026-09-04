#!/usr/bin/env bash
# classify-skill-contamination.sh — did a skill run that this experiment did not install?
#
#   classify-skill-contamination.sh <enable_skills:true|false> <telemetry-json>
#
# WHY THIS IS ITS OWN FILE. The rule it holds was wrong for exactly one day and the error
# was invisible: run-agent.sh counted `Skill` tool calls and reported every one of them as
# "a plugin skill executed despite --disable-slash-commands (harness bug #13)", F15,
# excluded. That was RIGHT while skills were unconditionally disabled — nothing could
# legitimately call one, so any call was a leak. It became WRONG the moment a skill was a
# treatment: the first run of the matched arm of E-004 loaded its own installed skill,
# and the guard marked the arm that works as infrastructure failure and threw it away.
#
# That is the fourth appearance of one shape in this stop: AN OPEN "EVERYTHING ELSE IS
# MINE" BUCKET, read in the direction that flatters. `skill-activation.sh` had it three
# times (not-bundled, then not-bundled-or-empty, then not-bundled-or-plugin, each fix
# naming one more scope instead of rejecting the category). Here it is the mirror image —
# everything is THEIRS — and it lands on the treatment arm instead of the control.
#
# So the rule is written down where it can be given fixtures, and it is stated by SOURCE:
#
#   skills disabled (the default, and every run recorded before 2026-09-04)
#       any skill activation at all is a leak.            -> contaminated
#
#   skills enabled (--enable-skills)
#       bundled        Claude Code ships its own; present equally in every arm.   -> clean
#       projectSettings  what a skill installed by the customization overlay emits.
#                        MEASURED 2026-09-04 on run 46ffad94-0609-48dd-a9b5-a5114b331e43,
#                        the first project-scope skill ever recorded on this instrument.
#                        Clean ONLY when this run actually installed one.          -> clean
#       anything else  plugin, user, enterprise, or a source this runtime has not
#                      shipped yet.                                                -> contaminated
#
# The last line is the point. It is an allowlist, and a source nobody has seen yet lands
# OUTSIDE it. That is the direction an unknown should fail in.
#
# Exit 0 clean · 2 contaminated (reason on stdout) · 1 usage.

set -uo pipefail

[[ $# -eq 3 ]] || {
  echo "usage: classify-skill-contamination.sh <true|false> <installed_skill:true|false> <telemetry-json>" >&2
  exit 1
}
ENABLE_SKILLS="$1"
INSTALLED_SKILL="$2"
TELEMETRY="$3"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# Fall back to the tool-call count when the runtime does not report activations by source
# (copilot and codex do not emit skill_activated at all). A count with no source cannot be
# cleared by an allowlist, so it stays contamination under the old rule.
SOURCES="$(jq -r '[.skillActivations[]? | "\(.source) \(.calls)"] | .[]' <<<"$TELEMETRY" 2>/dev/null)"
TOOL_SKILL_CALLS="$(jq -r '[.toolBreakdown[]? | select(.tool == "Skill") | .calls] | add // 0' <<<"$TELEMETRY" 2>/dev/null)"
[[ "$TOOL_SKILL_CALLS" =~ ^[0-9]+$ ]] || TOOL_SKILL_CALLS=0

if [[ "$ENABLE_SKILLS" != true ]]; then
  if [[ "$TOOL_SKILL_CALLS" -gt 0 ]]; then
    echo "a skill executed ${TOOL_SKILL_CALLS}× despite --disable-slash-commands (harness bug #13)"
    exit 2
  fi
  echo "clean"
  exit 0
fi

# Skills were enabled deliberately. Only a source outside the allowlist is contamination.
FOREIGN=""
FOREIGN_CALLS=0
while read -r src calls; do
  [[ -n "$src" ]] || continue
  case "$src" in
    bundled) ;;
    projectSettings)
      if [[ "$INSTALLED_SKILL" != true ]]; then
        FOREIGN="${FOREIGN}${FOREIGN:+, }${src}(${calls})"
        FOREIGN_CALLS=$((FOREIGN_CALLS + calls))
      fi
      ;;
    *)
      FOREIGN="${FOREIGN}${FOREIGN:+, }${src}(${calls})"
      FOREIGN_CALLS=$((FOREIGN_CALLS + calls))
      ;;
  esac
done <<<"$SOURCES"

if [[ -n "$FOREIGN" ]]; then
  echo "a skill this run did not install executed ${FOREIGN_CALLS}× — source(s): ${FOREIGN}"
  exit 2
fi

# Skills enabled, activations reported, none foreign. A `Skill` tool call with NO activation
# record behind it is not cleared: it is a skill this instrument could not attribute.
if [[ -z "$SOURCES" && "$TOOL_SKILL_CALLS" -gt 0 ]]; then
  echo "${TOOL_SKILL_CALLS} Skill tool call(s) with no skill_activated record to attribute them to"
  exit 2
fi

echo "clean"
exit 0
