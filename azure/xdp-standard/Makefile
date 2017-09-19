.PHONY: all clean deploy group deploy

SHELL = /bin/bash
GROUP = $(shell id -un)-rg
LOCATION  = westus2
BOOTSTRAP = ../bootstrap/ampBootstrap.sh
NOW = $(shell date +'%Y%m%d%H%M')

BUCKET = xcrepo
S3_INSTALLER = s3://$(BUCKET)/builds/e5c22263-01d66bb7/prod/xcalar-1.2.2-1191-installer
S3_BOOTSTRAP_KEY = bysha1/$(shell sha1sum $(BOOTSTRAP) | awk '{print $$1}')/$(shell basename $(BOOTSTRAP))
S3_BOOTSTRAP = s3://$(BUCKET)/$(S3_BOOTSTRAP_KEY)
ZONE = azure.xcalar.io
PARAMETERS = parameters.json

COUNT=$(shell jq -r '.parameters.scaleNumber.value' $(PARAMETERS))
EMAIL=$(shell jq -r '.parameters.adminEmail.value' $(PARAMETERS))
PASSWORD=$(shell jq -r '.parameters.adminPassword.value' $(PARAMETERS))
USERNAME=$(shell jq -r '.parameters.adminUsername.value' $(PARAMETERS))
LICENSE=$(shell jq -r '.parameters.licenseKey.value' $(PARAMETERS))

SCRIPTS_PATH=$(shell jq -r '[.variables.scriptsUri,.variables.customScriptName]|join("/")' applianceMainTemplate.json | sed -e 's@^http://@@g')
SCRIPTS_SHA1=$(shell sha1sum $(BOOTSTRAP) | cut -d' ' -f1)

export GNUPGHOME=$(CURDIR)/.gnupg
TEMPLATE=azuredeploy.json

s3url = $(shell aws s3 presign --expires-in 3600 $(1))

-include local.mk

all: xdp-standard-package.zip

/usr/bin/sshpass:
	@echo "You need sshpass installed. Please use 'sudo apt-get install -y sshpass' on Ubuntu and 'sudo yum install -y sshpass' on EL"
	exit 1

xdp-standard-package.zip: createUiDefinition.json applianceMainTemplate.json mainTemplate.json
	aws s3 cp $(BOOTSTRAP) - >/dev/null 2>&1 || { aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP) && aws s3api put-object-acl --acl public-read --bucket $(BUCKET) --key $(S3_BOOTSTRAP_KEY); }
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
	-az group delete --no-wait --name $(GROUP)
	@tail -1 local.mk | grep -q 'GROUP=$(GROUP)' && uniq local.mk | head -n-1 > local.mk.tmp && mv local.mk.tmp local.mk || true

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
	@test -e $@ || { cp -v $< $@; @echo "Please modify the password in $(PARAMETERS) before!"; exit 1; }
	@touch $@

validate_params: $(PARAMETERS)
	@echo "$(EMAIL)" | grep -q '@xcalar.com' || { echo "Need to specify email!"; exit 1; }
	@test "$(COUNT)" -ge 1 || { echo "Need to specify valid scaleNumber!"; exit 1; }
	@test "$$(echo $(LICENSE) | wc -c)" -ge 40 || { echo "Need to specify valid scaleNumber!"; exit 1; }


deploy: validate_params group
	@bash -n $(BOOTSTRAP)
	@aws s3 cp $(BOOTSTRAP) - >/dev/null 2>&1 || aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP)
	@(touch local.mk; cat local.mk; echo GROUP=$(GROUP)) | uniq | tee local.mk.tmp >/dev/null && mv local.mk.tmp local.mk
	time az group deployment create --resource-group $(GROUP) --name $(GROUP)-deploy-$(NOW) \
     --template-file "$(TEMPLATE)" \
     --parameters "$$(jq -r '.parameters | {\
                                           adminEmail, adminUsername, adminPassword, licenseKey, scaleNumber,\
                                           dnsLabelPrefix: {value:"$(GROUP)"},\
                                           installerUrl: {value:"$(call s3url,$(S3_INSTALLER))"},\
                                           bootstrapUrl: {value:"$(call s3url,$(S3_BOOTSTRAP))"}\
                                           }|tojson' $(PARAMETERS))"

deployDev: validate_params group
	bash -n $(BOOTSTRAP)
	aws s3 cp $(BOOTSTRAP) - >/dev/null 2>&1 || { aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP) && aws s3api put-object-acl --acl public-read --bucket $(BUCKET) --key $(S3_BOOTSTRAP_KEY); }
	sed -i -e 's|"scriptsUri":.*$$|"scriptsUri": "https://'$(BUCKET)'.s3.amazonaws.com/'`dirname $(S3_BOOTSTRAP_KEY)`'",|g' applianceDevTemplate.json
	@(touch local.mk; cat local.mk; echo GROUP=$(GROUP)) | uniq | tee local.mk.tmp >/dev/null && mv local.mk.tmp local.mk
	time az group deployment create --resource-group $(GROUP) --name $(GROUP)-deploy-$(NOW) \
     --template-file applianceDevTemplate.json \
     --parameters "$$(jq -r '.parameters | {\
                                           adminEmail, adminUsername, adminPassword, licenseKey, scaleNumber,\
                                           dnsLabelPrefix: {value:"$(GROUP)"},\
                                           installerUrl: {value:"$(call s3url,$(S3_INSTALLER))"},\
                                           bootstrapUrl: {value:"$(call s3url,$(S3_BOOTSTRAP))"}\
                                           }|tojson' $(PARAMETERS))"

deployMain: validate_params group
	bash -n $(BOOTSTRAP)
	aws s3 cp $(BOOTSTRAP) - >/dev/null 2>&1 || { aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP) && aws s3api put-object-acl --acl public-read --bucket $(BUCKET) --key $(S3_BOOTSTRAP_KEY); }
	sed -i -e 's|"scriptsUri":.*$$|"scriptsUri": "https://'$(BUCKET)'.s3.amazonaws.com/'`dirname $(S3_BOOTSTRAP_KEY)`'",|g' applianceMainTemplate.json
	@(touch local.mk; cat local.mk; echo GROUP=$(GROUP)) | uniq | tee local.mk.tmp >/dev/null && mv local.mk.tmp local.mk
	time az group deployment create --resource-group $(GROUP) --name $(GROUP)-deploy-$(NOW) \
     --template-file applianceMainTemplate.json \
     --parameters "$$(jq -r '.parameters | {adminEmail, adminUsername, adminPassword, licenseKey, scaleNumber}|tojson' $(PARAMETERS))"

getips:
	@az vm list-ip-addresses --resource-group $(GROUP) --output json --query '[].virtualMachine.network.publicIpAddresses[].[name,ipAddress]' --output tsv

ssh: ssh/0 /usr/bin/sshpass
ssh/%:
	@sshpass -p "$(PASSWORD)" \
       ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR \
       -l "$(USERNAME)" \
       `az vm list-ip-addresses --resource-group $(GROUP) --output json --query '[].virtualMachine.network.publicIpAddresses[].[name,ipAddress]' --output tsv | awk '/IP$(@F)/{print $$2}' $<`

# make certs/xdp-standard-001-099.tar.gz.gpg
.PRECIOUS: %.gpg
%.gpg: %
	cat $(GNUPGHOME)/password | gpg --no-use-agent --homedir=$(GNUPGHOME) --passphrase-fd=0 --armor --output=$@ --cipher-algo=AES256 --symmetric $<

.PRECIOUS: %.tar.gz
%.tar.gz: %.pem %.key
	fakeroot tar czvf $@ --transform='s,^$*,cert,' $^

%.gpg.upload: %.gpg
	aws s3 cp $< s3://xccerts/certs/$(ZONE)/bysha1/`sha1sum $< | cut -d' ' -f1`/$(<F)
