import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  api,
  fmtDuration,
  fmtPercent,
  fmtTokens,
  totalTokens,
  type Run,
} from '../api';
import { useAsync } from '../useAsync';

/** Page 1 — Runs (§18). */
export default function RunsPage() {
  const [benchmarkId, setBenchmarkId] = useState('');
  const [variant, setVariant] = useState('');
  const [runtime, setRuntime] = useState('');
  const [result, setResult] = useState('');

  const { data, error, loading } = useAsync<Run[]>(
    () => api.runs({ benchmarkId, variant, runtime }),
    [benchmarkId, variant, runtime],
  );

  const runs = data ?? [];

  // Filter options come from the data itself so the page works for any runtime that
  // has ever reported — including adapters added later (§25, §26).
  const options = useMemo(() => {
    const uniq = (xs: string[]) => Array.from(new Set(xs)).sort();
    return {
      benchmarks: uniq(runs.map((r) => r.benchmarkId)),
      variants: uniq(runs.map((r) => r.variant)),
      runtimes: uniq(runs.map((r) => r.runtime.provider)),
    };
  }, [runs]);

  const visible = runs.filter((r) => {
    const e = r.evaluation;
    if (result === 'pass') return e?.passed === true;
    // A discarded run is not a failed variant (#19). Keeping it out of the Fail filter is
    // what stops the same run reading as "discarded" on Compare and "failed" here.
    if (result === 'fail') return e != null && !e.passed && !e.infrastructureFailure;
    if (result === 'discarded') return e?.infrastructureFailure === true;
    if (result === 'none') return e == null;
    return true;
  });

  return (
    <>
      <h2>Runs</h2>
      <p className="subtitle">
        Every recorded agent run. Individual technical traces live in Tempo — open a run to jump there.
      </p>

      <div className="filters">
        <label>
          Runtime
          <select value={runtime} onChange={(e) => setRuntime(e.target.value)}>
            <option value="">All</option>
            {options.runtimes.map((r) => (
              <option key={r} value={r}>{r}</option>
            ))}
          </select>
        </label>
        <label>
          Benchmark
          <select value={benchmarkId} onChange={(e) => setBenchmarkId(e.target.value)}>
            <option value="">All</option>
            {options.benchmarks.map((b) => (
              <option key={b} value={b}>{b}</option>
            ))}
          </select>
        </label>
        <label>
          Variant
          <select value={variant} onChange={(e) => setVariant(e.target.value)}>
            <option value="">All</option>
            {options.variants.map((v) => (
              <option key={v} value={v}>{v}</option>
            ))}
          </select>
        </label>
        <label>
          Result
          <select value={result} onChange={(e) => setResult(e.target.value)}>
            <option value="">All</option>
            <option value="pass">Pass</option>
            <option value="fail">Fail</option>
            <option value="discarded">Discarded (F13/F15)</option>
            <option value="none">Not evaluated</option>
          </select>
        </label>
      </div>

      {error && <div className="notice error">Could not load runs: {error}</div>}
      {loading && <p className="muted">Loading…</p>}

      {!loading && !error && visible.length === 0 && (
        <div className="notice">
          No runs recorded yet. Run <span className="mono">make demo</span> to seed a baseline-vs-variant
          experiment, or <span className="mono">make run-benchmark</span> for a real one.
        </div>
      )}

      {visible.length > 0 && (
        <table>
          <thead>
            <tr>
              <th>Started</th>
              <th>Runtime</th>
              <th>Model</th>
              <th>Benchmark</th>
              <th>Variant</th>
              <th>Result</th>
              <th className="num">Duration</th>
              <th className="num">Tokens</th>
              <th className="num">Tools</th>
              <th className="num">Acceptance</th>
            </tr>
          </thead>
          <tbody>
            {visible.map((run) => (
              <tr key={run.runId}>
                <td>
                  <Link to={`/runs/${run.runId}`}>
                    {new Date(run.startedAt).toLocaleString()}
                  </Link>
                </td>
                <td>{run.runtime.provider}</td>
                <td className="muted">{run.runtime.model ?? '—'}</td>
                <td>{run.benchmarkId}</td>
                <td>{run.variant}</td>
                <td>
                  {run.evaluation == null ? (
                    <span className="badge none">not evaluated</span>
                  ) : run.evaluation.infrastructureFailure ? (
                    // Neither pass nor fail: the harness broke, so it gets the neutral badge
                    // rather than the red one that accuses the agent.
                    <span className="badge none" title="Infrastructure failure — excluded from comparisons">
                      {run.evaluation.failureClass ?? 'DISCARDED'}
                    </span>
                  ) : (
                    <span className={`badge ${run.evaluation.passed ? 'pass' : 'fail'}`}>
                      {run.evaluation.passed ? 'PASS' : run.evaluation.failureClass ?? 'FAIL'}
                    </span>
                  )}
                </td>
                <td className="num">{fmtDuration(run.efficiency.durationMs)}</td>
                <td className="num">{fmtTokens(totalTokens(run.efficiency))}</td>
                <td className="num">{run.behavior.toolCalls ?? '—'}</td>
                <td className="num">{fmtPercent(run.evaluation?.acceptanceRate ?? null)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
