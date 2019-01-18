SHELL = /bin/bash

PUPPET_SRC = $(HOME)/puppet

# We have to pass in an IP here because the host name doesn't
# resolve inside the VM/container.
CACHER_IP  = $(shell getent hosts cacher | awk '{print $$1}')

#%.img: %.json
#	$(PACKER_BUILD) -only=$(@F) $<
all_qemu:
	@echo Please specify target:
	@echo    el7-base-qemu/tdhtest
	@echo    el7-puppet-qemu/tdhtest

el7-base-qemu/tdhtest: el7-base-qemu.json
	$(PACKER_BUILD) -only=$(@D) $<

el7-puppet-qemu/tdhtest: run-puppet-qemu.json
	$(PACKER_BUILD) -only=$(@D) \
	    -var "puppet_src=$(PUPPET_SRC)" \
	    -var "cacher_ip=$(CACHER_IP)" \
	    $<

include ../common.mk
-include local.mk
