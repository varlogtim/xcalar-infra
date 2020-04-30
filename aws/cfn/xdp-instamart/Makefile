.PHONY: all check clean upload create deploy update

TOP  := $(patsubst %/,%,$(dir $(realpath $(firstword $(MAKEFILE_LIST)))))
SHELL:= /bin/bash

PACKER_JSON ?= $(XLRINFRADIR)/output/packer-manifest.json
LAST_UUID   := $(shell jq -r ".last_run_uuid" $(PACKER_JSON))
AMI_ID      := $(shell jq -r '.builds[]|select(.name == "amazon-ebs-amzn2")|select(.packer_run_uuid == "$(LAST_UUID)") .artifact_id' $(PACKER_JSON) | cut -d':' -f 2)

PROJECT = xdp-instamart
#GEN = ref/xdp-standard-byovpc.template ref/xdp-standard.template ref/stepfun.template
GEN = .shadow/xdp-standard.cf.yaml .shadow/stepfun.cf.yaml
VARS := $(wildcard vars/*.yaml) ../vars/sharedinf.yaml
TEMPLATES = $(patsubst %.cf.yaml, %.template, $(GEN))
JSONS = $(patsubst %.template, %.json, $(TEMPLATES))
VALIDATION = $(patsubst %.template, %.valid, $(TEMPLATES))
PARAMS = $(patsubst %.valid, %.params, $(VALIDATION))
DEBUG ?= 0
ENVIRONMENT ?= test
AWS_DEFAULT_REGION = us-west-2
ALL_REGIONS   = us-west-2 us-east-1 us-east-2 us-west-1
REGIONS      ?= $(AWS_DEFAULT_REGION)
AWS_ACCOUNT   = 559166403383
S3FLAGS = --cache-control 'private, no-cache, no-store, must-revalidate, max-age=0, no-transform' --acl public-read --metadata-directive REPLACE
SOURCES = .shadow/xdp-standard.template .shadow/stepfun.template scripts/user-data.sh scripts/batch.sh
LAMBDA_BUCKET_PREFIX = sharedinf-lambdabucket-$(AWS_ACCOUNT)
LAMBDA_BUCKET = $(LAMBDA_BUCKET_PREFIX)-$(AWS_DEFAULT_REGION)
URL = ref/output.url
UUID := $(shell uuidgen)
CHANGE_SET = mychange-$(UUID)
NAME := $(shell id -un)
STACK_NAME = $(NAME)-instamart
BASEURL := $(shell baseurl.sh `installer-version.sh --format=cli $(AMI_ID)` --env $(ENVIRONMENT) --project $(PROJECT))

all: check

check: $(GEN) $(VALIDATION) $(PARAMS)
	yamllint -c $(XLRINFRADIR)/.yamllint .shadow/*.cf.yaml
	cfn-lint .shadow/*.cf.yaml

%.valid: %.template
	cfn-lint $<
	aws cloudformation validate-template --template-body file://./$< > $@.tmp
	@mv $@.tmp $@

%.params: %.valid
	jq -r '[.Parameters[]|{ParameterKey:.ParameterKey, UsePreviousValue: true}]' $< > $@.tmp
	@mv $@.tmp $@

ref/$(AMI_ID).json:
	set -o pipefail; aws ec2 describe-images --image-ids $(AMI_ID) --query 'Images[].Tags[]' | jq '{ami: map_values({(.Key): .Value})|add}' > $@.tmp
	@mv $@.tmp $@

clean:
	rm -fv $(TEMPLATES) $(GEN) $(VALIDATION) $(PARAMS) $(JSONS)

.shadow/xdp-standard.cf.yaml: .shadow/stepfun.json

constraints.txt: requirements.txt
	pip-compile -v -o $@ $<

#%.json: %.template
#	cfn-flip -c < $^ > $@.tmp
#	@mv $@.tmp $@
# +
# |
#
# foo.template.j2 -> .shadow/foo.template -> .shadow/foo.template.cf.yaml -> .shadow/foo.json

%.json: %.cf.yaml
	cfn-flip -c < $^ > $@.tmp
	@mv $@.tmp $@

#.shadow/lambda.zip: lambda/add_notification.py lambda/schedule.py
#	rm -rf .shadow/lambda
#	rm -f $@
#	cp -a lambda .shadow/
#	pip install -t .shadow/lambda -r requirements.txt
#	cd .shadow/lambda && zip -9r -q ../lambda.zip .
#
#lambda.zip: .shadow/lambda.zip
#	cp $< $@

%.cf.yaml: %.template .shadow/lambda.zip
	aws cloudformation package --s3-bucket $(LAMBDA_BUCKET) --s3-prefix $(PROJECT) --template-file $< --output-template-file $@

.shadow/%.template: %.template.j2
	mkdir -p $(@D)
	set -o pipefail; cat $(VARS) ../flavor/default.yaml | jinja2 -DforSam=True -Dlambdabucket=$(LAMBDA_BUCKET) -DbaseUrl=$(BASEURL) -DbootstrapUrl=$(BASEURL)/scripts/user-data.sh -DDEBUG=$(DEBUG) -Dami_id=$(AMI_ID) $^ > $@.tmp
	@mv $@.tmp $@

pkg.zip: lambda/requirements.txt lambda/constraints.txt
	rm -rf pkg/
	mkdir -p pkg
	cp $^ pkg/
	#docker run -it -e HOME=/var/tmp/ --rm -v `pwd`/pkg:`pwd`/pkg -w `pwd`/pkg -u `id -u`:`id -g`  lambci/lambda:build-python3.6 pip install -r requirements.txt -c constraints.txt -t ./
	cd pkg && pip install -r requirements.txt -c constraints.txt -t .
	cd pkg && zip -q -9r ../$@ .
	rm -rf pkg

lambda.zip: lambda/schedule.py lambda/add_notification.py
	rm -f $@
	cd lambda && zip -9r ../$@ $(notdir $^)

.shadow/lambda.zip:
	T=$$(dirname $@)/$$(basename $@ .zip); \
	  rm -rf $${T} && \
	  mkdir $${T} && \
	  cp -a $(filter %.py,$^) $${T} && \
	  unzip -q -d $${T} $(filter %.zip,$^) && \
	  cd $${T} && zip -q -9r $(TOP)/$@ .
	md5sum $@ > $@.md5sum

update: $(TEMPLATES)

upload: lambda.zip
	KEY=`publish-lambda.sh --bucket $(LAMBDA_BUCKET) --prefix $(PROJECT) --suffix .zip --file $<` \
        && echo "lambdakey: $${KEY}" > vars/lambdakey.yaml && \
	dc2 upload --debug --keep --project $(PROJECT) --env $(ENVIRONMENT) --manifest $(XLRINFRADIR)/output/packer-manifest.json `installer-version.sh --format=cli $(AMI_ID)` --url-file $(URL)

STACK_CHANGE = --stack-name $(STACK_NAME) --change-set-name $(CHANGE_SET)
create: check upload
	aws cloudformation create-stack --stack-name $(STACK_NAME) --template-url `grep xdp-standard $(URL)` --parameters file://./ref/$(NAME).params.json --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND

deploy: .shadow/xdp-standard.cf.yaml
	aws cloudformation create-change-set $(STACK_CHANGE) --template-body file://`pwd`/.shadow/xdp-standard.cf.yaml --parameters file://./ref/$(NAME).params.json --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND
	#aws cloudformation create-change-set $(STACK_CHANGE) --template-url `grep xdp-standard $(URL)` --parameters file://./ref/$(NAME).params.json --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND
	aws cloudformation wait change-set-create-complete $(STACK_CHANGE)
	aws cloudformation describe-change-set $(STACK_CHANGE) | tee ref/$(STACK_NAME)-$(CHANGE_SET).change
	aws cloudformation execute-change-set $(STACK_CHANGE)
	aws cloudformation wait stack-update-complete --stack-name $(STACK_NAME)

update:
	$(MAKE) CHANGE_SET=change-`uuidgen` check upload deploy
