// Wire types mirroring the Observatory API. They are deliberately vendor-neutral:
// chapter 00 §35 forbids letting any runtime's telemetry shape leak into the UI.

export interface Runtime {
  provider: string;
  product: string;
  version: string | null;
  model: string | null;
}

export interface Behavior {
  modelCalls: number;
  toolCalls: number;
  toolFailures: number;
  retries: number;
  permissionRequests: number;
  permissionDenials: number;
}

export interface Efficiency {
  durationMs: number | null;
  inputTokens: number | null;
  outputTokens: number | null;
  cachedTokens: number | null;
  estimatedCost: number | null;
}

export interface Customization {
  instructionsHash: string | null;
  skillsHash: string | null;
  agentHash: string | null;
  hooksHash: string | null;
  mcpHash: string | null;
}

export interface Evaluation {
  evaluatorVersion: string;
  completedAt: string;
  exitCode: number;
  passed: boolean;
  failureClass: string | null;
  buildPassed: boolean;
  testsPassed: boolean;
  acceptanceCriteriaPassed: number;
  acceptanceCriteriaTotal: number;
  acceptanceRate: number;
  unrelatedFilesChanged: number;
  newDependencies: number;
  staticAnalysisPassed: boolean;
  forbiddenActionAttempts: number;
  secretExposureDetected: boolean;
}

export interface HumanReview {
  id: string;
  reviewer: string;
  reviewedAt: string;
  correctness: number | null;
  scopeDiscipline: number | null;
  maintainability: number | null;
  testQuality: number | null;
  notes: string | null;
}

export interface Run {
  runId: string;
  experimentId: string | null;
  experimentKey: string | null;
  benchmarkId: string;
  variant: string;
  startedAt: string;
  finishedAt: string | null;
  runtime: Runtime;
  repository: { commitSha: string | null; dirtyBeforeRun: boolean };
  customization: Customization;
  behavior: Behavior;
  efficiency: Efficiency;
  result: { changedFiles: string[]; addedLines: number; deletedLines: number };
  traceId: string | null;
  telemetryQueryKey: string | null;
  traceUrl: string | null;
  evaluation: Evaluation | null;
  humanReviews: HumanReview[];
}

export interface VariantComparison {
  variant: string;
  runs: number;
  passed: number;
  passRate: number;
  acceptanceRate: number;
  medianToolCalls: number | null;
  medianModelCalls: number | null;
  medianTokens: number | null;
  medianDurationMs: number | null;
  medianRetries: number | null;
  meanUnrelatedFilesChanged: number | null;
  failureClasses: Record<string, number>;
}

export interface Comparison {
  experimentId: string | null;
  experimentKey: string | null;
  totalRuns: number;
  variants: VariantComparison[];
  warning: string | null;
}

export interface Benchmark {
  id: string;
  name: string;
  category: string;
  repository: string | null;
  prompt: string | null;
  constraints: string | null;
  acceptanceCriteria: string | null;
  evaluatorVersion: string | null;
  baselineCommit: string | null;
  runCount: number;
}

export interface ExperimentSummary {
  id: string;
  key: string;
  hypothesis: string | null;
  createdAt: string;
}

const BASE = import.meta.env.VITE_API_BASE ?? '/api';

async function get<T>(path: string): Promise<T> {
  const response = await fetch(`${BASE}${path}`);
  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText} for ${path}`);
  }
  return response.json() as Promise<T>;
}

export const api = {
  runs: (params: Record<string, string> = {}) => {
    const query = new URLSearchParams(
      Object.entries(params).filter(([, v]) => v !== ''),
    ).toString();
    return get<Run[]>(`/runs${query ? `?${query}` : ''}`);
  },
  run: (id: string) => get<Run>(`/runs/${id}`),
  experiments: () => get<ExperimentSummary[]>('/experiments'),
  comparison: (ref: string) => get<Comparison>(`/experiments/${ref}/comparison`),
  benchmarks: () => get<Benchmark[]>('/benchmarks'),
  benchmark: (id: string) => get<Benchmark>(`/benchmarks/${id}`),
};

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

export const fmtDuration = (ms: number | null): string =>
  ms == null ? '—' : ms < 1000 ? `${ms}ms` : `${(ms / 1000).toFixed(1)}s`;

export const fmtTokens = (n: number | null): string => {
  if (n == null) return '—';
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n);
};

export const fmtPercent = (v: number | null): string =>
  v == null ? '—' : `${Math.round(v * 100)}%`;

export const fmtNumber = (v: number | null, digits = 1): string =>
  v == null ? '—' : Number.isInteger(v) ? String(v) : v.toFixed(digits);

export const totalTokens = (e: Efficiency): number | null =>
  e.inputTokens == null && e.outputTokens == null
    ? null
    : (e.inputTokens ?? 0) + (e.outputTokens ?? 0);
