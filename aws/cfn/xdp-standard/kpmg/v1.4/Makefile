SHELL = /bin/bash

## deploy
TARGET = s3://xcrepoe1/cfn/prod/v1.4/

FILES= xdp-template.template scripts/user-data.sh

VARS = $(wildcard vars/*.yaml)
TEMPLATES = $(wildcard *.template)
J2VARS = $(patsubst %.template, %.template.vars.j2, $(TEMPLATES))
VARSTEMPLATE = $(patsubst %.template, %.template.vars, $(TEMPLATES))
YAML = $(patsubst %.template, %.yaml, $(TEMPLATES))
DIR = $(shell dirname $(PWD))
PARENTDIR = $(dir $(realpath $(firstword $(MAKEFILE_LIST))))

param_License='H4sIAJJDLVsAA22OvZKCMACE%2BzyFvacCgkKRQvmJMIp6oDI0NzEERCBoABGf%2FtQ5uyt399vZXaaEsopGfgkDgnPMv3o2I8CuKcd1WjIoDQWwyXEdl7yAS9vdBT%2FBRAZ7yqtXLA7lJ7DCd5u9KqROb9TANfbSB4WiPwdOdCQmw8ecRjDGeUXBhpdRQ%2Bq%2Fvd6L7n0WwJqZ90vKO3jAnH1QCxdp3v1feOPvq0%2BfQkkQtYHTsIEkAbeMqF42rIaiIClgV1H%2BkYIKqjRhuG44hbNFcUWqRv2cYMFjhZtkM6lKHH296Puuzs%2BtKAd%2BN5GjsrtmnZRok7zJRGSNV0JXaP7psg8kpCGHBspVTYpQUKzxASGmTs9tcXKaUBFMfTF3jqHXbov%2BfNEuOywr29u3TqbMiLUjOjOFhiWyyMiIRe%2By927rLHwsjS3es0sQuQkanVtTBr%2F3AXhNsAEAAA%3D%3D'

S3BUCKET = $(shell yq r vars.yaml s3bucket)
S3PREFIX = $(shell yq r vars.yaml s3prefix)


all: $(YAML)

%.json: %
	cfn-flip $^ > $@

%.yaml: %.json
	cfn-flip $^ > $@

%: %.j2 vars.yaml
	jinja2 $^ > $@

%.json: %.template.json %.template.vars.json
	jq -r -s '.[0] * .[1]' $^ > $@

vars.yaml: $(VARS)
	yq m $^ > $@

%.json: %.j2 vars.yaml
	jinja2 $^ > $@.tmp
	cfn-flip $@.tmp > $@
	@rm -f $@.tmp

clean:
	rm -vf $(VARSTEMPLATE) $(YAML) vars.yaml $(wildcard *.json) $(wildcard *.yaml)

quickcreate.url: quickcreate.url.j2 vars.yaml
	jinja2 $^ > $@

publish:
	aws s3 cp --acl public-read \
	    --metadata-directive REPLACE \
	    --content-disposition inline \
	    --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' \
	    xdp-standard.yaml  s3://xcrepoe1/cfn/prod/v1.4/xdp-standard.template
	aws s3 cp --acl public-read \
	    --metadata-directive REPLACE \
	    --content-disposition inline \
	    --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' \
	    scripts/user-data.sh  s3://xcrepoe1/cfn/prod/v1.4/scripts/user-data.sh

build: $(YAML)

deploy: publish quickcreate.url
	cat quickcreate.url

