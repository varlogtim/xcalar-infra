SHELL=/bin/bash

VIRTUAL_ENV ?= $(HOME)/.local/lib/xcalar-infra

BUCKET ?= xcrepo
TARGET ?= /netstore/infra
VERSION ?= 2
all: $(VIRTUAL_ENV)/.updated

$(VIRTUAL_ENV):
	virtualenv $@

$(VIRTUAL_ENV)/.updated: $(VIRTUAL_ENV) frozen.txt
	$(VIRTUAL_ENV)/bin/pip install -r frozen.txt
	touch $@

update:
	$(VIRTUAL_ENV)/bin/pip install -r requirements.txt
	$(VIRTUAL_ENV)/bin/pip freeze > frozen.txt

deploy:
	cp aws/cfn/XCE-CloudFormationSingleNodeForIMS.yaml $(TARGET)/XCE-CloudFormationSingleNodeForIMS-v$(VERSION).yaml
	cd $(TARGET)/aws && git add -u && git commit -m "Deployment"
	aws s3 cp --quiet --acl public-read --metadata-directive REPLACE --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' \
		aws/cfn/XCE-CloudFormationSingleNodeForIMS.yaml \
		s3://$(BUCKET)/$(KEY)aws/cfn/XCE-CloudFormationSingleNodeForIMS-$(VERSION).yaml
