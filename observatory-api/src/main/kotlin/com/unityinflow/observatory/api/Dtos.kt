package com.unityinflow.observatory.api

import jakarta.validation.Valid
import jakarta.validation.constraints.Max
import jakarta.validation.constraints.Min
import jakarta.validation.constraints.NotBlank
import java.math.BigDecimal
import java.time.Instant
import java.util.UUID

/**
 * Wire contract for the runner. Shapes follow chapter 00 §12 (run record) and §13
 * (evaluation record) so `run.json` / `evaluation.json` can be POSTed unchanged.
 */

data class RuntimeDto(
    @field:NotBlank val provider: String,
    @field:NotBlank val product: String,
    val version: String? = null,
    val model: String? = null,
)

data class RepositoryDto(
    val commitSha: String? = null,
    val dirtyBeforeRun: Boolean = false,
)

data class CustomizationDto(
    val instructionsHash: String? = null,
    val skillsHash: String? = null,
    val agentHash: String? = null,
    val hooksHash: String? = null,
    val mcpHash: String? = null,
) {
    // Deliberately not named isEmpty()/getX(): Jackson would treat a getter-shaped helper
    // as a real property and serialize it into the API response.
    fun hasNoHashes(): Boolean =
        listOf(instructionsHash, skillsHash, agentHash, hooksHash, mcpHash).all { it == null }
}

data class BehaviorDto(
    val modelCalls: Int = 0,
    val toolCalls: Int = 0,
    val toolFailures: Int = 0,
    val retries: Int = 0,
    val permissionRequests: Int = 0,
    val permissionDenials: Int = 0,
)

data class EfficiencyDto(
    val durationMs: Long? = null,
    val inputTokens: Long? = null,
    val outputTokens: Long? = null,
    /** Cache reads. */
    val cachedTokens: Long? = null,
    /** Cache creations — separate from reads because they are priced differently. */
    val cacheCreationTokens: Long? = null,
    val estimatedCost: BigDecimal? = null,
)

data class ResultDto(
    val changedFiles: List<String> = emptyList(),
    val addedLines: Int = 0,
    val deletedLines: Int = 0,
)

data class CreateRunRequest(
    /** Optional: the runner generates the id so it can be used as an OTel resource attribute. */
    val runId: UUID? = null,
    /** Human-readable experiment key such as `EXP-001`; resolved or created server-side. */
    val experimentId: String? = null,
    @field:NotBlank val benchmarkId: String,
    @field:NotBlank val variant: String,
    val startedAt: Instant? = null,
    val finishedAt: Instant? = null,
    @field:Valid val runtime: RuntimeDto,
    val repository: RepositoryDto = RepositoryDto(),
    val customization: CustomizationDto = CustomizationDto(),
    val behavior: BehaviorDto = BehaviorDto(),
    val efficiency: EfficiencyDto = EfficiencyDto(),
    val result: ResultDto = ResultDto(),
    val traceId: String? = null,
    val telemetryQueryKey: String? = null,
)

data class CorrectnessDto(
    val buildPassed: Boolean,
    val testsPassed: Boolean,
    val acceptanceSuitePassed: Boolean = false,
    val acceptanceCriteriaPassed: Int = 0,
    val acceptanceCriteriaTotal: Int = 0,
    /**
     * Whether the agent changed any production file at all. Nullable on purpose: an
     * evaluator that predates the field says nothing about it, and that is not the same
     * claim as "the task was not attempted". Only an explicit `false` condemns a run.
     */
    val taskAttempted: Boolean? = null,
    val productionFilesChanged: Int? = null,
)

data class QualityDto(
    val unrelatedFilesChanged: Int = 0,
    val newDependencies: Int = 0,
    val staticAnalysisPassed: Boolean = true,
)

data class SafetyDto(
    val forbiddenActionAttempts: Int = 0,
    val secretExposureDetected: Boolean = false,
)

data class CreateEvaluationRequest(
    @field:NotBlank val evaluatorVersion: String,
    val completedAt: Instant? = null,
    val exitCode: Int = 0,
    val passed: Boolean? = null,
    /** §23 taxonomy code such as `F03`. */
    val failureClass: String? = null,
    @field:Valid val correctness: CorrectnessDto,
    val quality: QualityDto = QualityDto(),
    val safety: SafetyDto = SafetyDto(),
)

data class CreateHumanReviewRequest(
    @field:NotBlank val reviewer: String,
    @field:Min(1) @field:Max(5) val correctness: Int? = null,
    @field:Min(1) @field:Max(5) val scopeDiscipline: Int? = null,
    @field:Min(1) @field:Max(5) val maintainability: Int? = null,
    @field:Min(1) @field:Max(5) val testQuality: Int? = null,
    val notes: String? = null,
)

/**
 * Backfills behaviour/efficiency for a run whose telemetry was unavailable when it was
 * first recorded — a collector outage, or an adapter that did not exist yet. Only
 * non-null fields are applied, so a partial backfill cannot erase what is already there.
 */
data class UpdateTelemetryRequest(
    val behavior: BehaviorDto? = null,
    val efficiency: EfficiencyDto? = null,
    val traceId: String? = null,
)

data class UpsertBenchmarkRequest(
    @field:NotBlank val id: String,
    @field:NotBlank val name: String,
    @field:NotBlank val category: String,
    val repository: String? = null,
    val prompt: String? = null,
    val constraints: String? = null,
    val acceptanceCriteria: String? = null,
    val evaluatorVersion: String? = null,
    val baselineCommit: String? = null,
)

// ---------------------------------------------------------------------------
// Responses
// ---------------------------------------------------------------------------

data class EvaluationResponse(
    val evaluatorVersion: String,
    val completedAt: Instant,
    val exitCode: Int,
    val passed: Boolean,
    val failureClass: String?,
    /**
     * F13/F15 — the harness or the environment failed, not the agent. Derived from the
     * same [com.unityinflow.observatory.domain.FailureTaxonomy] the comparison uses, so a
     * run cannot read as "discarded" on one screen and "failed" on another.
     */
    val infrastructureFailure: Boolean,
    val buildPassed: Boolean,
    val testsPassed: Boolean,
    /**
     * Null when the evaluator did not report it. `false` means the agent changed no
     * production file, so the run is not evidence about the code it would have written —
     * see the analyzer, which refuses a batch containing such runs rather than averaging
     * them in.
     */
    val taskAttempted: Boolean?,
    val productionFilesChanged: Int?,
    val acceptanceCriteriaPassed: Int,
    val acceptanceCriteriaTotal: Int,
    val acceptanceRate: Double,
    val unrelatedFilesChanged: Int,
    val newDependencies: Int,
    val staticAnalysisPassed: Boolean,
    val forbiddenActionAttempts: Int,
    val secretExposureDetected: Boolean,
)

data class HumanReviewResponse(
    val id: UUID,
    val reviewer: String,
    val reviewedAt: Instant,
    val correctness: Int?,
    val scopeDiscipline: Int?,
    val maintainability: Int?,
    val testQuality: Int?,
    val notes: String?,
)

data class RunResponse(
    val runId: UUID,
    val experimentId: UUID?,
    val experimentKey: String?,
    val benchmarkId: String,
    val variant: String,
    val startedAt: Instant,
    val finishedAt: Instant?,
    val runtime: RuntimeDto,
    val repository: RepositoryDto,
    val customization: CustomizationDto,
    val behavior: BehaviorDto,
    val efficiency: EfficiencyDto,
    val result: ResultDto,
    val traceId: String?,
    val telemetryQueryKey: String?,
    /** Deep link into Grafana/Tempo — the UI must not rebuild a trace viewer (§17). */
    val traceUrl: String?,
    val evaluation: EvaluationResponse?,
    val humanReviews: List<HumanReviewResponse> = emptyList(),
)

data class VariantComparison(
    val variant: String,
    /** Runs that actually measure this variant — infrastructure failures are not among them. */
    val runs: Int,
    /**
     * §23 F13/F15 — runs discarded as harness or environment failures (#19). Excluded from
     * every number below and from the §20 minimum, but surfaced so they never vanish silently.
     */
    val infrastructureFailures: Int,
    val passed: Int,
    /** Null when no run in this arm measured the variant — never 0.0, which reads as failure. */
    val passRate: Double?,
    val acceptanceRate: Double?,
    val medianToolCalls: Double?,
    val medianModelCalls: Double?,
    /** Billable input + output. Excludes cache, which is usually the larger number. */
    val medianTokens: Double?,
    /**
     * Cache reads plus creations. On a Claude run these outnumber input+output ~100:1, and
     * an instruction file's whole footprint is extra context — so a token comparison that
     * omits them measures everything except the thing being varied.
     */
    val medianCacheTokens: Double?,
    /**
     * Creations alone. A newly installed AGENTS.md is written to the cache on the first
     * request of every run, so this is the component a B0/B1 comparison moves most directly.
     */
    val medianCacheCreationTokens: Double?,
    /** Vendor-reported cost in USD where the runtime documents one; null where it does not. */
    val medianEstimatedCost: Double?,
    val medianDurationMs: Double?,
    val medianRetries: Double?,
    val meanUnrelatedFilesChanged: Double?,
    val failureClasses: Map<String, Int>,
)

data class ComparisonResponse(
    val experimentId: UUID?,
    val experimentKey: String?,
    /** Every run recorded, including the infrastructure failures the variants exclude. */
    val totalRuns: Int,
    val variants: List<VariantComparison>,
    /** §20: one successful run proves very little. */
    val warning: String?,
)

data class BenchmarkResponse(
    val id: String,
    val name: String,
    val category: String,
    val repository: String?,
    val prompt: String?,
    val constraints: String?,
    val acceptanceCriteria: String?,
    val evaluatorVersion: String?,
    val baselineCommit: String?,
    val runCount: Int = 0,
)
