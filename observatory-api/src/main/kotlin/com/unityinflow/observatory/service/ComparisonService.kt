package com.unityinflow.observatory.service

import com.unityinflow.observatory.api.ComparisonResponse
import com.unityinflow.observatory.api.VariantComparison
import com.unityinflow.observatory.domain.AgentRun
import com.unityinflow.observatory.domain.AgentRunRepository
import com.unityinflow.observatory.domain.Evaluation
import com.unityinflow.observatory.domain.EvaluationRepository
import com.unityinflow.observatory.domain.ExperimentRepository
import java.util.UUID
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

/**
 * The comparison layer sits *above* vendor differences (§26) and answers the only
 * question that matters after a customization change: did it actually improve anything?
 */
@Service
@Transactional(readOnly = true)
class ComparisonService(
    private val runs: AgentRunRepository,
    private val evaluations: EvaluationRepository,
    private val experiments: ExperimentRepository,
) {

    /** §20: minimum learning sample is 5 runs per variant; 10 is a better first comparison. */
    private val minimumRunsPerVariant = 5

    /**
     * What the runs are grouped by. §20 describes two different experiments: varying the
     * customization (experiments 2–3) and varying the runtime/harness (experiment 5).
     * Grouping only by variant can express the first but not the second.
     */
    enum class GroupBy { VARIANT, RUNTIME }

    /**
     * Compare every run of one benchmark, across experiments — the only way to put two
     * runtimes side by side, since a Copilot baseline and a Claude baseline are naturally
     * recorded as separate experiments rather than as variants of one.
     *
     * Grouping by runtime measures the whole harness + model combination, never "the
     * model" alone (§20).
     */
    fun compareBenchmark(benchmarkId: String, groupBy: GroupBy): ComparisonResponse {
        val benchmarkRuns = runs.search(benchmarkId, null, null)
        if (benchmarkRuns.isEmpty()) throw NotFoundException("No runs recorded for benchmark '$benchmarkId'")
        return summarizeAll(experiment = null, runsToCompare = benchmarkRuns, groupBy = groupBy)
    }

    fun compare(experimentRef: String): ComparisonResponse {
        val experiment = runCatching { UUID.fromString(experimentRef) }
            .getOrNull()
            ?.let { id -> experiments.findById(id).orElse(null) }
            ?: experiments.findByName(experimentRef)
            ?: throw NotFoundException("Unknown experiment '$experimentRef'")

        return summarizeAll(experiment, runs.findByExperimentId(experiment.id), GroupBy.VARIANT)
    }

    private fun summarizeAll(
        experiment: com.unityinflow.observatory.domain.Experiment?,
        runsToCompare: List<AgentRun>,
        groupBy: GroupBy,
    ): ComparisonResponse {
        val evaluationsByRun = evaluations
            .findByRunIdIn(runsToCompare.map { it.id })
            .associateBy { it.runId }

        val key: (AgentRun) -> String = when (groupBy) {
            GroupBy.VARIANT -> { run -> run.variant }
            GroupBy.RUNTIME -> { run -> "${run.runtime.provider}/${run.runtime.model ?: "unknown"}" }
        }

        val groups = runsToCompare
            .groupBy(key)
            .map { (label, groupRuns) -> summarize(label, groupRuns, evaluationsByRun) }
            .sortedBy { it.variant }

        val thin = groups.filter { it.runs < minimumRunsPerVariant }.map { it.variant }
        val discarded = groups.sumOf { it.infrastructureFailures }
        val warning = if (thin.isEmpty()) null else
            "${thin.joinToString(", ")} ${if (thin.size == 1) "has" else "have"} fewer than " +
                "$minimumRunsPerVariant measuring runs. Agent runs are non-deterministic — " +
                "one successful run proves very little." +
                if (discarded == 0) "" else
                    " $discarded ${if (discarded == 1) "run is" else "runs are"} excluded as " +
                        "infrastructure failures (F13/F15) and do not count toward the minimum."

        return ComparisonResponse(
            experimentId = experiment?.id,
            experimentKey = experiment?.name,
            totalRuns = runsToCompare.size,
            variants = groups,
            warning = warning,
        )
    }

    private fun summarize(
        variant: String,
        variantRuns: List<AgentRun>,
        evaluationsByRun: Map<UUID, Evaluation>,
    ): VariantComparison {
        // #19: a run that aborted on a quota or a broken evaluator measures the harness,
        // not the variant. It is reported, never averaged, and never counted as sample.
        val (infrastructure, measured) = variantRuns.partition {
            evaluationsByRun[it.id]?.isInfrastructureFailure() == true
        }
        val evaluated = measured.mapNotNull { evaluationsByRun[it.id] }
        val passed = evaluated.count { it.passed }

        return VariantComparison(
            variant = variant,
            runs = measured.size,
            infrastructureFailures = infrastructure.size,
            passed = passed,
            passRate = if (evaluated.isEmpty()) 0.0 else passed.toDouble() / evaluated.size,
            acceptanceRate = if (evaluated.isEmpty()) 0.0 else evaluated.map { it.acceptanceRate() }.average(),
            medianToolCalls = median(measured.map { it.behavior.toolCalls.toDouble() }),
            medianModelCalls = median(measured.map { it.behavior.modelCalls.toDouble() }),
            medianTokens = median(measured.mapNotNull { it.efficiency.totalTokens()?.toDouble() }),
            medianDurationMs = median(measured.mapNotNull { it.efficiency.durationMs?.toDouble() }),
            medianRetries = median(measured.map { it.behavior.retries.toDouble() }),
            meanUnrelatedFilesChanged =
                if (evaluated.isEmpty()) null else evaluated.map { it.unrelatedFilesChanged.toDouble() }.average(),
            // §23: a taxonomy is more useful than a generic FAIL counter.
            failureClasses = evaluated
                .filter { !it.passed }
                .mapNotNull { it.failureClass }
                .groupingBy { it }
                .eachCount(),
        )
    }

    private fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2.0
    }
}
