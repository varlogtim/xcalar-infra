.PHONY: all ubuntu ubuntu-desktop

all:
	@echo arguments:
	@echo   ubuntu

ubuntu:
	time -p packer build -only=ubuntu-1404-server-vagrant ubuntu-14.04-server-amd64-vagrant.json

ubuntu-desktop:
	time -p packer build -only=ubuntu-1404-desktop-vagrant ubuntu-14.04-desktop-amd64-vagrant.json
