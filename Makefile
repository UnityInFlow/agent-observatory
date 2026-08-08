# Agent Observatory — one-command local ecosystem.
#
#   make up      build everything and start the whole stack
#   make demo    seed a baseline-vs-instructions experiment so the UI is meaningful
#   make down    stop it
#
# Prerequisites: Docker, JDK 21+, Node 20+.

SHELL          := /usr/bin/env bash
ENV_FILE       := infra/.env
COMPOSE        := docker compose --env-file $(ENV_FILE) -f infra/compose.yaml
API_DIR        := observatory-api
WEB_DIR        := observatory-web
RUNNER         := runner

# Host ports live in infra/.env, so a collision with something already running on the
# machine is a one-line fix instead of an edit to a tracked file.
-include $(ENV_FILE)
API_PORT        ?= 8080
WEB_PORT        ?= 5173
GRAFANA_PORT    ?= 3000
PROMETHEUS_PORT ?= 9090
TEMPO_PORT      ?= 3200
OTLP_HTTP_PORT  ?= 4318
OTLP_GRPC_PORT  ?= 4317

API_URL         = http://localhost:$(API_PORT)
WEB_URL         = http://localhost:$(WEB_PORT)
GRAFANA_URL     = http://localhost:$(GRAFANA_PORT)
PROMETHEUS_URL  = http://localhost:$(PROMETHEUS_PORT)
TEMPO_URL       = http://localhost:$(TEMPO_PORT)

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@echo "Agent Observatory"
	@echo ""
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Quick start:  make up && make demo && open $(WEB_URL)"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

.PHONY: build
build: build-api build-web ## Build the API jar and the web bundle

.PHONY: build-api
build-api: ## Build the Spring Boot jar (skips tests)
	@echo "==> building observatory-api"
	@cd $(API_DIR) && ./mvnw -B -q -DskipTests package

.PHONY: build-web
build-web: ## Build the React production bundle
	@echo "==> building observatory-web"
	@cd $(WEB_DIR) && npm install --silent && npm run build --silent

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

.PHONY: env
env: ## Create infra/.env from the template if missing
	@test -f $(ENV_FILE) || { cp infra/.env.example $(ENV_FILE); echo "created $(ENV_FILE)"; }

.PHONY: up
up: env check-docker build ## Build and start the ENTIRE stack, then wait until it is ready
	@echo "==> starting the ecosystem"
	@$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory wait
	@$(MAKE) --no-print-directory urls

.PHONY: infra
infra: check-docker ## Start only the observability stack (Collector, Tempo, Prometheus, Grafana, Postgres)
	@$(COMPOSE) up -d postgres tempo otel-collector prometheus grafana
	@$(MAKE) --no-print-directory wait-infra

.PHONY: down
down: ## Stop the stack (volumes preserved)
	@$(COMPOSE) down

.PHONY: clean
clean: ## Stop the stack and delete all data volumes
	@$(COMPOSE) down -v
	@rm -rf $(API_DIR)/target $(WEB_DIR)/dist $(WEB_DIR)/node_modules

.PHONY: restart
restart: down up ## Restart everything

.PHONY: ps
ps: ## Show container status
	@$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs from every service
	@$(COMPOSE) logs -f --tail=80

.PHONY: logs-api
logs-api: ## Tail the API logs
	@$(COMPOSE) logs -f --tail=120 observatory-api

# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------

.PHONY: wait-infra
wait-infra:
	@echo "==> waiting for observability stack"
	@$(RUNNER)/lib/wait-for.sh "Tempo"      "$(TEMPO_URL)/ready"
	@$(RUNNER)/lib/wait-for.sh "Prometheus" "$(PROMETHEUS_URL)/-/ready"
	@$(RUNNER)/lib/wait-for.sh "Grafana"    "$(GRAFANA_URL)/api/health"

.PHONY: wait
wait: wait-infra
	@$(RUNNER)/lib/wait-for.sh "Observatory API" "$(API_URL)/actuator/health"
	@$(RUNNER)/lib/wait-for.sh "Observatory Web" "$(WEB_URL)/"

.PHONY: urls
urls: ## Print every entry point
	@echo ""
	@echo "  Observatory UI   $(WEB_URL)"
	@echo "  Observatory API  $(API_URL)/api/runs"
	@echo "  Grafana          $(GRAFANA_URL)  (dashboard: Agent Observatory — Overview)"
	@echo "  Prometheus       $(PROMETHEUS_URL)"
	@echo "  Tempo            $(TEMPO_URL)"
	@echo "  OTLP endpoint    http://localhost:$(OTLP_HTTP_PORT)  (http/protobuf) / $(OTLP_GRPC_PORT) (gRPC)"
	@echo ""

.PHONY: open
open: ## Open the UI and Grafana in a browser
	@open $(WEB_URL) $(GRAFANA_URL) 2>/dev/null || xdg-open $(WEB_URL) 2>/dev/null || true

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

.PHONY: test
test: test-api test-web ## Run all tests

.PHONY: test-api
test-api: ## Run the API test suite (Testcontainers PostgreSQL — needs Docker)
	@cd $(API_DIR) && ./mvnw -B test

.PHONY: test-web
test-web: ## Type-check and build the web app
	@cd $(WEB_DIR) && npm install --silent && npm run build

.PHONY: smoke
smoke: ## End-to-end check against a running stack
	@API=$(API_URL) WEB=$(WEB_URL) GRAFANA=$(GRAFANA_URL) PROM=$(PROMETHEUS_URL) TEMPO=$(TEMPO_URL) \
	  $(RUNNER)/smoke-test.sh

.PHONY: test-trace
test-trace: ## Send a synthetic OTLP trace and confirm Tempo stored it (M2 exit criterion)
	@OTLP_ENDPOINT=http://localhost:$(OTLP_HTTP_PORT) TEMPO_URL=$(TEMPO_URL) GRAFANA_URL=$(GRAFANA_URL) \
	  $(RUNNER)/send-test-trace.sh

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

.PHONY: demo
demo: ## Seed a baseline-vs-instructions experiment (10 runs) so Compare is meaningful
	@API=$(API_URL) WEB=$(WEB_URL) $(RUNNER)/seed-demo.sh

.PHONY: run-benchmark
run-benchmark: ## Run BE-001 against a real agent runtime (RUNTIME=copilot|claude|codex|manual)
	@API=$(API_URL) OTLP_HTTP_ENDPOINT=http://localhost:$(OTLP_HTTP_PORT) \
	  OTLP_GRPC_ENDPOINT=http://localhost:$(OTLP_GRPC_PORT) \
	  $(RUNNER)/run-agent.sh --runtime $${RUNTIME:-manual} --benchmark $${BENCHMARK:-BE-001}

# ---------------------------------------------------------------------------

.PHONY: check-docker
check-docker:
	@docker info >/dev/null 2>&1 || { \
	  echo "Docker does not appear to be running. Start Docker Desktop and retry."; exit 1; }
