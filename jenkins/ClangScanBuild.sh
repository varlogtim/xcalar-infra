#!/bin/bash

export XLRDIR=$PWD
export PATH=$XLRDIR/bin:$PATH

test -e /opt/clang && export PATH=/opt/clang/bin:$PATH

export ASAN_OPTIONS=suppressions=$XLRDIR/bin/ASan.supp
export LSAN_OPTIONS=suppressions=$XLRDIR/bin/LSan.supp

git clean -fxd
build clean
build config
scan-build-3.9 -o `pwd`/clangScanBuildReports -v -v --force-analyze-debug-code -disable-checker deadcode.DeadStores --use-cc=`which clang-3.9` --use-c++=`which clang++-3.9` --use-analyzer=`which clang-3.9` make V=0 -s -j`nproc` CFLAGS="-Wno-unknown-warning-option" CXXFLAGS="-Wno-overloaded-virtual -Wno-unknown-warning-option -Wno-unused"
