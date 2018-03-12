.PHONY: venv all

SHELL=/bin/bash


mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(notdir $(patsubst %/,%,$(dir $(mkfile_path))))

PYTHON = python2
PYTHON_VERSION = $(shell $(PYTHON) --version 2>&1 | sed -e 's/^P/p/; s/ /-/')

VIRTUAL_ENV = $(current_dir)/.venv

all: venv

venv: $(VIRTUAL_ENV)/.updated

$(VIRTUAL_ENV):
	virtualenv --python=$(PYTHON) --prompt=$(shell dirname $(current_dir)) $@

$(VIRTUAL_ENV)/.updated: $(VIRTUAL_ENV) frozen.txt
	$(VIRTUAL_ENV)/bin/pip install -r frozen.txt
	touch $@

update:
	$(VIRTUAL_ENV)/bin/pip install -r requirements.txt
	$(VIRTUAL_ENV)/bin/pip freeze > frozen.txt

