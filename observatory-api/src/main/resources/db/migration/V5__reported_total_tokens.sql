-- A runtime that reports one total and no breakdown had nowhere to put it.
--
-- `totalTokens()` is derived as input + output. Codex reports neither: `codex exec` prints a
-- single `tokens used` line and nothing else, so the B2 codex arm recorded null tokens and
-- null cost while the claude arm recorded 8876 output tokens and $0.185 — and the number was
-- sitting in the agent log the whole time (32386 on run 514b094e).
--
-- The wrong fix is to put a total into output_tokens. That is the same class of error as
-- V4's zeros: a field that means one thing carrying a value that means another, in the
-- direction that looks like data. This adds the field the runtime actually reports.
--
-- Nullable, and expected to stay null on every runtime that reports a real breakdown —
-- there, input + output IS the total and a second copy could disagree with it.
ALTER TABLE agent_run ADD COLUMN reported_total_tokens bigint;

COMMENT ON COLUMN agent_run.reported_total_tokens IS
  'A total reported directly by the runtime, for runtimes that give no input/output split. '
  'Null when the runtime reports a breakdown; totalTokens() prefers the breakdown.';
