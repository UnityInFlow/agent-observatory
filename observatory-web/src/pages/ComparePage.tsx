import { useEffect, useState } from 'react';
import {
  api,
  fmtDuration,
  fmtNumber,
  fmtPercent,
  fmtTokens,
  type Comparison,
  type ExperimentSummary,
  type VariantComparison,
} from '../api';
import { useAsync } from '../useAsync';

/** `neutral` means the row has no "better" direction and is never highlighted. */
type Direction = 'higher' | 'lower' | 'neutral';

interface MetricRow {
  label: string;
  value: (v: VariantComparison) => number | null;
  format: (n: number | null) => string;
  better: Direction;
}

const ROWS: MetricRow[] = [
  // Sample size is context, not a score — more runs is not "better".
  { label: 'runs', value: (v) => v.runs, format: (n) => fmtNumber(n, 0), better: 'neutral' },
  { label: 'acceptance', value: (v) => v.acceptanceRate, format: fmtPercent, better: 'higher' },
  { label: 'pass rate', value: (v) => v.passRate, format: fmtPercent, better: 'higher' },
  { label: 'tool calls (median)', value: (v) => v.medianToolCalls, format: (n) => fmtNumber(n), better: 'lower' },
  { label: 'model calls (median)', value: (v) => v.medianModelCalls, format: (n) => fmtNumber(n), better: 'lower' },
  { label: 'tokens (median)', value: (v) => v.medianTokens, format: fmtTokens, better: 'lower' },
  { label: 'duration (median)', value: (v) => v.medianDurationMs, format: fmtDuration, better: 'lower' },
  { label: 'retries (median)', value: (v) => v.medianRetries, format: (n) => fmtNumber(n), better: 'lower' },
  { label: 'unwanted files (mean)', value: (v) => v.meanUnrelatedFilesChanged, format: (n) => fmtNumber(n), better: 'lower' },
];

/** Page 3 — Compare (§18): "This is the most important screen." */
export default function ComparePage() {
  const experiments = useAsync<ExperimentSummary[]>(() => api.experiments(), []);
  const [selected, setSelected] = useState('');

  useEffect(() => {
    if (!selected && experiments.data && experiments.data.length > 0) {
      setSelected(experiments.data[0].key);
    }
  }, [experiments.data, selected]);

  const comparison = useAsync<Comparison | null>(
    () => (selected ? api.comparison(selected) : Promise.resolve(null)),
    [selected],
  );

  const data = comparison.data;

  return (
    <>
      <h2>Compare</h2>
      <p className="subtitle">
        One variable at a time. If a skill and the model both changed, the result cannot be attributed (§20).
      </p>

      <div className="filters">
        <label>
          Experiment
          <select value={selected} onChange={(e) => setSelected(e.target.value)}>
            {(experiments.data ?? []).map((e) => (
              <option key={e.id} value={e.key}>{e.key}</option>
            ))}
          </select>
        </label>
      </div>

      {experiments.error && <div className="notice error">{experiments.error}</div>}
      {!experiments.loading && (experiments.data ?? []).length === 0 && (
        <div className="notice">
          No experiments yet. Run <span className="mono">make demo</span> to seed a
          baseline-vs-instructions comparison.
        </div>
      )}
      {comparison.error && <div className="notice error">{comparison.error}</div>}

      {data && data.warning && <div className="notice">{data.warning}</div>}

      {data && data.variants.length > 0 && (
        <>
          <table>
            <thead>
              <tr>
                <th>Metric</th>
                {data.variants.map((v) => (
                  <th key={v.variant} className="num">{v.variant}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {ROWS.map((row) => {
                const values = data.variants.map(row.value);
                const present = values.filter((v): v is number => v != null);
                // A tie is not a win: only highlight when the variants actually differ.
                const allEqual = present.every((v) => v === present[0]);
                const best =
                  row.better === 'neutral' || present.length < 2 || allEqual
                    ? null
                    : row.better === 'higher'
                      ? Math.max(...present)
                      : Math.min(...present);

                return (
                  <tr key={row.label}>
                    <td>{row.label}</td>
                    {values.map((value, i) => (
                      <td
                        key={data.variants[i].variant}
                        className={`num ${best != null && value === best ? 'best' : ''}`}
                      >
                        {row.format(value)}
                      </td>
                    ))}
                  </tr>
                );
              })}
              <tr>
                <td>failure classes</td>
                {data.variants.map((v) => (
                  <td key={v.variant} className="num muted mono">
                    {Object.keys(v.failureClasses).length === 0
                      ? '—'
                      : Object.entries(v.failureClasses)
                          .map(([k, n]) => `${k}×${n}`)
                          .join(' ')}
                  </td>
                ))}
              </tr>
            </tbody>
          </table>

          <div className="notice">
            A single score would hide the trade-off: a run can be <em>fast + cheap + wrong</em> or{' '}
            <em>slow + expensive + correct</em> (§13). Green marks the better value per row, not an
            overall winner.
          </div>
        </>
      )}
    </>
  );
}
