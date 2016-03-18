#!/bin/bash
APT_PROXY="${APT_PROXY-http://apt-cacher.int.xcalar.com:3142}"
if [ "$(curl -sL -w "%{http_code}\\n" "$APT_PROXY" -o /dev/null)" != "200" ]; then
    unset APT_PROXY
fi
export DEBIAN_FRONTEND=noninteractive
PACKAGES="
curl
htop
nmon
slurm
tcpdump
unzip
vim-nox
"
http_proxy=$APT_PROXY apt-get -y install $PACKAGES
