#!/usr/bin/env python3
"""
Tests for the MDE derivation that Amendment 2 registers.

    python3 -m unittest discover -s runner -p 'test_*.py'

The number this script prints becomes the threshold a later comparison is judged against,
so the formula and the incomplete-arm gate both have to be pinned. A quiet change to
either would move the bar after the fact, which is the failure mode the registration
exists to prevent.
"""
import contextlib
import importlib.util
import io
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "derive_mde", pathlib.Path(__file__).with_name("derive-mde.py")
)
dm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dm)


def run(variant="baseline", *, experiment="EXP-TEST", failure=None, passed=True,
        tool_calls=10, model_calls=12, cost=0.2, duration_ms=100_000,
        cached=400_000, created=20_000, evaluated=True):
    return {
        "experimentKey": experiment,
        "variant": variant,
        "behavior": {"toolCalls": tool_calls, "modelCalls": model_calls},
        "efficiency": {
            "estimatedCost": cost, "durationMs": duration_ms,
            "cachedTokens": cached, "cacheCreationTokens": created,
        },
        "evaluation": None if not evaluated else {"passed": passed, "failureClass": failure},
    }


class EffectSize(unittest.TestCase):
    def test_the_registered_constant_at_n_10(self):
        """Amendment 2 registers d = 1.28. Pinned so a tidy-up cannot move the bar."""
        self.assertAlmostEqual(dm.effect_size(10), 1.2821, places=4)

    def test_efficiency_enters_as_a_square_root(self):
        """The pilot's 1.31 divided by ARE; d scales with sqrt(n), so it is sqrt(ARE)."""
        d_t = (dm.Z_ALPHA_TWO_SIDED_05 + dm.Z_POWER_80) * (2 / 10) ** 0.5
        self.assertAlmostEqual(dm.effect_size(10), d_t / dm.RANK_TEST_ARE**0.5, places=9)
        self.assertLess(dm.effect_size(10), d_t / dm.RANK_TEST_ARE)

    def test_larger_n_detects_smaller_effects(self):
        self.assertLess(dm.effect_size(40), dm.effect_size(10))

    def test_scales_as_one_over_sqrt_n(self):
        self.assertAlmostEqual(dm.effect_size(10) / dm.effect_size(40), 2.0, places=6)

    def test_rank_test_correction_costs_power(self):
        """The registered analysis is Mann-Whitney, which needs a larger effect than a t test."""
        t_test_d = (dm.Z_ALPHA_TWO_SIDED_05 + dm.Z_POWER_80) * (2 / 10) ** 0.5
        self.assertGreater(dm.effect_size(10), t_test_d)


class Derive(unittest.TestCase):
    def test_relative_mde_is_d_times_coefficient_of_variation(self):
        runs = [run(cost=c) for c in (0.18, 0.20, 0.22, 0.20, 0.20)]
        rows = {r["metric"]: r for r in dm.derive(runs, 10)[0]}
        cost = rows["cost"]
        self.assertAlmostEqual(cost["mean"], 0.20, places=9)
        self.assertAlmostEqual(cost["relative"], dm.effect_size(10) * cost["sd"] / cost["mean"])

    def test_zero_spread_gives_a_zero_mde(self):
        rows = {r["metric"]: r for r in dm.derive([run(cost=0.2) for _ in range(5)], 10)[0]}
        self.assertEqual(rows["cost"]["relative"], 0.0)

    def test_a_single_run_cannot_produce_an_sd(self):
        rows, missing = dm.derive([run()], 10)
        self.assertEqual(rows, [])
        self.assertEqual(len(missing), len(dm.METRICS))

    def test_missing_telemetry_is_not_a_very_efficient_run(self):
        """Amendment 1.3: zero model calls and zero tool calls is a collector gap."""
        runs = [run(tool_calls=0, model_calls=0) for _ in range(3)] + [run(), run()]
        rows = {r["metric"]: r for r in dm.derive(runs, 10)[0]}
        self.assertEqual(rows["toolCalls"]["n"], 2)
        self.assertEqual(rows["cost"]["n"], 5)

    def test_a_zero_mean_has_no_relative_mde(self):
        rows, missing = dm.derive([run(cost=0.0) for _ in range(3)], 10)
        self.assertNotIn("cost", {r["metric"] for r in rows})
        self.assertTrue(any("mean is 0" in m for m in missing))


class Selection(unittest.TestCase):
    def test_only_the_named_arm_of_the_named_experiment(self):
        runs = [run(), run("instructions"), run(experiment="EXP-OTHER")]
        kept, _, _ = dm.measuring_runs(runs, "EXP-TEST", "baseline")
        self.assertEqual(len(kept), 1)

    def test_infrastructure_failures_are_discarded_not_measured(self):
        runs = [run(), run(passed=False, failure="F13"), run(passed=False, failure="F15")]
        kept, discarded, _ = dm.measuring_runs(runs, "EXP-TEST", "baseline")
        self.assertEqual((len(kept), discarded), (1, 2))

    def test_a_genuine_failure_still_measures_the_variant(self):
        kept, discarded, _ = dm.measuring_runs(
            [run(passed=False, failure="F07")], "EXP-TEST", "baseline"
        )
        self.assertEqual((len(kept), discarded), (1, 0))

    def test_unevaluated_runs_are_counted_separately(self):
        kept, _, unevaluated = dm.measuring_runs(
            [run(), run(evaluated=False)], "EXP-TEST", "baseline"
        )
        self.assertEqual((len(kept), unevaluated), (1, 1))


class IncompleteArmGate(unittest.TestCase):
    """A threshold derived from a partial arm moves while you watch it."""

    def invoke(self, runs, *argv):
        original, buf = dm.ae.fetch, io.StringIO()
        dm.ae.fetch = lambda url: runs
        try:
            with contextlib.redirect_stdout(buf):
                code = dm.main(["EXP-TEST", *argv])
        finally:
            dm.ae.fetch = original
        return code, buf.getvalue()

    def test_refuses_a_short_arm(self):
        code, out = self.invoke([run() for _ in range(4)], "--expect-n", "10")
        self.assertEqual(code, 2)
        self.assertIn("REFUSING", out)
        self.assertNotIn("minimum detectable effect", out)

    def test_refuses_while_a_run_is_still_unevaluated(self):
        runs = [run() for _ in range(9)] + [run(evaluated=False)]
        code, out = self.invoke(runs, "--expect-n", "10")
        self.assertEqual(code, 2)
        self.assertIn("no evaluation yet", out)

    def test_discarded_runs_must_be_replaced_not_tolerated(self):
        runs = [run() for _ in range(9)] + [run(passed=False, failure="F13")]
        code, out = self.invoke(runs, "--expect-n", "10")
        self.assertEqual(code, 2)
        self.assertIn("replace them with fresh runs", out)

    def test_a_complete_arm_prints_the_table(self):
        runs = [run(cost=0.2 + i / 100) for i in range(10)]
        code, out = self.invoke(runs, "--expect-n", "10")
        self.assertEqual(code, 0)
        self.assertIn("minimum detectable effect", out)
        self.assertNotIn("REFUSING", out)

    def test_exploratory_looks_but_does_not_register(self):
        code, out = self.invoke([run(cost=0.2 + i / 100) for i in range(4)],
                                "--expect-n", "10", "--exploratory")
        self.assertEqual(code, 0)
        self.assertIn("NOT REGISTRABLE", out)
        self.assertIn("Not registrable", out)


if __name__ == "__main__":
    unittest.main()
