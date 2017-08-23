.PHONY: all clean deploy group deploy

SHELL = /bin/bash
GROUP = $(shell id -un)-rg
LOCATION  = westus2
BOOTSTRAP = ../bootstrap/ampBootstrap.sh
S3_INSTALLER_URL = s3://xcrepo/builds/bc8beef7-0649eba1/prod/xcalar-1.2.1-1088-installer
S3_BOOTSTRAP_URL = s3://xcrepo/bysha1/$(shell sha1sum $(BOOTSTRAP) | awk '{print $$1}')/$(shell basename $(BOOTSTRAP))

SCRIPTS_URI=$(shell jq -r .variables.scriptsUri applianceMainTemplate.json | sed -e 's@^http://@@g')
SCRIPTS_NAME=$(shell jq -r .variables.customScriptName applianceMainTemplate.json)
SCRIPTS_PATH=$(SCRIPTS_URI)/$(SCRIPTS_NAME)
SCRIPTS_SHA1=$(shell sha1sum $(BOOTSTRAP) | cut -d' ' -f1)

all: xdp-standard-package.zip

xdp-standard-package.zip: createUiDefinition.json applianceMainTemplate.json mainTemplate.json
	cp createUiDefinition.json applianceCreateUiDefinition.json
	zip xdp-standard-package.zip applianceCreateUiDefinition.json createUiDefinition.json applianceMainTemplate.json mainTemplate.json

clean:
	rm -f xdp-standard-package.zip applianceCreateUiDefinition.json
	rm -rf .tmp/

group:
	@if ! test "`az group exists --name $(GROUP) --output tsv`" = true; then \
        az group create --name $(GROUP) --location $(LOCATION); \
    fi

delete:
	az group delete --name $(GROUP) --no-wait

check_bootstrap:
	@http_proxy=; \
     if ! test "`curl -sSL http://$(SCRIPTS_PATH) | sha1sum | cut -d' ' -f1`" = "$(SCRIPTS_SHA1)"; then \
        echo >&2 "ERROR: Checksum of $(BOOTSTRAP) doesn't match with what's referenced in your applianceMainTemplate (http://$(SCRIPTS_PATH))"; \
        exit 1; \
     fi

update_bootstrap:
	@http_proxy=; \
    if test "`curl -o /dev/null -w '%{http_code}' -sSL http://$(SCRIPTS_PATH) 2>/dev/null`" != 200; then \
        gsutil cp $(BOOTSTRAP) gs://$(SCRIPTS_PATH); \
    elif test "`curl -sSL http://$(SCRIPTS_PATH) 2>/dev/null | sha1sum | cut -d' ' -f1`" = "$(SCRIPTS_SHA1)"; then \
        echo >&2 "http://$(SCRIPTS_PATH) already up-to-date"; \
    else \
        echo >&2 "http://$(SCRIPTS_PATH) already exists with a different checksum! Not overwriting! Bump the version in applianceMainTemplate.json."; \
        exit 1; \
    fi

%.json: %.json.example
	@test -e $@ || { cp -v $< $@; @echo "Please modify the password in parameters.json before!"; exit 1; }
	@touch $@

deploy: group parameters.json
	INSTALLER_URL=`aws s3 presign --expires-in 3600 $(S3_INSTALLER_URL)` && \
    aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP_URL) && \
    BOOTSTRAP_URL=`aws s3 presign --expires-in 3600 $(S3_BOOTSTRAP_URL)` && \
    echo $${INSTALLER_URL} && \
    echo $${BOOTSTRAP_URL} && \
    time az group deployment create --resource-group $(GROUP) --name $(GROUP)-deploy \
     --template-file azuredeploy.json \
     --parameters @parameters.json \
     --parameters "{\"installerUrl\": { \"value\": \"$${INSTALLER_URL}\"}}" \
     --parameters "{\"bootstrapUrl\": { \"value\": \"$${BOOTSTRAP_URL}\"}}"

deployMain: check_bootstrap group parameters.json
	time az group deployment create --resource-group $(GROUP) --name $(GROUP)-deploy \
     --template-file applianceMainTemplate.json \
     --parameters @parameters.json

getips:
	@az vm list-ip-addresses --resource-group $(GROUP) --output json --query '[].virtualMachine.network.publicIpAddresses[].[name,ipAddress]' --output tsv

ssh: ssh/0
ssh/%:
	@sshpass -p "`jq -r .parameters.adminPassword.value parameters.json`" \
       ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR \
       -l "`jq -r .parameters.adminUsername.value parameters.json`" \
       `az vm list-ip-addresses --resource-group $(GROUP) --output json --query '[].virtualMachine.network.publicIpAddresses[].[name,ipAddress]' --output tsv | awk '/IP$(@F)/{print $$2}' $<`
