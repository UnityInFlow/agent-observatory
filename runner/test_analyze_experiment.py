#!/usr/bin/env python3
"""
Tests for the statistics and gates that decide an experiment's verdict.

    python3 -m unittest discover -s runner -p 'test_*.py'

These are not incidental. The U test, the dataset gate and the decision rule together
produce a KEEP/REJECT that goes into a document, so a later tidy-up must not be able to
change the registered analysis silently.
"""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "analyze_experiment", pathlib.Path(__file__).with_name("analyze-experiment.py")
)
ae = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ae)


def run(variant, *, passed=True, failure=None, tool_calls=10, model_calls=12,
        cost=0.2, duration_ms=100_000, cached=400_000, created=20_000,
        benchmark="BE-002", provider="anthropic", model="haiku", sha="abc", evaluated=True):
    return {
        "variant": variant,
        "benchmarkId": benchmark,
        "runtime": {"provider": provider, "model": model},
        "repository": {"commitSha": sha},
        "behavior": {"toolCalls": tool_calls, "modelCalls": model_calls},
        "efficiency": {
            "estimatedCost": cost, "durationMs": duration_ms,
            "cachedTokens": cached, "cacheCreationTokens": created,
        },
        "evaluation": None if not evaluated else {
            "passed": passed, "failureClass": failure,
        },
    }


class MannWhitney(unittest.TestCase):
    def test_identical_samples_give_no_evidence(self):
        _, p = ae.mann_whitney_u([1, 2, 3, 4, 5], [1, 2, 3, 4, 5])
        self.assertAlmostEqual(p, 1.0, places=6)

    def test_complete_separation_is_significant(self):
        u, p = ae.mann_whitney_u(list(range(1, 11)), list(range(21, 31)))
        self.assertEqual(u, 0.0)
        self.assertLess(p, 0.001)

    def test_conservative_against_the_exact_value(self):
        # Exact two-sided p for full separation at n=10 is 2/C(20,10) = 1.08e-5.
        _, p = ae.mann_whitney_u(list(range(1, 11)), list(range(21, 31)))
        self.assertGreater(p, 1.08e-5, "approximation must not claim more significance than exact")

    def test_heavy_overlap_is_not_significant(self):
        _, p = ae.mann_whitney_u(list(range(1, 11)), list(range(2, 12)))
        self.assertGreater(p, 0.05)

    def test_ties_are_rank_averaged(self):
        _, p = ae.mann_whitney_u([1, 1, 1, 2, 2], [1, 1, 2, 2, 2])
        self.assertGreater(p, 0.05)

    def test_all_values_tied_is_no_evidence_not_a_crash(self):
        _, p = ae.mann_whitney_u([5, 5, 5], [5, 5, 5])
        self.assertEqual(p, 1.0)

    def test_unequal_sample_sizes(self):
        _, p = ae.mann_whitney_u([1, 2, 3], list(range(50, 70)))
        self.assertLess(p, 0.05)

    def test_empty_input_returns_nothing_rather_than_dividing_by_zero(self):
        self.assertEqual(ae.mann_whitney_u([], [1, 2, 3]), (None, None))
        self.assertEqual(ae.mann_whitney_u([1, 2, 3], []), (None, None))


class RelativeChange(unittest.TestCase):
    def test_zero_baseline_is_undefined_not_zero_percent(self):
        self.assertIsNone(ae.relative_change(0, 5))

    def test_sign_is_preserved(self):
        self.assertAlmostEqual(ae.relative_change(10, 8), -0.2)
        self.assertAlmostEqual(ae.relative_change(10, 12), 0.2)


class Telemetry(unittest.TestCase):
    def test_all_zero_behaviour_is_treated_as_missing_not_as_efficiency(self):
        blind = run("baseline", tool_calls=0, model_calls=0)
        self.assertIsNone(ae.metrics(blind)["toolCalls"])
        self.assertIsNone(ae.metrics(blind)["modelCalls"])

    def test_a_genuine_zero_tool_call_run_still_counts_when_the_model_ran(self):
        m = ae.metrics(run("baseline", tool_calls=0, model_calls=7))
        self.assertEqual(m["toolCalls"], 0)

    def test_cache_totals_reads_plus_creations(self):
        self.assertEqual(ae.metrics(run("baseline", cached=100, created=25))["cacheTokens"], 125)

    def test_cache_absent_entirely_is_none(self):
        r = run("baseline")
        r["efficiency"]["cachedTokens"] = None
        r["efficiency"]["cacheCreationTokens"] = None
        self.assertIsNone(ae.metrics(r)["cacheTokens"])


class DatasetGate(unittest.TestCase):
    def complete(self, n=2):
        return [run("baseline") for _ in range(n)] + [run("instructions") for _ in range(n)]

    def check(self, runs, expect_n=2):
        arms, discarded, unevaluated, unexpected = ae.partition(runs, "baseline", "instructions")
        return ae.validate(runs, arms, discarded, unevaluated, unexpected, expect_n)

    def test_the_registered_dataset_passes(self):
        self.assertEqual(self.check(self.complete()), [])

    def test_a_short_arm_is_refused(self):
        runs = self.complete()[:-1]
        self.assertTrue(any("instructions" in p and "expected 2" in p for p in self.check(runs)))

    def test_partial_batch_is_refused_so_optional_stopping_cannot_happen(self):
        self.assertTrue(self.check([run("baseline")]))

    def test_unevaluated_run_is_refused(self):
        runs = self.complete() + [run("baseline", evaluated=False)]
        self.assertTrue(any("no evaluation" in p for p in self.check(runs)))

    def test_unexpected_variant_is_refused(self):
        runs = self.complete() + [run("skills")]
        self.assertTrue(any("unexpected variants" in p for p in self.check(runs)))

    def test_a_different_model_between_arms_is_refused(self):
        runs = self.complete()
        runs[-1]["runtime"]["model"] = "sonnet"
        self.assertTrue(any("runtime.model" in p for p in self.check(runs)))

    def test_a_different_baseline_commit_is_refused(self):
        runs = self.complete()
        runs[0]["repository"]["commitSha"] = "def"
        self.assertTrue(any("commitSha" in p for p in self.check(runs)))

    def test_discarded_runs_must_be_replaced_not_tolerated(self):
        runs = self.complete() + [run("baseline", passed=False, failure="F13")]
        problems = self.check(runs)
        self.assertEqual(problems, [], "a discard on top of a full arm is fine")
        short = [run("baseline"), run("baseline", passed=False, failure="F13")] + [
            run("instructions") for _ in range(2)
        ]
        self.assertTrue(any("discarded" in p for p in self.check(short)))

    def test_missing_telemetry_in_one_arm_is_refused(self):
        runs = self.complete()
        runs[0]["behavior"] = {"toolCalls": 0, "modelCalls": 0}
        self.assertTrue(any("missing toolCalls telemetry" in p for p in self.check(runs)))


class Verdict(unittest.TestCase):
    """The three registered outcomes, exercised through main() against a stubbed API."""

    def analyse(self, runs, **kw):
        original, out = ae.fetch, []
        ae.fetch = lambda url: runs
        try:
            import contextlib, io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = ae.main(["EXP-TEST", "--expect-n", str(kw.get("n", 3))])
            out = buf.getvalue()
        finally:
            ae.fetch = original
        return code, out

    def arms(self, control_cost, treatment_cost, treatment_failure=None):
        runs = []
        for cost in control_cost:
            runs.append(run("baseline", cost=cost))
        for i, cost in enumerate(treatment_cost):
            failed = treatment_failure is not None and i == 0
            runs.append(run("instructions", cost=cost, passed=not failed,
                            failure=treatment_failure if failed else None))
        for r in runs:
            r["experimentKey"] = "EXP-TEST"
        return runs

    def test_rejects_when_the_treatment_adds_an_error_contract_failure(self):
        _, out = self.analyse(self.arms([0.2, 0.2, 0.2], [0.1, 0.1, 0.1], treatment_failure="F02"))
        self.assertIn("VERDICT: REJECT", out)
        self.assertIn("error-contract", out)

    def test_keeps_on_a_large_significant_cost_improvement(self):
        control = [0.30, 0.31, 0.32, 0.33, 0.34, 0.35, 0.36, 0.37, 0.38, 0.39]
        treatment = [0.10, 0.11, 0.12, 0.13, 0.14, 0.15, 0.16, 0.17, 0.18, 0.19]
        _, out = self.analyse(self.arms(control, treatment), n=10)
        self.assertIn("VERDICT: KEEP", out)

    def test_inconclusive_when_the_change_is_below_the_registered_threshold(self):
        control = [0.200, 0.201, 0.202, 0.203, 0.204, 0.205, 0.206, 0.207, 0.208, 0.209]
        treatment = [0.198, 0.199, 0.200, 0.201, 0.202, 0.203, 0.204, 0.205, 0.206, 0.207]
        _, out = self.analyse(self.arms(control, treatment), n=10)
        self.assertIn("VERDICT: INCONCLUSIVE", out)
        self.assertIn("not a finding", out)

    def test_a_cost_increase_never_reads_as_a_win(self):
        control = [0.10, 0.11, 0.12, 0.13, 0.14, 0.15, 0.16, 0.17, 0.18, 0.19]
        treatment = [0.30, 0.31, 0.32, 0.33, 0.34, 0.35, 0.36, 0.37, 0.38, 0.39]
        _, out = self.analyse(self.arms(control, treatment), n=10)
        self.assertIn("VERDICT: INCONCLUSIVE", out)
        self.assertIn("worse", out)
        self.assertNotIn("KEEP", out)

    def test_refuses_an_incomplete_dataset_instead_of_printing_a_p_value(self):
        code, out = self.analyse(self.arms([0.2, 0.2], [0.1]), n=10)
        self.assertEqual(code, 2)
        self.assertIn("REFUSING", out)
        self.assertNotIn("VERDICT", out)


if __name__ == "__main__":
    unittest.main()


class VariedDimension(unittest.TestCase):
    """--vary lets the treatment BE a fixed dimension, without opening the gate generally."""

    def validate(self, runs, vary=(), n=2):
        arms, discarded, unevaluated, unexpected = ae.partition(runs, "baseline", "instructions")
        return ae.validate(runs, arms, discarded, unevaluated, unexpected, n, vary)

    def two_arms(self, ctrl_model, treat_model):
        return ([run("baseline", model=ctrl_model) for _ in range(2)]
                + [run("instructions", model=treat_model) for _ in range(2)])

    def test_mixed_models_still_fail_closed_without_vary(self):
        problems = self.validate(self.two_arms("haiku", "sonnet"))
        self.assertTrue(any("runtime.model" in p for p in problems))

    def test_vary_permits_the_intended_difference(self):
        problems = self.validate(self.two_arms("haiku", "sonnet"), vary=("runtime.model",))
        self.assertEqual(problems, [])

    def test_vary_rejects_an_arm_that_mixes_values(self):
        runs = ([run("baseline", model="haiku"), run("baseline", model="sonnet")]
                + [run("instructions", model="sonnet") for _ in range(2)])
        problems = self.validate(runs, vary=("runtime.model",))
        self.assertTrue(any("mixes 2 values" in p for p in problems))

    def test_vary_rejects_arms_that_do_not_actually_differ(self):
        problems = self.validate(self.two_arms("haiku", "haiku"), vary=("runtime.model",))
        self.assertTrue(any("both arms have the same value" in p for p in problems))

    def test_vary_rejects_an_unknown_dimension(self):
        problems = self.validate(self.two_arms("haiku", "haiku"), vary=("runtime.temperature",))
        self.assertTrue(any("is not one of" in p for p in problems))

    def test_varying_one_dimension_does_not_relax_the_others(self):
        runs = ([run("baseline", model="haiku", sha="abc") for _ in range(2)]
                + [run("instructions", model="sonnet", sha="def") for _ in range(2)])
        problems = self.validate(runs, vary=("runtime.model",))
        self.assertTrue(any("repository.commitSha" in p for p in problems))


class UnattemptedRuns(unittest.TestCase):
    """A run that changed no production file is not evidence about the code."""

    def validate(self, runs, n=2):
        arms, discarded, unevaluated, unexpected = ae.partition(runs, "baseline", "instructions")
        return ae.validate(runs, arms, discarded, unevaluated, unexpected, n)

    def test_unattempted_runs_block_the_analysis(self):
        runs = [run("baseline") for _ in range(2)] + [run("instructions") for _ in range(2)]
        runs[2]["evaluation"]["taskAttempted"] = False
        problems = self.validate(runs)
        self.assertTrue(any("changed no production file" in p for p in problems))

    def test_attempted_runs_are_fine(self):
        runs = [run("baseline") for _ in range(2)] + [run("instructions") for _ in range(2)]
        for r in runs:
            r["evaluation"]["taskAttempted"] = True
        self.assertEqual(self.validate(runs), [])

    def test_absent_field_is_not_treated_as_unattempted(self):
        """Runs recorded before the evaluator emitted the field must not be condemned."""
        runs = [run("baseline") for _ in range(2)] + [run("instructions") for _ in range(2)]
        self.assertEqual(self.validate(runs), [])

    def test_an_unattempted_run_is_still_counted_not_discarded(self):
        """It stays in the arm. Silently dropping it would flatter the agent."""
        runs = [run("baseline") for _ in range(2)] + [run("instructions") for _ in range(2)]
        runs[2]["evaluation"]["taskAttempted"] = False
        arms, discarded, _, _ = ae.partition(runs, "baseline", "instructions")
        self.assertEqual(len(arms["instructions"]), 2)
        self.assertEqual(discarded["instructions"], 0)
