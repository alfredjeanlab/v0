# v0 Makefile - Test targets

# Get the directory where this Makefile is located (works even if make is run from elsewhere)
MAKEFILE_DIR := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))

# BATS installed globally by scripts/test
V0_DATA_DIR := $(or $(XDG_DATA_HOME),$(HOME)/.local/share)/v0
BATS := $(V0_DATA_DIR)/bats/bats-core/bin/bats
BATS_LIB_PATH := $(V0_DATA_DIR)/bats

.PHONY: help check test test-file test-package lint lint-scripts lint-tests lint-quality license install

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
	@echo "  make lint            Run lint on all scripts"
	@echo "  make check           Run lint and all tests"
	@echo ""
	@echo "Maintenance:"
	@echo "  make license         Add license headers to source files"

# Run lint and all tests
check: lint test

# Lint scripts with ShellCheck
lint: lint-quality lint-scripts lint-tests

# Enforce LOC limits, suppress rules, etc
lint-quality:
	quench check

# Lint bin and lib files with ShellCheck
lint-scripts:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "Error: shellcheck not found. Install with: brew install shellcheck"; \
		exit 1; \
	fi
	@echo "Linting bin/ scripts..."
	@shellcheck -x bin/v0-*
	@echo "Linting packages/*/lib/ files..."
	@find packages/*/lib -maxdepth 1 -name "*.sh" -type f | xargs shellcheck -x
	@echo "All scripts pass ShellCheck!"

# Lint test files with ShellCheck
lint-tests:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "Error: shellcheck not found. Install with: brew install shellcheck"; \
		exit 1; \
	fi
	@echo "Linting test files..."
	@find packages/*/tests tests -name "*.bats" -type f | xargs shellcheck -x -S warning -e SC1090,SC2155,SC2164,SC2178
	@shellcheck -x -S warning -e SC1090,SC2155,SC2164,SC2178 packages/test-support/helpers/*.bash
	@echo "All test files pass ShellCheck!"

# Run all tests (incremental with caching)
test:
	./scripts/test

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
	@scripts/license

# Symlink v0 to ~/.local/bin for local development
install:
	@scripts/install
