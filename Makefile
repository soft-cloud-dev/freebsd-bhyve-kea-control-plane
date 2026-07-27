SHELL = /bin/sh

SCRIPTS = \
	scripts/01_host_setup.sh \
	scripts/02_install_dependencies.sh \
	scripts/provision_vm.sh \
	scripts/rollback_vm.sh

TESTS = \
	tests/test_pf.sh \
	tests/test_kea.sh \
	tests/test_provisioner.sh

.PHONY: all lint syntax test validate-freebsd install

all: lint

syntax:
	@set -e; for file in $(SCRIPTS) $(TESTS); do \
		echo "sh -n $$file"; \
		sh -n "$$file"; \
	done

lint: syntax
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s sh $(SCRIPTS) $(TESTS); \
	else \
		echo "shellcheck is not installed; syntax validation completed"; \
	fi

test: lint
	@tests/test_provisioner.sh

validate-freebsd: lint
	@tests/test_pf.sh
	@tests/test_kea.sh

install:
	@echo "Follow docs/installation.md; installation is intentionally not automatic."
