SHELL = /bin/bash


ALL = vmware_inventory.ini vmware_inventory.py azure_rm.py azure_rm.ini docker.py ec2.py ec2.ini ovirt.ini ovirt.py cobbler.py


all: $(ALL)

$(ALL):
	curl -sL https://raw.githubusercontent.com/ansible/ansible/devel/contrib/inventory/$(@F) -o $@
	[[ $@ =~ .py$$ ]] && chmod +x $@ || :


