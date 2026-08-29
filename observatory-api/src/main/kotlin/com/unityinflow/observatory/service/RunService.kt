package com.unityinflow.observatory.service

import com.unityinflow.observatory.api.BehaviorDto
import com.unityinflow.observatory.api.CreateEvaluationRequest
import com.unityinflow.observatory.api.CreateHumanReviewRequest
import com.unityinflow.observatory.api.CreateRunRequest
import com.unityinflow.observatory.api.CustomizationDto
import com.unityinflow.observatory.api.EfficiencyDto
import com.unityinflow.observatory.api.EvaluationResponse
import com.unityinflow.observatory.api.HumanReviewResponse
import com.unityinflow.observatory.api.RepositoryDto
import com.unityinflow.observatory.api.ResultDto
import com.unityinflow.observatory.api.RunResponse
import com.unityinflow.observatory.api.RuntimeDto
import com.unityinflow.observatory.api.UpdateTelemetryRequest
import com.unityinflow.observatory.config.ObservatoryProperties
import com.unityinflow.observatory.domain.AgentRun
import com.unityinflow.observatory.domain.AgentRunRepository
import com.unityinflow.observatory.domain.AgentRuntime
import com.unityinflow.observatory.domain.BehaviorMetrics
import com.unityinflow.observatory.domain.BenchmarkRepository
import com.unityinflow.observatory.domain.ChangeSummary
import com.unityinflow.observatory.domain.CustomizationSnapshot
import com.unityinflow.observatory.domain.CustomizationSnapshotRepository
import com.unityinflow.observatory.domain.EfficiencyMetrics
import com.unityinflow.observatory.domain.Evaluation
import com.unityinflow.observatory.domain.EvaluationRepository
import com.unityinflow.observatory.domain.Experiment
import com.unityinflow.observatory.domain.ExperimentRepository
import com.unityinflow.observatory.domain.HumanReview
import com.unityinflow.observatory.domain.HumanReviewRepository
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.util.UUID
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional

class NotFoundException(message: String) : RuntimeException(message)

@Service
@Transactional
class RunService(
    private val runs: AgentRunRepository,
    private val evaluations: EvaluationRepository,
    private val reviews: HumanReviewRepository,
    private val experiments: ExperimentRepository,
    private val benchmarks: BenchmarkRepository,
    private val customizations: CustomizationSnapshotRepository,
    private val metrics: ObservatoryMetrics,
    private val properties: ObservatoryProperties,
) {

    fun createRun(request: CreateRunRequest): RunResponse {
        if (!benchmarks.existsById(request.benchmarkId)) {
            throw NotFoundException(
                "Unknown benchmark '${request.benchmarkId}'. Register it via POST /api/benchmarks first.",
            )
        }

        val experiment = request.experimentId?.takeIf { it.isNotBlank() }?.let(::resolveExperiment)

        val customizationId = request.customization
            .takeIf { !it.hasNoHashes() }
            ?.let {
                customizations.save(
                    CustomizationSnapshot(
                        instructionsHash = it.instructionsHash,
                        skillsHash = it.skillsHash,
                        agentHash = it.agentHash,
                        hooksHash = it.hooksHash,
                        mcpHash = it.mcpHash,
                    ),
                ).id
            }

        val run = AgentRun(
            id = request.runId ?: UUID.randomUUID(),
            experimentId = experiment?.id,
            benchmarkId = request.benchmarkId,
            variant = request.variant,
            startedAt = request.startedAt ?: Instant.now(),
            finishedAt = request.finishedAt,
            runtime = AgentRuntime(
                provider = request.runtime.provider,
                product = request.runtime.product,
                version = request.runtime.version,
                model = request.runtime.model,
            ),
            commitSha = request.repository.commitSha,
            dirtyBeforeRun = request.repository.dirtyBeforeRun,
            customizationId = customizationId,
            behaviorOrNull = BehaviorMetrics(
                modelCalls = request.behavior.modelCalls,
                toolCalls = request.behavior.toolCalls,
                toolFailures = request.behavior.toolFailures,
                retries = request.behavior.retries,
                permissionRequests = request.behavior.permissionRequests,
                permissionDenials = request.behavior.permissionDenials,
            ),
            efficiency = EfficiencyMetrics(
                durationMs = request.efficiency.durationMs,
                inputTokens = request.efficiency.inputTokens,
                outputTokens = request.efficiency.outputTokens,
                cachedTokens = request.efficiency.cachedTokens,
                cacheCreationTokens = request.efficiency.cacheCreationTokens,
                reportedTotalTokens = request.efficiency.reportedTotalTokens,
                estimatedCost = request.efficiency.estimatedCost,
            ),
            result = ChangeSummary(
                addedLines = request.result.addedLines,
                deletedLines = request.result.deletedLines,
                changedFiles = request.result.changedFiles
                    .takeIf { it.isNotEmpty() }
                    ?.joinToString("\n"),
            ),
            traceId = request.traceId,
            telemetryQueryKey = request.telemetryQueryKey,
        )

        return toResponse(runs.save(run))
    }

    @Transactional(readOnly = true)
    fun listRuns(benchmarkId: String?, variant: String?, provider: String?): List<RunResponse> =
        runs.search(benchmarkId?.ifBlank { null }, variant?.ifBlank { null }, provider?.ifBlank { null })
            .map(::toResponse)

    @Transactional(readOnly = true)
    fun getRun(runId: UUID): RunResponse = toResponse(requireRun(runId))

    fun recordEvaluation(runId: UUID, request: CreateEvaluationRequest): RunResponse {
        val run = requireRun(runId)

        // An evaluation is 1:1 with a run; re-running the evaluator overwrites in place
        // rather than accumulating conflicting verdicts for the same run.
        val evaluation = evaluations.findByRunId(runId) ?: Evaluation(runId = runId)
        evaluation.apply {
            evaluatorVersion = request.evaluatorVersion
            completedAt = request.completedAt ?: Instant.now()
            exitCode = request.exitCode
            passed = request.passed ?: (request.exitCode == 0)
            failureClass = request.failureClass?.takeIf { it.isNotBlank() }
            buildPassed = request.correctness.buildPassed
            testsPassed = request.correctness.testsPassed
            taskAttempted = request.correctness.taskAttempted
            productionFilesChanged = request.correctness.productionFilesChanged
            acceptanceCriteriaPassed = request.correctness.acceptanceCriteriaPassed
            acceptanceCriteriaTotal = request.correctness.acceptanceCriteriaTotal
            unrelatedFilesChanged = request.quality.unrelatedFilesChanged
            newDependencies = request.quality.newDependencies
            staticAnalysisPassed = request.quality.staticAnalysisPassed
            forbiddenActionAttempts = request.safety.forbiddenActionAttempts
            secretExposureDetected = request.safety.secretExposureDetected
        }
        evaluations.save(evaluation)

        val category = benchmarks.findById(run.benchmarkId).map { it.category }.orElse("unknown")
        metrics.recordRun(run, evaluation, category)

        return toResponse(run)
    }

    /**
     * Backfill telemetry for an already-recorded run. Needed because a run whose trace
     * was unavailable at record time otherwise contributes zeros to every aggregate, and
     * a missing measurement averaged as zero biases the agent to look cheaper than it was.
     */
    fun updateTelemetry(runId: UUID, request: UpdateTelemetryRequest): RunResponse {
        val run = requireRun(runId)

        request.behavior?.let {
            run.behavior = BehaviorMetrics(
                modelCalls = it.modelCalls,
                toolCalls = it.toolCalls,
                toolFailures = it.toolFailures,
                retries = it.retries,
                permissionRequests = it.permissionRequests,
                permissionDenials = it.permissionDenials,
            )
        }

        // Field-by-field so a partial payload cannot wipe values already recorded —
        // durationMs in particular is measured by the runner, not read from telemetry.
        request.efficiency?.let {
            run.efficiency = EfficiencyMetrics(
                durationMs = it.durationMs ?: run.efficiency.durationMs,
                inputTokens = it.inputTokens ?: run.efficiency.inputTokens,
                outputTokens = it.outputTokens ?: run.efficiency.outputTokens,
                cachedTokens = it.cachedTokens ?: run.efficiency.cachedTokens,
                cacheCreationTokens = it.cacheCreationTokens ?: run.efficiency.cacheCreationTokens,
                estimatedCost = it.estimatedCost ?: run.efficiency.estimatedCost,
            )
        }

        request.traceId?.takeIf { it.isNotBlank() }?.let { run.traceId = it }

        return toResponse(runs.save(run))
    }

    /**
     * Discard a run. Intended for runs invalidated by the *harness* rather than by the
     * agent — a contaminated worktree, a mis-set variable, a bug in the runner. Keeping
     * such a run would silently corrupt every aggregate it appears in, and there is no
     * honest way to interpret it after the fact.
     *
     * Evaluations and human reviews are removed with it (ON DELETE CASCADE in V1).
     */
    fun deleteRun(runId: UUID) {
        val run = requireRun(runId)
        evaluations.findByRunId(runId)?.let(evaluations::delete)
        reviews.findByRunIdOrderByReviewedAtDesc(runId).forEach(reviews::delete)
        runs.delete(run)
    }

    fun addHumanReview(runId: UUID, request: CreateHumanReviewRequest): RunResponse {
        val run = requireRun(runId)
        reviews.save(
            HumanReview(
                runId = run.id,
                reviewer = request.reviewer,
                reviewedAt = Instant.now(),
                correctness = request.correctness,
                scopeDiscipline = request.scopeDiscipline,
                maintainability = request.maintainability,
                testQuality = request.testQuality,
                notes = request.notes,
            ),
        )
        return toResponse(run)
    }

    private fun requireRun(runId: UUID): AgentRun =
        runs.findById(runId).orElseThrow { NotFoundException("Unknown run '$runId'") }

    private fun resolveExperiment(key: String): Experiment =
        experiments.findByName(key) ?: experiments.save(Experiment(name = key))

    fun toResponse(run: AgentRun): RunResponse {
        val evaluation = evaluations.findByRunId(run.id)
        val experimentKey = run.experimentId?.let { id -> experiments.findById(id).map { it.name }.orElse(null) }

        return RunResponse(
            runId = run.id,
            experimentId = run.experimentId,
            experimentKey = experimentKey,
            benchmarkId = run.benchmarkId,
            variant = run.variant,
            startedAt = run.startedAt,
            finishedAt = run.finishedAt,
            runtime = RuntimeDto(
                run.runtime.provider,
                run.runtime.product,
                run.runtime.version,
                run.runtime.model,
            ),
            repository = RepositoryDto(run.commitSha, run.dirtyBeforeRun),
            customization = run.customizationId
                ?.let { id -> customizations.findById(id).orElse(null) }
                ?.let {
                    CustomizationDto(
                        it.instructionsHash,
                        it.skillsHash,
                        it.agentHash,
                        it.hooksHash,
                        it.mcpHash,
                    )
                }
                ?: CustomizationDto(),
            behavior = BehaviorDto(
                modelCalls = run.behavior.modelCalls,
                toolCalls = run.behavior.toolCalls,
                toolFailures = run.behavior.toolFailures,
                retries = run.behavior.retries,
                permissionRequests = run.behavior.permissionRequests,
                permissionDenials = run.behavior.permissionDenials,
            ),
            // Named, not positional. Adding reportedTotalTokens ahead of estimatedCost in a
            // positional call would have shifted the cost into it silently and compiled.
            efficiency = EfficiencyDto(
                durationMs = run.efficiency.durationMs,
                inputTokens = run.efficiency.inputTokens,
                outputTokens = run.efficiency.outputTokens,
                cachedTokens = run.efficiency.cachedTokens,
                cacheCreationTokens = run.efficiency.cacheCreationTokens,
                reportedTotalTokens = run.efficiency.reportedTotalTokens,
                estimatedCost = run.efficiency.estimatedCost,
            ),
            result = ResultDto(
                changedFiles = run.result.changedFiles?.lines()?.filter { it.isNotBlank() } ?: emptyList(),
                addedLines = run.result.addedLines,
                deletedLines = run.result.deletedLines,
            ),
            traceId = run.traceId,
            telemetryQueryKey = run.telemetryQueryKey,
            traceUrl = buildTraceUrl(run),
            evaluation = evaluation?.let {
                EvaluationResponse(
                    evaluatorVersion = it.evaluatorVersion,
                    completedAt = it.completedAt,
                    exitCode = it.exitCode,
                    passed = it.passed,
                    failureClass = it.failureClass,
                    infrastructureFailure = it.isInfrastructureFailure(),
                    buildPassed = it.buildPassed,
                    testsPassed = it.testsPassed,
                    taskAttempted = it.taskAttempted,
                    productionFilesChanged = it.productionFilesChanged,
                    acceptanceCriteriaPassed = it.acceptanceCriteriaPassed,
                    acceptanceCriteriaTotal = it.acceptanceCriteriaTotal,
                    acceptanceRate = it.acceptanceRate(),
                    unrelatedFilesChanged = it.unrelatedFilesChanged,
                    newDependencies = it.newDependencies,
                    staticAnalysisPassed = it.staticAnalysisPassed,
                    forbiddenActionAttempts = it.forbiddenActionAttempts,
                    secretExposureDetected = it.secretExposureDetected,
                )
            },
            humanReviews = reviews.findByRunIdOrderByReviewedAtDesc(run.id).map {
                HumanReviewResponse(
                    it.id, it.reviewer, it.reviewedAt,
                    it.correctness, it.scopeDiscipline, it.maintainability, it.testQuality, it.notes,
                )
            },
        )
    }

    /**
     * Deep link into Grafana Explore. §17: the Observatory links to the trace viewer
     * instead of trying to recreate distributed tracing itself.
     */
    private fun buildTraceUrl(run: AgentRun): String? {
        val uid = properties.grafana.tempoDatasourceUid
        val query = run.traceId
            ?: run.telemetryQueryKey
            ?: """{ resource.observatory.run.id = "${run.id}" }"""
        val pane = """{"obs":{"datasource":"$uid","queries":[{"refId":"A","datasource":{"type":"tempo","uid":"$uid"},"queryType":"traceql","query":${jsonString(query)}}],"range":{"from":"now-24h","to":"now"}}}"""
        val encoded = URLEncoder.encode(pane, StandardCharsets.UTF_8)
        return "${properties.grafana.baseUrl.trimEnd('/')}/explore?schemaVersion=1&orgId=1&panes=$encoded"
    }

    private fun jsonString(value: String): String =
        '"' + value.replace("\\", "\\\\").replace("\"", "\\\"") + '"'
}
