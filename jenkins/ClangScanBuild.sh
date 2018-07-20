#!/bin/bash
set -e

CLANG=${CLANG:-/opt/clang5}
test -e $CLANG && export PATH=$CLANG/bin:$PATH || true

export ASAN_OPTIONS=suppressions=$XLRDIR/bin/ASan.supp
export LSAN_OPTIONS=suppressions=$XLRDIR/bin/LSan.supp

export CCC_CC=clang
export CCC_CXX=clang++

scan_build() {
    scan-build -o $XLRDIR/clangScanBuildReports -v --force-analyze-debug-code -disable-checker deadcode.DeadStores --keep-going "$@"
}

cd ${XLRDIR?Need XLRDIR set}
rm -rf buildOut
mkdir -p buildOut
cd buildOut
scan_build 'cmake -GNinja -DUSE_CCACHE=OFF -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_C_COMPILER=$CC  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_PREFIX:PATH=/opt/xcalar $XLRDIR'
scan_build "$@" ninja
