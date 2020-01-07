SHELL = /bin/bash

VIRTUAL_ENV = .venv
REQUIREMENTS = requirements.txt
CONSTRAINTS = constraints.txt
PYTHON = .venv/bin/python
STACK_NAME = DiscoverSchemaStack

run: .venv-update
	$(PYTHON) discover_schema.py

.venv-update: $(REQUIREMENTS) $(CONSTRAINTS)
	/opt/xcalar/bin/python3.6 -m venv --clear --prompt venv $(VIRTUAL_ENV)
	$(PYTHON) -m pip install -r $(REQUIREMENTS) -c $(CONSTRAINTS)
	touch $@

update-stack:
	aws cloudformation update-stack --stack-name $(STACK_NAME) --template-body file://kinesis-service-role.yaml --capabilities CAPABILITY_IAM

create-stack:
	aws cloudformation create-stack --stack-name $(STACK_NAME) --template-body file://kinesis-service-role.yaml --capabilities CAPABILITY_IAM
