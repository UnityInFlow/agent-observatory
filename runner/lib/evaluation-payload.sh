#!/usr/bin/env bash
#
# Shared jq filter mapping an evaluator's `evaluation.json` (evaluation.schema.json) onto
# the body of POST /api/runs/{id}/evaluation. Source this, do not execute it.
#
# The trailing `del(..|nulls)` is the important part. jq object construction materializes
# an *explicit null* for every field missing from the source document, and the API's
# Kotlin DTOs apply their defaults only for **absent** keys — an explicit null fails the
# non-null check and the entire POST is rejected with HTTP 400. Since the schema marks
# `quality`, `safety`, `acceptanceSuitePassed` and the acceptance counts as optional, a
# perfectly schema-valid evaluator could not persist its verdict at all.
#
# A `// default` fallback would be the obvious fix and would be wrong: in jq
# `false // true` evaluates to `true`, so a genuinely failing `staticAnalysisPassed`
# would be silently flipped to passing. Dropping nulls keeps optional fields optional
# without touching any value that is actually present.
#
# `buildPassed` and `testsPassed` have no defaults on either side: the schema requires
# them, so an evaluation missing them should be rejected.

EVALUATION_PAYLOAD_FILTER='{
  evaluatorVersion,
  completedAt,
  exitCode,
  passed,
  failureClass,
  correctness: {
    buildPassed:              .correctness.buildPassed,
    testsPassed:              .correctness.testsPassed,
    acceptanceSuitePassed:    .correctness.acceptanceSuitePassed,
    acceptanceCriteriaPassed: .correctness.acceptanceCriteriaPassed,
    acceptanceCriteriaTotal:  .correctness.acceptanceCriteriaTotal,
    taskAttempted:            .correctness.taskAttempted,
    productionFilesChanged:   .correctness.productionFilesChanged
  },
  quality: {
    unrelatedFilesChanged: .quality.unrelatedFilesChanged,
    newDependencies:       .quality.newDependencies,
    staticAnalysisPassed:  .quality.staticAnalysisPassed
  },
  safety
}
| del(..|nulls)'
