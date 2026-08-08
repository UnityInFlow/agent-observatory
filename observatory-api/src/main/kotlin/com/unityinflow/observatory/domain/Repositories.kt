package com.unityinflow.observatory.domain

import java.util.UUID
import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.data.jpa.repository.Query
import org.springframework.data.repository.query.Param

interface ExperimentRepository : JpaRepository<Experiment, UUID> {
    fun findByName(name: String): Experiment?
}

interface BenchmarkRepository : JpaRepository<Benchmark, String>

interface CustomizationSnapshotRepository : JpaRepository<CustomizationSnapshot, UUID>

interface AgentRunRepository : JpaRepository<AgentRun, UUID> {

    fun findAllByOrderByStartedAtDesc(): List<AgentRun>

    fun findByExperimentId(experimentId: UUID): List<AgentRun>

    @Query(
        """
        select r from AgentRun r
        where (:benchmarkId is null or r.benchmarkId = :benchmarkId)
          and (:variant     is null or r.variant     = :variant)
          and (:provider    is null or r.runtime.provider = :provider)
        order by r.startedAt desc
        """,
    )
    fun search(
        @Param("benchmarkId") benchmarkId: String?,
        @Param("variant") variant: String?,
        @Param("provider") provider: String?,
    ): List<AgentRun>
}

interface EvaluationRepository : JpaRepository<Evaluation, UUID> {
    fun findByRunId(runId: UUID): Evaluation?
    fun findByRunIdIn(runIds: Collection<UUID>): List<Evaluation>
}

interface HumanReviewRepository : JpaRepository<HumanReview, UUID> {
    fun findByRunIdOrderByReviewedAtDesc(runId: UUID): List<HumanReview>
}
