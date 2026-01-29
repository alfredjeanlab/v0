# v0 Makefile - Test targets

# Get the directory where this Makefile is located (works even if make is run from elsewhere)
MAKEFILE_DIR := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))

# BATS installed globally by scripts/test
V0_DATA_DIR := $(or $(XDG_DATA_HOME),$(HOME)/.local/share)/v0
BATS := $(V0_DATA_DIR)/bats/bats-core/bin/bats
BATS_LIB_PATH := $(V0_DATA_DIR)/bats

.PHONY: help check test test-init test-file test-package lint lint-scripts lint-tests lint-quality license install

# Default target
help:
	@echo "v0 Development Targets:"
	@echo "  make install         Symlink v0 to ~/.local/bin for development"
	@echo ""
	@echo "Testing:"
	@echo "  make test            Run all tests (incremental, cached)"
	@echo "  make test-package PKG=state  Run tests for a specific package"
	@echo "  make test-file FILE=packages/core/tests/foo.bats"
	@echo ""
	@echo "Linting:"
	@echo "  make lint            Run shellcheck (incremental, cached)"
	@echo "  make check           Run lint and all tests"
	@echo ""
	@echo "Maintenance:"
	@echo "  make license         Add license headers to source files"

# Run lint and all tests
check: lint-quality lint test

# Lint with shellcheck (incremental)
lint:
	./scripts/lint

# Lint bin/ scripts and package libs (for CI)
lint-scripts:
	./scripts/lint bin $(shell find packages -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)

# Lint test files (for CI)
lint-tests:
	./scripts/lint tests $(shell find packages -mindepth 1 -maxdepth 1 -type d -exec sh -c 'echo {}/tests' \;)

# Enforce LOC limits, suppress rules, etc
lint-quality:
	quench check

# Run all tests (incremental with caching)
test:
	./scripts/test

# Initialize test framework (install BATS, for CI)
test-init:
	./scripts/test --init

# Run tests for a specific package
test-package:
	@if [ -z "$(PKG)" ]; then \
		echo "Usage: make test-package PKG=state"; \
		exit 1; \
	fi
	./scripts/test $(PKG)

# Run a specific test file
test-file:
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make test-file FILE=packages/core/tests/foo.bats"; \
		exit 1; \
	fi
	@if [ ! -x "$(BATS)" ]; then \
		./scripts/test --init; \
	fi
	BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) --timing $(FILE)


# Add license headers to source files
license:
	quench check --ci --fix --license

# Symlink v0 to ~/.local/bin for local development
install:
	@scripts/install
