SHELL = /bin/bash

COPY = aws s3 cp --acl public-read --content-disposition 'inline' --metadata-directive 'REPLACE' --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform'
BUCKET = xcrepo
BASE = s3://$(BUCKET)/cfn/
STACK = sharedinf
SHAREDINF_TEMPLATE = sharedinfrastructure.yaml

.PHONY: sharedinf
sharedinf:
	$(COPY) $(SHAREDINF_TEMPLATE) $(BASE)$(STACK)/

update: sharedinf
	aws cloudformation update-stack --stack-name sharedinf --template-url https://xcrepo.s3.amazonaws.com/cfn/$(STACK)/$(SHAREDINF_TEMPLATE)
deploy: sharedinf
	aws cloudformation create-stack --stack-name sharedinf --template-url https://xcrepo.s3.amazonaws.com/cfn/$(STACK)/$(SHAREDINF_TEMPLATE)
