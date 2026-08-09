-- Cache reads and cache creations are priced differently and behave differently: a fresh
-- AGENTS.md lands almost entirely in *creation* on the first request of a run, then in
-- reads for the rest of it. Folding them into one column would hide exactly the signal an
-- instruction-file experiment is looking for, so they are recorded separately.
--
-- Nullable, like every other token column: a runtime that reports nothing must record
-- nothing rather than a zero that reads as a measurement.
ALTER TABLE agent_run ADD COLUMN cache_creation_tokens bigint;
