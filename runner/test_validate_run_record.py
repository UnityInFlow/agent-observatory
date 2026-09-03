#!/usr/bin/env python3
"""
Tests for the run-record validator that #53 makes executable.

    python3 -m unittest discover -s runner -p 'test_*.py'

The point of these is narrow and worth stating. `run.schema.json` was correct-looking and
loaded by nothing, and it drifted three migrations behind the payload without a single
failure anywhere. A validator with no tests would be the same artifact one layer down, so
the cases that matter most here are the ones asserting a bad record is REFUSED — a validator
that accepts everything passes every happy-path test ever written for it.

`test_the_schema_on_main_would_have_rejected_a_current_record` is the finding itself, pinned:
it reconstructs the pre-fix schema and asserts it rejects a record the runner produces today.
"""
import copy
import importlib.util
import json
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "validate_run_record", pathlib.Path(__file__).with_name("validate-run-record.py")
)
vr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vr)

SCHEMA_PATH = pathlib.Path(__file__).with_name("schemas") / "run.schema.json"
SCHEMA = json.loads(SCHEMA_PATH.read_text())


def record(**overrides):
    """A record in the shape `run-agent.sh` actually POSTs, codex arm."""
    base = {
        "runId": "3f6c1a2e-1111-4222-8333-444455556666",
        "experimentId": "EXP-BE002",
        "benchmarkId": "BE-001",
        "variant": "baseline",
        "startedAt": "2026-09-02T10:00:00Z",
        "finishedAt": "2026-09-02T10:01:20Z",
        "runtime": {
            "provider": "openai", "product": "codex", "version": "0.9.1", "model": "auto",
            "userSettingsIsolated": True, "shimsStripped": True,
            "surface": "systemSkills=none; remotePlugins=none",
        },
        "repository": {"commitSha": "abc123", "dirtyBeforeRun": False},
        "customization": {"instructionsHash": None, "skillsHash": None, "agentHash": None},
        "behavior": {},
        "efficiency": {"durationMs": 80_000, "reportedTotalTokens": 32_386},
        "result": {"changedFiles": ["a.kt"], "addedLines": 3, "deletedLines": 1},
        "traceId": None,
        "telemetryQueryKey": '{ resource.observatory.run.id = "x" }',
    }
    base.update(overrides)
    return base


class AcceptsWhatTheRunnerSends(unittest.TestCase):
    def test_a_codex_record_validates(self):
        self.assertEqual(vr.validate(record(), SCHEMA), [])

    def test_a_claude_record_with_full_telemetry_validates(self):
        r = record()
        r["runtime"] = {"provider": "anthropic", "product": "claude-code",
                        "version": "2.1.0", "model": "claude-opus-5",
                        "userSettingsIsolated": False, "shimsStripped": True, "surface": None}
        r["behavior"] = {"modelCalls": 12, "toolCalls": 30, "toolFailures": 0,
                         "retries": 0, "permissionRequests": 2, "permissionDenials": 0}
        r["efficiency"] = {"durationMs": 149_000, "inputTokens": 900, "outputTokens": 8876,
                           "cachedTokens": 571_000, "cacheCreationTokens": 5300,
                           "estimatedCost": 0.1487}
        self.assertEqual(vr.validate(r, SCHEMA), [])

    def test_nulls_are_accepted_where_the_runtime_exposes_nothing(self):
        """A null is a measurement — 'the runtime does not expose this' — and must not be
        confused with a violation. V4 exists because zero was standing in for it."""
        r = record()
        r["runtime"]["version"] = None
        r["efficiency"] = {"durationMs": 80_000, "inputTokens": None, "outputTokens": None,
                           "estimatedCost": None, "reportedTotalTokens": None}
        self.assertEqual(vr.validate(r, SCHEMA), [])


class RefusesWhatIsWrong(unittest.TestCase):
    def test_a_missing_required_property_is_refused(self):
        r = record()
        del r["runtime"]
        self.assertIn("missing required property 'runtime'", " ".join(vr.validate(r, SCHEMA)))

    def test_an_unknown_property_is_refused(self):
        """additionalProperties is false everywhere on purpose: a field the schema has never
        heard of is either a typo or a migration nobody added here."""
        r = record()
        r["efficiency"]["totalTokens"] = 500
        self.assertIn("unexpected property 'totalTokens'", " ".join(vr.validate(r, SCHEMA)))

    def test_a_negative_measurement_is_refused(self):
        r = record()
        r["efficiency"]["durationMs"] = -5
        self.assertIn("below the minimum 0", " ".join(vr.validate(r, SCHEMA)))

    def test_a_string_where_an_integer_belongs_is_refused(self):
        r = record()
        r["result"]["addedLines"] = "three"
        self.assertIn("expected integer, got str", " ".join(vr.validate(r, SCHEMA)))

    def test_a_boolean_is_not_an_integer(self):
        """True is an int in Python and is not an integer in JSON. A counter carrying True
        would otherwise validate and land in the database as 1."""
        r = record()
        r["behavior"]["toolCalls"] = True
        self.assertIn("expected integer, got bool", " ".join(vr.validate(r, SCHEMA)))

    def test_a_wrongly_typed_array_item_is_refused(self):
        r = record()
        r["result"]["changedFiles"] = ["a.kt", 7]
        self.assertIn("$.result.changedFiles[1]", " ".join(vr.validate(r, SCHEMA)))

    def test_every_violation_is_reported_not_just_the_first(self):
        """One run of the validator should name everything wrong with a record. Reporting
        one error at a time turns a broken payload into several sequential runs."""
        r = record()
        r["efficiency"]["durationMs"] = -5
        r["result"]["addedLines"] = "three"
        self.assertEqual(len(vr.validate(r, SCHEMA)), 2)


class TheSchemaCannotOutrunTheValidator(unittest.TestCase):
    def test_an_unimplemented_keyword_is_an_error_not_a_skip(self):
        """The whole risk of a hand-written validator: silently ignoring a keyword it does
        not understand, and reporting a success it never checked. Adding `enum` to the schema
        must fail here until `enum` is implemented."""
        s = copy.deepcopy(SCHEMA)
        s["properties"]["variant"]["enum"] = ["baseline", "instructions"]
        with self.assertRaises(vr.SchemaUnsupported):
            vr.validate(record(), s)

    def test_a_keyword_on_a_property_the_record_omits_is_still_caught(self):
        """The hole the first version had, pinned.

        The guard used to run inside the instance walk, so it only ever reached a subschema
        whose property was PRESENT in the record. `behavior: {}` is what the codex arm sends,
        so an `enum` on `behavior.modelCalls` was never looked at and the validator reported
        a success on a schema it had not read. A guard whose coverage depends on the data it
        happens to see is not a guard."""
        s = copy.deepcopy(SCHEMA)
        s["properties"]["behavior"]["properties"]["modelCalls"]["enum"] = [1, 2]
        r = record(behavior={})
        with self.assertRaises(vr.SchemaUnsupported):
            vr.validate(r, s)

    def test_a_keyword_under_an_array_items_subschema_is_caught(self):
        """Same hole, the other recursion path: `items` is only descended when the array is
        non-empty, so an empty changedFiles would have hidden it."""
        s = copy.deepcopy(SCHEMA)
        s["properties"]["result"]["properties"]["changedFiles"]["items"]["pattern"] = ".*"
        r = record()
        r["result"]["changedFiles"] = []
        with self.assertRaises(vr.SchemaUnsupported):
            vr.validate(r, s)

    def test_the_schema_is_checked_before_the_record_is_judged(self):
        """An unsupported schema must not be able to return 'valid' for anything, including
        a record that is itself wrong. Order matters: check the schema, then the record."""
        s = copy.deepcopy(SCHEMA)
        s["properties"]["variant"]["enum"] = ["baseline"]
        with self.assertRaises(vr.SchemaUnsupported):
            vr.validate(record(variant=None, behavior={"toolCalls": -1}), s)

    def test_additional_properties_as_a_schema_is_refused_not_ignored(self):
        """Found by the opencode reviewer's PROBE K.

        `additionalProperties` takes a boolean OR a schema, and only `false` is implemented.
        The keyword-name guard cannot see that difference, so `{"type": "string"}` passed the
        guard and was then silently ignored — admitting exactly the properties it was written
        to constrain. A keyword being implemented is not the same as every form of it being
        implemented, and the silent skip arrived through the value rather than the key."""
        s = copy.deepcopy(SCHEMA)
        s["properties"]["runtime"]["additionalProperties"] = {"type": "string"}
        with self.assertRaises(vr.SchemaUnsupported):
            vr.validate(record(), s)

    def test_the_shipped_schema_uses_only_implemented_keywords(self):
        """Guards the reverse direction: someone edits run.schema.json, CI stays green
        because no test exercised the new keyword, and the validator quietly stops covering
        the field. Validating a record against the real schema is what catches that."""
        try:
            vr.validate(record(), SCHEMA)
        except vr.SchemaUnsupported as exc:
            self.fail(f"run.schema.json uses an unimplemented keyword: {exc}")


class TheFindingThatMotivatedThis(unittest.TestCase):
    def test_the_schema_on_main_would_have_rejected_a_current_record(self):
        """#53 pinned. Before this change `runtime` allowed only provider/product/version/
        model and `efficiency` had no reportedTotalTokens, both with additionalProperties
        false — so wiring the file in as it stood would have rejected every run, and the
        codex arm on two counts. The schema drifted three migrations behind the payload
        precisely because nothing executed it."""
        stale = copy.deepcopy(SCHEMA)
        for f in ("userSettingsIsolated", "shimsStripped", "surface"):
            del stale["properties"]["runtime"]["properties"][f]
        del stale["properties"]["efficiency"]["properties"]["reportedTotalTokens"]

        errors = vr.validate(record(), stale)
        self.assertEqual(len(errors), 4, errors)
        joined = " ".join(errors)
        for f in ("userSettingsIsolated", "shimsStripped", "surface", "reportedTotalTokens"):
            self.assertIn(f"unexpected property '{f}'", joined)


if __name__ == "__main__":
    unittest.main()
