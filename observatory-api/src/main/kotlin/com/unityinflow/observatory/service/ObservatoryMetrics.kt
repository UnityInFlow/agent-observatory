package com.unityinflow.observatory.service

import com.unityinflow.observatory.domain.AgentRun
import com.unityinflow.observatory.domain.Evaluation
import io.micrometer.core.instrument.DistributionSummary
import io.micrometer.core.instrument.MeterRegistry
import io.micrometer.core.instrument.Tags
import org.springframework.stereotype.Component

/**
 * Aggregated experiment metrics for Prometheus.
 *
 * Chapter 00 §15 is a hard constraint here: run ids, commit shas, prompt ids, file paths
 * and user emails are high-cardinality and must never become labels. Individual run
 * detail lives in PostgreSQL; individual span detail lives in Tempo. Only the four
 * low-cardinality dimensions below are published.
 */
@Component
class ObservatoryMetrics(private val registry: MeterRegistry) {

    fun recordRun(run: AgentRun, evaluation: Evaluation, benchmarkCategory: String) {
        val tags = Tags.of(
            "runtime", run.runtime.provider,
            "variant", run.variant,
            "benchmark_category", benchmarkCategory,
            "result", if (evaluation.passed) "pass" else "fail",
        )

        registry.counter("observatory.runs", tags).increment()

        registry.counter(
            "observatory.tool.failures",
            Tags.of("runtime", run.runtime.provider, "variant", run.variant),
        ).increment(run.behavior.toolFailures.toDouble())

        summary("observatory.run.duration", tags).record((run.efficiency.durationMs ?: 0L).toDouble())
        summary("observatory.run.tool_calls", tags).record(run.behavior.toolCalls.toDouble())
        summary("observatory.run.model_calls", tags).record(run.behavior.modelCalls.toDouble())
        run.efficiency.totalTokens()?.let { summary("observatory.run.tokens", tags).record(it.toDouble()) }
        summary("observatory.run.acceptance_rate", tags).record(evaluation.acceptanceRate())
    }

    private fun summary(name: String, tags: Tags): DistributionSummary =
        DistributionSummary.builder(name)
            .tags(tags)
            .publishPercentiles(0.5, 0.95)
            .register(registry)
}
