import { Link, useParams } from 'react-router-dom';
import {
  api,
  fmtBehavior,
  fmtDuration,
  fmtPercent,
  fmtTokens,
  hasBehaviorTelemetry,
  totalTokens,
  type Run,
} from '../api';
import { useAsync } from '../useAsync';

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <>
      <dt>{label}</dt>
      <dd>{children}</dd>
    </>
  );
}

/** Page 2 — Run detail (§18). */
export default function RunDetailPage() {
  const { id = '' } = useParams();
  const { data: run, error, loading } = useAsync<Run>(() => api.run(id), [id]);

  if (loading) return <p className="muted">Loading…</p>;
  if (error) return <div className="notice error">Could not load run: {error}</div>;
  if (!run) return null;

  const evaluation = run.evaluation;
  const customization = Object.entries(run.customization).filter(([, v]) => v != null);

  return (
    <>
      <p className="muted">
        <Link to="/runs">← Runs</Link>
      </p>
      <h2>
        {run.benchmarkId} · {run.variant}{' '}
        {evaluation && (
          <span className={`badge ${evaluation.passed ? 'pass' : 'fail'}`}>
            {evaluation.passed ? 'PASS' : evaluation.failureClass ?? 'FAIL'}
          </span>
        )}
      </h2>
      <p className="subtitle mono">{run.runId}</p>

      {run.traceUrl && (
        <p>
          <a className="btn" href={run.traceUrl} target="_blank" rel="noreferrer">
            Open trace in Grafana →
          </a>
        </p>
      )}

      <div className="grid">
        <div className="card">
          <h3>Run metadata</h3>
          <dl className="kv">
            <Row label="Runtime">{run.runtime.provider} / {run.runtime.product}</Row>
            <Row label="Version">{run.runtime.version ?? '—'}</Row>
            <Row label="Model">{run.runtime.model ?? '—'}</Row>
            <Row label="Experiment">{run.experimentKey ?? '—'}</Row>
            <Row label="Started">{new Date(run.startedAt).toLocaleString()}</Row>
            <Row label="Commit"><span className="mono">{run.repository.commitSha ?? '—'}</span></Row>
            <Row label="Dirty before run">{run.repository.dirtyBeforeRun ? 'yes' : 'no'}</Row>
          </dl>
        </div>

        <div className="card">
          <h3>Behaviour</h3>
          {/*
            All six counters come from the same telemetry block, so when it is absent they
            are all fabricated zeros — not just the two the guard inspects. Say so once,
            loudly, rather than printing six confident zeros with a caveat elsewhere.
          */}
          {!hasBehaviorTelemetry(run.behavior) && (
            <div className="notice">
              Behaviour counters were not reported for this run. The API serialises them as
              <code> 0</code> when absent, so these are <strong>unknown</strong>, not zero.
              The analyzer excludes them from comparisons for the same reason.
            </div>
          )}
          <dl className="kv">
            <Row label="Model calls">{fmtBehavior(run.behavior, run.behavior.modelCalls)}</Row>
            <Row label="Tool calls">{fmtBehavior(run.behavior, run.behavior.toolCalls)}</Row>
            <Row label="Tool failures">{fmtBehavior(run.behavior, run.behavior.toolFailures)}</Row>
            <Row label="Retries">{fmtBehavior(run.behavior, run.behavior.retries)}</Row>
            <Row label="Permission requests">
              {fmtBehavior(run.behavior, run.behavior.permissionRequests)}
            </Row>
            <Row label="Permission denials">
              {fmtBehavior(run.behavior, run.behavior.permissionDenials)}
            </Row>
          </dl>
        </div>

        <div className="card">
          <h3>Efficiency</h3>
          <dl className="kv">
            <Row label="Duration">{fmtDuration(run.efficiency.durationMs)}</Row>
            <Row label="Input tokens">{fmtTokens(run.efficiency.inputTokens)}</Row>
            <Row label="Output tokens">{fmtTokens(run.efficiency.outputTokens)}</Row>
            <Row label="Cached tokens">{fmtTokens(run.efficiency.cachedTokens)}</Row>
            <Row label="Total tokens">{fmtTokens(totalTokens(run.efficiency))}</Row>
            <Row label="Estimated cost">{run.efficiency.estimatedCost ?? '—'}</Row>
          </dl>
        </div>

        <div className="card">
          <h3>Evaluation</h3>
          {evaluation ? (
            <dl className="kv">
              <Row label="Evaluator">{evaluation.evaluatorVersion}</Row>
              <Row label="Exit code">{evaluation.exitCode}</Row>
              <Row label="Build">{evaluation.buildPassed ? 'pass' : 'fail'}</Row>
              <Row label="Tests">{evaluation.testsPassed ? 'pass' : 'fail'}</Row>
              <Row label="Acceptance">
                {evaluation.acceptanceCriteriaPassed}/{evaluation.acceptanceCriteriaTotal}{' '}
                ({fmtPercent(evaluation.acceptanceRate)})
              </Row>
              <Row label="Failure class">{evaluation.failureClass ?? '—'}</Row>
            </dl>
          ) : (
            <p className="muted">Not evaluated yet.</p>
          )}
        </div>

        <div className="card">
          <h3>Change quality</h3>
          <dl className="kv">
            <Row label="Files changed">{run.result.changedFiles.length}</Row>
            <Row label="Lines added">+{run.result.addedLines}</Row>
            <Row label="Lines deleted">−{run.result.deletedLines}</Row>
            <Row label="Unrelated files">{evaluation?.unrelatedFilesChanged ?? '—'}</Row>
            <Row label="New dependencies">{evaluation?.newDependencies ?? '—'}</Row>
            <Row label="Static analysis">
              {evaluation == null ? '—' : evaluation.staticAnalysisPassed ? 'pass' : 'fail'}
            </Row>
          </dl>
        </div>

        <div className="card">
          <h3>Safety</h3>
          <dl className="kv">
            <Row label="Forbidden actions">{evaluation?.forbiddenActionAttempts ?? '—'}</Row>
            <Row label="Secret exposure">
              {evaluation == null ? '—' : evaluation.secretExposureDetected ? 'DETECTED' : 'none'}
            </Row>
            <Row label="Permission denials">{run.behavior.permissionDenials}</Row>
          </dl>
        </div>
      </div>

      <h3>Customization snapshot</h3>
      {customization.length === 0 ? (
        <p className="muted">
          Plain agent — no instructions, skills, custom agent, hooks or MCP servers.
        </p>
      ) : (
        <dl className="kv">
          {customization.map(([k, v]) => (
            <Row key={k} label={k}>
              <span className="mono">{v}</span>
            </Row>
          ))}
        </dl>
      )}

      <h3>Changed files</h3>
      {run.result.changedFiles.length === 0 ? (
        <p className="muted">No file changes recorded.</p>
      ) : (
        <pre className="block">{run.result.changedFiles.join('\n')}</pre>
      )}

      <h3>Human review</h3>
      {run.humanReviews.length === 0 ? (
        <p className="muted">
          No review recorded. Some quality cannot be captured by tests alone (§22).
        </p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Reviewer</th>
              <th>Reviewed</th>
              <th className="num">Correctness</th>
              <th className="num">Scope</th>
              <th className="num">Maintainability</th>
              <th className="num">Test quality</th>
              <th>Notes</th>
            </tr>
          </thead>
          <tbody>
            {run.humanReviews.map((review) => (
              <tr key={review.id}>
                <td>{review.reviewer}</td>
                <td>{new Date(review.reviewedAt).toLocaleString()}</td>
                <td className="num">{review.correctness ?? '—'}</td>
                <td className="num">{review.scopeDiscipline ?? '—'}</td>
                <td className="num">{review.maintainability ?? '—'}</td>
                <td className="num">{review.testQuality ?? '—'}</td>
                <td className="muted">{review.notes ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
