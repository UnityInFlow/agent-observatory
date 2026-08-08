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

    fun compare(experimentRef: String): ComparisonResponse {
        val experiment = runCatching { UUID.fromString(experimentRef) }
            .getOrNull()
            ?.let { id -> experiments.findById(id).orElse(null) }
            ?: experiments.findByName(experimentRef)
            ?: throw NotFoundException("Unknown experiment '$experimentRef'")

        val experimentRuns = runs.findByExperimentId(experiment.id)
        val evaluationsByRun = evaluations
            .findByRunIdIn(experimentRuns.map { it.id })
            .associateBy { it.runId }

        val variants = experimentRuns
            .groupBy { it.variant }
            .map { (variant, variantRuns) -> summarize(variant, variantRuns, evaluationsByRun) }
            .sortedBy { it.variant }

        val thin = variants.filter { it.runs < minimumRunsPerVariant }.map { it.variant }
        val warning = if (thin.isEmpty()) null else
            "Variant(s) ${thin.joinToString(", ")} have fewer than $minimumRunsPerVariant runs. " +
                "Agent runs are non-deterministic — one successful run proves very little."

        return ComparisonResponse(
            experimentId = experiment.id,
            experimentKey = experiment.name,
            totalRuns = experimentRuns.size,
            variants = variants,
            warning = warning,
        )
    }

    private fun summarize(
        variant: String,
        variantRuns: List<AgentRun>,
        evaluationsByRun: Map<UUID, Evaluation>,
    ): VariantComparison {
        val evaluated = variantRuns.mapNotNull { evaluationsByRun[it.id] }
        val passed = evaluated.count { it.passed }

        return VariantComparison(
            variant = variant,
            runs = variantRuns.size,
            passed = passed,
            passRate = if (evaluated.isEmpty()) 0.0 else passed.toDouble() / evaluated.size,
            acceptanceRate = if (evaluated.isEmpty()) 0.0 else evaluated.map { it.acceptanceRate() }.average(),
            medianToolCalls = median(variantRuns.map { it.behavior.toolCalls.toDouble() }),
            medianModelCalls = median(variantRuns.map { it.behavior.modelCalls.toDouble() }),
            medianTokens = median(variantRuns.mapNotNull { it.efficiency.totalTokens()?.toDouble() }),
            medianDurationMs = median(variantRuns.mapNotNull { it.efficiency.durationMs?.toDouble() }),
            medianRetries = median(variantRuns.map { it.behavior.retries.toDouble() }),
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
