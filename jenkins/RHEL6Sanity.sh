#!/bin/bash

#set +e
#docker stop $(docker ps -aq)
#docker rm $(docker ps -aq)
#docker rmi $(docker images -aq)
#set -e

export XLRDIR=`pwd`
export ExpServerd="false"
export PATH="/opt/clang/bin:$XLRDIR/bin:$PATH"
export CCACHE_BASEDIR=$XLRDIR
source $XLRDIR/doc/env/xc_aliases

rpm -q xcalar && sudo yum remove -y xcalar
sudo rm -rf /opt/xcalar/scripts

# Set this for pytest to be able to find the correct cfg file
pgrep childnode | sudo xargs -r kill -9
pgrep usrnode | sudo xargs -r kill -9
pgrep xcmgmtd | sudo xargs -r kill -9

if true; then
  rm -rf /var/tmp/xcalar-`id -un`/* /var/tmp/xcalar-`id -un`/*
  mkdir -p /var/tmp/xcalar-`id -un`/sessions /var/tmp/xcalar-`id -un`/sessions
  sudo ln -sfn $XLRDIR/src/data/qa /var/tmp/
  sudo ln -sfn $XLRDIR/src/data/qa /var/tmp/`id -un`-qa  
fi
git clean -fxd >/dev/null
git submodule update --init --recursive

set +e
xclean
set -e

ccache -s
# debug build
build clean  >/dev/null
build config  >/dev/null
build CC="ccache gcc" CXX="ccache g++"
ccache -s
build sanitySerial

set +e
xclean
set -e

# prod build
build clean >/dev/null
build prod CC="ccache gcc" CXX="ccache g++"
build sanitySerial
ccache -s