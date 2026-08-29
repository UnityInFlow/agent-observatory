#!/usr/bin/env python3
"""
Tests for the single-arm baseline report.

    python3 -m unittest discover -s runner -p 'test_*.py'

B2's exit gate asks for "a baseline report with median and range, never an average alone",
and this tool is what produces it. The number it prints is the one every later phase is
compared against, so a later tidy-up must not be able to reintroduce a mean, silently drop a
run, or average an absent measurement in as a zero.
"""
import ast
import contextlib
import importlib.util
import io
import itertools
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "baseline_report", pathlib.Path(__file__).with_name("baseline-report.py")
)
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)

_ids = itertools.count()


def run(experiment="EXP-B", *, passed=True, failure=None, tool_calls=10, model_calls=12,
        cost=0.2, duration_ms=100_000, cached=400_000, created=20_000,
        evaluated=True, model="haiku", version="1.0.0"):
    behavior = {
        "modelCalls": model_calls, "toolCalls": tool_calls, "toolFailures": 0,
        "retries": 0, "permissionRequests": 0, "permissionDenials": 0,
    }
    r = {
        "runId": f"run-{next(_ids)}",
        "experimentKey": experiment,
        "variant": "baseline",
        "runtime": {"provider": "anthropic", "product": "cli", "model": model, "version": version},
        "behavior": behavior,
        "efficiency": {
            "durationMs": duration_ms, "estimatedCost": cost,
            "cachedTokens": cached, "cacheCreationTokens": created,
        },
        "result": {"changedFiles": ["a.kt"], "addedLines": 10, "deletedLines": 0},
    }
    if evaluated:
        r["evaluation"] = {"passed": passed, "exitCode": 0 if passed else 12,
                           "failureClass": failure}
    return r


def render(runs, *args, min_n=3):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = br.report_arm(args[0] if args else "EXP-B", runs, min_n)
    return buf.getvalue(), code


class Spread(unittest.TestCase):
    def test_median_is_the_order_statistic_not_the_mean(self):
        # The case this whole tool exists for: one stalled run. This project already has a
        # run at 1063 s against 82-167 s for the rest, and registered a 175% MDE because of
        # it. A mean of this sample is 240; no run resembles 240.
        s = br.spread([100, 100, 100, 100, 1000])
        self.assertEqual(s["median"], 100)
        self.assertEqual(s["max"], 1000)
        self.assertNotIn("mean", s)

    def test_reports_nothing_when_nothing_was_measured(self):
        self.assertIsNone(br.spread([None, None]))

    def test_a_single_value_is_its_own_median_and_range(self):
        s = br.spread([7])
        self.assertEqual((s["min"], s["median"], s["max"], s["n"]), (7, 7, 7, 1))


class NoMeanAnywhere(unittest.TestCase):
    def test_the_module_computes_no_mean(self):
        """
        Structural, not cosmetic: there is no mean to accidentally print.

        Checked against the parsed tree rather than the text, so a docstring may go on
        explaining why means are wrong here without tripping its own guard, and so
        `sum(1 for ...)` — counting passes — is not mistaken for computing one. What is
        banned is the arithmetic: a mean function, or a division by a length.
        """
        tree = ast.parse(pathlib.Path(br.__file__).read_text())
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                name = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
                self.assertNotIn(
                    name, {"mean", "fmean", "average"},
                    f"{name}() appeared — a mean can now be printed",
                )
            if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Div, ast.FloorDiv)):
                divisor = getattr(node.right, "func", None)
                divisor_name = getattr(divisor, "id", None)
                self.assertNotEqual(
                    divisor_name, "len",
                    "division by len() appeared — that is a mean wearing arithmetic",
                )


class Partition(unittest.TestCase):
    def test_infrastructure_failures_are_discarded_and_named(self):
        runs = [run() for _ in range(3)] + [run(passed=False, failure="F13")]
        out, code = render(runs)
        self.assertEqual(code, 0)
        self.assertIn("3 measuring run(s)", out)
        self.assertIn("1 discarded as harness failure (F13)", out)

    def test_an_agent_failure_stays_in_the_sample(self):
        """F03 is the agent being wrong. It is the measurement, not an excuse to drop a run."""
        runs = [run() for _ in range(2)] + [run(passed=False, failure="F03")]
        out, code = render(runs)
        self.assertEqual(code, 0)
        self.assertIn("3 measuring run(s)", out)
        self.assertIn("pass rate   2/3", out)
        self.assertIn("F03×1", out)

    def test_an_unevaluated_run_is_excluded_and_counted(self):
        runs = [run() for _ in range(3)] + [run(evaluated=False)]
        out, _ = render(runs)
        self.assertIn("1 run(s) with NO evaluation record", out)
        self.assertIn("3 measuring run(s)", out)

    def test_other_experiments_are_ignored(self):
        runs = [run() for _ in range(3)] + [run(experiment="EXP-OTHER") for _ in range(9)]
        out, _ = render(runs)
        self.assertIn("3 measuring run(s)", out)


class Refusals(unittest.TestCase):
    def test_refuses_below_the_minimum(self):
        out, code = render([run(), run()])
        self.assertEqual(code, 1)
        self.assertIn("REFUSING to report", out)
        # And prints no table it could be mistaken for.
        self.assertNotIn("median", out)

    def test_reports_nothing_for_an_unknown_experiment(self):
        out, code = render([run(experiment="EXP-OTHER")])
        self.assertEqual(code, 2)
        self.assertIn("no runs recorded", out)


class MissingTelemetry(unittest.TestCase):
    def test_an_unmeasured_run_is_excluded_from_that_metric_not_zeroed(self):
        runs = [run(tool_calls=10, model_calls=12) for _ in range(3)]
        runs.append(run(tool_calls=None, model_calls=None))
        out, code = render(runs)
        self.assertEqual(code, 0)
        # Four measuring runs, but tool calls has n=3 and says so.
        self.assertIn("4 measuring run(s)", out)
        self.assertIn("1 run(s) missing this measurement, excluded", out)
        # A zeroed run would drag the minimum to 0.
        self.assertNotIn(" 0 ", out.split("tool calls")[1].split("\n")[0])

    def test_pre_v4_all_zero_behaviour_is_still_read_as_absent(self):
        """The fallback heuristic, for rows written before the API reported null itself."""
        self.assertFalse(br.has_behavior_telemetry(
            {"behavior": {"modelCalls": 0, "toolCalls": 0}}))
        self.assertTrue(br.has_behavior_telemetry(
            {"behavior": {"modelCalls": 0, "toolCalls": 3}}))

    def test_a_metric_absent_from_every_run_says_so(self):
        runs = [run(cost=None) for _ in range(3)]
        out, _ = render(runs)
        self.assertIn("not measured on any run", out)


class Constancy(unittest.TestCase):
    def test_warns_when_an_arm_mixes_models(self):
        runs = [run(model="haiku"), run(model="haiku"), run(model="sonnet")]
        out, _ = render(runs)
        self.assertIn("mixes 2 models", out)

    def test_warns_when_an_arm_mixes_runtime_versions(self):
        runs = [run(version="2.1.226"), run(version="2.1.226"), run(version="2.1.227")]
        out, _ = render(runs)
        self.assertIn("mixes 2 runtime versions", out)

    def test_silent_when_the_arm_is_constant(self):
        out, _ = render([run() for _ in range(3)])
        self.assertNotIn("mixes", out)


if __name__ == "__main__":
    unittest.main()
