# Rucio Storage Testbed — developer commands
#
# All docker compose invocations need TESTBED_HOST_SOURCE to resolve
# bind-mount paths. The Makefile defaults it to the repo root so that
# running `make` outside a devcontainer Just Works; inside a
# devcontainer, set it via remoteEnv (already wired in
# .devcontainer/kind/devcontainer.json).

SHELL      := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Anchor for compose bind-mounts. Override if running from an unusual shell.
export TESTBED_HOST_SOURCE ?= $(CURDIR)

COMPOSE_FILE := deploy/compose/docker-compose.yml
COMPOSE      := docker compose -f $(COMPOSE_FILE)

# ── Help ──────────────────────────────────────────────────────────────────
.PHONY: help
help: ## Show this help (default target)
	@awk 'BEGIN {FS = ":.*?## "} \
		/^[a-zA-Z0-9_-]+:.*?## / { printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2 } \
		/^## / { sub(/^## /, ""); printf "\n\033[1m%s\033[0m\n", $$0 }' $(MAKEFILE_LIST)

## Setup

.PHONY: certs
certs: ## Generate all certificates (CA, hosts, StoRM trust anchors, JVM cacerts)
	./shared/scripts/generate-certs.sh

## Stack lifecycle (compose-*)

.PHONY: compose-up
compose-up: ## Start the full stack in the background
	$(COMPOSE) up -d

.PHONY: compose-down
compose-down: ## Stop the stack and remove volumes
	$(COMPOSE) down -v

.PHONY: compose-restart
compose-restart: compose-down compose-up ## Tear down and restart the stack

.PHONY: compose-ps
compose-ps: ## List running containers
	$(COMPOSE) ps

.PHONY: compose-logs
compose-logs: ## Tail logs from all services (Ctrl-C to exit)
	$(COMPOSE) logs -f --tail=50

.PHONY: compose-logs-%
compose-logs-%: ## Tail logs from a single service, e.g. `make compose-logs-rucio`
	$(COMPOSE) logs -f --tail=100 $*

.PHONY: compose-build
compose-build: ## Build local Docker images (fts, xrd-scitokens, rucio-client-dind)
	$(COMPOSE) build

.PHONY: bootstrap
bootstrap: ## Bootstrap Rucio (accounts, RSEs, OIDC identities, token providers)
	./shared/scripts/bootstrap-testbed.sh

## Tests

.PHONY: test-rucio
test-rucio: ## Rucio E2E transfer test (bash version)
	./shared/scripts/test-rucio-transfers.sh

.PHONY: test-rucio-python
test-rucio-python: ## Rucio E2E transfer test (Python, runs in rucio-client container)
	docker exec compose-rucio-client-1 \
		python3 /scripts/test-rucio-transfers.py

.PHONY: test-xrootd-gsi
test-xrootd-gsi: ## XRootD TPC test with X.509 GSI
	docker exec compose-fts-1 \
		python3 /scripts/test-fts-with-xrootd.py

.PHONY: test-xrootd-oidc
test-xrootd-oidc: ## XRootD TPC test with OIDC tokens (SciTokens)
	./shared/scripts/test-fts-with-xrootd-scitokens.sh

.PHONY: test-storm
test-storm: ## StoRM WebDAV TPC test with OIDC tokens
	./shared/scripts/test-fts-with-storm-webdav.sh

.PHONY: test-webdav
test-webdav: ## WebDAV TPC test with X.509 GSI
	./shared/scripts/test-fts-with-webdav.sh

.PHONY: test-s3
test-s3: ## S3/MinIO test with signed URLs
	./shared/scripts/test-fts-with-s3.sh

.PHONY: test-all
test-all: test-rucio test-xrootd-gsi test-xrootd-oidc test-storm test-webdav test-s3 ## Run every test sequentially

## Development

.PHONY: lint
lint: ## Run pre-commit hooks on all files
	pre-commit run --all-files

## Cleanup

.PHONY: clean
clean: ## Remove generated certs and volumes; keep CA (rucio_ca.pem + key)
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true
	@# Preserve the CA so we don't have to re-trust it on every iteration.
	@# find is safer than shell globs here because it handles the
	@# "no matching files" case cleanly and lets us express "*.pem
	@# except rucio_ca.pem and rucio_ca.key.pem" as a single predicate.
	find certs -maxdepth 1 -type f -name '*.pem' \
		! -name 'rucio_ca.pem' \
		! -name 'rucio_ca.key.pem' \
		-delete 2>/dev/null || true
	rm -rf certs/storm-cacerts certs/trustanchors
	@echo "Cleaned certs (preserved rucio_ca.pem and rucio_ca.key.pem) and volumes"
