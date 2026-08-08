import { useEffect, useState } from 'react';
import { api, type Benchmark } from '../api';
import { useAsync } from '../useAsync';

/** Page 4 — Benchmark (§18). Exists for reproducibility, not decoration. */
export default function BenchmarkPage() {
  const { data, error, loading } = useAsync<Benchmark[]>(() => api.benchmarks(), []);
  const [selectedId, setSelectedId] = useState('');

  useEffect(() => {
    if (!selectedId && data && data.length > 0) setSelectedId(data[0].id);
  }, [data, selectedId]);

  const benchmark = (data ?? []).find((b) => b.id === selectedId) ?? null;

  return (
    <>
      <h2>Benchmarks</h2>
      <p className="subtitle">
        The exact contract a run was judged against — requirement, constraints, criteria,
        evaluator version and baseline commit.
      </p>

      {error && <div className="notice error">Could not load benchmarks: {error}</div>}
      {loading && <p className="muted">Loading…</p>}
      {!loading && !error && (data ?? []).length === 0 && (
        <div className="notice">
          No benchmarks registered. The runner registers one with{' '}
          <span className="mono">POST /api/benchmarks</span> before its first run.
        </div>
      )}

      {(data ?? []).length > 0 && (
        <div className="filters">
          <label>
            Benchmark
            <select value={selectedId} onChange={(e) => setSelectedId(e.target.value)}>
              {(data ?? []).map((b) => (
                <option key={b.id} value={b.id}>{b.id} — {b.name}</option>
              ))}
            </select>
          </label>
        </div>
      )}

      {benchmark && (
        <>
          <div className="card">
            <dl className="kv">
              <dt>Id</dt><dd className="mono">{benchmark.id}</dd>
              <dt>Name</dt><dd>{benchmark.name}</dd>
              <dt>Category</dt><dd>{benchmark.category}</dd>
              <dt>Repository</dt><dd>{benchmark.repository ?? '—'}</dd>
              <dt>Evaluator version</dt><dd className="mono">{benchmark.evaluatorVersion ?? '—'}</dd>
              <dt>Baseline commit</dt><dd className="mono">{benchmark.baselineCommit ?? '—'}</dd>
              <dt>Recorded runs</dt><dd>{benchmark.runCount}</dd>
            </dl>
          </div>

          <h3>Requirement / exact prompt</h3>
          <pre className="block">{benchmark.prompt ?? '— not recorded —'}</pre>

          <h3>Constraints</h3>
          <pre className="block">{benchmark.constraints ?? '— not recorded —'}</pre>

          <h3>Acceptance criteria</h3>
          <pre className="block">{benchmark.acceptanceCriteria ?? '— not recorded —'}</pre>
        </>
      )}
    </>
  );
}
