# Quality gates. Nothing here applies anything: init is always -backend=false, tests use mocks.
# Tools live in ./.tools (make tools); every tool home stays under ./.tools.
SHELL := /bin/bash
.DEFAULT_GOAL := check

export PATH := $(CURDIR)/.tools/bin:$(PATH)
export TFLINT_PLUGIN_DIR := $(CURDIR)/.tools/tflint-plugins
export TF_PLUGIN_CACHE_DIR := $(CURDIR)/.tools/tf-plugin-cache
export PRE_COMMIT_HOME := $(CURDIR)/.tools/pre-commit

# OpenTofu roots: every directory holding *.tf under bootstrap/, modules/ and envs/.
ROOTS := $(sort $(patsubst %/,%,$(dir $(shell find bootstrap modules envs -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null))))
TF_DIRS := $(wildcard bootstrap modules envs)
NO_ROOTS = echo "no OpenTofu roots yet"

.PHONY: tools tools-dry-run fmt validate lint test shellcheck secrets check

tools:
	@scripts/tools.sh install

tools-dry-run:
	@scripts/tools.sh --dry-run install

fmt:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@tofu fmt -check -recursive $(TF_DIRS)
endif

validate:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@set -e; for d in $(ROOTS); do echo "==> validate $$d"; \
	  tofu -chdir="$$d" init -backend=false -input=false; tofu -chdir="$$d" validate; done
endif

lint:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@tflint --config="$(CURDIR)/.tflint.hcl" --init
	@set -e; for d in $(ROOTS); do echo "==> tflint $$d"; \
	  tflint --config="$(CURDIR)/.tflint.hcl" --chdir="$$d"; done
	@checkov -d . --framework terraform --quiet --compact --skip-download
endif

test:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@set -e; for d in $(ROOTS); do if [ -d "$$d/tests" ]; then echo "==> tofu test $$d"; \
	  tofu -chdir="$$d" test; fi; done
endif
	@bats tests/

shellcheck:
	@shellcheck scripts/*.sh

secrets:
	@gitleaks git --redact --no-banner .

check: fmt validate lint test shellcheck secrets
