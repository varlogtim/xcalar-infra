#!/bin/bash

set +e

set -e

export XLRDIR=`pwd`
export XCE_LICENSEDIR=/etc/xcalar
export PATH="$XLRDIR/bin:$PATH"

TestList=$TestList
configFile="${2:-$XLRDIR/src/bin/usrnode/test-config.cfg}"
ScriptPath="${3:-/netstore/users/xma/dashboard/startFuncTests.py}"
numNode="${4:-2}"

TestStr=""
TestArray=(${TestList//,/ })
for Test in "${TestArray[@]}"
do
TestStr="$TestStr --testCase $Test"
done


# Set this for pytest to be able to find the correct cfg file
pgrep -u `whoami` childnode | xargs -r kill -9
pgrep -u `whoami` usrnode | xargs -r kill -9
pgrep -u `whoami` xcmgmtd | xargs -r kill -9
rm -rf /var/tmp/xcalar-jenkins/*
mkdir -p /var/tmp/xcalar-jenkins/sessions
rm -rf /var/opt/xcalar/*
git clean -fxd
git submodule init
git submodule update

. doc/env/xc_aliases


sudo pkill -9 gdbserver || true
pgrep -f 'python*'$ScriptPath'.*' | xargs -r sudo kill -9
#sudo pkill -9 python || true
sudo pkill -9 usrnode || true
sudo pkill -9 childnode || true
sudo pkill -9 xcmonitor || true
find $XLRDIR -name "core.*" -exec rm --force {} +

# Debug build
set +e
sudo rm -rf /etc/xcalar/*
xclean
set -e
build clean
build coverage
build

if [ $? -ne 0 ]; then
    echo "build config failed"
    exit 1
fi


cd $XLRDIR


$XLRDIR/src/bin/cli/xccli -c "shutdown"
sleep 10s


source $XLRDIR/doc/env/xc_aliases

xclean &> /dev/null

date
cp $configFile $configFile-copy
echo "$FuncTestParam" | cat >> $configFile-copy
sudo sed -i -e "s'Constants\.BufferCachePercentOfTotalMem=.*'Constants\.BufferCachePercentOfTotalMem=$BufferCachePercentOfTotalMem'" $configFile-copy

for ii in `seq 0 $((numNode - 1))`;
do
    LD_PRELOAD=$XLRDIR/src/lib/libfaulthandler/.libs/libfaulthandler.so.0 $XLRDIR/src/bin/usrnode/usrnode -f $configFile-copy -i $ii -n $numNode  &> /dev/null &
    $XLRDIR/src/bin/monitor/xcmonitor -n $ii -c $configFile-copy &> /dev/null &
done

find . -type f -name '*core*'
ps -ef | grep gdbserver | grep -v grep || true

date
timeOut=800
counter=0
set +e
while true; do

    $XLRDIR/src/bin/cli/xccli -c "version" | grep "Backend Version"
    
    if [ $? -eq 0 ]; then
        break
    fi

    find . -type f -name '*core*'
    ps -ef | grep gdbserver | grep -v grep
    sleep 5s
    counter=$(($counter + 5))
    if [ $counter -gt $timeOut ]; then
        echo "usrnode time out"
        exit 1
    fi
done
set -e

echo "usrnode ready"

python2.7 $ScriptPath $TestStr --cliPath $XLRDIR/src/bin/cli/xccli --cfgPath $configFile-copy --single


# Turn this on when we can shutdown successfully
#echo "Shutting down now"
#$XLRDIR/src/bin/cli/xccli -c "shutdown"

echo "Please find more startFuncTests.py logs in syslog"
