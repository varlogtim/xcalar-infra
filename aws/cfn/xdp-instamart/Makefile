SHELL:=/bin/bash

PACKER_JSON ?= $(XLRINFRADIR)/output/packer-manifest.json
LAST_UUID := $(shell jq -r ".last_run_uuid" $(PACKER_JSON))
AMI_ID := $(shell jq -r '.builds[]|select(.name == "amazon-ebs-amzn2")|select(.packer_run_uuid == "$(LAST_UUID)") .artifact_id' $(PACKER_JSON) | cut -d':' -f 2)

PROJECT = xdp-instamart
GEN = ref/xdp-standard-byovpc.cf.yaml ref/xdp-standard.cf.yaml ref/stepfun.cf.yaml
VALIDATION = $(patsubst %.cf.yaml, %.valid, $(GEN))
PARAMS = $(patsubst %.valid, %.params, $(VALIDATION))
DEBUG = 0
ENVIRONMENT = test
S3FLAGS = --cache-control 'private, no-cache, no-store, must-revalidate, max-age=0, no-transform' --acl public-read --metadata-directive REPLACE
SOURCES = xdp-standard.cf.yaml stepfun.cf.yaml scripts/user-data.sh scripts/batch.sh
LAMBDA_BUCKET = sharedinf-lambdabucket-559166403383
URL = ref/output.url
UUID := $(shell uuidgen)
CHANGE_SET = mychange-$(UUID)
NAME := $(shell id -un)
STACK_NAME = $(NAME)-instamart
BASEURL := $(shell baseurl.sh `installer-version.sh --format=cli $(AMI_ID)` --env $(ENVIRONMENT) --project $(PROJECT))

all: check

check: $(GEN) $(VALIDATION) $(PARAMS)

%.valid: %.cf.yaml
	cfn-lint $<
	aws cloudformation validate-template --template-body file://./$< > $@.tmp
	mv $@.tmp $@

%.params: %.valid
	jq -r '[.Parameters[]|{ParameterKey:.ParameterKey, UsePreviousValue: true}]' $< > $@.tmp
	mv $@.tmp $@

ref/$(AMI_ID).json:
	aws ec2 describe-images --image-ids $(AMI_ID) --query 'Images[].Tags[]' | jq '{ami: map_values({(.Key): .Value})|add}' > $@.tmp
	@mv $@.tmp $@

clean:
	rm -fv $(GEN) $(VALIDATION) $(PARAMS)

ref/xdp-standard-byovpc.cf.yaml: xdp-standard.template.j2
	jinja2 -DbaseUrl=$(BASEURL) -DkeepIp=True -DenableLifecycle=False -DbootstrapUrl=$(BASEURL)scripts/user-data.sh  -DDEBUG=$(DEBUG) -Dami_id=$(AMI_ID) -DcreateVpc=False $< vars/allowed_types.yaml var/lambda.yaml > $@

ref/stepfun.cf.yaml: stepfun.template.j2
	jinja2 -DbaseUrl=$(BASEURL) -DkeepIp=True -DenableLifecycle=False -DbootstrapUrl=$(BASEURL)scripts/user-data.sh  -DDEBUG=$(DEBUG) -Dami_id=$(AMI_ID) -DcreateVpc=True $< vars/allowed_types.yaml vars/lambda.yaml > $@

ref/xdp-standard.cf.yaml: xdp-standard.template.j2
	jinja2 -DbaseUrl=$(BASEURL) -DkeepIp=True -DenableLifecycle=False -DbootstrapUrl=$(BASEURL)scripts/user-data.sh  -DDEBUG=$(DEBUG) -Dami_id=$(AMI_ID) -DcreateVpc=True $< vars/allowed_types.yaml vars/lambda.yaml > $@

%.zip: %/requirements.txt %/constraints.txt
	rm -rf pkg/$(<D)
	cp -a $(<D) pkg/
	cd pkg/$(<D) && pip install -r requirements.txt -c constraints.txt -t .
	cd pkg/$(<D) && zip -9r ../../$@ *


lambda.zip: lambda/schedule.py lambda/add_notification.py lambda/requirements.txt lambda/constraints.txt
	rm -f $@
	rm -rf pkg/
	mkdir -p pkg
	cp -a $^ pkg/
	cd pkg && pip install -r requirements.txt -c constraints.txt -t .
	cd pkg && zip -9r ../$@ *
	md5sum $@ > $@.md5sum

#--manifest $(XLRINFRADIR)/output/packer-manifest.json

upload: lambda.zip
	MD5=`md5sum $< | cut -c1-16`; for region in us-west-2 us-east-1 us-east-2 us-west-1; do aws s3 cp $(S3FLAGS) $< s3://$(LAMBDA_BUCKET)-$${region}/$(PROJECT)/$${MD5}.zip; done \
        && sed -i 's@S3Key: xdp.*$$@S3Key: $(PROJECT)/'$${MD5}'.zip@' stepfun.template.j2
	dc2 upload --debug --keep --project $(PROJECT) --env $(ENVIRONMENT) --manifest $(XLRINFRADIR)/output/packer-manifest.json `installer-version.sh --format=cli $(AMI_ID)` --url-file $(URL)

STACK_CHANGE = --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET)
create: check upload
	aws cloudformation create-stack --stack-name $(STACK_NAME) --template-url `cat $(URL)` --parameters file://./ref/$(NAME).params.json --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND

deploy:
	aws cloudformation create-change-set $(STACK_CHANGE) --template-url `cat $(URL)` --parameters file://./ref/$(NAME).params.json --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND
	aws cloudformation wait change-set-create-complete $(STACK_CHANGE)
	aws cloudformation describe-change-set $(STACK_CHANGE) | tee ref/$(STACK_NAME)-$(CHANGE_SET).change
	aws cloudformation execute-change-set $(STACK_CHANGE)
	aws cloudformation wait stack-update-complete --stack-name $(STACK_NAME)

update:
	$(MAKE) CHANGE_SET=change-`uuidgen` check upload deploy
