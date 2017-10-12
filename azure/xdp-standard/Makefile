.PHONY: all clean deploy group deploy

SHELL = /bin/bash
NOW = $(shell date +'%Y%m%d%H%M')

GROUP ?= $(shell id -un)-rg
LOCATION  ?= westus2
DEPLOY = $(GROUP)-deploy
VALIDATE_RG = validate-$(LOCATION)-rg


BOOTSTRAP ?= ../bootstrap/ampBootstrap.sh
BUCKET ?= xcrepo
S3_INSTALLER ?= s3://$(BUCKET)/builds/2f08e5a2-b820c309/prod/xcalar-1.2.2-1264-installer
S3_BOOTSTRAP ?= s3://$(BUCKET)/bysha1/$(shell sha1sum $(BOOTSTRAP) | awk '{print $$1}')/$(shell basename $(BOOTSTRAP))
S3_BOOTSTRAP_KEY = $(subst s3://$(BUCKET)/,,$(S3_BOOTSTRAP))
ZONE ?= azure.xcalar.io
PARAMETERS ?= parameters.json
PARAMETERS_DEFAULTS ?= parameters.json.defaults
TEMPLATE ?= azuredeploy.json
S3CP= aws s3 cp --quiet
PUBLIC = --acl public-read --metadata-directive REPLACE --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform'
S3PUBLIC = $(S3CP) $(PUBLIC)

PASSWORD=$(shell jq -r '.parameters.adminPassword.value' $(PARAMETERS))
USERNAME=$(shell jq -r '.parameters.adminUsername.value' $(PARAMETERS))

SCRIPTS_PATH=$(shell jq -r '[.variables.scriptsUri,.variables.customScriptName]|join("/")' mainTemplate.json | sed -e 's@^http://@@g')
SCRIPTS_SHA1=$(shell sha1sum $(BOOTSTRAP) | cut -d' ' -f1)

PAYLOAD = $(wildcard payload/*)

export GNUPGHOME=$(CURDIR)/.gnupg
JQ=/usr/local/bin/jq

s3url = $(shell aws s3 presign $(1))

-include local.mk

# These are the full URLs, possibly with parameter eg: https://xcrepo.s3.amazonaws.com/builds/foo.sh?Arg-1&Arg2=2
BOOTSTRAP_URL = https://s3-us-west-2.amazonaws.com/$(BUCKET)/$(S3_BOOTSTRAP_KEY)
INSTALLER_URL = $(call s3url, $(S3_INSTALLER))

all: xdp-standard-package.zip

clean:
	rm -f xdp-standard-package.zip payload.tar.gz
	rm -rf .tmp

/usr/bin/sshpass:
	@echo "You need sshpass installed. Please use 'sudo apt-get install -y sshpass' on Ubuntu and 'sudo yum install -y sshpass' on EL"
	exit 1

jq15:
	@if ! jq --version | grep -q '1.5'; then sudo curl -o $(JQ).tmp -fsSL https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 && sudo chmod +x $(JQ).tmp && sudo mv $(JQ).tmp $(JQ); fi
	@hash -r; jq --version | grep -q '1.5' || { echo "jq 1.5 had to be installed. Please run 'hash -r', and make sure jq is $(JQ) in your PATH"; exit 2; }

payload.tar.gz: $(PAYLOAD)
	rm -f $@
	fakeroot tar czvf $@ $^

.PHONY: xdp-standard-package.zip
xdp-standard-package.zip: createUiDefinition.json mainTemplate.json bootstrap.sh payload.tar.gz
	rm -rf .tmp
	mkdir -p .tmp
	cp $^ .tmp
	#(cat bootstrap.sh; base64 payload.tar.gz) > .tmp/bootstrap.sh
	rm -f $@
	(cd .tmp/ && zip ../$@ * && cp ../$@ .)

$(VALIDATE_RG) $(GROUP):
	@if ! test "`az group exists --name $@ --output tsv`" = true; then \
        az group create --name $@ --location $(LOCATION); \
    fi

destroy:
	-az group delete --no-wait --name $(GROUP)
	@tail -1 local.mk | grep -q 'GROUP=$(GROUP)' && uniq local.mk | head -n-1 > local.mk.tmp && mv local.mk.tmp local.mk || true

check_bootstrap:
	@http_proxy=; \
     if ! test "`curl -sSL http://$(SCRIPTS_PATH) | sha1sum | cut -d' ' -f1`" = "$(SCRIPTS_SHA1)"; then \
        echo >&2 "ERROR: Checksum of $(BOOTSTRAP) doesn't match with what's referenced in your mainTemplate (http://$(SCRIPTS_PATH))"; \
        exit 1; \
     fi

update_bootstrap:
	@http_proxy=; \
    if test "`curl -o /dev/null -w '%{http_code}' -sSL http://$(SCRIPTS_PATH) 2>/dev/null`" != 200; then \
        gsutil cp $(BOOTSTRAP) gs://$(SCRIPTS_PATH); \
    elif test "`curl -sSL http://$(SCRIPTS_PATH) 2>/dev/null | sha1sum | cut -d' ' -f1`" = "$(SCRIPTS_SHA1)"; then \
        echo >&2 "http://$(SCRIPTS_PATH) already up-to-date"; \
    else \
        echo >&2 "http://$(SCRIPTS_PATH) already exists with a different checksum! Not overwriting! Bump the version in mainTemplate.json."; \
        exit 1; \
    fi

%.json: %.json.example
	@test -e $@ || { echo "Copying template $< to $@ ..." && cp $< $@ && echo "Please modify the missing sections in $(PARAMETERS) before redeploying!"; exit 1; }
	@touch $@

validateMain: $(VALIDATE_RG) parameters.json
	@bash -n $(BOOTSTRAP)
	@az group deployment validate --resource-group $(VALIDATE_RG) --template-file "mainTemplate.json" --parameters @parameters.main.json

validate: $(VALIDATE_RG) parameters.json
	@bash -n $(BOOTSTRAP)
	@aws s3 cp $(S3_BOOTSTRAP) - >/dev/null 2>&1 || aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP)
	@az group deployment validate --resource-group $(VALIDATE_RG) \
     --template-file "$(TEMPLATE)" \
     --parameters "$$(jq -r -s '.[0] * .[1] | .parameters | {\
                                           adminEmail, adminUsername, adminPassword, licenseKey, scaleNumber, dataDiskSize,\
                                           dnsLabelPrefix: {value:"$(GROUP)"},\
                                           installerUrl: {value:"$(INSTALLER_URL)"},\
                                           bootstrapUrl: {value:"$(BOOTSTRAP_URL)"}\
                                           }|tojson' $(PARAMETERS_DEFAULTS) $(PARAMETERS))" --output json

deploy: $(GROUP) validate
	@(touch local.mk; cat local.mk; echo GROUP=$(GROUP)) | uniq | tee local.mk.tmp >/dev/null && mv local.mk.tmp local.mk
	time az group deployment create --resource-group $(GROUP) --name $(DEPLOY) \
     --template-file "$(TEMPLATE)" \
     --parameters "$$(jq -r -s '.[0] * .[1] | .parameters | {\
                                           adminEmail, adminUsername, adminPassword, licenseKey, scaleNumber, dataDiskSize,\
                                           dnsLabelPrefix: {value:"$(GROUP)"},\
                                           installerUrl: {value:"$(INSTALLER_URL)"},\
                                           bootstrapUrl: {value:"$(BOOTSTRAP_URL)"}\
                                           }|tojson' $(PARAMETERS_DEFAULTS) $(PARAMETERS))"
	@echo "Your cluster is available at https://$$(az group deployment show --resource-group $(GROUP) --name $(DEPLOY) --output json --query 'properties.outputs.url.value' --output tsv)"

deployDev: $(GROUP) validate
	bash -n $(BOOTSTRAP)
	aws s3 cp $(S3_BOOTSTRAP) - >/dev/null 2>&1 || aws s3 cp $(BOOTSTRAP) $(S3_BOOTSTRAP)
	aws s3api put-object-acl --acl public-read --bucket $(BUCKET) --key $(S3_BOOTSTRAP_KEY)
	sed -i -e 's|"scriptsUri":.*$$|"scriptsUri": "'`dirname $(BOOTSTRAP_URL)`'",|g' applianceDevTemplate.json
	@(touch local.mk; cat local.mk; echo GROUP=$(GROUP)) | uniq | tee local.mk.tmp >/dev/null && mv local.mk.tmp local.mk
	time az group deployment create --resource-group $(GROUP) --name $(DEPLOY) \
     --template-file applianceDevTemplate.json \
     --parameters "$$(jq -r -s '.[0] * .[1] | .parameters | {\
                                           adminEmail, adminUsername, adminPassword, licenseKey, scaleNumber,\
                                           dnsLabelPrefix: {value:"$(GROUP)"},\
                                           installerUrl: {value:"$(INSTALLER_URL)"},\
                                           bootstrapUrl: {value:"$(BOOTSTRAP_URL)"}\
                                           }|tojson' $(PARAMETERS_DEFAULTS) $(PARAMETERS))"
	@echo "Your cluster is available at https://$$(az group deployment show --resource-group $(GROUP) --name $(DEPLOY) --output json --query 'properties.outputs.url.value' --output tsv)"

deployMain: $(GROUP) validateMain
	time az group deployment create --resource-group $(GROUP) --name $(DEPLOY) \
     --template-file mainTemplate.json --parameters @parameters.main.json
	@echo "Your cluster is available at https://$$(az group deployment show --resource-group $(GROUP) --name $(DEPLOY) --output json --query 'properties.outputs.url.value' --output tsv)"

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
	$(S3PUBLIC) $< s3://xccerts/certs/$(ZONE)/bysha1/`sha1sum $< | cut -d' ' -f1`/$(<F)

%.upload: %.pem %.key
	$(S3PUBLIC) $(<F).pem s3://xccerts/certs/$(ZONE)/
	$(S3PUBLIC) $(<F).key s3://xccerts/certs/$(ZONE)/
