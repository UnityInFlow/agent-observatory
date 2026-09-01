-- A behaviour counter of 0 and an absent measurement were the same value.
--
-- These six columns were `not null default 0`, so a run whose telemetry was never collected
-- was stored as a run that made zero model calls and zero tool calls. The codex arm has no
-- telemetry path at all — `run-agent.sh` fills BehaviorMetrics only for copilot and claude —
-- so every codex run recorded a complete-looking set of zeros. Measured 2026-08-29 on the
-- first codex run ever recorded: two files changed, 64 lines added, `modelCalls: 0`.
--
-- The same row already reported `null` for the equivalent missing efficiency fields. One
-- absent measurement was honest and the other was a number that reads like data, inside one
-- object.
--
-- This is the same rule V3 applied to task_attempted, and the same rule the lab repo
-- enforces on its scorer: a missing cell is not a null cell. A zero is a claim.
ALTER TABLE agent_run
    ALTER COLUMN model_calls         DROP NOT NULL,
    ALTER COLUMN tool_calls          DROP NOT NULL,
    ALTER COLUMN tool_failures       DROP NOT NULL,
    ALTER COLUMN retries             DROP NOT NULL,
    ALTER COLUMN permission_requests DROP NOT NULL,
    ALTER COLUMN permission_denials  DROP NOT NULL;

ALTER TABLE agent_run
    ALTER COLUMN model_calls         DROP DEFAULT,
    ALTER COLUMN tool_calls          DROP DEFAULT,
    ALTER COLUMN tool_failures       DROP DEFAULT,
    ALTER COLUMN retries             DROP DEFAULT,
    ALTER COLUMN permission_requests DROP DEFAULT,
    ALTER COLUMN permission_denials  DROP DEFAULT;

-- BACKFILL, and the predicate is not invented here.
--
-- `runner/analyze-experiment.py` has carried `has_behavior_telemetry()` since before this
-- migration: it treats modelCalls == 0 AND toolCalls == 0 as missing telemetry rather than
-- as a very efficient run, "otherwise an outage concentrated in one arm reads as an
-- improvement, which is the direction of error this project keeps making." The analysis
-- layer was already correcting the record. This moves the correction into the record so the
-- heuristic is not duplicated in every future reader — the API, the web UI and Prometheus
-- were all still reading the zeros literally.
--
-- An agent run with no model calls and no tool calls did not happen, so nothing that could
-- be a genuine measurement is lost. Rows where the agent demonstrably worked are the
-- clearest case: 2026-08-29 this affected three rows with changed files and all-zero
-- counters, one of them the codex rehearsal.
UPDATE agent_run
SET model_calls         = NULL,
    tool_calls          = NULL,
    tool_failures       = NULL,
    retries             = NULL,
    permission_requests = NULL,
    permission_denials  = NULL
WHERE model_calls = 0
  AND tool_calls = 0
  AND tool_failures = 0
  AND retries = 0
  AND permission_requests = 0
  AND permission_denials = 0;
