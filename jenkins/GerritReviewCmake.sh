#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$PATH"
export CCACHE_BASEDIR=$XLRDIR

dobuild () {
  echo "NINJA=$NINJA dobuild $*"
  ccache -s
  git clean -fxd
  cmBuild config "$1"
  time cmBuild
  ccache -s
}

export NINJA=1
for config in prod; do
  dobuild $config
done

exit $?

git clean -fxd
export NINJA=0
cmBuild config debug
cmBuild
cmBuild config prod
cmBuild
git clean -fxd
export NINJA=1
cmBuild config debug
cmBuild
cmBuild config prod
cmBuild
ccache -s
