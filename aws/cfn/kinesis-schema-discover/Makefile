SHELL = /bin/bash

VIRTUAL_ENV = .venv
REQUIREMENTS = requirements.txt
CONSTRAINTS = constraints.txt
PYTHON = .venv/bin/python
AWS = .venv/bin/aws
SAM = .venv/bin/sam
PYLINT = .venv/bin/pylint

# Lambda vars
AWS_DEFAULT_REGION ?= us-west-2
STACK_NAME = DiscoverSchemaStack
CFNROLE = kinesis-service-role.yaml
SAM_TEMPLATE = template.yaml
CFN_TEMPLATE = output.yaml
S3_LAMBDA_BUCKET = sharedinf-lambdabucket-559166403383-us-west-2

# Local conversion
TMP := $(shell mktemp -u s3://xcfield/tmp/discover-XXXXXX)
CSV1 = s3://xcfield/instantdatamart/csv/GlobalLandTemperaturesByCity.csv
JSON1 = s3://xcfield/instantdatamart/json/geneinfo_arr/xbq-arr
SAMPLEDATA = data.csv policy.json
SCHEMAS = $(patsubst %,%.schema.json,$(SAMPLEDATA))

export AWS_DEFAULT_REGION

all: $(SCHEMAS)

run: venv
	$(PYTHON) app.py $(CSV1) | jq -r .
	$(PYTHON) app.py $(JSON1) | jq -r .

	@echo "Discovering schema on $(TMP) ..."
.venv-update: $(REQUIREMENTS) $(CONSTRAINTS)
	[ -e $(PYTHON) ] || /opt/xcalar/bin/python3.6 -m venv --clear --prompt $$(basename `pwd`) $(VIRTUAL_ENV)
	$(PYTHON) -m pip install -r $(REQUIREMENTS) -c $(CONSTRAINTS)
	touch $@

%.schema.json: % .venv-update
	@$(AWS) s3 cp $< $(TMP)
	@echo "Discovering schema for $< ..."
	@$(PYTHON) app.py $(TMP) | jq -r . > `basename $(TMP)`
	@echo "Saved schema $@ ..."
	@mv `basename $(TMP)` $@
	@-$(AWS) s3 --quiet rm $(TMP)

clean:
	rm -f $(SCHEMAS)

very-clean: clean
	rm -rf .venv-update $(VIRTUAL_ENV)

venv: .venv-update

check:
	$(PYLINT) app.py

sam: venv
	$(SAM) package --template-file $(SAM_TEMPLATE) --output-template-file $(CFN_TEMPLATE) --s3-bucket $(S3_LAMBDA_BUCKET)
	$(SAM) deploy --template-file $(CFN_TEMPLATE) --stack-name $(STACK_NAME) --capabilities CAPABILITY_IAM
