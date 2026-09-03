-- The record could not tell two different experiments apart, and twice it did not.
--
-- 1. 2026-08-29: a cmux terminal shim in front of the real CLI appended `--settings` with
--    12 hooks. Measured: shim present -> 26 hook executions per run; shim stripped -> 0.
--    The runner strips it now and prints that it did. The RECORD kept no trace, so run
--    092a384a and the 172 runs before it are indistinguishable rows.
-- 2. 2026-09-01 (#65): every codex run opened by reading ~240 lines of the operator's
--    skills, while customization.{instructions,skills,mcp}Hash were all null — which every
--    consumer reads as "uncustomized". The transcript said otherwise and nothing else did.
--
-- Both facts existed at run time and were thrown away. These columns keep them.
--
-- NULLABLE, AND THAT IS THE WHOLE DESIGN. The 172 runs already on record were taken before
-- anything measured this, so they are null: not measured. `false` would be a claim — "we
-- looked, and it was not isolated" — about runs where nobody looked. That is V4's mistake
-- (a collector gap stored as a genuine zero) and it is not being repeated one migration
-- later.
ALTER TABLE agent_run ADD COLUMN user_settings_isolated boolean;
ALTER TABLE agent_run ADD COLUMN shims_stripped         boolean;
ALTER TABLE agent_run ADD COLUMN agent_surface          text;

COMMENT ON COLUMN agent_run.user_settings_isolated IS
  'Was the runtime launched with the operators user-scope settings excluded? '
  'Null on every run recorded before 2026-09-01: not measured, not "no".';

COMMENT ON COLUMN agent_run.shims_stripped IS
  'Did the runner remove a terminal CLI shim from PATH before resolving the binary? '
  'True means a wrapper was there and was taken out; false means none was found. '
  'Null on runs recorded before this was captured.';

COMMENT ON COLUMN agent_run.agent_surface IS
  'What the runtime brought with it, MEASURED after the run rather than declared - for '
  'codex, the skills it seeds into its own home and the plugins it installs from the '
  'network, with versions. Evidence for telling two runs apart, not a control: nothing '
  'refuses a run on this value. Null where the runtime offers nothing to enumerate.';
