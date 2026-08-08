# Agent Observatory

Instrumentation and evaluation foundation for AI coding agents — the Chapter 00 platform.

We are **not** starting by building an `AGENTS.md`, a skill, a custom agent, a hook or an
MCP server. We are first building the thing that will tell us whether any of those
actually improve an agent.

```text
UNDERSTAND THE AGENT → OBSERVE ONE REAL RUN → ESTABLISH A BASELINE → CHANGE ONE VARIABLE
→ RUN THE SAME TASK AGAIN → EVALUATE → COMPARE WITH BASELINE → KEEP / REJECT / MODIFY
```

The Observatory answers four *separate* questions. They are deliberately not collapsed
into one score:

| Question | Answered by |
|---|---|
| **Observation** — what happened? | Tempo traces |
| **Metrics** — how much happened? | Prometheus |
| **Evaluation** — was it correct and good? | deterministic evaluator → PostgreSQL |
| **Impact** — did the customization help? | the Compare screen |

---

**Picking this up after a break?** Read [`docs/STATE.md`](docs/STATE.md) first — where the
project stands, what is blocked and what to do next.

## Quick start

Prerequisites: Docker, JDK 21+, Node 20+.

```bash
make up      # build everything and start the whole stack
make demo    # seed a baseline-vs-instructions experiment so the UI is meaningful
make open    # open the UI and Grafana
```

`make up` finishes only when every service actually answers, and then prints its URLs:

```text
Observatory UI   http://localhost:5173
Observatory API  http://localhost:8080/api/runs
Grafana          http://localhost:3000   (dashboard: Agent Observatory — Overview)
Prometheus       http://localhost:9090
Tempo            http://localhost:3200
OTLP endpoint    http://localhost:4318 (http/protobuf) / 4317 (gRPC)
```

Verify it end to end:

```bash
make smoke        # 18 checks across infra, provisioning, scraping and the API contract
make test-trace   # synthetic OTLP trace → collector → Tempo (the M2 exit criterion)
make test         # API test suite (Testcontainers PostgreSQL) + web type-check/build
```

`make help` lists every target.

### Port conflicts

Every host port lives in `infra/.env` (created from `infra/.env.example` on first run).
If `make up` reports *"port is already allocated"*, or a service answers but behaves
strangely, change the port there and re-run — nothing else needs editing. `make smoke`
verifies service **identity**, not just HTTP 200, so a port shadowed by an unrelated
local service is reported rather than silently passing.

---

## What is here

```text
infra/            Collector, Tempo, Prometheus, Grafana, PostgreSQL — pinned versions
runner/           The reproducibility engine: run → diff → evaluate → persist
observatory-api/  Kotlin/Spring Boot: normalized experiment truth
observatory-web/  React MVP: Runs · Run detail · Compare · Benchmark
docs/             Foundation, architecture, metric catalog
```

The benchmark tasks live in a **separate** repository,
[`agent-observatory-benchmarks`](https://github.com/UnityInFlow/agent-observatory-benchmarks),
so the evaluator can be versioned independently of the product under test.

---

## Running a real benchmark

```bash
git clone https://github.com/UnityInFlow/agent-observatory-benchmarks ../agent-observatory-benchmarks
make run-benchmark RUNTIME=copilot      # or claude | codex | manual
```

The runner creates a clean worktree at the baseline commit, generates a run id, captures
runtime versions, hashes the customization files, sets the OTel correlation attributes,
launches the agent, records the diff, executes the deterministic evaluator and persists
the normalized run plus its evaluation.

`RUNTIME=manual` is the default on purpose. Chapter 00 §24 says not to automate the agent
launch until several runs have been watched by hand, and §11 says the first run should be
interactive so you see permissions and actions happen.

---

## The privacy rule

For a bank, observability can accidentally become a data-exfiltration mechanism. This
stack is **metadata-only**:

- `runner/lib/telemetry-env.sh` disables message-content capture for every runtime.
- The collector runs an `attributes/scrub` processor that deletes prompt, completion,
  tool-argument, tool-result and `user.email` attributes **even if a client is
  misconfigured** — one wrong env var on a laptop cannot leak source code.

Telemetry configuration goes through the same security review as application logging.
See the governance checklist issue before any team rollout.

---

## The cardinality rule

Run ids, prompt ids, commit shas, file paths and user emails are high-cardinality and
must never become Prometheus labels. Only these dimensions are published:

```text
runtime · variant · benchmark_category · result
```

Individual run detail belongs in PostgreSQL; individual span detail belongs in Tempo.
Both the API test suite and `make smoke` assert that run ids do not leak into metrics.

---

## Architectural rule to preserve

Never let vendor telemetry become the domain model.

```text
Copilot telemetry ─┐
Claude telemetry ──┼── adapters ──► internal experiment model
Codex telemetry ───┘
```

The vendor products will change. Our questions should not: *Did it work? How did it work?
How much did it cost? What did it change? Was it safe? Did the customization improve it?*
