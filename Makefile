# VMBOX Build System - Lint and Test Targets
#
# Usage:
#   make lint          - Run all linters
#   make lint-shell    - Run shellcheck on core scripts
#   make lint-python   - Run Python syntax check on core files
#   make smoke-test    - Validate package files and config
#   make check         - Run lint + smoke-test

SHELL := /bin/bash

# Core shell scripts (excludes submodule scripts under apps/)
SHELL_SCRIPTS := \
	build.sh \
	config.sh \
	scripts/lib.sh \
	scripts/chroot-helper.sh \
	scripts/01-create-alpine-rootfs.sh \
	scripts/02-build-packages.sh \
	scripts/03-create-image.sh \
	scripts/04-convert-to-vbox.sh \
	scripts/build-app-partition.sh \
	scripts/smoke-test.sh

# Core Python files (excludes submodule apps)
PYTHON_FILES := \
	rootfs/opt/app-manager/app-manager.py \
	rootfs/opt/system-mgmt/app.py \
	rootfs/opt/business-app/app.py \
	apps/hello-world/src/app.py

.PHONY: lint lint-shell lint-python smoke-test check help

help:
	@echo "Available targets:"
	@echo "  make lint          - Run all linters (shellcheck + python)"
	@echo "  make lint-shell    - Run shellcheck on core build scripts"
	@echo "  make lint-python   - Run Python syntax check"
	@echo "  make smoke-test    - Validate package files and script syntax"
	@echo "  make check         - Run lint + smoke-test"

lint: lint-shell lint-python

lint-shell:
	@echo "=== Shellcheck ==="
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s bash -S warning $(SHELL_SCRIPTS); \
		echo "shellcheck passed"; \
	else \
		echo "SKIP: shellcheck not installed (apt install shellcheck)"; \
	fi

lint-python:
	@echo "=== Python syntax check ==="
	@errors=0; \
	for f in $(PYTHON_FILES); do \
		if [ -f "$$f" ]; then \
			python3 -m py_compile "$$f" 2>&1 || errors=$$((errors + 1)); \
		fi; \
	done; \
	if [ $$errors -eq 0 ]; then echo "python syntax OK"; else exit 1; fi

smoke-test:
	@./scripts/smoke-test.sh

check: lint smoke-test
	@echo ""
	@echo "All checks passed."
