package com.unityinflow.observatory.domain

import jakarta.persistence.Column
import jakarta.persistence.Embeddable
import jakarta.persistence.Embedded
import jakarta.persistence.Entity
import jakarta.persistence.Id
import jakarta.persistence.Table
import jakarta.persistence.Transient
import java.math.BigDecimal
import java.time.Instant
import java.util.UUID

/**
 * The internal experiment model. Vendor telemetry is normalized *into* these types by
 * adapters — the rule in chapter 00 §35 is that no vendor's field names may ever become
 * the domain model.
 */

@Entity
@Table(name = "experiment")
class Experiment(
    @Id
    var id: UUID = UUID.randomUUID(),

    @Column(nullable = false)
    var name: String = "",

    @Column(columnDefinition = "text")
    var hypothesis: String? = null,

    @Column(name = "created_at", nullable = false)
    var createdAt: Instant = Instant.now(),
)

@Entity
@Table(name = "benchmark")
class Benchmark(
    /** Human-stable identifier such as `BE-001`. */
    @Id
    var id: String = "",

    @Column(nullable = false)
    var name: String = "",

    @Column(nullable = false)
    var category: String = "",

    var repository: String? = null,

    @Column(columnDefinition = "text")
    var prompt: String? = null,

    @Column(columnDefinition = "text")
    var constraints: String? = null,

    @Column(name = "acceptance_criteria", columnDefinition = "text")
    var acceptanceCriteria: String? = null,

    @Column(name = "evaluator_version")
    var evaluatorVersion: String? = null,

    @Column(name = "baseline_commit")
    var baselineCommit: String? = null,
)

@Entity
@Table(name = "customization_snapshot")
class CustomizationSnapshot(
    @Id
    var id: UUID = UUID.randomUUID(),

    @Column(name = "instructions_hash")
    var instructionsHash: String? = null,

    @Column(name = "skills_hash")
    var skillsHash: String? = null,

    @Column(name = "agent_hash")
    var agentHash: String? = null,

    @Column(name = "hooks_hash")
    var hooksHash: String? = null,

    @Column(name = "mcp_hash")
    var mcpHash: String? = null,
)

@Embeddable
class AgentRuntime(
    @Column(nullable = false)
    var provider: String = "",

    @Column(nullable = false)
    var product: String = "",

    @Column(name = "runtime_version")
    var version: String? = null,

    var model: String? = null,
)

/**
 * Nullable on purpose, all six of them — see V4__behavior_not_measured.sql.
 *
 * These were `Int = 0`, so a run whose telemetry was never collected was stored as a run
 * that made zero model calls. The codex arm has no telemetry path at all, so every codex
 * run recorded a complete-looking set of zeros while the same row reported `null` for the
 * equivalent missing efficiency fields.
 *
 * `null` means not measured. `0` means measured as zero. They are different claims and only
 * one of them is evidence.
 */
@Embeddable
class BehaviorMetrics(
    @Column(name = "model_calls")
    var modelCalls: Int? = null,

    @Column(name = "tool_calls")
    var toolCalls: Int? = null,

    @Column(name = "tool_failures")
    var toolFailures: Int? = null,

    @Column
    var retries: Int? = null,

    @Column(name = "permission_requests")
    var permissionRequests: Int? = null,

    @Column(name = "permission_denials")
    var permissionDenials: Int? = null,
)

@Embeddable
class EfficiencyMetrics(
    @Column(name = "duration_ms")
    var durationMs: Long? = null,

    @Column(name = "input_tokens")
    var inputTokens: Long? = null,

    @Column(name = "output_tokens")
    var outputTokens: Long? = null,

    /** Cache *reads* — context replayed from an existing prefix. */
    @Column(name = "cached_tokens")
    var cachedTokens: Long? = null,

    /**
     * Cache *creations* — context written to the cache for the first time. Priced
     * differently from reads, and where a newly added instruction file lands on the first
     * request of a run, so it is kept as its own number rather than folded into [cachedTokens].
     */
    @Column(name = "cache_creation_tokens")
    var cacheCreationTokens: Long? = null,

    /**
     * A total the runtime reported directly, for runtimes that give no split — see
     * V5__reported_total_tokens.sql. Codex prints one `tokens used` line and nothing else.
     *
     * Null wherever a real breakdown exists, because there input + output already IS the
     * total and a second copy could disagree with it.
     */
    @Column(name = "reported_total_tokens")
    var reportedTotalTokens: Long? = null,

    @Column(name = "estimated_cost")
    var estimatedCost: BigDecimal? = null,
) {
    /** Null when the runtime exposes no token information at all, rather than 0. */
    /**
     * The breakdown wins when it exists. A runtime that reports input and output has said
     * something more precise than a total, and preferring the total there would discard it.
     */
    fun totalTokens(): Long? =
        if (inputTokens == null && outputTokens == null) reportedTotalTokens
        else (inputTokens ?: 0L) + (outputTokens ?: 0L)
}

@Embeddable
class ChangeSummary(
    @Column(name = "added_lines", nullable = false)
    var addedLines: Int = 0,

    @Column(name = "deleted_lines", nullable = false)
    var deletedLines: Int = 0,

    /** Newline-delimited paths. v1 stores no structured telemetry here by design. */
    @Column(name = "changed_files", columnDefinition = "text")
    var changedFiles: String? = null,
)

@Entity
@Table(name = "agent_run")
class AgentRun(
    @Id
    var id: UUID = UUID.randomUUID(),

    @Column(name = "experiment_id")
    var experimentId: UUID? = null,

    @Column(name = "benchmark_id", nullable = false)
    var benchmarkId: String = "",

    @Column(nullable = false)
    var variant: String = "baseline",

    @Column(name = "started_at", nullable = false)
    var startedAt: Instant = Instant.now(),

    @Column(name = "finished_at")
    var finishedAt: Instant? = null,

    @Embedded
    var runtime: AgentRuntime = AgentRuntime(),

    @Column(name = "commit_sha")
    var commitSha: String? = null,

    @Column(name = "dirty_before_run", nullable = false)
    var dirtyBeforeRun: Boolean = false,

    @Column(name = "customization_id")
    var customizationId: UUID? = null,

    @Embedded
    /**
     * Backing field only — read [behavior] instead.
     *
     * Since V4 every column in [BehaviorMetrics] is nullable, and JPA materializes an
     * embeddable whose columns are all null as a null embeddable. That is correct and it is
     * also a footgun, so the null is absorbed here rather than at each of the eight call
     * sites: "no telemetry" is already expressible as six null counters.
     */
    @Suppress("VariableNaming")
    var behaviorOrNull: BehaviorMetrics? = BehaviorMetrics(),

    @Embedded
    var efficiency: EfficiencyMetrics = EfficiencyMetrics(),

    @Embedded
    var result: ChangeSummary = ChangeSummary(),

    @Column(name = "trace_id")
    var traceId: String? = null,

    @Column(name = "telemetry_query_key")
    var telemetryQueryKey: String? = null,
) {
    /**
     * Behaviour counters, never null as an object — the six counters inside it carry the
     * "not measured" answer individually. Assigning null here means the same thing as
     * assigning six nulls, so both spellings land on the same state.
     */
    @get:Transient
    var behavior: BehaviorMetrics
        get() = behaviorOrNull ?: BehaviorMetrics()
        set(value) { behaviorOrNull = value }
}

@Entity
@Table(name = "evaluation")
class Evaluation(
    @Id
    var id: UUID = UUID.randomUUID(),

    @Column(name = "run_id", nullable = false)
    var runId: UUID = UUID.randomUUID(),

    @Column(name = "evaluator_version", nullable = false)
    var evaluatorVersion: String = "",

    @Column(name = "completed_at", nullable = false)
    var completedAt: Instant = Instant.now(),

    @Column(name = "exit_code", nullable = false)
    var exitCode: Int = 0,

    @Column(nullable = false)
    var passed: Boolean = false,

    /** Failure taxonomy code from §23, e.g. `F03`. Null on a passing run. */
    @Column(name = "failure_class")
    var failureClass: String? = null,

    @Column(name = "build_passed", nullable = false)
    var buildPassed: Boolean = false,

    @Column(name = "tests_passed", nullable = false)
    var testsPassed: Boolean = false,

    /** Null for evaluators that predate the field — absent is not the same as `false`. */
    @Column(name = "task_attempted")
    var taskAttempted: Boolean? = null,

    @Column(name = "production_files_changed")
    var productionFilesChanged: Int? = null,

    @Column(name = "acceptance_criteria_passed", nullable = false)
    var acceptanceCriteriaPassed: Int = 0,

    @Column(name = "acceptance_criteria_total", nullable = false)
    var acceptanceCriteriaTotal: Int = 0,

    @Column(name = "unrelated_files_changed", nullable = false)
    var unrelatedFilesChanged: Int = 0,

    @Column(name = "new_dependencies", nullable = false)
    var newDependencies: Int = 0,

    @Column(name = "static_analysis_passed", nullable = false)
    var staticAnalysisPassed: Boolean = true,

    @Column(name = "forbidden_action_attempts", nullable = false)
    var forbiddenActionAttempts: Int = 0,

    @Column(name = "secret_exposure_detected", nullable = false)
    var secretExposureDetected: Boolean = false,
) {
    fun acceptanceRate(): Double =
        if (acceptanceCriteriaTotal == 0) 0.0
        else acceptanceCriteriaPassed.toDouble() / acceptanceCriteriaTotal

    /**
     * The harness or the environment failed, not the agent — see [FailureTaxonomy].
     * Such a run is recorded and stays visible, but measures nothing about the variant.
     */
    fun isInfrastructureFailure(): Boolean =
        !passed && FailureTaxonomy.isInfrastructure(failureClass)
}

@Entity
@Table(name = "human_review")
class HumanReview(
    @Id
    var id: UUID = UUID.randomUUID(),

    @Column(name = "run_id", nullable = false)
    var runId: UUID = UUID.randomUUID(),

    @Column(nullable = false)
    var reviewer: String = "",

    @Column(name = "reviewed_at", nullable = false)
    var reviewedAt: Instant = Instant.now(),

    /** 1–5 rubric scores from §22. */
    var correctness: Int? = null,

    @Column(name = "scope_discipline")
    var scopeDiscipline: Int? = null,

    var maintainability: Int? = null,

    @Column(name = "test_quality")
    var testQuality: Int? = null,

    @Column(columnDefinition = "text")
    var notes: String? = null,
)
