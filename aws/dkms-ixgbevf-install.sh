#!/bin/bash
VER=2.16.4
if [ $UID -ne 0 ]; then
    echo >&2 "Must run as root or with sudo"
    exit 1
fi
set -ex
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get upgrade -y
apt-get install -y dkms

cd /usr/src
#wget "sourceforge.net/projects/e1000/files/ixgbevf stable/$VER/ixgbevf-$VER.tar.gz"
wget http://repo.xcalar.net/drivers/ixgbevf-$VER.tar.gz
tar -xzf ixgbevf-$VER.tar.gz
cat > /usr/src/ixgbevf-$VER/dkms.conf<<EOF
PACKAGE_NAME="ixgbevf"
PACKAGE_VERSION="$VER"
CLEAN="cd src/; make clean"
MAKE="cd src/; make BUILD_KERNEL=\${kernelver}"
BUILT_MODULE_LOCATION[0]="src/"
BUILT_MODULE_NAME[0]="ixgbevf"
DEST_MODULE_LOCATION[0]="/updates"
DEST_MODULE_NAME[0]="ixgbevf"
AUTOINSTALL="yes"
EOF
dkms add -m ixgbevf -v $VER
dkms build -m ixgbevf -v $VER
dkms install -m ixgbevf -v $VER
update-initramfs -c -k all


