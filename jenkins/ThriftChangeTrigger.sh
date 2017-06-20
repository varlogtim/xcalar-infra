#!/bin/bash
export XLRDIR=$PWD/xcalar
export PATH=$XLRDIR/bin:$PATH
export XLRGUIDIR=$PWD/gui
cd $XLRDIR
python2.7 ./bin/genVersionSig.py -i src/include/libapis/LibApisCommon.h -o out
a=`cat out | grep "VersionSignature" | cut -f2 -d'"'`
b=`cat $XLRGUIDIR/assets/js/thrift/XcalarApiVersionSignature_types.js | grep 'VersionTStr' | cut -f2 -d"'"`

echo "Backend SHA:"
echo $a
echo "Frontend SHA:"
echo $b

if [ "$a" = "$b" ]
then
    echo "All good!"
    exit 0
else
    echo "Versions mismatch!"
    echo "Backend last commit"
    git log -n 1
    cd ../gui
    echo "Frontend last commit"
    git log -n 1
    exit 1
fi

#if git diff HEAD^ --name-only |  egrep '(XcalarApi\.js|\.thrift)$'; then
#   echo "Found matching files!!" >&2
#   exit 1
#fi
#exit 0
