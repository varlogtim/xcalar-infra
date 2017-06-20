#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$PATH"
export CCACHE_BASEDIR=$XLRDIR
#pgrep -u `whoami` usrnode | xargs -r kill -9
#pgrep -u `whoami` xcmgmtd | xargs -r kill -9
# Nuke as soon as possible
#rm -rf /var/tmp/xcalar-jenkins/*
#mkdir -p /var/tmp/xcalar-jenkins/sessions
# Debug build
git clean -fxd
build config
build coverage CC="ccache gcc" CXX="ccache g++"
#build coverage
#build sanity
make cstyle
#bin/coverageReport.sh --output /netstore/qa/coverage --type html
# Prod build
git clean -fxd
build clean
build prod CC="ccache gcc" CXX="ccache g++"
#build prod
#build sanity
ccache -s
