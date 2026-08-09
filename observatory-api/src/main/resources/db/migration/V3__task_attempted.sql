-- Whether the agent changed any production file at all.
--
-- Nullable deliberately. Runs recorded before the evaluator emitted this say nothing about
-- it, and "we do not know" must not be storable as "the task was not attempted" — that
-- would condemn every historical row. Only an explicit FALSE means the agent produced no
-- implementation, which the analysis layer refuses to average into a result.
ALTER TABLE evaluation
    ADD COLUMN task_attempted BOOLEAN,
    ADD COLUMN production_files_changed INTEGER;
