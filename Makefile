# v0 Makefile - Test targets

# Get the directory where this Makefile is located (works even if make is run from elsewhere)
MAKEFILE_DIR := $(dir $(abspath $(firstword $(MAKEFILE_LIST))))

# BATS detection - prefer system install, fall back to local
SYSTEM_BATS := $(shell command -v bats 2>/dev/null)
LOCAL_BATS := $(MAKEFILE_DIR)tests/bats/bats-core/bin/bats

ifdef SYSTEM_BATS
    BATS := $(SYSTEM_BATS)
    SYSTEM_LIB_PATH := $(shell dirname $(shell dirname $(SYSTEM_BATS)))/lib
    # Use system libraries if available, otherwise fall back to local
    ifneq ($(wildcard $(SYSTEM_LIB_PATH)/bats-support/load.bash),)
        BATS_LIB_PATH := $(SYSTEM_LIB_PATH)
    else
        BATS_LIB_PATH := $(MAKEFILE_DIR)tests/bats
    endif
else
    BATS := $(LOCAL_BATS)
    BATS_LIB_PATH := $(MAKEFILE_DIR)tests/bats
endif

# Parallel test execution - requires GNU parallel
# Default to parallel if available, use JOBS=1 to force sequential
HAS_PARALLEL := $(shell command -v parallel 2>/dev/null)
JOBS ?= $(if $(HAS_PARALLEL),4,1)
ifeq ($(JOBS),1)
    BATS_JOBS :=
else
    ifdef HAS_PARALLEL
        BATS_JOBS := --jobs $(JOBS)
    else
        BATS_JOBS :=
    endif
endif

TEST_FILES := $(wildcard tests/unit/*.bats)

.PHONY: test test-unit test-verbose test-file test-init test-integration test-all lint lint-tests check help license test-profile test-fixtures

# Default target
help:
	@echo "v0 Test Targets:"
	@echo "  make test            Run all unit tests (parallel if GNU parallel installed)"
	@echo "  make test JOBS=1     Run tests sequentially"
	@echo "  make test-verbose    Run tests with verbose output"
	@echo "  make test-file FILE=tests/unit/foo.bats"
	@echo "  make test-profile    Run tests and show per-file execution times"
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
	BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) $(BATS_JOBS) tests/unit/

# Run tests with verbose output
test-verbose: test-init
	@if [ ! -x "$(BATS)" ]; then \
		echo "Error: BATS not found. Run 'make test-init' or install bats-core."; \
		exit 1; \
	fi
	BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) $(BATS_JOBS) --verbose-run --print-output-on-failure tests/unit/

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
	BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) $(FILE)

# Run integration tests
test-integration: test-init
	@if [ ! -d "tests/integration" ]; then \
		echo "No integration tests found (tests/integration/ does not exist)"; \
		exit 0; \
	fi
	@if [ ! -x "$(BATS)" ]; then \
		echo "Error: BATS not found. Run 'make test-init' or install bats-core."; \
		exit 1; \
	fi
	BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) tests/integration/

# Run all tests (unit + integration)
test-all: test-unit test-integration

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
	@shellcheck -x tests/unit/*.bats tests/helpers/*.bash
	@echo "All test files pass ShellCheck!"

# Run lint and all tests
check: lint test-all

# Add license headers to source files
license:
	@scripts/license

# Generate test fixtures (cached git repo, etc.)
test-fixtures:
	@if [ ! -f "tests/fixtures/git-repo.tar" ]; then \
		echo "Generating test fixtures..."; \
		bash tests/fixtures/create-git-fixture.sh; \
	fi

# Profile test execution times per file
test-profile: test-init
	@echo "Running test profile..."
	@for f in tests/unit/*.bats; do \
		start=$$(gdate +%s%N 2>/dev/null || date +%s%N); \
		BATS_LIB_PATH="$(BATS_LIB_PATH)" $(BATS) "$$f" >/dev/null 2>&1 || true; \
		end=$$(gdate +%s%N 2>/dev/null || date +%s%N); \
		ms=$$(( (end - start) / 1000000 )); \
		printf "%6dms %s\n" "$$ms" "$$f"; \
	done | sort -rn
