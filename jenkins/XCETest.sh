#!/bin/bash

set -e

export XLRDIR=`pwd`
export XCE_LICENSEDIR=/etc/xcalar
export ExpServerd="false"

rm -rf xcalar-gui
git clone ssh://gerrit.int.xcalar.com:29418/xcalar/xcalar-gui.git
export XLRGUIDIR=$PWD/xcalar-gui

export PATH="$XLRDIR/bin:$PATH"
# Set this for pytest to be able to find the correct cfg file
pgrep -u `whoami` childnode | xargs -r kill -9
pgrep -u `whoami` usrnode | xargs -r kill -9
pgrep -u `whoami` xcmgmtd | xargs -r kill -9
# Nuke as soon as possible
#ipcs -m | cut -d \  -f 2 | xargs -iid ipcrm -mid || true
#rm /tmp/xcalarSharedHeapXX* || true
sudo rm -rf /var/tmp/xcalar-jenkins/*
mkdir -p /var/tmp/xcalar-jenkins/sessions
sudo rm -rf /var/opt/xcalar/*
git clean -fxd -q
git submodule init
git submodule update

. doc/env/xc_aliases


sudo pkill -9 gdbserver || true
sudo pkill -9 python || true
sudo pkill -9 usrnode || true
sudo pkill -9 childnode || true
sudo pkill -9 xcmgmtd || true

# Debug build
set +e
xclean
set -e
build clean
build coverage
build
build sanitySerial
bin/coverageReport.sh --output /netstore/qa/coverage --type html

# Prod build
set +e
xclean
set -e
build clean
build prod 
build
build sanitySerial

