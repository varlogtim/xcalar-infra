#!/bin/bash
APT_PROXY="${APT_PROXY-http://apt-cacher.int.xcalar.com:3142}"
if [ "$(curl -sL -w "%{http_code}\\n" "$APT_PROXY" -o /dev/null)" != "200" ]; then
    unset APT_PROXY
fi
export DEBIAN_FRONTEND=noninteractive
PACKAGES="
libc6
libstdc++6
libgcc1
libaio1
libjansson4
libmysqlclient18
unixodbc
libodbc1
libbsd0
libuuid1
libarchive13
libprotobuf8
libkrb5-3
krb5-user
libgsasl7
libeditline0
python
python-pip
libpython2.7
apache2
node-less
node-uglify
libxml2
libtinfo5
libncurses5
zlib1g
libnettle4
libattr1
liblzo2-2
liblzma5
libbz2-1.0
libltdl7
libcomerr2
libkeyutils1
dnsutils
libsnappy1
curl
dnsutils
htop
nmon
slurm
tcpdump
unzip
vim-nox
awscli
"
http_proxy=$APT_PROXY apt-get -yqq install $PACKAGES
