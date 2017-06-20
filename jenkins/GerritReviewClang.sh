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
build-clang config
build-clang coverage
#build sanity
#bin/coverageReport.sh --output /netstore/qa/coverage --type html
# Prod build
git clean -fxd
build-clang config --enable-silent-rules --enable-debug=no --enable-coverage=no --enable-inlines=yes --enable-prof=no --enable-asserts=no
build-clang prod
#build sanity
ccache -s
