SHELL = /bin/bash

ACLPUB = --acl public-read --metadata-directive 'REPLACE' --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform'
COPY = --content-disposition 'inline' $(ACLPUB)
BUCKET = xcrepo
BASE = s3://$(BUCKET)/cfn/
LAMBDABASE = s3://$(BUCKET)/cfn/sharedinf/
STACK = sharedinf
SHAREDINF_TEMPLATE = sharedinfrastructure.yaml
FTMPDIR := $(shell mktemp -u -t -d pip.XXXXXX)
PKGDIR := $(FTMPDIR)-pkg
LAMBDABUCKET = sharedinf-lambdabucket-559166403383-us-west-2
NAME = sharedinf
.PHONY: sharedinf

sharedinf:
	aws s3 cp $(COPY) $(SHAREDINF_TEMPLATE) $(BASE)$(STACK)/

layer.zip: requirements.txt constraints.txt
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

update: sharedinf layer.zip
	aws cloudformation update-stack --stack-name sharedinf --template-url https://xcrepo.s3.amazonaws.com/cfn/$(STACK)/$(SHAREDINF_TEMPLATE) --parameters "`cat ref/sharedinf.params.json`"

deploy: sharedinf layer.zip
	aws cloudformation create-stack --stack-name sharedinf --template-url https://xcrepo.s3.amazonaws.com/cfn/$(STACK)/$(SHAREDINF_TEMPLATE) --parameters "`cat ref/sharedinf.params.json`"

