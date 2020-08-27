SHELL = /bin/bash

ACLPUB = --acl public-read --metadata-directive 'REPLACE' --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform'
COPY = --content-disposition 'inline' $(ACLPUB)
BUCKET = xcrepo
BASE = cfn
LAMBDABASE = s3://$(BUCKET)/cfn/sharedinf/
STACK = sharedinf
SHAREDINF_TEMPLATE = sharedinfrastructure.yaml
SHAREDINF_TEMPLATE_JSON = sharedinfrastructure.json
FTMPDIR := $(shell mktemp -u -t -d pip.XXXXXX)
PKGDIR := $(FTMPDIR)-pkg

# 559166403383
AWS_XCALAR_PROFILE ?= default
AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text)
AWS_REGION ?= $(AWS_DEFAULT_REGION)
LAMBDABUCKET := sharedinf-lambdabucket-$(AWS_ACCOUNT_ID)-$(AWS_REGION)
SHARED_TEMPLATE_MD5SUM := $(shell md5sum $(SHAREDINF_TEMPLATE) | cut -d' ' -f 1)
SHARED_TEMAPLTE_PATH = $(BASE)/$(STACK)/$(SHARED_TEMPLATE_MD5SUM)
NAME = sharedinf
CHANGE_NAME := $(NAME)-change-$(shell uuidgen)
SHARED_TEMPLATE_URL = https://$(BUCKET).s3-us-west-2.amazonaws.com/$(SHARED_TEMAPLTE_PATH)/$(SHAREDINF_TEMPLATE_JSON)
.PHONY: sharedinf

sharedinf:
	cfn-flip < $(SHAREDINF_TEMPLATE) | AWS_PROFILE=$(AWS_XCALAR_PROFILE) aws s3 cp $(COPY) - s3://$(BUCKET)/$(SHARED_TEMAPLTE_PATH)/$(SHAREDINF_TEMPLATE_JSON)
	@echo "URL: $(SHARED_TEMPLATE_URL)"

layer.zip: #requirements.txt constraints.txt
	mkdir -p $(FTMPDIR) $(PKGDIR) && python3.6 -m venv $(FTMPDIR) && source $(FTMPDIR)/bin/activate \
	    && python3 -m pip install -U pip setuptools wheel \
	    && python3 -m pip install -t $(PKGDIR) -r requirements.txt -c constraints.txt \
	    && pwd=`pwd` \
	    && cd $(PKGDIR) \
	    && zip -9r $${pwd}/$@.tmp . \
	    && cd - >/dev/null \
	    && rm -rf $(FTMPDIR) $(PKGDIR) \
	    && md5sum $@.tmp | cut -d' ' -f1 > $(@F).md5sum \
	    && MD5=`cat $(@F).md5sum` \
	    && sed -i 's@S3Key: .*$$@S3Key: sharedlibs/'$${MD5}'.zip@'  $(SHAREDINF_TEMPLATE) \
        && aws s3 cp $(ACLPUB) $@.tmp s3://$(LAMBDABUCKET)/sharedlibs/$${MD5}.zip \
        && mv $@.tmp $@

uploadzip: layer.zip
	md5sum $< | cut -d' ' -f1 > $(@F).md5sum \
	    && MD5=`cat $(@F).md5sum` \
	    && sed -i 's@S3Key: .*$$@S3Key: sharedlibs/'$${MD5}'.zip@'  $(SHAREDINF_TEMPLATE) \
        && aws s3 cp $(ACLPUB) $< s3://$(LAMBDABUCKET)/sharedlibs/$${MD5}.zip

update: sharedinf
	subnet=$$(aws cloudformation describe-stacks --stack-name sharedinf --query 'Stacks[0].Parameters[0].ParameterValue' --output text | cut -d. -f2); \
		   jinja2 -Dsubnet=$$(( $${subnet} + 1 ))  ref/$@.parameters.json.j2 > ref/$@.parameters.json
	aws cloudformation update-stack --stack-name sharedinf --template-url $(SHARED_TEMPLATE_URL) --capabilities CAPABILITY_IAM --parameters "`cat ref/$@.parameters.json`"

noupdate: sharedinf
	subnet=$$(aws cloudformation describe-stacks --stack-name sharedinf --query 'Stacks[0].Parameters[0].ParameterValue' --output text | cut -d. -f2); \
		   jinja2 -Dsubnet=$$(( $${subnet} + 1 ))  ref/$@.parameters.json.j2 > ref/$@.parameters.json
	aws cloudformation update-stack --stack-name sharedinf --template-url $(SHARED_TEMPLATE_URL) --capabilities CAPABILITY_IAM --parameters "`cat ref/$@.parameters.json`"
	#aws cloudformation create-change-set --change-set-name $(CHANGE_NAME) --stack-name sharedinf --template-url https://$(BUCKET).s3-us-west-2.amazonaws.com/$(SHARED_TEMAPLTE_PATH)/$(SHAREDINF_TEMPLATE_JSON) --capabilities CAPABILITY_IAM --parameters "`cat ref/$@.parameters.json`"

deploy: sharedinf layer.zip
	aws cloudformation create-stack --stack-name sharedinf --template-url https://$(BUCKET).s3-us-west-2.amazonaws.com/$(SHARED_TEMAPLTE_PATH)/$(SHAREDINF_TEMPLATE) --parameters "`cat ref/sharedinf.params.json`"
