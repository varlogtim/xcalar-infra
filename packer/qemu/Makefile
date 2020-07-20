SHELL = /bin/bash

PUPPETSRCDIR ?= $(HOME)/puppet

VPATH := $(shell pwd)

PACKER ?= packer.io
PACKER_BUILD := $(PACKER) build -force -on-error=abort
GIT_COMMIT_1 ?= $(cd $(PUPPETSRCDIR) && git rev-parse --short HEAD)
PUPPETSHA1 := $(GIT_COMMIT_1)

CACHER_IP  = $(shell getent hosts cacher | awk '{print $$1}')
http_proxy ?= http://$(CACHER_IP):3128
no_proxy := 10.,127.0.0.1,localhost,.localdomain,netstore,169.254.
# We have to pass in an IP here because the host name doesn't
# resolve inside the VM/container.
#EL7_BASE_MD5=md5:c725eab04431dcc046719c92888d5c5e
EL7_BASE_IMAGE=http://netstore/images/el7-base-qemu.qcow2.gz
EL7_BASE_MD5=md5:0b21fb7fb1e65b208c478b6d28d18e0d
BUILD_NUMBER ?= 6
OUTDIR ?= /mnt/ssd/images
OUTPUT_DIRECTORY ?= $(OUTDIR)

COMMON_ARGS ?= \
	-var "puppet_src=$(PUPPETSRCDIR)" \
	-var "puppet_sha1=$(PUPPETSHA1)" \
	-var "cacher_ip=$(CACHER_IP)" \
	-var "http_proxy=$(http_proxy)" \
	-var "https_proxy=" \
	-var "no_proxy=$(no_proxy)" \
	-var "output_directory=$(OUTPUT_DIRECTORY)/$(@D)/$(BUILD_NUMBER)" \
	-var "build_number=$(BUILD_NUMBER)"

#%.img: %.json
#	$(PACKER_BUILD) -only=$(@F) $<
all_qemu:
	@echo Please specify target:
	@echo    el7-base-qemu/tdhtest
	@echo    el7-jenkins_slave-qemu/tdhtest

run-puppet-qemu.json: run-puppet-qemu.yaml
base-qemu.json: base-qemu.yaml

%.json: %.yaml
	cfn-flip < $< > $@

el8-base-qemu/tdhtest: base-qemu.json
	test -e $@ && mv -fv $@ $@-`date +%%s` || true
	$(PACKER_BUILD) \
	$(COMMON_ARGS) \
	-var "osid=el8" \
	-var "kickstart=ks-el8.cfg" \
	-var "iso_url=http://netstore/isos/CentOS_ISO/CentOS-8-x86_64-1905-boot.iso" \
	-var "iso_checksum=md5:49d7d1b5d89451d20efd709161601714" \
	$<

el7-base-qemu/tdhtest: base-qemu.json
	rm -fv $@
	$(PACKER_BUILD) -only=$(@D) \
	$(COMMON_ARGS) \
	-var "osid=el7" \
	-var "iso_url=http://netstore/isos/CentOS_ISO/CentOS-7-x86_64-Minimal-2003.iso" \
	-var "iso_checksum=md5:f99e2b01389c62a56bb0d3afdbc202f2" \
	-var "kickstart=ks7.cfg" \
	$<

el7-puppet-qemu/tdhtest: run-puppet-qemu.json
	$(PACKER_BUILD)  \
	$(COMMON_ARGS) \
	-var "osid=el7" \
	-var "iso_url=$(EL7_BASE_IMAGE)" \
	-var "iso_checksum=$(EL7_BASE_MD5)" $<

el7-jenkins_slave-qemu/tdhtest: run-puppet-qemu.json
	rm -fv $@
	$(PACKER_BUILD) \
	$(COMMON_ARGS) \
	-var "osid=el7" \
	-var "iso_url=$(EL7_BASE_IMAGE)" \
	-var "iso_checksum=$(EL7_BASE_MD5)" $<

%/tdhtest: run-puppet-qemu.json
	rm -fv $@
	$(PACKER_BUILD) \
	$(COMMON_ARGS) \
	-var "iso_url=$(EL7_BASE_IMAGE)" \
	-var "iso_checksum=$(EL7_BASE_MD5)" $<

#%.xz: %/tdhtest:
#	xz -zc $< > $@.tmp
#	mv $@.tmp $@



include ../common.mk
-include local.mk
