.PHONY: all clean deploy group deploy

SHELL = /bin/bash
GROUP = $(shell id -un)-rg
LOCATION  = westus2
BOOTSTRAP = ../bootstrap/ampBootstrap.sh
S3_INSTALLER_URL = s3://xcrepo/builds/bc8beef7-0649eba1/prod/xcalar-1.2.1-1088-installer
S3_BOOTSTRAP_URL = s3://xcrepo/bysha1/$(shell sha1sum $(BOOTSTRAP) | awk '{print $$1}')/$(shell basename $(BOOTSTRAP))

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

%.json: %.json.example
	@test -e $@ || { cp -v $< $@; @echo "Please modify the password in parameters.json before!"; exit 1; }
	@touch $@

deploy: group parameters.json
	INSTALLER_URL=`aws s3 presign --expires-in 3600 $(S3_INSTALLER_URL)` && \
    aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP_URL) && \
    BOOTSTRAP_URL=`aws s3 presign --expires-in 3600 $(S3_BOOTSTRAP_URL)` && \
    echo $${INSTALLER_URL} && \
    echo $${BOOTSTRAP_URL} && \
    time az group deployment create --resource-group $(GROUP) --name mydeploy \
     --template-file azuredeploy.json \
     --parameters @parameters.json \
     --parameters "{\"installerUrl\": { \"value\": \"$${INSTALLER_URL}\"}}" \
     --parameters "{\"bootstrapUrl\": { \"value\": \"$${BOOTSTRAP_URL}\"}}" \
     --parameters "{\"licenseKey\": { \"value\": \"`cat /etc/xcalar/XcalarLic.key`\"}}"

getips:
	@az vm list-ip-addresses --resource-group $(GROUP) --output json --query '[].virtualMachine.network.publicIpAddresses[].[name,ipAddress]' --output tsv

ssh: ssh/0
ssh/%:
	@sshpass -p "`jq -r .parameters.adminPassword.value parameters.json`" \
       ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR \
       -l "`jq -r .parameters.adminUsername.value parameters.json`" \
       `az vm list-ip-addresses --resource-group $(GROUP) --output json --query '[].virtualMachine.network.publicIpAddresses[].[name,ipAddress]' --output tsv | awk '/IP$(@F)/{print $$2}' $<`
