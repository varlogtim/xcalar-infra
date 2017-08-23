.PHONY: all clean deploy group deploy

SHELL = /bin/bash
GROUP = $(shell id -un)-rg
LOCATION  = westus2
BOOTSTRAP = ../bootstrap/ampBootstrap.sh
BUCKET = xcrepo
S3_INSTALLER = s3://$(BUCKET)/builds/ce1c3bbd-254932a4/prod/xcalar-1.2.2-1179-installer
S3_BOOTSTRAP_KEY = bysha1/$(shell sha1sum $(BOOTSTRAP) | awk '{print $$1}')/$(shell basename $(BOOTSTRAP))
S3_BOOTSTRAP = s3://$(BUCKET)/$(S3_BOOTSTRAP_KEY)

SCRIPTS_PATH=$(shell jq -r '[.variables.scriptsUri,.variables.customScriptName]|join("/")' applianceMainTemplate.json | sed -e 's@^http://@@g')
SCRIPTS_SHA1=$(shell sha1sum $(BOOTSTRAP) | cut -d' ' -f1)

-include local.mk

all: xdp-standard-package.zip

xdp-standard-package.zip: createUiDefinition.json applianceMainTemplate.json mainTemplate.json
	aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP)
	aws s3api put-object-acl --acl public-read --bucket $(BUCKET) --key $(S3_BOOTSTRAP_KEY)
	sed -i -e 's|"scriptsUri":.*$$|"scriptsUri": "https://'$(BUCKET)'.s3.amazonaws.com/'`dirname $(S3_BOOTSTRAP_KEY)`'",|g' applianceMainTemplate.json
	cp createUiDefinition.json applianceCreateUiDefinition.json
	zip xdp-standard-package.zip applianceCreateUiDefinition.json createUiDefinition.json applianceMainTemplate.json mainTemplate.json

clean:
	rm -f xdp-standard-package.zip applianceCreateUiDefinition.json
	rm -rf .tmp/

group:
	@if ! test "`az group exists --name $(GROUP) --output tsv`" = true; then \
        az group create --name $(GROUP) --location $(LOCATION); \
    fi

destroy:
	az group delete --name $(GROUP) --no-wait
	-rm -f local.mk

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
	aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP)
	INSTALLER_URL=`aws s3 presign --expires-in 3600 $(S3_INSTALLER)` && \
	BOOTSTRAP_URL=`aws s3 presign --expires-in 3600 $(S3_BOOTSTRAP)` && \
    echo $${INSTALLER_URL} && \
    echo $${BOOTSTRAP_URL} && \
    echo GROUP=$(GROUP) | tee local.mk && \
    time az group deployment create --resource-group $(GROUP) --name $(GROUP)-deploy \
     --template-file azuredeploy.json \
     --parameters @parameters.json \
     --parameters "{\"dnsLabelPrefix\": { \"value\": \"$(GROUP)\"}}" \
     --parameters "{\"installerUrl\": { \"value\": \"$${INSTALLER_URL}\"}}" \
     --parameters "{\"bootstrapUrl\": { \"value\": \"$${BOOTSTRAP_URL}\"}}"

deployMain: group parameters.json
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
