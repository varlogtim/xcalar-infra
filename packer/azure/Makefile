all: azure-jenkins azure-devstation azure-infra
.PHONY: azure-jenkins azure-devstation azure-infra

SHELL = /bin/bash


azure-%: %.json
	packer.io build \
		-var-file <(vault kv get -format=json -field=data secret/azure/packer-sp) \
		-var-file $< \
		build.json
