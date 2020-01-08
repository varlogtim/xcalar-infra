SHELL = /bin/bash

VIRTUAL_ENV = .venv
REQUIREMENTS = requirements.txt
CONSTRAINTS = constraints.txt
PYTHON = .venv/bin/python
STACK_NAME = DiscoverSchemaStack
TMP := $(shell mktemp -u s3://xcfield/tmp/discover-XXXXXX)

CSVS = data.csv
SCHEMAS = $(patsubst %.csv,%.schema.json,$(CSVS))

all: $(SCHEMAS)

run: .venv-update
	$(PYTHON) discover_schema.py

.venv-update: $(REQUIREMENTS) $(CONSTRAINTS)
	/opt/xcalar/bin/python3.6 -m venv --clear --prompt venv $(VIRTUAL_ENV)
	$(PYTHON) -m pip install -r $(REQUIREMENTS) -c $(CONSTRAINTS)
	touch $@

%.schema.json: %.csv .venv-update
	aws s3 cp $< $(TMP)
	$(PYTHON) ./discover_schema.py $(TMP) | jq -r . > `basename $(TMP)`
	mv `basename $(TMP)` $@
	-aws s3 rm $(TMP)

update-stack:
	aws cloudformation update-stack --stack-name $(STACK_NAME) --template-body file://kinesis-service-role.yaml --capabilities CAPABILITY_IAM

create-stack:
	aws cloudformation create-stack --stack-name $(STACK_NAME) --template-body file://kinesis-service-role.yaml --capabilities CAPABILITY_IAM

clean:
	rm -f $(SCHEMAS)
