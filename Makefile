SHELL := /bin/bash

MONGO_IMAGE ?= mongo:latest
export MONGO_IMAGE

.PHONY: \
	help \
	test \
	unit-test \
	spec-test \
	integration-test \
	tls-integration-test \
	runtime-integration-test \
	cmap-integration-test \
	sdam-integration-test \
	deez-readiness-test \
	fixtures \
	fixtures-status \
	fixtures-reset \
	fixtures-clean

help:
	@printf '%s\n' \
		'make test                     Run the complete Bongo test suite' \
		'make unit-test                Run unit tests only' \
		'make spec-test                Run MongoDB specification harness tests' \
		'make integration-test         Run normal MongoDB integration tests' \
		'make tls-integration-test     Run TLS integration test' \
		'make runtime-integration-test Run RuntimeClient transaction test' \
		'make cmap-integration-test    Run CMAP pool lifecycle integration tests' \
		'make sdam-integration-test    Run 3-member SDAM discovery/failover tests' \
		'make deez-readiness-test      Test the Deez-facing API surface' \
		'make fixtures                 Ensure all MongoDB fixtures are ready' \
		'make fixtures-status          Show fixture status' \
		'make fixtures-reset           Recreate all fixtures' \
		'make fixtures-clean           Remove all fixtures'

# This is intentionally sequential. The fixtures share predictable local
# container names and ports, and readable sequential output is more useful
# than parallel test noise.
test:
	@$(MAKE) unit-test
	@$(MAKE) spec-test
	@$(MAKE) integration-test
	@$(MAKE) tls-integration-test
	@$(MAKE) runtime-integration-test
	@$(MAKE) cmap-integration-test
	@$(MAKE) sdam-integration-test
	@$(MAKE) deez-readiness-test
	@printf '\nBongo test suite passed.\n'

unit-test:
	zig build test

spec-test:
	zig build spec-test

integration-test:
	@./scripts/ensure-mongo-fixture.sh standalone
	zig build integration-test

tls-integration-test:
	@./scripts/ensure-mongo-fixture.sh tls
	zig build tls-integration-test

runtime-integration-test:
	@./scripts/ensure-mongo-fixture.sh replica
	zig build runtime-integration-test

cmap-integration-test:
	@./scripts/ensure-mongo-fixture.sh replica
	zig build cmap-integration-test

sdam-integration-test:
	@./scripts/ensure-mongo-fixture.sh sdam
	zig build sdam-integration-test

deez-readiness-test:
	zig build deez-readiness-test

fixtures:
	@./scripts/ensure-mongo-fixture.sh standalone
	@./scripts/ensure-mongo-fixture.sh tls
	@./scripts/ensure-mongo-fixture.sh replica
	@./scripts/ensure-mongo-fixture.sh sdam

fixtures-status:
	@./scripts/ensure-mongo-fixture.sh status

fixtures-reset:
	@./scripts/ensure-mongo-fixture.sh reset

fixtures-clean:
	@./scripts/ensure-mongo-fixture.sh clean
