import { NavLink, Navigate, Route, Routes } from 'react-router-dom';
import RunsPage from './pages/RunsPage';
import RunDetailPage from './pages/RunDetailPage';
import ComparePage from './pages/ComparePage';
import BenchmarkPage from './pages/BenchmarkPage';

/**
 * Four pages, exactly as chapter 00 §18 prescribes. The Observatory does not replace
 * Grafana or Tempo — it compares runs, experiments, correctness and quality, and links
 * out to Tempo for the technical trace of any single run.
 */
export default function App() {
  return (
    <>
      <header className="top">
        <div className="inner">
          <h1>Agent Observatory</h1>
          <nav>
            <NavLink to="/runs">Runs</NavLink>
            <NavLink to="/compare">Compare</NavLink>
            <NavLink to="/benchmarks">Benchmarks</NavLink>
          </nav>
        </div>
      </header>
      <main className="shell">
        <Routes>
          <Route path="/" element={<Navigate to="/runs" replace />} />
          <Route path="/runs" element={<RunsPage />} />
          <Route path="/runs/:id" element={<RunDetailPage />} />
          <Route path="/compare" element={<ComparePage />} />
          <Route path="/benchmarks" element={<BenchmarkPage />} />
        </Routes>
      </main>
    </>
  );
}
