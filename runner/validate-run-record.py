#!/usr/bin/env python3
"""Validate a run record against runner/schemas/run.schema.json. Reads JSON on stdin.

WHY THIS EXISTS

Three artifacts described the shape of a run record and only one executed, checking four
strings (#53). `run.schema.json` was the most dangerous of the three: loaded by nothing while
looking exactly like enforcement. It had drifted three migrations behind the payload without
anyone noticing, because nothing was ever going to notice.

    runtime     allowed provider/product/version/model, additionalProperties false,
                while the runner sent userSettingsIsolated, shimsStripped and surface (V6)
    efficiency  had no reportedTotalTokens (V5)

Wiring the file in as it stood would have rejected every run, and the codex arm twice over.
That is the argument for running it rather than reading it: a schema nothing executes is a
description, and descriptions drift silently.

WHY NOT `jsonschema`

`.github/workflows/ci.yml` installs no Python packages, deliberately — *"this machine has no
scipy, and a benchmark harness should not need one."* Adding a dependency to make the runner
work would trade a real property of this instrument for a library.

So this implements the subset of draft 2020-12 that `run.schema.json` actually uses. The
subset is the risk: a hand-written validator that silently ignores a keyword it does not
understand is worse than no validator, because it reports success it did not check.

**So an unimplemented keyword is a hard error, not a skip.** Adding `enum`, `pattern` or
`oneOf` to the schema fails loudly here until it is implemented, which is the failure mode
that leaves the record honest. `format`, `examples`, `default`, `title`, `description`, `$id`
and `$schema` are annotations and are listed as deliberately non-validating — `format` in
particular is an annotation by default in 2020-12, and treating it as a constraint would be
this validator inventing a rule the schema does not state.
"""

import argparse
import json
import sys

# Keywords this validator enforces.
ENFORCED = {"type", "required", "additionalProperties", "properties", "minimum", "items"}

# Keywords that carry no constraint. Listed rather than ignored by default, so that a
# keyword absent from BOTH sets is an error instead of a silent pass.
ANNOTATIONS = {"$schema", "$id", "title", "description", "examples", "default", "format"}

JSON_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


class SchemaUnsupported(Exception):
    """The schema uses a keyword this validator does not implement."""


def _matches_type(value, name):
    """One JSON type test, with the two traps JSON/Python disagree on.

    `True` is an `int` in Python and is not an integer in JSON, so a boolean must be
    rejected for "integer"/"number". And `1.0` is a `float`; JSON Schema calls it an
    integer only when it has zero fractional part, but nothing in this schema needs that
    leniency, so a float is simply not an integer here.
    """
    if name not in JSON_TYPES:
        raise SchemaUnsupported(f"unknown type name: {name!r}")
    if name in ("integer", "number") and isinstance(value, bool):
        return False
    if name == "integer":
        return isinstance(value, int)
    return isinstance(value, JSON_TYPES[name])


def validate(instance, schema, path="$", errors=None):
    """Collect every violation rather than raising on the first, so one run of the
    validator names everything wrong with a record instead of one thing at a time."""
    if errors is None:
        errors = []

    unknown = set(schema) - ENFORCED - ANNOTATIONS
    if unknown:
        raise SchemaUnsupported(
            f"{path}: schema uses keyword(s) this validator does not implement: "
            f"{sorted(unknown)}. Implement them in validate-run-record.py — do not "
            f"remove them from the schema to make this pass."
        )

    if "type" in schema:
        names = schema["type"]
        names = [names] if isinstance(names, str) else names
        if not any(_matches_type(instance, n) for n in names):
            errors.append(f"{path}: expected {'|'.join(names)}, got {type(instance).__name__}")
            return errors  # every further check would be noise against the wrong type

    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")

        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in instance:
                if key not in props:
                    errors.append(
                        f"{path}: unexpected property {key!r} "
                        f"(schema allows: {', '.join(sorted(props)) or 'none'})"
                    )
        for key, subschema in props.items():
            if key in instance:
                validate(instance[key], subschema, f"{path}.{key}", errors)

    if isinstance(instance, list) and "items" in schema:
        for i, item in enumerate(instance):
            validate(item, schema["items"], f"{path}[{i}]", errors)

    if "minimum" in schema and isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if instance < schema["minimum"]:
            errors.append(f"{path}: {instance} is below the minimum {schema['minimum']}")

    return errors


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--schema", required=True, help="path to run.schema.json")
    ap.add_argument("--record", help="path to the record; defaults to stdin")
    args = ap.parse_args(argv)

    with open(args.schema, encoding="utf-8") as fh:
        schema = json.load(fh)

    raw = open(args.record, encoding="utf-8").read() if args.record else sys.stdin.read()
    try:
        instance = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"run record is not valid JSON: {exc}", file=sys.stderr)
        return 2

    try:
        errors = validate(instance, schema)
    except SchemaUnsupported as exc:
        print(f"SCHEMA UNSUPPORTED: {exc}", file=sys.stderr)
        return 3

    if errors:
        print("run record does not match run.schema.json:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
