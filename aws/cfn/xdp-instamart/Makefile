SHELL:=/bin/bash

AMI_ID = ami-0c7f3778b6dfb6401
PROJECT = xdp-instamart
GEN = ref/xdp-standard-byovpc.cf.yaml ref/xdp-standard.cf.yaml
VALIDATION = $(patsubst %.cf.yaml, %.valid, $(GEN))
PARAMS = $(patsubst %.valid, %.params, $(VALIDATION))
DEBUG = 1
S3FLAGS = --cache-control 'private, no-cache, no-store, must-revalidate, max-age=0, no-transform' --acl public-read --metadata-directive REPLACE
SOURCES = xdp-standard.cf.yaml stepfun.cf.yaml scripts/user-data.sh scripts/batch.sh
LAMBDA_BUCKET = sharedinf-lambdabucket-559166403383-us-west-2
URL = ref/output.url
UUID := $(shell uuidgen)
CHANGE_SET = mychange-$(UUID)
NAME := $(shell id -un)
STACK_NAME = $(NAME)-instamart

all: check

check: $(GEN) $(VALIDATION) $(PARAMS)

%.valid: %.cf.yaml
	cfn-lint $<
	aws cloudformation validate-template --template-body file://./$< > $@.tmp
	mv $@.tmp $@

%.params: %.valid
	jq -r '[.Parameters[]|{ParameterKey:.ParameterKey, UsePreviousValue: true}]' $< > $@.tmp
	mv $@.tmp $@

clean:
	rm -fv $(GEN) $(VALIDATION) $(PARAMS)

ref/xdp-standard-byovpc.cf.yaml: xdp-standard.template.j2
	jinja2 -DDEBUG=$(DEBUG) -Dami_id=$(AMI_ID) -DcreateVpc=False $< vars/allowed_types.yaml > $@

ref/xdp-standard.cf.yaml: xdp-standard.template.j2
	jinja2 -DDEBUG=$(DEBUG) -Dami_id=$(AMI_ID) -DcreateVpc=True $< vars/allowed_types.yaml > $@

lambda.zip: lambda/requirements.txt lambda/constraints.txt lambda/add_notification.py
	rm -rf pkg
	mkdir -p pkg
	cp $^ pkg
	cd pkg && pip install -r requirements.txt -c constraints.txt -t .
	rm -f $@
	cd pkg && zip -q -9r ../$@ *
	md5sum $@ > $@.md5sum

upload: lambda.zip
	MD5=`md5sum $< | cut -c1-16`; aws s3 cp $(S3FLAGS) $^ s3://$(LAMBDA_BUCKET)/$(PROJECT)/$${MD5}.zip \
        && sed -i 's@S3Key:.*$$@S3Key: $(PROJECT)/'$${MD5}'.zip@' stepfun.cf.yaml
	dc2 upload --debug --keep --project $(PROJECT) --env test --manifest $(XLRINFRADIR)/output/packer-manifest.json `img2json.sh --format=cli $(AMI_ID)` --url-file $(URL)

STACK_CHANGE = --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET)
create: check upload
	aws cloudformation create-stack --stack-name $(STACK_NAME) --template-url `cat $(URL)` --parameters file://./ref/abakshi.params.json --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND

deploy:
	aws cloudformation create-change-set $(STACK_CHANGE) --template-url `cat $(URL)` --parameters file://./ref/xdp-standard.params --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND
	aws cloudformation wait change-set-create-complete $(STACK_CHANGE)
	aws cloudformation describe-change-set $(STACK_CHANGE) | tee ref/$(STACK_NAME)-$(CHANGE_SET).change
	aws cloudformation execute-change-set $(STACK_CHANGE)
	aws cloudformation wait stack-update-complete --stack-name $(STACK_NAME)

update:
	$(MAKE) CHANGE_SET=change-`uuidgen` check upload deploy
