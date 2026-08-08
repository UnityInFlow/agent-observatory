package com.unityinflow.observatory.api

import com.unityinflow.observatory.domain.AgentRunRepository
import com.unityinflow.observatory.domain.Benchmark
import com.unityinflow.observatory.domain.BenchmarkRepository
import com.unityinflow.observatory.domain.ExperimentRepository
import com.unityinflow.observatory.service.ComparisonService
import com.unityinflow.observatory.service.NotFoundException
import com.unityinflow.observatory.service.RunService
import jakarta.validation.Valid
import java.util.UUID
import org.springframework.http.HttpStatus
import org.springframework.http.ProblemDetail
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.ExceptionHandler
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RequestParam
import org.springframework.web.bind.annotation.RestController
import org.springframework.web.bind.annotation.RestControllerAdvice

@RestController
@RequestMapping("/api/runs")
class RunController(private val runService: RunService) {

    @PostMapping
    fun create(@Valid @RequestBody request: CreateRunRequest): ResponseEntity<RunResponse> {
        val created = runService.createRun(request)
        return ResponseEntity.status(HttpStatus.CREATED).body(created)
    }

    @GetMapping
    fun list(
        @RequestParam(required = false) benchmarkId: String?,
        @RequestParam(required = false) variant: String?,
        @RequestParam(required = false) runtime: String?,
    ): List<RunResponse> = runService.listRuns(benchmarkId, variant, runtime)

    @GetMapping("/{id}")
    fun get(@PathVariable id: UUID): RunResponse = runService.getRun(id)

    @PostMapping("/{id}/evaluation")
    fun evaluate(
        @PathVariable id: UUID,
        @Valid @RequestBody request: CreateEvaluationRequest,
    ): RunResponse = runService.recordEvaluation(id, request)

    @PostMapping("/{id}/human-review")
    fun review(
        @PathVariable id: UUID,
        @Valid @RequestBody request: CreateHumanReviewRequest,
    ): RunResponse = runService.addHumanReview(id, request)
}

@RestController
@RequestMapping("/api/experiments")
class ExperimentController(
    private val comparisonService: ComparisonService,
    private val experiments: ExperimentRepository,
) {

    @GetMapping
    fun list(): List<Map<String, Any?>> = experiments.findAll().map {
        mapOf("id" to it.id, "key" to it.name, "hypothesis" to it.hypothesis, "createdAt" to it.createdAt)
    }

    /** Accepts either the UUID or the human key such as `EXP-001`. */
    @GetMapping("/{ref}/comparison")
    fun comparison(@PathVariable ref: String): ComparisonResponse = comparisonService.compare(ref)
}

@RestController
@RequestMapping("/api/benchmarks")
class BenchmarkController(
    private val benchmarks: BenchmarkRepository,
    private val runs: AgentRunRepository,
) {

    @PostMapping
    fun upsert(@Valid @RequestBody request: UpsertBenchmarkRequest): ResponseEntity<BenchmarkResponse> {
        val existing = benchmarks.findById(request.id).orElse(null)
        val benchmark = (existing ?: Benchmark(id = request.id)).apply {
            name = request.name
            category = request.category
            repository = request.repository
            prompt = request.prompt
            constraints = request.constraints
            acceptanceCriteria = request.acceptanceCriteria
            evaluatorVersion = request.evaluatorVersion
            baselineCommit = request.baselineCommit
        }
        val saved = benchmarks.save(benchmark)
        val status = if (existing == null) HttpStatus.CREATED else HttpStatus.OK
        return ResponseEntity.status(status).body(saved.toResponse(0))
    }

    @GetMapping
    fun list(): List<BenchmarkResponse> = benchmarks.findAll().map { benchmark ->
        benchmark.toResponse(runs.search(benchmark.id, null, null).size)
    }

    @GetMapping("/{id}")
    fun get(@PathVariable id: String): BenchmarkResponse =
        benchmarks.findById(id)
            .map { it.toResponse(runs.search(id, null, null).size) }
            .orElseThrow { NotFoundException("Unknown benchmark '$id'") }

    private fun Benchmark.toResponse(runCount: Int) = BenchmarkResponse(
        id = id,
        name = name,
        category = category,
        repository = repository,
        prompt = prompt,
        constraints = constraints,
        acceptanceCriteria = acceptanceCriteria,
        evaluatorVersion = evaluatorVersion,
        baselineCommit = baselineCommit,
        runCount = runCount,
    )
}

@RestControllerAdvice
class ApiExceptionHandler {

    @ExceptionHandler(NotFoundException::class)
    fun handleNotFound(ex: NotFoundException): ProblemDetail =
        ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, ex.message ?: "Not found").apply {
            title = "Resource not found"
        }
}
