.PHONY: default docker-base docker-xcalar

SHELL = /bin/bash

INSTALLER ?= /netstore/builds/byJob/BuildTrunk/xcalar-latest-2.3.0-installer-prod
INSTALLER_VARS = installer_vars.json
INSTALLER_VERSION = $(shell jq -r .installer_version $(INSTALLER_VARS))
PROJECT ?= xdp-instamart
PACKER_LOG := 1
PACKER_LOG_PATH := packer.log
PACKER_BIN = packer.io
ARGS = -var-file=vars/ssh.json -var installer="$(INSTALLER)" -var-file=$(INSTALLER_VARS)

ifneq ($(JENKINS_URL),)
	COLOR = -color=false
endif

export PROJECT PACKER_LOG PACKER_LOG_PATH

default: docker-xcalar-el7

%.json: %.yaml
	cfn-flip < $< > $@

.PHONY: $(INSTALLER_VARS)
$(INSTALLER_VARS):
	installer-version.sh --format=json "$(INSTALLER)" > $@

docker-xcalar-el7: docker.json $(INSTALLER_VARS)
	packer.io validate $(ARGS) -only=$@ $<
	packer.io build $(ARGS) -var repository='xcalar/xcalar' $(COLOR) -only=$@ $<

docker-base-el7: docker.json $(INSTALLER_VARS)
	jq -r '.installer_tag="$(INSTALLER_VERSION)"' < $(INSTALLER_VARS) > tmp.json && mv tmp.json $(INSTALLER_VARS)
	packer.io validate $(ARGS) -only=$@ $<
	packer.io build $(ARGS) -var repository='xcalar/base' -var "installer_tag=`jq -r .installer_version $(INSTALLER_VARS)`" $(COLOR) -only=$@ $<

%.yaml: %.yaml.j2
	e2j2 --block_start '[%%' --block_end '%%]' --variable_start '[[' --variable_end ']]' -f $<
