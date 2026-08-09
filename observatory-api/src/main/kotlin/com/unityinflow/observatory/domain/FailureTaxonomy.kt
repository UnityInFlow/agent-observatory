package com.unityinflow.observatory.domain

/**
 * §23 splits failures by *what they blame*. Most codes blame the agent: it misunderstood
 * the requirement (F01), wrote incorrect code (F03), broke the build (F04). Two do not —
 * they blame the harness or the environment around it:
 *
 * - **F13** timeout / rate limit — an exhausted quota measures the billing account.
 * - **F15** evaluator / infrastructure failure — the measuring instrument broke.
 *
 * A run that never really executed must not be able to make a variant look worse, nor
 * make an under-powered arm look adequately sampled (#19). Everything else is a result.
 */
object FailureTaxonomy {

    val INFRASTRUCTURE: Set<String> = setOf("F13", "F15")

    fun isInfrastructure(failureClass: String?): Boolean =
        failureClass != null && INFRASTRUCTURE.contains(failureClass.trim().uppercase())
}
