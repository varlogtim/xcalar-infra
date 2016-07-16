#!/bin/bash
set -e
curl -sSL https://releases.hashicorp.com/packer/0.10.1/packer_0.10.1_linux_amd64.zip > /usr/local/bin/packer.zip
cd /usr/local/bin
unzip packer.zip
rm -f packer.zip
chmod +x packer
