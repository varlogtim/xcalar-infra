.PHONY: all ubuntu gce

all:
	@echo arguments:
	@echo   ubuntu
	@echo   gce

ubuntu:
	time packer build -only=ubuntu-1404-server-vagrant ubuntu-14.04-server-amd64-vagrant.json

gce:
	time packer build -only=googlecompute ubuntu-14.04-gce.json
