.PHONY: all venv hooks clean update frozen clean recompile

SHELL=/bin/bash

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(notdir $(patsubst %/,%,$(dir $(mkfile_path))))

ifeq ($(XLRINFRADIR),)
$(error Must set XLRINFRADIR. Please source .env file)
endif

VENV = .venv
PIP_FLAGS   ?= -q
REQUIRES     = requirements.txt
REQUIRES_IN  = requirements.in
HOOKS        = .git/hooks/pre-commit
PYTHON  ?= /opt/xcalar/bin/python3.6

all: venv
	@echo "Run source .venv/bin/activate"

hooks: $(HOOKS)

$(HOOKS) : scripts/hooks/pre-commit.sh
	ln -sfT ../../$< $@

venv: .updated

.updated: $(VENV)/bin/pip-compile $(REQUIRES)
	@echo "Syncing virtualenv in $(VENV) with packages in $(REQUIRES) ..."
	@$(VENV)/bin/pip-sync $(REQUIRES)
	@/usr/bin/touch $@

recompile: $(VENV)/bin/pip-compile
	$(VENV)/bin/pip-compile -o $(REQUIRES) -v $(REQUIRES_IN)
	make venv

$(VENV):
	@echo "Creating new virtualenv in $@ ..."
	@mkdir -p $@
	@deactivate 2>/dev/null || true; $(PYTHON) -m venv --prompt=$(shell basename $(current_dir)) $@

$(VENV)/bin/pip-compile: $(VENV) $(REQUIRES)
	@deactivate 2>/dev/null || true; $(VENV)/bin/python -m pip install $(PIP_FLAGS) -U pip
	@deactivate 2>/dev/null || true; $(VENV)/bin/python -m pip install $(PIP_FLAGS) -U setuptools wheel pip-tools
	@/usr/bin/touch $@

clean:
	@echo Removing $(VENV) ...
	@rm -f .updated
	@if test -e $(VENV); then rm -r $(VENV); fi

# Used for running testing/verifying sources and json data
include mk/check.mk
include mk/convert.mk
-include local.mk
