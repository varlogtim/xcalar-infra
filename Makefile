.PHONY: all venv hooks clean update frozen clean

SHELL=/bin/bash

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(notdir $(patsubst %/,%,$(dir $(mkfile_path))))

ifeq ($(XLRINFRADIR),)
$(error Must set XLRINFRADIR. Please source .env file)
endif

VIRTUAL_ENV = .venv
PIP_FLAGS   ?= -q
REQUIRES     = requirements.txt
CONSTRAINTS  = constraints.txt
HOOKS        = .git/hooks/pre-commit
PYTHON  ?= /opt/xcalar/bin/python3.6

all: venv

hooks: $(HOOKS)

$(HOOKS) : scripts/hooks/pre-commit.sh
	ln -sfT ../../$< $@

venv: .updated

.updated: $(VIRTUAL_ENV)/bin/pip
	@/usr/bin/touch $@

$(VIRTUAL_ENV)/bin/pip: $(VIRTUAL_ENV) $(REQUIRES)
	@echo "Updating virtualenv in $(VIRTUAL_ENV) with packages in $(REQUIRES) ..."
	$(VIRTUAL_ENV)/bin/python -m pip install $(PIP_FLAGS) pip setuptools wheel
	$(VIRTUAL_ENV)/bin/python -m pip install $(PIP_FLAGS) -r $(REQUIRES) -c $(CONSTRAINTS)
	@/usr/bin/touch $@

$(VIRTUAL_ENV):
	@echo "Creating new virtualenv in $@ ..."
	@mkdir -p $@
	@deactivate 2>/dev/null || true; $(PYTHON) -m venv --prompt=$(shell basename $(current_dir)) $@
	@deactivate 2>/dev/null || true; $(VIRTUAL_ENV)/bin/python -m pip install $(PIP_FLAGS) -U pip setuptools wheel pipenv

$(CONSTRAINTS): venv
	@echo "Saving requirements to $@ ..."
	$(VIRTUAL_ENV)/bin/pip freeze -r $(REQUIRES) | grep -v pkg-resources > $@.tmp
	mv $@.tmp $@

clean:
	@echo Removing $(VIRTUAL_ENV) ...
	@if test -e $(VIRTUAL_ENV); then rm -r $(VIRTUAL_ENV); fi

# Used for running testing/verifying sources and json data
include mk/check.mk
include mk/convert.mk
-include local.mk
