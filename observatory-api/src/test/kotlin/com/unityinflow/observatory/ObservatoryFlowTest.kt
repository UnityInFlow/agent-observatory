package com.unityinflow.observatory

import com.jayway.jsonpath.JsonPath
import org.junit.jupiter.api.Test
import org.springframework.beans.factory.annotation.Autowired
import org.springframework.boot.micrometer.metrics.test.autoconfigure.AutoConfigureMetrics
import org.springframework.boot.test.context.SpringBootTest
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc
import org.springframework.http.MediaType
import org.springframework.test.web.servlet.MockMvc
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch
import org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath
import org.springframework.test.web.servlet.result.MockMvcResultMatchers.status

/**
 * Exercises the whole M4–M6 contract the runner depends on:
 * register benchmark → record run → record evaluation → human review → compare.
 */
@SpringBootTest
@AutoConfigureMockMvc
// Spring Boot disables metrics export in tests by default; §15 needs a real scrape.
@AutoConfigureMetrics
class ObservatoryFlowTest : AbstractIntegrationTest() {

    @Autowired
    lateinit var mockMvc: MockMvc

    private fun registerBenchmark(id: String) {
        mockMvc.perform(
            post("/api/benchmarks").contentType(MediaType.APPLICATION_JSON).content(
                """
                {
                  "id": "$id",
                  "name": "customer-id-validation",
                  "category": "bugfix",
                  "repository": "sample-service",
                  "prompt": "Reject blank customerId with HTTP 400.",
                  "evaluatorVersion": "1.0.0",
                  "baselineCommit": "abc123"
                }
                """.trimIndent(),
            ),
        ).andExpect(status().isCreated)
    }

    private fun createRun(
        benchmarkId: String,
        experiment: String,
        variant: String,
        toolCalls: Int,
        durationMs: Long,
        provider: String = "github",
        model: String = "gpt-x",
    ): String {
        val body = mockMvc.perform(
            post("/api/runs").contentType(MediaType.APPLICATION_JSON).content(
                """
                {
                  "experimentId": "$experiment",
                  "benchmarkId": "$benchmarkId",
                  "variant": "$variant",
                  "runtime": { "provider": "$provider", "product": "cli", "version": "0.0.1", "model": "$model" },
                  "repository": { "commitSha": "abc123", "dirtyBeforeRun": false },
                  "customization": { "instructionsHash": "sha256:deadbeef" },
                  "behavior": { "modelCalls": 6, "toolCalls": $toolCalls, "toolFailures": 1, "retries": 2 },
                  "efficiency": { "durationMs": $durationMs, "inputTokens": 20000, "outputTokens": 8000 },
                  "result": { "changedFiles": ["a/Customer.kt"], "addedLines": 12, "deletedLines": 3 }
                }
                """.trimIndent(),
            ),
        )
            .andExpect(status().isCreated)
            .andExpect(jsonPath("$.runId").exists())
            .andReturn().response.contentAsString

        return JsonPath.read(body, "$.runId")
    }

    private fun evaluate(runId: String, passed: Boolean, failureClass: String = "F03") {
        val exit = if (passed) 0 else 12
        mockMvc.perform(
            post("/api/runs/$runId/evaluation").contentType(MediaType.APPLICATION_JSON).content(
                """
                {
                  "evaluatorVersion": "1.0.0",
                  "exitCode": $exit,
                  "failureClass": ${if (passed) "null" else "\"$failureClass\""},
                  "correctness": {
                    "buildPassed": true,
                    "testsPassed": true,
                    "acceptanceSuitePassed": $passed,
                    "acceptanceCriteriaPassed": ${if (passed) 6 else 4},
                    "acceptanceCriteriaTotal": 6
                  },
                  "quality": { "unrelatedFilesChanged": 0, "newDependencies": 0, "staticAnalysisPassed": true },
                  "safety": { "forbiddenActionAttempts": 0, "secretExposureDetected": false }
                }
                """.trimIndent(),
            ),
        ).andExpect(status().isOk)
    }

    @Test
    fun `records a run, its evaluation and a human review, then exposes them on the detail endpoint`() {
        registerBenchmark("BE-FLOW-1")
        val runId = createRun("BE-FLOW-1", "EXP-FLOW-1", "baseline", toolCalls = 23, durationMs = 182_000)
        evaluate(runId, passed = true)

        mockMvc.perform(
            post("/api/runs/$runId/human-review").contentType(MediaType.APPLICATION_JSON).content(
                """{"reviewer":"jiri","correctness":5,"scopeDiscipline":4,"maintainability":4,"testQuality":3}""",
            ),
        ).andExpect(status().isOk)

        mockMvc.perform(get("/api/runs/$runId"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.benchmarkId").value("BE-FLOW-1"))
            .andExpect(jsonPath("$.experimentKey").value("EXP-FLOW-1"))
            .andExpect(jsonPath("$.evaluation.passed").value(true))
            .andExpect(jsonPath("$.evaluation.acceptanceRate").value(1.0))
            // §12: customization hashes make a variant reproducible, not just labelled.
            .andExpect(jsonPath("$.customization.instructionsHash").value("sha256:deadbeef"))
            // Guard against getter-shaped Kotlin helpers leaking into the wire contract.
            .andExpect(jsonPath("$.customization.isEmpty").doesNotExist())
            .andExpect(jsonPath("$.customization.empty").doesNotExist())
            // §17: the UI deep-links to Tempo rather than rebuilding a trace viewer.
            .andExpect(jsonPath("$.traceUrl").exists())
            .andExpect(jsonPath("$.humanReviews[0].reviewer").value("jiri"))
    }

    @Test
    fun `re-running the evaluator overwrites the verdict instead of duplicating it`() {
        registerBenchmark("BE-FLOW-2")
        val runId = createRun("BE-FLOW-2", "EXP-FLOW-2", "baseline", toolCalls = 10, durationMs = 1000)

        evaluate(runId, passed = false)
        evaluate(runId, passed = true)

        mockMvc.perform(get("/api/runs/$runId"))
            .andExpect(jsonPath("$.evaluation.passed").value(true))
            .andExpect(jsonPath("$.evaluation.failureClass").doesNotExist())
    }

    @Test
    fun `backfills telemetry without erasing what the runner already measured`() {
        registerBenchmark("BE-FLOW-6")
        val runId = createRun("BE-FLOW-6", "EXP-BACKFILL", "baseline", toolCalls = 0, durationMs = 49_000)

        // A run recorded before its trace was available: duration measured by the runner,
        // behaviour metrics absent.
        mockMvc.perform(
            patch("/api/runs/$runId/telemetry").contentType(MediaType.APPLICATION_JSON).content(
                """
                {
                  "behavior": { "modelCalls": 10, "toolCalls": 15, "toolFailures": 1 },
                  "efficiency": { "inputTokens": 243872, "outputTokens": 2579, "cachedTokens": 225280 },
                  "traceId": "8439c5f1006ab0812abc6684d7fe512"
                }
                """.trimIndent(),
            ),
        ).andExpect(status().isOk)

        mockMvc.perform(get("/api/runs/$runId"))
            .andExpect(jsonPath("$.behavior.toolCalls").value(15))
            .andExpect(jsonPath("$.behavior.modelCalls").value(10))
            .andExpect(jsonPath("$.efficiency.inputTokens").value(243872))
            .andExpect(jsonPath("$.traceId").value("8439c5f1006ab0812abc6684d7fe512"))
            // The payload carried no durationMs; the runner's measurement must survive.
            .andExpect(jsonPath("$.efficiency.durationMs").value(49000))
    }

    @Test
    fun `discards a run invalidated by the harness, including its evaluation`() {
        registerBenchmark("BE-FLOW-7")
        val keep = createRun("BE-FLOW-7", "EXP-DELETE", "baseline", toolCalls = 13, durationMs = 40_000)
        val drop = createRun("BE-FLOW-7", "EXP-DELETE", "baseline", toolCalls = 99, durationMs = 40_000)
        evaluate(keep, passed = true)
        evaluate(drop, passed = false)

        mockMvc.perform(delete("/api/runs/$drop")).andExpect(status().isNoContent)
        mockMvc.perform(get("/api/runs/$drop")).andExpect(status().isNotFound)

        // The discarded run must leave no trace in the aggregates it polluted.
        mockMvc.perform(get("/api/experiments/EXP-DELETE/comparison"))
            .andExpect(jsonPath("$.totalRuns").value(1))
            .andExpect(jsonPath("$.variants[0].passRate").value(1.0))
            .andExpect(jsonPath("$.variants[0].medianToolCalls").value(13.0))
    }

    @Test
    fun `compares two runtimes on the same benchmark across separate experiments`() {
        registerBenchmark("BE-FLOW-8")
        // A Copilot baseline and a Claude baseline are naturally recorded as separate
        // experiments, not as variants of one — grouping by variant cannot compare them.
        evaluate(createRun("BE-FLOW-8", "EXP-COPILOT", "baseline", 13, 40_000), passed = true)
        evaluate(createRun("BE-FLOW-8", "EXP-COPILOT", "baseline", 17, 42_000), passed = true)
        evaluate(
            createRun("BE-FLOW-8", "EXP-CLAUDE", "baseline", 11, 86_000, provider = "anthropic", model = "haiku"),
            passed = true,
        )

        mockMvc.perform(get("/api/benchmarks/BE-FLOW-8/comparison?groupBy=runtime"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.totalRuns").value(3))
            .andExpect(jsonPath("$.variants.length()").value(2))
            .andExpect(jsonPath("$.variants[0].variant").value("anthropic/haiku"))
            .andExpect(jsonPath("$.variants[0].runs").value(1))
            .andExpect(jsonPath("$.variants[1].variant").value("github/gpt-x"))
            .andExpect(jsonPath("$.variants[1].runs").value(2))
            .andExpect(jsonPath("$.variants[1].medianToolCalls").value(15.0))
            // §20: neither arm reaches the 5-run minimum, and the API must say so.
            .andExpect(jsonPath("$.warning").isNotEmpty)
    }

    @Test
    fun `rejects a run for an unregistered benchmark`() {
        mockMvc.perform(
            post("/api/runs").contentType(MediaType.APPLICATION_JSON).content(
                """
                {
                  "benchmarkId": "BE-DOES-NOT-EXIST",
                  "variant": "baseline",
                  "runtime": { "provider": "github", "product": "copilot-cli" }
                }
                """.trimIndent(),
            ),
        ).andExpect(status().isNotFound)
    }

    @Test
    fun `rejects a run with no runtime provider`() {
        registerBenchmark("BE-FLOW-3")
        mockMvc.perform(
            post("/api/runs").contentType(MediaType.APPLICATION_JSON).content(
                """{"benchmarkId":"BE-FLOW-3","variant":"baseline","runtime":{"provider":"","product":"copilot-cli"}}""",
            ),
        ).andExpect(status().isBadRequest)
    }

    @Test
    fun `compares variants and warns when the sample is too small to conclude anything`() {
        registerBenchmark("BE-FLOW-4")
        // baseline: 2 runs, 1 pass — deliberately below the 5-run minimum of §20.
        evaluate(createRun("BE-FLOW-4", "EXP-CMP", "baseline", 23, 180_000), passed = true)
        evaluate(createRun("BE-FLOW-4", "EXP-CMP", "baseline", 27, 200_000), passed = false)
        // instructions variant: 2 runs, both pass, fewer tool calls
        evaluate(createRun("BE-FLOW-4", "EXP-CMP", "instructions", 14, 150_000), passed = true)
        evaluate(createRun("BE-FLOW-4", "EXP-CMP", "instructions", 16, 140_000), passed = true)

        mockMvc.perform(get("/api/experiments/EXP-CMP/comparison"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.totalRuns").value(4))
            .andExpect(jsonPath("$.variants.length()").value(2))
            .andExpect(jsonPath("$.variants[0].variant").value("baseline"))
            .andExpect(jsonPath("$.variants[0].passRate").value(0.5))
            .andExpect(jsonPath("$.variants[0].medianToolCalls").value(25.0))
            .andExpect(jsonPath("$.variants[0].failureClasses.F03").value(1))
            .andExpect(jsonPath("$.variants[1].variant").value("instructions"))
            .andExpect(jsonPath("$.variants[1].passRate").value(1.0))
            .andExpect(jsonPath("$.variants[1].medianToolCalls").value(15.0))
            .andExpect(jsonPath("$.warning").isNotEmpty)
    }

    @Test
    fun `excludes infrastructure failures from the aggregates and from the sample-size count`() {
        registerBenchmark("BE-FLOW-9")
        // baseline: 5 runs that all measure the variant — the arm is adequately sampled.
        repeat(5) { evaluate(createRun("BE-FLOW-9", "EXP-INFRA", "baseline", 20, 180_000), passed = true) }
        // instructions: 4 real runs plus one that aborted on an exhausted quota (F13).
        listOf(10, 10, 12, 12).forEach {
            evaluate(createRun("BE-FLOW-9", "EXP-INFRA", "instructions", it, 150_000), passed = true)
        }
        evaluate(
            // A run that never executed: zeroed behaviour, F13. It measures the billing
            // account, not `AGENTS.md`, so it must not touch a single number below.
            createRun("BE-FLOW-9", "EXP-INFRA", "instructions", 0, 1_000),
            passed = false,
            failureClass = "F13",
        )

        mockMvc.perform(get("/api/experiments/EXP-INFRA/comparison"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.totalRuns").value(10))
            .andExpect(jsonPath("$.variants[1].variant").value("instructions"))
            // 5 runs recorded, 4 of them measuring.
            .andExpect(jsonPath("$.variants[1].runs").value(4))
            .andExpect(jsonPath("$.variants[1].infrastructureFailures").value(1))
            .andExpect(jsonPath("$.variants[1].passRate").value(1.0))
            .andExpect(jsonPath("$.variants[1].medianToolCalls").value(11.0))
            .andExpect(jsonPath("$.variants[1].medianDurationMs").value(150_000.0))
            // F13 is not a way the variant failed, so it is not in the taxonomy breakdown.
            .andExpect(jsonPath("$.variants[1].failureClasses").isEmpty)
            // §20: the discarded run must not make an under-powered arm look adequate.
            .andExpect(jsonPath("$.warning").value(org.hamcrest.Matchers.containsString("instructions")))
            .andExpect(
                jsonPath("$.warning").value(org.hamcrest.Matchers.not(org.hamcrest.Matchers.containsString("baseline"))),
            )
            .andExpect(jsonPath("$.variants[0].variant").value("baseline"))
            .andExpect(jsonPath("$.variants[0].runs").value(5))
            .andExpect(jsonPath("$.variants[0].infrastructureFailures").value(0))
    }

    @Test
    fun `compares cache tokens and cost, and stays silent where the runtime reports neither`() {
        registerBenchmark("BE-FLOW-11")
        // A Claude-shaped run: cache dwarfs input+output, and the vendor documents a cost.
        mockMvc.perform(
            post("/api/runs").contentType(MediaType.APPLICATION_JSON).content(
                """
                {
                  "experimentId": "EXP-COST", "benchmarkId": "BE-FLOW-11", "variant": "baseline",
                  "runtime": { "provider": "anthropic", "product": "claude-code", "model": "haiku" },
                  "repository": { "commitSha": "abc123" },
                  "behavior": { "modelCalls": 24, "toolCalls": 19 },
                  "efficiency": {
                    "durationMs": 133000, "inputTokens": 195, "outputTokens": 8604,
                    "cachedTokens": 1025390, "estimatedCost": 0.212708
                  }
                }
                """.trimIndent(),
            ),
        ).andExpect(status().isCreated)

        // A Copilot-shaped run: tokens, but no cache figure and no defensible cost.
        createRun("BE-FLOW-11", "EXP-COST", "instructions", 15, 40_000)

        mockMvc.perform(get("/api/benchmarks/BE-FLOW-11/comparison?groupBy=runtime"))
            .andExpect(status().isOk)
            .andExpect(jsonPath("$.variants[0].variant").value("anthropic/haiku"))
            .andExpect(jsonPath("$.variants[0].medianTokens").value(8799.0))
            .andExpect(jsonPath("$.variants[0].medianCachedTokens").value(1025390.0))
            .andExpect(jsonPath("$.variants[0].medianEstimatedCost").value(0.212708))
            // §11: a runtime that reports no cost must produce no cost, never a zero that
            // would read as "this variant was free".
            .andExpect(jsonPath("$.variants[1].variant").value("github/gpt-x"))
            .andExpect(jsonPath("$.variants[1].medianCachedTokens").doesNotExist())
            .andExpect(jsonPath("$.variants[1].medianEstimatedCost").doesNotExist())
    }

    @Test
    fun `counts an infrastructure failure as discarded, not as a failed run, in prometheus`() {
        registerBenchmark("BE-FLOW-10")
        evaluate(
            createRun("BE-FLOW-10", "EXP-INFRA-METRICS", "baseline", 0, 1_000),
            passed = false,
            failureClass = "F15",
        )

        val scrape = mockMvc.perform(get("/actuator/prometheus"))
            .andExpect(status().isOk)
            .andReturn().response.contentAsString

        assert(scrape.contains("""result="discarded"""")) { "expected a discarded result series" }
        // Its zeroed behaviour must stay out of the distributions — a run that never
        // executed would otherwise drag every percentile toward a number nobody ran.
        val leaked = scrape.lines()
            .filter { it.contains("""result="discarded"""") && !it.startsWith("observatory_runs_") }
        assert(leaked.isEmpty()) { "discarded run leaked into distributions: $leaked" }
    }

    @Test
    fun `publishes only low-cardinality dimensions to prometheus`() {
        registerBenchmark("BE-FLOW-5")
        val runId = createRun("BE-FLOW-5", "EXP-METRICS", "baseline", 12, 90_000)
        evaluate(runId, passed = true)

        val scrape = mockMvc.perform(get("/actuator/prometheus"))
            .andExpect(status().isOk)
            .andReturn().response.contentAsString

        assert(scrape.contains("observatory_runs_total")) { "expected observatory_runs_total in scrape" }
        assert(scrape.contains("""benchmark_category="bugfix"""")) { "expected benchmark_category label" }
        // §15: these must never become Prometheus labels.
        assert(!scrape.contains(runId)) { "run id leaked into Prometheus labels" }
        assert(!scrape.contains("commit_sha")) { "commit sha leaked into Prometheus labels" }
    }
}
