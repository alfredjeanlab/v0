# v0 Makefile - Test targets

# Get the directory where this Makefile is located (works even if make is run from elsewhere)
MAKEFILE_DIR := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))

# Always use local bats for consistent behavior across environments
BATS := $(MAKEFILE_DIR)tests/bats/bats-core/bin/bats
BATS_LIB_PATH := $(MAKEFILE_DIR)tests/bats

TEST_FILES := $(wildcard tests/unit/*.bats)

.PHONY: test test-unit test-debug test-file test-init lint lint-tests lint-policy check help license test-fixtures install

# Default target
help:
	@echo "v0 Development Targets:"
	@echo "  make install         Symlink v0 to ~/.local/bin for development"
	@echo ""
	@echo "Testing:"
	@echo "  make test            Run all unit tests"
	@echo "  make test-debug      Run tests with verbose output"
	@echo "  make test-file FILE=tests/unit/foo.bats"
	@echo "  make test-fixtures   Generate test fixtures (cached git repo)"
	@echo ""
	@echo "Linting:"
	@echo "  make lint            Run ShellCheck on scripts"
	@echo "  make lint-tests      Run ShellCheck on test files"
	@echo "  make check           Run lint and all tests"
	@echo ""
	@echo "Maintenance:"
	@echo "  make license         Add license headers to source files"

# Check if local BATS/libraries need installation
.PHONY: test-init
test-init:
	@if [ ! -d "tests/bats/bats-support" ] && echo "$(BATS_LIB_PATH)" | grep -q "tests/bats"; then \
		echo "Installing BATS testing libraries..."; \
		./tests/bats/install.sh; \
	elif [ ! -x "$(BATS)" ] && [ ! -x "$(LOCAL_BATS)" ]; then \
		echo "Installing BATS testing libraries..."; \
		./tests/bats/install.sh; \
	fi

# Run all tests
test: test-unit

# Run unit tests
test-unit: test-init
	@if [ ! -x "$(BATS)" ]; then \
		echo "Error: BATS not found. Run 'make test-init' or install bats-core."; \
		exit 1; \
	fi
	BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) --timing --print-output-on-failure tests/unit/

# Run tests with verbose output (for debugging)
test-debug: test-init
	@if [ ! -x "$(BATS)" ]; then \
		echo "Error: BATS not found. Run 'make test-init' or install bats-core."; \
		exit 1; \
	fi
	BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) --timing --verbose-run --print-output-on-failure tests/unit/

# Run a specific test file
test-file: test-init
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make test-file FILE=tests/unit/foo.bats"; \
		exit 1; \
	fi
	@if [ ! -x "$(BATS)" ]; then \
		echo "Error: BATS not found. Run 'make test-init' or install bats-core."; \
		exit 1; \
	fi
	BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) --timing $(FILE)

# Run all tests
test-all: test-unit

# Lint scripts with ShellCheck
lint:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "Error: shellcheck not found. Install with: brew install shellcheck"; \
		exit 1; \
	fi
	@echo "Linting bin/ scripts..."
	@shellcheck -x bin/v0-*
	@echo "Linting lib/ files..."
	@shellcheck -x lib/*.sh
	@echo "All scripts pass ShellCheck!"

# Lint test files with ShellCheck
lint-tests:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "Error: shellcheck not found. Install with: brew install shellcheck"; \
		exit 1; \
	fi
	@echo "Linting test files..."
	@shellcheck -x -S warning -e SC1090,SC2155,SC2164,SC2178 tests/unit/*.bats tests/helpers/*.bash
	@echo "All test files pass ShellCheck!"

# Check policy compliance (shellcheck disables, etc.)
lint-policy:
	@scripts/lint-policy

# Run lint and all tests
check: lint lint-policy test-all

# Add license headers to source files
license:
	@scripts/license

# Generate test fixtures (cached git repo, etc.)
test-fixtures:
	@if [ ! -f "tests/fixtures/git-repo.tar" ]; then \
		echo "Generating test fixtures..."; \
		bash tests/fixtures/create-git-fixture.sh; \
	fi

# Symlink v0 to ~/.local/bin for local development
install:
	@scripts/install
