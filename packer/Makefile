.PHONY: all ubuntu gce aws cloud vmware

all:
	@echo arguments:
	@echo   aws
	@echo   gce
	@echo   vmware
	@echo   qemu

box/jenkins-slave-ub14-20161020.ova: vmware

vmware:
	time packer build -only=vmware-iso ub14-vmware-qemu.json

qemu:
	time packer build -only=qemu ub14-vmware-qemu.json

gce:
	time packer build -only=googlecompute ub14-cloud.json

aws:
	time packer build -only=amazon-ebs -var-file=$(HOME)/.packer-vars ub14-cloud.json

cloud:
	time packer build -var-file=$(HOME)/.packer-vars ub14-cloud.json

box/%.ova:
	ovftool -dm=thin --name="$(@F)" --compress=1 output-vmware/packer-vmware-iso.vmx $@
