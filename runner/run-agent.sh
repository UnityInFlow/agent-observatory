#!/usr/bin/env bash
#
# The benchmark runner — the reproducibility engine of chapter 00 §24.
#
#   1. select benchmark          7. start agent
#   2. build the agent's repo    8. wait for completion
#   3. generate run id           9. record diff
#   4. capture tool versions    10. execute deterministic evaluator
#   5. hash customization       11. persist normalized run + evaluation
#   6. set OTel correlation     12. clean worktree
#
# Step 7 defaults to `--runtime manual`: §24 says do not automate the agent launch until
# several runs have been watched by hand, and §11 says the first run should be interactive
# so students see permissions and actions happen.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

RUNTIME="${RUNTIME:-manual}"
BENCHMARK_ID="${BENCHMARK_ID:-BE-001}"
VARIANT="${VARIANT:-baseline}"
EXPERIMENT="${EXPERIMENT:-EXP-001}"
BENCHMARKS_REPO="${BENCHMARKS_REPO:-$(cd "$REPO_ROOT/../agent-observatory-benchmarks" 2>/dev/null && pwd)}"
API="${API:-http://localhost:8080}"
WEB="${WEB:-http://localhost:5173}"
TEMPO_URL="${TEMPO_URL:-http://localhost:3200}"
# Directory whose contents are copied into the worktree before the agent starts, e.g. a
# folder holding AGENTS.md. This is what makes a B0-vs-B1 comparison possible: the files
# are overlaid and then hashed, so the variant is reproducible rather than just labelled.
CUSTOMIZATION_DIR=""
KEEP_WORKTREE=false
# Pin the model explicitly. `auto` lets the vendor pick, which silently breaks the
# "change one variable" rule the moment their routing changes underneath a comparison.
AGENT_MODEL="${AGENT_MODEL:-}"
# Headless by default for repeated baseline runs; --interactive restores the watch-it-work
# mode that §11 asks for on the very first run.
INTERACTIVE=false

# Drop the operator's user-scope settings, and with them the hooks registered there. Left
# off by default so this does not silently change what "baseline" means between experiments;
# an experiment that wants it must ask, and the request is recorded in the run's invocation.
ISOLATE_USER_SETTINGS=false

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)    RUNTIME="$2"; shift 2 ;;
    --benchmark)  BENCHMARK_ID="$2"; shift 2 ;;
    --variant)    VARIANT="$2"; shift 2 ;;
    --experiment) EXPERIMENT="$2"; shift 2 ;;
    --repo)       BENCHMARKS_REPO="$2"; shift 2 ;;
    --api)        API="$2"; shift 2 ;;
    --web)        WEB="$2"; shift 2 ;;
    --customization) CUSTOMIZATION_DIR="$2"; shift 2 ;;
    --model)      AGENT_MODEL="$2"; shift 2 ;;
    --isolate-user-settings) ISOLATE_USER_SETTINGS=true; shift ;;
    --interactive) INTERACTIVE=true; shift ;;
    --keep)       KEEP_WORKTREE=true; shift ;;
    -h|--help)    usage ;;
    *) echo "run-agent: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

die() { echo "run-agent: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

# --- 3b. remove terminal wrappers from PATH --------------------------------
# THE AGENT MUST BE THE AGENT, NOT THE AGENT PLUS WHATEVER LAUNCHED THIS SCRIPT.
#
# Some terminal hosts install shims ahead of the real CLI on PATH. cmux does: it puts
# $TMPDIR/cmux-cli-shims/<id>/{claude,codex} first, and each shim execs a wrapper that
# APPENDS ARGUMENTS THIS SCRIPT NEVER PASSED --
#
#   cmux-claude-wrapper:  exec "$REAL_CLAUDE" --session-id <id> --settings "$HOOKS_JSON" "$@"
#   cmux-codex-wrapper:   injects --dangerously-bypass-hook-trust and -c hooks.X=...
#
# Measured 2026-08-29 on run 092a384a, launched from inside such a terminal: 12 hooks with
# `hook_source: flagSettings` registered and executed, including three on Stop. All 172
# runs recorded before it — launched elsewhere — have zero. Nothing in the run record
# distinguishes the two: `customization.hooksHash` hashes the repository's files, and these
# arrive on the command line. The wrapper's hooks act on PreToolUse and PermissionRequest,
# which is exactly where agent behaviour is decided.
#
# So a run launched from that terminal is a different experiment from one launched in a
# plain shell, and the record cannot tell them apart. That is the harness measuring itself
# again, and it is the reason this strips rather than trusts.
#
# Belt and braces, because either alone is one assumption:
#   PATH        drop every cmux-cli-shims entry, so the real binary is resolved
#   env         set the wrappers' own documented off switches, in case a shim is reached
#               by a path this does not recognise
# The list is intentionally specific. A generic "strip anything odd" would silently change
# which binary runs, which is the failure this is preventing.
PATH_BEFORE_SHIM_STRIP="$PATH"
CLEAN_PATH=""
while IFS= read -r entry; do
  case "$entry" in
    */cmux-cli-shims|*/cmux-cli-shims/*) continue ;;
  esac
  CLEAN_PATH="${CLEAN_PATH:+$CLEAN_PATH:}$entry"
done < <(printf '%s\n' "$PATH" | tr ':' '\n')
if [[ "$CLEAN_PATH" != "$PATH_BEFORE_SHIM_STRIP" ]]; then
  export PATH="$CLEAN_PATH"
  echo "  stripped terminal CLI shims from PATH — the agent runs the real binary"
fi
export CMUX_CLAUDE_HOOKS_DISABLED=1 CMUX_CODEX_HOOKS_DISABLED=1
WRAPPER_STRIPPED=$([[ "$CLEAN_PATH" != "$PATH_BEFORE_SHIM_STRIP" ]] && echo true || echo false)

# shellcheck source=lib/evaluation-payload.sh
source "$HERE/lib/evaluation-payload.sh"

[[ -n "${BENCHMARKS_REPO:-}" && -d "$BENCHMARKS_REPO" ]] \
  || die "benchmarks repo not found; clone agent-observatory-benchmarks next to this repo or pass --repo"

case "$BENCHMARK_ID" in
  BE-001) BENCH_DIR="$BENCHMARKS_REPO/tasks/BE-001-customer-validation" ;;
  *)      BENCH_DIR="$(find "$BENCHMARKS_REPO/tasks" -maxdepth 1 -name "${BENCHMARK_ID}-*" | head -1)" ;;
esac
[[ -d "${BENCH_DIR:-}" ]] || die "benchmark '$BENCHMARK_ID' not found under $BENCHMARKS_REPO/tasks"

curl -fsS "${API}/actuator/health" >/dev/null 2>&1 \
  || die "Observatory API not reachable at ${API}; run 'make up' first"

# --- 3. run id -------------------------------------------------------------
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"

# --- 2. the repository the agent receives ----------------------------------
BASELINE_SHA="$(git -C "$BENCHMARKS_REPO" rev-parse HEAD)" || die "cannot resolve baseline commit"
WORKTREE="${TMPDIR:-/tmp}/observatory-run-${RUN_ID}"

cleanup() {
  if [[ "$KEEP_WORKTREE" == true ]]; then
    echo "  worktree kept at $WORKTREE"
    [[ -d "${WORKTREE}.codex-home" ]] && echo "  isolated codex home kept at ${WORKTREE}.codex-home"
    [[ -d "${WORKTREE}.home" ]] && echo "  isolated HOME kept at ${WORKTREE}.home"
  else
    rm -rf "$WORKTREE"
    # The isolated codex home lives beside the worktree and holds session state and sqlite
    # files codex writes during the run. It is disposable for the same reason the worktree is.
    rm -rf "${WORKTREE}.codex-home"
    # The isolated HOME holds a symlink to ~/.m2 and nothing else. `rm -rf` on a directory
    # removes the LINK, never the 8.5 GB it points at — but the ordering matters, so this
    # deletes the link explicitly first rather than relying on that being remembered.
    rm -f "${WORKTREE}.home/.m2"
    rm -rf "${WORKTREE}.home"
  fi
}
trap cleanup EXIT

# --- 2b. build it from an allowlist, as its own repository ------------------
# The benchmarks repository holds the graded acceptance suites, a known-good fixture and a
# README describing each task's trap. None of it may reach the agent: a run that can read
# the answer measures "can you find the answer file", and at least one demonstrably did —
# its summary named BE002FunctionalTest and BE002ContractTest, filenames that exist nowhere
# else.
#
# This builds a *fresh repository* from an allowlist. It is deliberately not a checkout
# with the authoring material deleted, which is what the first attempt at this did and why
# that attempt failed: a git worktree shares the parent repository's object store, so from
# inside the "stripped" tree `git show HEAD^:tasks/.../known-good/OrderController.kt`
# still returned the model solution, and `git show --stat HEAD` listed the acceptance-suite
# filenames in the setup commit's own diff. The material was hidden from `ls` and from
# nothing else.
#
# `git archive` extracts only the allowlisted paths, so the rest never lands on disk, and
# `git init` gives the tree a history of exactly one commit with no earlier state to
# recover. An allowlist rather than a denylist because a denylist rots the first time a
# benchmark adds a file, and this class of leak flatters the agent, so nobody investigates
# it.
#
# Safe for evaluation: the evaluator runs from BENCH_DIR in the *main* repository and
# copies its acceptance suites into the service at evaluation time. It never reads the
# agent's tree for them.
WORKTREE_KEEP=(sample-service .gitignore)
mkdir -p "$WORKTREE" || die "cannot create $WORKTREE"
git -C "$BENCHMARKS_REPO" archive --format=tar "$BASELINE_SHA" -- "${WORKTREE_KEEP[@]}" \
  | tar -x -C "$WORKTREE" \
  || die "cannot extract the allowlisted paths at ${BASELINE_SHA:0:12}"
[[ -d "$WORKTREE/sample-service" ]] || die "the allowlist did not yield the service under test"

# One commit, so the agent's `git log` has somewhere to start and the diff below has
# something to measure against. The customization overlay is committed the same way.
git -C "$WORKTREE" init -q -b main || die "cannot initialise the agent's repository"
git -C "$WORKTREE" add -A >/dev/null 2>&1
git -C "$WORKTREE" -c user.email=runner@observatory -c user.name=observatory-runner \
    commit -qm "initial commit" \
  || die "failed to commit the agent's starting state"
STRIPPED_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"

# Assert the leak is closed rather than trust that it is. The previous version of this
# looked correct for six merged PRs while handing over the answer key, and a leak that
# flatters the agent produces passes, which nobody investigates. These cost milliseconds.
[[ "$(git -C "$WORKTREE" rev-list --all --count)" == "1" ]] \
  || die "the agent's repository has more than one commit; history could hold the answer key"
if git -C "$WORKTREE" rev-list --all --objects | awk '{print $2}' | grep -q "^tasks/"; then
  die "benchmark authoring material is reachable from the agent's git history"
fi

echo "=============================================================="
echo " run        ${RUN_ID}"
echo " benchmark  ${BENCHMARK_ID}   variant ${VARIANT}   experiment ${EXPERIMENT}"
echo " runtime    ${RUNTIME}"
echo " binary     $(command -v "$RUNTIME" 2>/dev/null || echo n/a)"
echo " shims      $([[ "$WRAPPER_STRIPPED" == true ]] \
                    && echo "stripped from PATH (a terminal wrapper was in front of the real CLI)" \
                    || echo "none found on PATH")"
echo " worktree   ${WORKTREE}"
echo " baseline   ${BASELINE_SHA:0:12}"
echo "=============================================================="

# --- 4. capture tool/runtime versions --------------------------------------
case "$RUNTIME" in
  copilot) PROVIDER=github;  PRODUCT=copilot-cli; RUNTIME_VERSION="$(copilot --version 2>/dev/null | head -1)" ;;
  claude)  PROVIDER=anthropic; PRODUCT=claude-code; RUNTIME_VERSION="$(claude --version 2>/dev/null | head -1)" ;;
  codex)   PROVIDER=openai;  PRODUCT=codex;       RUNTIME_VERSION="$(codex --version 2>/dev/null | head -1)" ;;
  manual)  PROVIDER=manual;  PRODUCT=human;       RUNTIME_VERSION="n/a" ;;
  *) die "unknown runtime '$RUNTIME' (copilot|claude|codex|manual)" ;;
esac

# Fail before the worktree work rather than recording a run with a placeholder version:
# run.schema.json says "record the real version, never a placeholder".
if [[ "$RUNTIME" != "manual" ]]; then
  command -v "$RUNTIME" >/dev/null 2>&1 \
    || die "'$RUNTIME' is not on PATH; install it or use --runtime manual"
  [[ -n "${RUNTIME_VERSION:-}" ]] \
    || die "could not determine the version of '$RUNTIME'"
fi
RUNTIME_VERSION="${RUNTIME_VERSION:-unknown}"

# --- the run record must not claim a model the runtime was never told ------
# `runtime.model` is written from $AGENT_MODEL, which is what the CALLER asked for. Until
# 2026-08-28 the codex arm accepted --model and never forwarded it, so a run invoked with
# MODEL=x recorded model:x while codex used whatever ~/.codex/config.toml selected. That is
# not a missing control — it is a provenance field that is wrong in the direction that looks
# correct, on the experiment's own independent variable.
#
# This is the L2 half: something executes and refuses. Every non-manual arm forwards --model
# today; if one ever stops, this fails the run instead of recording the claim.
case "$RUNTIME" in
  copilot|claude|codex) MODEL_FORWARDED=true ;;
  *)                    MODEL_FORWARDED=false ;;
esac
if [[ -n "$AGENT_MODEL" && "$MODEL_FORWARDED" != true ]]; then
  die "--model '$AGENT_MODEL' is not forwarded to runtime '$RUNTIME'.
    Recording it would put a model in runtime.model that never ran."
fi

# --- 5. install and hash the customization (§12) ----------------------------
# The commit the *evaluation* measures against — always a setup commit, never the raw
# benchmark HEAD: the worktree has already had the authoring material stripped out of it,
# and a customized run adds the overlay on top. Both are starting state, not agent output.
EVAL_BASELINE_SHA="$STRIPPED_SHA"

if [[ -n "$CUSTOMIZATION_DIR" ]]; then
  [[ -d "$CUSTOMIZATION_DIR" ]] || die "customization directory not found: $CUSTOMIZATION_DIR"
  cp -R "$CUSTOMIZATION_DIR"/. "$WORKTREE"/ || die "failed to install customization"

  # Commit the overlay before the agent starts. Without this the customization files are
  # part of the diff, so the scope guard blames the agent for a change the *harness* made
  # — which failed every run of a treatment arm for a violation the agent never committed
  # and made the comparison meaningless. The customization is starting state, not output.
  git -C "$WORKTREE" add -A >/dev/null 2>&1
  git -C "$WORKTREE" -c user.email=runner@observatory -c user.name=observatory-runner \
      commit -qm "experiment setup: install customization for variant '${VARIANT}'" \
    || die "failed to commit the customization overlay"
  EVAL_BASELINE_SHA="$(git -C "$WORKTREE" rev-parse HEAD)"

  echo "  customization installed from ${CUSTOMIZATION_DIR}"
  echo "  evaluation baseline moved to ${EVAL_BASELINE_SHA:0:12} (setup commit)"

  # --- the treatment must be a file this runtime actually reads --------------
  # EXP-BE002-AGENTSMD-V3 installed AGENTS.md and ran it against Claude Code, which reads
  # CLAUDE.md. The file was copied, committed, hashed, and identical across all ten runs of
  # the treatment arm — so every check the harness had said the treatment was applied, and
  # the comparison was baseline against baseline. It was written up as the project's first
  # result before anyone noticed.
  #
  # Installing a file proves nothing about whether a model reads it. This asserts the
  # second thing, which is the only one the experiment depends on. Verified by controlled
  # test rather than from documentation: an identical instruction file is honoured under
  # one name and ignored under the other.
  #
  # A customization with no instruction file at all is allowed — skills, hooks and MCP
  # config are legitimate treatments. What is refused is an instruction file aimed at the
  # wrong runtime, which is indistinguishable from a working experiment once it is running.
  case "$RUNTIME" in
    claude)  INSTRUCTION_FILE="CLAUDE.md";  FOREIGN_INSTRUCTIONS=(AGENTS.md .github/copilot-instructions.md) ;;
    copilot) INSTRUCTION_FILE="AGENTS.md";  FOREIGN_INSTRUCTIONS=(CLAUDE.md) ;;
    codex)   INSTRUCTION_FILE="AGENTS.md";  FOREIGN_INSTRUCTIONS=(CLAUDE.md) ;;
    *)       INSTRUCTION_FILE="";           FOREIGN_INSTRUCTIONS=() ;;
  esac

  if [[ -n "$INSTRUCTION_FILE" ]]; then
    for foreign in "${FOREIGN_INSTRUCTIONS[@]}"; do
      if [[ -f "$WORKTREE/$foreign" && ! -f "$WORKTREE/$INSTRUCTION_FILE" ]]; then
        die "customization installs '${foreign}', which runtime '${RUNTIME}' does not read.
    It reads '${INSTRUCTION_FILE}'. The run would record an instructionsHash for a
    treatment the model never sees, and the arm would silently be a second baseline.
    Rename the file in ${CUSTOMIZATION_DIR}, or run this customization on the runtime
    it was written for."
      fi
    done
    if [[ -f "$WORKTREE/$INSTRUCTION_FILE" ]]; then
      echo "  instruction file ${INSTRUCTION_FILE} present — ${RUNTIME} reads this"
    fi
  fi
fi

hash_of() {
  local path="$WORKTREE/$1"
  [[ -f "$path" ]] || { echo "null"; return; }
  printf '"sha256:%s"' "$(shasum -a 256 "$path" | cut -c1-32)"
}
# Hash the file this runtime actually reads, not a fixed filename. Hashing AGENTS.md on a
# Claude run produced a stable, real-looking instructionsHash across a whole treatment arm
# for a file the model never opened, and that hash was then cited as evidence the treatment
# was applied consistently. A hash of the wrong file is worse than no hash: it is a
# provenance claim about something that had no effect.
case "$RUNTIME" in
  claude)  RUNTIME_INSTRUCTIONS="CLAUDE.md" ;;
  copilot|codex) RUNTIME_INSTRUCTIONS="AGENTS.md" ;;
  *)       RUNTIME_INSTRUCTIONS="AGENTS.md" ;;
esac
CUSTOMIZATION=$(jq -nc \
  --argjson instructions "$(hash_of "$RUNTIME_INSTRUCTIONS")" \
  --argjson skills "$(hash_of .github/skills.md)" \
  --argjson agent "$(hash_of .github/copilot-instructions.md)" \
  '{instructionsHash: $instructions, skillsHash: $skills, agentHash: $agent}')

# --- 6. OTel correlation ---------------------------------------------------
# shellcheck source=/dev/null
RUN_ID="$RUN_ID" BENCHMARK_ID="$BENCHMARK_ID" VARIANT="$VARIANT" \
  source "$HERE/lib/telemetry-env.sh" "$RUNTIME"

# --- 7/8. start the agent and wait -----------------------------------------
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_MS=$(( $(date +%s) * 1000 ))
# Deliberately outside the worktree: anything written inside it would be staged by the
# diff step and counted as a file the agent changed.
AGENT_LOG="${TMPDIR:-/tmp}/observatory-agent-${RUN_ID}.log"

echo
echo "--- task ------------------------------------------------------"
cat "$BENCH_DIR/task.md"
echo "---------------------------------------------------------------"
echo

case "$RUNTIME" in
  manual)
    # The OTel variables exported above live in *this* shell only, so a second terminal
    # would produce a run with no correlating telemetry. Hand them over explicitly.
    echo "Manual run. In another terminal:"
    echo
    echo "  cd $WORKTREE"
    echo "  export OTEL_RESOURCE_ATTRIBUTES='${OTEL_RESOURCE_ATTRIBUTES}'"
    echo "  export OTEL_EXPORTER_OTLP_ENDPOINT='${OTEL_EXPORTER_OTLP_ENDPOINT:-}'"
    echo
    echo "Apply the task above by hand (or drive an agent yourself), then return here."
    read -r -p "Press ENTER when the run is complete... " _
    ;;
  copilot)
    # A plain baseline means a *plain* agent: with no customization installed, custom
    # instruction files are disabled explicitly, otherwise a stray AGENTS.md anywhere in
    # scope would quietly contaminate the run that is supposed to be the control.
    COPILOT_ARGS=(--allow-all-tools --allow-all-paths --no-ask-user --no-color)
    [[ -n "$AGENT_MODEL" ]] && COPILOT_ARGS+=(--model "$AGENT_MODEL")
    [[ -z "$CUSTOMIZATION_DIR" ]] && COPILOT_ARGS+=(--no-custom-instructions)

    if [[ "$INTERACTIVE" == true ]]; then
      ( cd "$WORKTREE" && copilot "${COPILOT_ARGS[@]}" ) \
        || echo "run-agent: copilot exited non-zero — recording the run anyway"
    else
      ( cd "$WORKTREE" && copilot "${COPILOT_ARGS[@]}" --prompt "$(cat "$BENCH_DIR/task.md")" ) \
        2>&1 | tee "$AGENT_LOG" \
        || echo "run-agent: copilot exited non-zero — recording the run anyway"
    fi
    ;;
  claude)
    # Latitude must be explicit and equal to Copilot's, or the harness measures its own
    # configuration. It did: with only `--permission-mode acceptEdits`, edits were
    # auto-approved but the build was not, and the two models resolved that ambiguity
    # differently — haiku called the tool, sonnet stopped and asked a human who was not
    # there. Seven of ten sonnet runs never implemented anything and were recorded as
    # "incorrect code". permissionDenials was 0 throughout: nothing was refused, so no
    # telemetry showed it.
    #
    # The task tells the agent to run `./mvnw test` before finishing. An agent that cannot
    # do what the task instructs is not being measured on the task.
    #
    # --strict-mcp-config: without it the agent inherits whatever MCP servers the operator
    # has configured at user scope, so the "plain baseline" varies by machine and its tool
    # schemas inflate the context of every request — which lands on cost, the primary
    # metric. A benchmark run gets no MCP servers unless a customization supplies them.
    # --disable-slash-commands: the same argument as --strict-mcp-config, for the hole next
    # to it. Without it the agent loads the operator's user-scope plugins and their skills,
    # so a "plain baseline" carries whatever workflow tooling happens to be installed on the
    # machine. That is not hypothetical (harness bug #13): in EXP-BE002-CLAUDEMD a plugin
    # skill fired in 5 of 23 runs, and one of them wrote a planning document to
    # docs/superpowers/plans/ and changed no production file at all. The three contaminated
    # passing runs held the three highest tool counts in their arm, so the leak lands on
    # cost and tool calls — two of the registered outcomes.
    #
    # This does not isolate ~/.claude/settings.json; permission rules still leak. That is a
    # separate, narrower hole and it is tracked, not fixed here.
    CLAUDE_ARGS=(
      --permission-mode acceptEdits
      --strict-mcp-config
      --disable-slash-commands
      --allowedTools "Bash(./mvnw:*)" "Bash(mvn:*)"
    )
    # --setting-sources project: load project settings only, so ~/.claude/settings.json and
    # the 21 hooks registered in it never reach the agent. Verified not to disturb CLAUDE.md
    # discovery, which matters because that file *is* the treatment — unlike --bare, which
    # would switch the treatment off along with the hooks.
    [[ "$ISOLATE_USER_SETTINGS" == true ]] && CLAUDE_ARGS+=(--setting-sources project)
    [[ -n "$AGENT_MODEL" ]] && CLAUDE_ARGS+=(--model "$AGENT_MODEL")
    if [[ "$INTERACTIVE" == true ]]; then
      ( cd "$WORKTREE" && claude "${CLAUDE_ARGS[@]}" ) \
        || echo "run-agent: claude exited non-zero — recording the run anyway"
    else
      ( cd "$WORKTREE" && claude "${CLAUDE_ARGS[@]}" -p "$(cat "$BENCH_DIR/task.md")" ) \
        2>&1 | tee "$AGENT_LOG" \
        || echo "run-agent: claude exited non-zero — recording the run anyway"
    fi
    ;;
  codex)
    # PARITY WITH THE OTHER TWO ARMS, and every flag below has an analogue there. Until
    # 2026-08-28 this arm was `codex exec "$(cat task.md)"` and nothing else: no model, no
    # sandbox policy, no isolation. It had never run, so nothing on record is affected —
    # which is exactly why it had to change before the first codex run rather than after.
    #
    #   --sandbox danger-full-access   the analogue of copilot's --allow-all-paths and of
    #                                  claude running unsandboxed under acceptEdits. NOT a
    #                                  convenience: the task instructs the agent to run
    #                                  ./mvnw test, and Maven writes to ~/.m2 and fetches
    #                                  over the network. Under workspace-write this arm
    #                                  would fail the build for a reason the other two never
    #                                  meet, and the evaluator would record it as incorrect
    #                                  code. Approval policy is already `never` in exec
    #                                  mode, so no approval flag is needed to keep it
    #                                  headless.
    #   --color never                  copilot's --no-color
    #   --model                        pinned, as on both other arms
    #
    # NOT --approve-for-me: it adds an automatic reviewer the other arms do not have, which
    # is a behaviour change wearing an isolation flag's clothes.
    CODEX_ARGS=(--sandbox danger-full-access --color never)
    [[ -n "$AGENT_MODEL" ]] && CODEX_ARGS+=(--model "$AGENT_MODEL")

    # ISOLATION IS AN ENVIRONMENT, NOT A FLAG, AND THAT WAS MEASURED RATHER THAN READ.
    # `--ignore-user-config` says only "do not load $CODEX_HOME/config.toml". Tested
    # 2026-08-28 with a marker instruction in $CODEX_HOME/AGENTS.md: with the flag, the
    # model still emitted the marker. Global instructions survive it. With CODEX_HOME
    # pointed at a directory holding auth.json alone, the marker was gone.
    #
    # That matters here because ~/.codex on this operator's machine carries AGENTS.md
    # (importing a 32-line shell-routing instruction file), 3 MCP servers — one of them a
    # code-search tool — 71 skills, 66 agents, 2 hooks and a plugin. A "plain baseline" run
    # would carry a global instruction file, which is B3's treatment sitting inside B2's
    # control.
    #
    # This is L2, not L1: nothing stops someone writing an AGENTS.md into this directory
    # after it is built. What makes it a control is that the runner rebuilds it per run and
    # asserts its contents below.
    CODEX_HOME_ISOLATED=""
    if [[ "$ISOLATE_USER_SETTINGS" == true ]]; then
      CODEX_HOME_ISOLATED="${WORKTREE}.codex-home"
      rm -rf "$CODEX_HOME_ISOLATED"
      mkdir -p "$CODEX_HOME_ISOLATED"
      if [[ -r "${CODEX_HOME:-$HOME/.codex}/auth.json" ]]; then
        cp "${CODEX_HOME:-$HOME/.codex}/auth.json" "$CODEX_HOME_ISOLATED/auth.json"
      else
        die "codex isolation needs auth.json from ${CODEX_HOME:-$HOME/.codex}; not found"
      fi
      # A REGRESSION GUARD ON THIS FUNCTION, not a control over the operator's machine —
      # said plainly because this project has repeatedly mistaken one for the other. The
      # directory was created three lines up, so today the loop cannot fire. It fires when
      # someone later adds a second `cp` here, which is the realistic way this isolation
      # gets undone.
      for forbidden in AGENTS.md config.toml instructions.md; do
        [[ -e "$CODEX_HOME_ISOLATED/$forbidden" ]] \
          && die "isolated CODEX_HOME contains $forbidden — refusing to record this as an isolated run"
      done
      echo "  codex isolated: CODEX_HOME=$CODEX_HOME_ISOLATED (auth.json only)"
    fi

    # HOME REDIRECTION — observatory#65. THIS IS L2 AND SAYING SO IS THE POINT.
    #
    # A clean CODEX_HOME stops global instructions AUTO-LOADING. It does nothing about an
    # agent that goes and READS instructions itself, and on 2026-08-30 every one of the
    # seven codex runs on record did exactly that: `sed -n '1,240p'
    # ~/.agents/skills/memtrace-first/SKILL.md` as its first action, before touching the
    # worktree. A run labelled plain baseline pulled ~240 lines of operator methodology into
    # context and announced it would follow it.
    #
    # MEASURED 2026-09-01, POSITIVE CONTROL FIRST, because a one-sided test passes when the
    # sandbox is simply broken:
    #   danger-full-access, real HOME  -> agent read the operator's skills. Probe works.
    #   workspace-write,    real HOME  -> agent read them ANYWAY. Sandbox mode is not the fix;
    #                                     workspace-write restricts writes, not reads.
    #   workspace-write,    HOME here  -> agent found none of them.
    # Given a discovery prompt with no path in it, the unredirected agent enumerated the
    # whole of ~/.codex/skills (gsd-undo, gsd-update, gsd-verify-work, ...), so the two
    # memtrace files in #65 were what one run reached for, not the extent of what is
    # reachable.
    #
    # WHAT THIS DOES AND DOES NOT BUY, stated because this project has mistaken the two
    # five times now. It makes the operator's files UNDISCOVERABLE: `~` no longer resolves
    # there. It does NOT make them UNREACHABLE: /Users/<op>/... still exists and is still
    # readable by an agent that constructs the path another way. This is a control at L2.
    # Do not let a later reader take it for isolation.
    #
    # ~/.m2 IS LINKED AND THAT IS A DELIBERATE HOLE. The task instructs `./mvnw test`;
    # maven's repository is 8.5 GB on this machine and a bare HOME would re-download it per
    # run, changing duration by orders of magnitude and failing the build for a reason the
    # other arms never meet. A dependency cache is a build artefact, not an instruction
    # channel — but it is a path back into the operator's home and it is named here rather
    # than hidden. Nothing else is linked.
    AGENT_HOME_ISOLATED=""
    if [[ "$ISOLATE_USER_SETTINGS" == true ]]; then
      AGENT_HOME_ISOLATED="${WORKTREE}.home"
      rm -rf "$AGENT_HOME_ISOLATED"
      mkdir -p "$AGENT_HOME_ISOLATED"
      [[ -d "$HOME/.m2" ]] && ln -s "$HOME/.m2" "$AGENT_HOME_ISOLATED/.m2"
      # Same regression guard as above, same honest scope: it protects this function against
      # a later edit that links something carrying instructions. It is not a control over
      # what the operator has on disk.
      for forbidden in .agents .codex .claude .config AGENTS.md CLAUDE.md .cursorrules; do
        [[ -e "$AGENT_HOME_ISOLATED/$forbidden" ]] \
          && die "isolated HOME contains $forbidden — refusing to record this as an isolated run"
      done
      echo "  codex isolated: HOME=$AGENT_HOME_ISOLATED (.m2 symlink only) — L2, see #65"
    fi

    # Exported inside the subshell rather than through an env array: an empty array under
    # `set -u` is an error on bash before 4.4, and this script's shebang does not pin one.
    if [[ "$INTERACTIVE" == true ]]; then
      (
        cd "$WORKTREE" || exit 1
        [[ -n "$CODEX_HOME_ISOLATED" ]] && export CODEX_HOME="$CODEX_HOME_ISOLATED"
        [[ -n "$AGENT_HOME_ISOLATED" ]] && export HOME="$AGENT_HOME_ISOLATED"
        codex "${CODEX_ARGS[@]}"
      ) || echo "run-agent: codex exited non-zero — recording the run anyway"
    else
      (
        cd "$WORKTREE" || exit 1
        [[ -n "$CODEX_HOME_ISOLATED" ]] && export CODEX_HOME="$CODEX_HOME_ISOLATED"
        # HOME is exported AFTER CODEX_HOME so the latter keeps pointing at the built
        # directory rather than re-deriving from the new HOME.
        [[ -n "$AGENT_HOME_ISOLATED" ]] && export HOME="$AGENT_HOME_ISOLATED"
        codex exec "${CODEX_ARGS[@]}" "$(cat "$BENCH_DIR/task.md")"
      ) 2>&1 | tee "$AGENT_LOG" \
        || echo "run-agent: codex exited non-zero — recording the run anyway"
    fi
    ;;
esac

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DURATION_MS=$(( $(date +%s) * 1000 - START_MS ))

# --- 9. record diff --------------------------------------------------------
# Everything is staged first and compared against the *baseline commit*, not the working
# tree. Agents routinely create new files (BE-001 asks for a new test) and often commit
# their work; both are invisible to a plain `git diff`, which would silently report
# addedLines/deletedLines as 0 while changedFiles listed the file — two contradictory
# fields, and a headline metric reading zero. The worktree is disposable, so staging is free.
git -C "$WORKTREE" add -A >/dev/null 2>&1 || true

CHANGED_FILES=$(git -C "$WORKTREE" diff --name-only --cached "$EVAL_BASELINE_SHA" \
  | jq -R . | jq -sc 'map(select(length>0))')
read -r ADDED DELETED <<<"$(git -C "$WORKTREE" diff --numstat --cached "$EVAL_BASELINE_SHA" \
  | awk '$1 ~ /^[0-9]+$/ {a+=$1; d+=$2} END {print (a+0), (d+0)}')"

echo
echo "--- diff ------------------------------------------------------"
git -C "$WORKTREE" diff --stat --cached "$EVAL_BASELINE_SHA" || true
echo "---------------------------------------------------------------"

# --- 9a. did the agent actually run? ---------------------------------------
# A quota exhaustion, auth expiry or rate limit produces an empty diff, which the
# evaluator can only see as "acceptance suite failed" and classifies as F03 (incorrect
# code). That is a lie about the agent and it poisons any comparison the run appears in:
# an exhausted quota would show up as the variant being less correct. The runner knows
# better, because it can see the agent never did anything.
#
# The signature list below is deliberately about the *environment*, never about the agent.
# A dropped connection, an exhausted quota and an expired token are all things that happen
# to the run; none of them is evidence about the variant. An agent that stops to ask a
# question is the opposite — that is behaviour, it may be caused by the thing under test,
# and it must keep counting against the arm it happened in. Do not add a "the agent asked
# something" pattern here: it would only ever delete runs from whichever arm makes the
# agent more deliberative, which is bias in the flattering direction.
#
# The match is gated on the agent having produced nothing. A run that finished the task and
# merely mentioned "API error" somewhere in its narration is not an aborted run, and keying
# on the log alone would misclassify it.
INFRA_SIGNATURE="no quota|quota exceeded|rate limit|too many requests|not authenticated"
INFRA_SIGNATURE="${INFRA_SIGNATURE}|401 unauthorized|api error|connection closed|connection reset"
INFRA_SIGNATURE="${INFRA_SIGNATURE}|502 bad gateway|503 service unavailable|overloaded_error|network error"
INFRA_SIGNATURE="${INFRA_SIGNATURE}|session limit|usage limit|limit reached|insufficient credit"

AGENT_ABORTED=false
ABORT_REASON=""
# F13 is "timeout/rate limit", F15 is "evaluator/infrastructure". Both are excluded from
# comparisons; which one is recorded is a statement about what went wrong, and the taxonomy
# is worth nothing if it is not accurate.
ABORT_CLASS="F13"
PRODUCED_NOTHING=false
[[ "$(jq -r 'length' <<<"$CHANGED_FILES")" == "0" ]] && PRODUCED_NOTHING=true

if [[ "$RUNTIME" != "manual" && -f "$AGENT_LOG" && "$PRODUCED_NOTHING" == true ]]; then
  if grep -qiE "$INFRA_SIGNATURE" "$AGENT_LOG"; then
    AGENT_ABORTED=true
    ABORT_REASON="$(grep -ioE "$INFRA_SIGNATURE" "$AGENT_LOG" | head -1)"
  fi
fi

# --- 9b. normalize vendor telemetry into our model (§35) --------------------
BEHAVIOR='{}'
EFFICIENCY_EXTRA='{}'
TRACE_ID=""

# CODEX REPORTS ONE NUMBER, AND IT WAS BEING THROWN AWAY.
# `codex exec` has no OTel path (ADR-001, #10), so this arm records null tokens and null
# cost — while printing its own total on the last line of the log:
#
#     tokens used
#     32 386
#
# That is not telemetry parity and it is not pretending to be: no input/output split, no
# cache figures, no cost. It is the one number the runtime states, and recording it beats
# recording nothing while the arm sits next to one reporting 8876 output tokens and $0.185.
#
# It lands in `reportedTotalTokens`, its own field (V5), NOT in outputTokens. Putting a
# total where a component belongs is the V4 mistake wearing a different name — a field that
# means one thing carrying a value that means another, in the direction that looks like data.
if [[ "$RUNTIME" == "codex" && -f "$AGENT_LOG" ]]; then
  # The count follows the label on the next line, and codex writes thousands separated by a
  # space ("32 386"), so the digits are joined rather than read as the first group.
  codex_tokens="$(awk '/^tokens used$/ { getline; gsub(/[^0-9]/, "", $0); if ($0 != "") print $0; exit }' "$AGENT_LOG")"
  if [[ -n "$codex_tokens" ]]; then
    EFFICIENCY_EXTRA="$(jq -cn --argjson t "$codex_tokens" '{reportedTotalTokens: $t}')"
    echo "    codex reported ${codex_tokens} tokens (total only — no split, no cost)"
  else
    echo "    codex reported no token total in its log" >&2
  fi
fi

if [[ "$RUNTIME" == "copilot" || "$RUNTIME" == "claude" ]]; then
  echo
  if [[ "$RUNTIME" == "copilot" ]]; then
    echo "==> reading telemetry back from Tempo"
    TELEMETRY="$(TEMPO_URL="$TEMPO_URL" "$HERE/lib/copilot-telemetry.sh" "$RUN_ID" || echo null)"
  else
    # Claude reports events, not spans — a different source, the same internal model.
    echo "==> reading telemetry back from the collector's event log"
    TELEMETRY="$("$HERE/lib/claude-telemetry.sh" "$RUN_ID" || echo null)"
  fi
  if [[ -n "$TELEMETRY" && "$TELEMETRY" != "null" ]]; then
    BEHAVIOR="$(jq -c '.behavior' <<<"$TELEMETRY")"
    EFFICIENCY_EXTRA="$(jq -c '.efficiency' <<<"$TELEMETRY")"
    TRACE_ID="$(jq -r '.traceId // empty' <<<"$TELEMETRY")"
    jq -r '"    model calls \(.behavior.modelCalls)   tool calls \(.behavior.toolCalls)   " +
           "tokens ↑\(.efficiency.inputTokens) ↓\(.efficiency.outputTokens)"' <<<"$TELEMETRY"
    jq -r '.toolBreakdown[] | "    \(.calls)× \(.tool)"' <<<"$TELEMETRY"

    # The leak this asserts against was found by reading what runs actually did, after a
    # flag was already believed to close it. A fix is confirmed by the symptom failing to
    # reappear, not by the story that motivated it — so the symptom is checked on every run
    # from now on. If a skill executes despite --disable-slash-commands, the run measured
    # the operator's plugins as well as the variant, and it is not evidence about either.
    # The signature list above is a convenience for *naming* the cause, and it will always
    # be incomplete: it was extended for "API Error" and the very next batch died on
    # "You've hit your session limit", a phrase it did not contain. Sixteen runs recorded
    # F03 "incorrect code" for a billing state. That is the fourth costume of the same bug,
    # and the fourth time it was fixed per-phrase instead of per-class.
    #
    # So the deciding rule is not a phrase. An agent that changed no file *and called no
    # tool* did not attempt the task and cannot have failed it — nothing it did was
    # measured, because it did nothing. Whatever stopped it was environmental by
    # construction. This needs no vocabulary and does not go stale.
    #
    # It stays narrow on purpose. A run that explored and then stalled has tool calls, so it
    # is untouched and keeps counting against its arm — which is what must happen when the
    # thing under test is what made the agent hesitate.
    TOOL_CALLS_SEEN="$(jq -r '.behavior.toolCalls // 0' <<<"$TELEMETRY")"
    MODEL_CALLS_SEEN="$(jq -r '.behavior.modelCalls // 0' <<<"$TELEMETRY")"
    if [[ "$PRODUCED_NOTHING" == true && "${TOOL_CALLS_SEEN:-0}" -eq 0 && "$AGENT_ABORTED" != true ]]; then
      AGENT_ABORTED=true
      ABORT_CLASS="F13"
      ABORT_REASON="the agent changed no file and called no tool — it never acted"
    # Amendment 1(3), the other half. A run that *did* change files but reports zero model
    # calls and zero tool calls did not run for free — the collector missed it. Cost and tool
    # calls are registered outcomes, so this run has no measurement of the things being
    # compared, whatever its diff looks like. Entering it as a zero would read as the
    # cheapest run in its arm, and an outage landing in one arm would look like an efficiency
    # win. Caught here rather than only in the analyser so it is replaced, not merely refused.
    elif [[ "${TOOL_CALLS_SEEN:-0}" -eq 0 && "${MODEL_CALLS_SEEN:-0}" -eq 0 && "$AGENT_ABORTED" != true ]]; then
      AGENT_ABORTED=true
      ABORT_CLASS="F15"
      ABORT_REASON="telemetry reports 0 model calls and 0 tool calls for a run that changed files — the collector missed it"
    fi

    SKILL_CALLS="$(jq -r '[.toolBreakdown[]? | select(.tool == "Skill") | .calls] | add // 0' <<<"$TELEMETRY")"
    if [[ "${SKILL_CALLS:-0}" -gt 0 ]]; then
      AGENT_ABORTED=true
      ABORT_CLASS="F15"
      ABORT_REASON="a plugin skill executed ${SKILL_CALLS}× despite --disable-slash-commands (harness bug #13)"
      echo
      echo "  !! CONTAMINATED: ${ABORT_REASON}"
      echo "     The agent had tooling this experiment did not give it. Recorded as"
      echo "     infrastructure so it is excluded and replaced, not averaged in."
    fi
  else
    echo "    no telemetry found — behaviour metrics stay empty rather than guessed"
    # Amendment 1(3): missing telemetry is not a measurement of zero. Combined with an empty
    # diff there is nothing here to score either way, so the run is excluded rather than
    # entered as a maximally cheap failure.
    if [[ "$PRODUCED_NOTHING" == true && "$AGENT_ABORTED" != true ]]; then
      AGENT_ABORTED=true
      ABORT_CLASS="F15"
      ABORT_REASON="no telemetry and no file changed — nothing about this run was measured"
    fi
  fi
fi

# --- 10. deterministic evaluator -------------------------------------------
EVALUATION_JSON="${WORKTREE}/evaluation.json"
echo
"$BENCH_DIR/evaluator.sh" \
  --baseline "$EVAL_BASELINE_SHA" \
  --service "$WORKTREE/sample-service" \
  --out "$EVALUATION_JSON" \
  --run-id "$RUN_ID"
EVAL_EXIT=$?
echo "evaluator exit code: ${EVAL_EXIT}"

# --- 11. persist -----------------------------------------------------------
echo
echo "==> registering benchmark and run with the Observatory"

BENCH_YAML="$BENCH_DIR/benchmark.yaml"
BENCH_NAME=$(awk -F': *' '/^name:/{print $2; exit}' "$BENCH_YAML")
BENCH_CATEGORY=$(awk -F': *' '/^category:/{print $2; exit}' "$BENCH_YAML")
EVALUATOR_VERSION=$(awk -F': *' '/^evaluator_version:/{print $2; exit}' "$BENCH_YAML")

# Must succeed: a run for an unregistered benchmark is rejected with 404, which would
# otherwise surface later as a misleading "failed to persist the run".
curl -fsS -X POST "${API}/api/benchmarks" -H 'Content-Type: application/json' -d "$(jq -nc \
  --arg id "$BENCHMARK_ID" --arg name "${BENCH_NAME:-$BENCHMARK_ID}" \
  --arg category "${BENCH_CATEGORY:-bugfix}" \
  --arg prompt "$(cat "$BENCH_DIR/task.md")" \
  --arg evaluatorVersion "${EVALUATOR_VERSION:-1.0.0}" \
  --arg baseline "$BASELINE_SHA" \
  '{id:$id, name:$name, category:$category, repository:"sample-service",
    prompt:$prompt, evaluatorVersion:$evaluatorVersion, baselineCommit:$baseline}')" >/dev/null \
  || die "failed to register benchmark '$BENCHMARK_ID' with ${API}"

RUN_PAYLOAD=$(jq -nc \
  --arg runId "$RUN_ID" --arg exp "$EXPERIMENT" --arg bench "$BENCHMARK_ID" \
  --arg variant "$VARIANT" --arg started "$STARTED_AT" --arg finished "$FINISHED_AT" \
  --arg provider "$PROVIDER" --arg product "$PRODUCT" --arg version "$RUNTIME_VERSION" \
  --arg model "${AGENT_MODEL:-auto}" --arg sha "$BASELINE_SHA" \
  --argjson customization "$CUSTOMIZATION" \
  --argjson duration "$DURATION_MS" --argjson changed "$CHANGED_FILES" \
  --argjson added "${ADDED:-0}" --argjson deleted "${DELETED:-0}" \
  --argjson behavior "$BEHAVIOR" --argjson efficiencyExtra "$EFFICIENCY_EXTRA" \
  --arg traceId "$TRACE_ID" \
  '{
    runId:$runId, experimentId:$exp, benchmarkId:$bench, variant:$variant,
    startedAt:$started, finishedAt:$finished,
    runtime:{provider:$provider, product:$product, version:$version, model:$model},
    repository:{commitSha:$sha, dirtyBeforeRun:false},
    customization:$customization,
    behavior:$behavior,
    efficiency:({durationMs:$duration} + $efficiencyExtra),
    result:{changedFiles:$changed, addedLines:$added, deletedLines:$deleted},
    traceId:(if $traceId == "" then null else $traceId end),
    telemetryQueryKey:("{ resource.observatory.run.id = \"" + $runId + "\" }")
  }')

curl -fsS -X POST "${API}/api/runs" -H 'Content-Type: application/json' \
  -d "$RUN_PAYLOAD" >/dev/null || die "failed to persist the run"

if [[ -s "$EVALUATION_JSON" ]]; then
  EVAL_PAYLOAD="$(jq -c "$EVALUATION_PAYLOAD_FILTER" "$EVALUATION_JSON")"

  # §23: F13 is "timeout/rate limit", not F03 "incorrect code". Recording the true cause
  # is the whole point of having a taxonomy instead of a FAIL counter.
  if [[ "$AGENT_ABORTED" == true ]]; then
    EVAL_PAYLOAD="$(jq -c --arg c "$ABORT_CLASS" '.failureClass = $c | .passed = false' <<<"$EVAL_PAYLOAD")"
    echo
    echo "  !! this run is not evidence about the variant: ${ABORT_REASON}"
    echo "     recorded as ${ABORT_CLASS} (infrastructure), not F03 (incorrect code)."
    echo "     EXCLUDE this run from comparisons — it measures your quota, not the variant."
  fi

  curl -fsS -X POST "${API}/api/runs/${RUN_ID}/evaluation" -H 'Content-Type: application/json' \
    -d "$EVAL_PAYLOAD" >/dev/null \
    || die "failed to persist the evaluation"
else
  echo "  warning: evaluator produced no evaluation.json — run recorded without a verdict" >&2
fi

echo
echo "  run recorded:  ${API}/api/runs/${RUN_ID}"
echo "  UI:            ${WEB}/runs/${RUN_ID}"
echo "  trace search:  { resource.observatory.run.id = \"${RUN_ID}\" }"
exit "$EVAL_EXIT"
