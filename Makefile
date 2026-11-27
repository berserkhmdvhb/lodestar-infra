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

.PHONY: tools tools-dry-run fmt validate tflint checkov lint test shellcheck secrets actions check

tools:
	@scripts/tools.sh install

tools-dry-run:
	@scripts/tools.sh --dry-run install

fmt:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@git ls-files -z -- $(TF_DIRS) | grep -zE '\.(tf|tftest\.hcl|tfmock\.hcl)$$' | xargs -0 tofu fmt -check
endif

validate:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@set -e; for d in $(ROOTS); do echo "==> validate $$d"; \
	  tofu -chdir="$$d" init -backend=false -input=false; tofu -chdir="$$d" validate; done
endif

tflint:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@tflint --config="$(CURDIR)/.tflint.hcl" --init
	@set -e; for d in $(ROOTS); do echo "==> tflint $$d"; \
	  tflint --config="$(CURDIR)/.tflint.hcl" --chdir="$$d"; done
endif

# checkov: tests are excluded; a failed check or a file it cannot parse fails the build.
checkov:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@scripts/checkov-gate.sh
endif

lint: tflint checkov

test:
ifeq ($(ROOTS),)
	@$(NO_ROOTS)
else
	@mkdir -p "$(TF_PLUGIN_CACHE_DIR)"
	@set -e; for d in $(ROOTS); do if [ -d "$$d/tests" ]; then echo "==> tofu test $$d"; \
	  tofu -chdir="$$d" test; fi; done
endif
	@if grep -rn --include='*.tf' --exclude-dir=.terraform 'google_secret_manager_secret_version' $(TF_DIRS); then \
	  echo "secret values must never go through OpenTofu"; exit 1; fi
	@bats tests/

shellcheck:
	@shellcheck scripts/*.sh

secrets:
	@gitleaks git --redact --no-banner .

# Workflow gates. zizmor runs offline so it needs no token and gives the same result locally and in CI.
actions:
	@actionlint
	@zizmor --offline --no-progress .github

check: fmt validate lint test shellcheck secrets actions
