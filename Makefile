.PHONY: all venv hooks clean update frozen.txt

SHELL=/bin/bash

mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(notdir $(patsubst %/,%,$(dir $(mkfile_path))))

# PYTHON_VERSION = $(shell $(PYTHON) --version 2>&1 | sed -e 's/^P/p/; s/ /-/')

VIRTUAL_ENV = .venv

ifeq ($(XLRINFRADIR),)
$(error Must set XLRINFRADIR. Please source .env file)
endif

PYTHON = python3.6
PYTHON_VERSION = $(shell $(PYTHON) --version 2>&1 | head -1 | sed 's/^Python //')
DIRENV_VENV = $(XLRINFRADIR)/.direnv/python-$(PYTHON_VERSION)
VIRTUAL_ENV = .venv
REQUIRES = requirements.txt

CDUP = cd $(shell -x git rev-parse --show-cdup)
HOOKS = .git/hooks/pre-commit

all: venv

hooks: $(HOOKS)

$(HOOKS) : scripts/hooks/pre-commit.sh
	ln -sfT ../../$< $@

venv: $(VIRTUAL_ENV)/.updated

$(VIRTUAL_ENV):
	@echo "Creating new virtualenv in $@ ..."
	@mkdir -p $@
	@deactivate 2>/dev/null || true; /opt/xcalar/bin/virtualenv -q --prompt=$(shell basename $(current_dir)) $@

$(VIRTUAL_ENV)/.updated: $(VIRTUAL_ENV) requirements.txt
	@echo "Updating virtualenv in $(VIRTUAL_ENV) with plugins from $(REQUIRES) ..."
	$(VIRTUAL_ENV)/bin/pip install -q -r $(REQUIRES)
	@touch $@

frozen.txt:
	@echo "Saving requirements to $@ ..."
	$(VIRTUAL_ENV)/bin/pip freeze -r $(REQUIRES) | grep -v pkg-resources > $@

clean:
	rm -r $(VIRTUAL_ENV)

# Used for running testing/verifying sources and json data
include mk/check.mk
include mk/convert.mk
