.PHONY: all ubuntu gce aws cloud

all:
	@echo arguments:
	@echo   ubuntu
	@echo   gce

ubuntu:
	time packer build -only=ubuntu-1404-server-vagrant ubuntu-14.04-server-amd64-vagrant.json

gce:
	time packer build -only=googlecompute ubuntu-14.04-cloud.json

aws:
	time packer build -only=amazon-ebs -var-file=$(HOME)/.packer-vars ubuntu-14.04-cloud.json

cloud:
	time packer build -var-file=$(HOME)/.packer-vars ubuntu-14.04-cloud.json
