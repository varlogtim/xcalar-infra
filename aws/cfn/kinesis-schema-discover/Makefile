SHELL = /bin/bash

VIRTUAL_ENV = .venv
REQUIREMENTS = requirements.txt
CONSTRAINTS = constraints.txt
PYTHON = .venv/bin/python
AWS = .venv/bin/aws
PYLINT = .venv/bin/pylint

STACK_NAME = DiscoverSchemaStack
KINESIS_ROLE_ARN =
TMP := $(shell mktemp -u s3://xcfield/tmp/discover-XXXXXX)
AWS_DEFAUALT_REGION ?= us-west-2

CSVS = data.csv
SCHEMAS = $(patsubst %.csv,%.schema.json,$(CSVS))

export AWS_DEFAUALT_REGION

all: $(SCHEMAS)

run: .venv-update
	$(PYTHON) discover_schema.py

.venv-update: $(REQUIREMENTS) $(CONSTRAINTS)
	[ -e $(PYTHON) ] || /opt/xcalar/bin/python3.6 -m venv --clear --prompt $$(basename `pwd`) $(VIRTUAL_ENV)
	$(PYTHON) -m pip install -r $(REQUIREMENTS) -c $(CONSTRAINTS)
	touch $@

%.schema.json: %.csv .venv-update
	$(AWS) s3 cp $< $(TMP)
	$(PYTHON) ./discover_schema.py $(TMP) | jq -r . > `basename $(TMP)`
	@mv `basename $(TMP)` $@
	@-$(AWS) s3 --quiet rm $(TMP)

update-stack:
	$(AWS) cloudformation update-stack --stack-name $(STACK_NAME) --template-body file://kinesis-service-role.yaml --capabilities CAPABILITY_IAM

create-stack:
	$(AWS) cloudformation create-stack --stack-name $(STACK_NAME) --template-body file://kinesis-service-role.yaml --capabilities CAPABILITY_IAM

clean:
	rm -f $(SCHEMAS)

very-clean: clean
	rm -rf .venv-update $(VIRTUAL_ENV)

venv: .venv-update

check:
	$(PYLINT) ./discover_schema.py
