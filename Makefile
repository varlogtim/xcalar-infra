SHELL=/bin/bash

VIRTUAL_ENV ?= $(HOME)/.local/lib/xcalar-infra

all: $(VIRTUAL_ENV)/.updated

$(VIRTUAL_ENV):
	virtualenv $@

$(VIRTUAL_ENV)/.updated: $(VIRTUAL_ENV) frozen.txt
	$(VIRTUAL_ENV)/bin/pip install -r frozen.txt
	touch $@

update:
	$(VIRTUAL_ENV)/bin/pip install -r requirements.txt
	$(VIRTUAL_ENV)/bin/pip freeze > frozen.txt


