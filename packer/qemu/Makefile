SHELL = /bin/bash

PUPPET_SRC ?= $(HOME)/puppet

VPATH := $(shell pwd)

PACKER_BUILD := /usr/local/bin/packer build -force -on-error=abort

# We have to pass in an IP here because the host name doesn't
# resolve inside the VM/container.
CACHER_IP  = $(shell getent hosts cacher | awk '{print $$1}')
EL7_BASE_IMAGE=el7-base-qemu/tdhtest

#%.img: %.json
#	$(PACKER_BUILD) -only=$(@F) $<
all_qemu:
	@echo Please specify target:
	@echo    el7-base-qemu/tdhtest
	@echo    el7-puppet-qemu/tdhtest

el7-base-qemu/tdhtest: el7-base-qemu.json
	rm -fv $@
	$(PACKER_BUILD) -only=$(@D) \
	-var "puppet_src=$(PUPPET_SRC)" \
	-var "cacher_ip=$(CACHER_IP)" \
	-var "http_proxy=http://$(CACHER_IP):3128" \
	-var "https_proxy=" \
	-var "no_proxy=10.,127.,localhost,169.254." \
	$<

el7-puppet-qemu/tdhtest: run-puppet-qemu.json
	$(PACKER_BUILD) -only=$(@D) \
	    -var "puppet_src=$(PUPPET_SRC)" \
	    -var "cacher_ip=$(CACHER_IP)" \
	    $<

el7-jenkins_slave-qemu/tdhtest: run-puppet-qemu.json
	rm -fv $@
	$(PACKER_BUILD) -only=$(@D) \
	-var "puppet_src=$(PUPPET_SRC)" \
	-var "cacher_ip=$(CACHER_IP)" \
	-var "http_proxy=http://$(CACHER_IP):3128" \
	-var "https_proxy=" \
	-var "no_proxy=10.,127.,localhost,169.254." \
	-var "iso_url=file://$(EL7_BASE_IMAGE)" \
	-var "iso_checksum=$(shell md5sum $(EL7_BASE_IMAGE) | awk '{print $$1}')" $<

%/tdhtest: run-puppet-qemu.json
	rm -fv $@
	$(PACKER_BUILD) -only=$(@D) \
	-var "puppet_src=$(PUPPET_SRC)" \
	-var "cacher_ip=$(CACHER_IP)" \
	-var "http_proxy=http://$(CACHER_IP):3128" \
	-var "https_proxy=" \
	-var "no_proxy=10.,127.,localhost,169.254." \
	-var "iso_url=file://$(EL7_BASE_IMAGE)" \
	-var "iso_checksum=$(shell md5sum $(EL7_BASE_IMAGE) | awk '{print $$1}')" \
	$<

#%.xz: %/tdhtest:
#	xz -zc $< > $@.tmp
#	mv $@.tmp $@



include ../common.mk
-include local.mk
