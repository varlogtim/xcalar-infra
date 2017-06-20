#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$HOME/google-cloud-sdk/bin:$PATH"

_ssh () {
    ssh -t -T -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}


#stop usrnode remotely
_ssh root@$NODE "service xcalar stop" < /dev/null || true

#build debug
build clean
build config
build


_scp () {
   scp -oUserKnownHostsFile=/dev/null -oLogLevel=ERROR -oStrictHostKeyChecking=no "$@"
}


#copy over binary
_scp $XLRDIR/src/bin/usrnode/usrnode root@$NODE:/opt/xcalar/bin/usrnode

_scp $XLRDIR/src/bin/childnode/childnode root@$NODE:/opt/xcalar/bin/childnode

_scp $XLRDIR/src/bin/mgmtd/xcmgmtd root@$NODE:/opt/xcalar/bin/xcmgmtd

_scp $XLRDIR/src/bin/cli/xccli root@$NODE:/opt/xcalar/bin/xccli

_scp $XLRDIR/src/lib/libfaulthandler/.libs/libfaulthandler.so.0 root@$NODE:/opt/xcalar/lib/libfaulthandler.so.0

#start usrnode remotely
_ssh root@$NODE "service xcalar start" < /dev/null || true


timeOut=600

counter=0
set +e
while true; do

    _ssh root@$NODE "/opt/xcalar/bin/xccli -c \"version\" | grep \"Backend Version\"" < /dev/null

    if [ $? -eq 0 ]; then
        break
    fi

    sleep 5s
    counter=$(($counter + 5))
    if [ $counter -gt $timeOut ]; then
        exit 1
    fi
done
set -e

_ssh root@$NODE "sudo echo \"kernel.core_pattern = /cores/core.%e.%p\" > /etc/sysctl.d/99-xcalar.conf && sudo sysctl -p /etc/sysctl.d/99-xcalar.conf"

_ssh root@$NODE "sudo df -h"
_ssh root@$NODE "time /opt/xcalar/bin/xccli -c 'version'"


echo "usrnode PIDs"
_ssh root@$NODE "sudo ps -ef | grep bin/usrnode | grep -v grep | awk '"'"'{print $2}'"'"'"

num_threads=$(_ssh root@$NODE 'sudo -E gdb -p $(ps -ef | grep usrnode | grep -v grep | awk '"'"'{print $2}'"'"' | head -1) -batch -ex '"'"'thread apply all bt'"'"' /opt/xcalar/bin/usrnode | grep Thread | grep LWP | wc -l')
echo "Before run, num of threads = "$num_threads

TestArray=(${TestList//,/ })
for Test in "${TestArray[@]}"
do
    date
    echo "=== Running $Test === CHANGE ONLY BELOW LINE"
    res=$(_ssh root@$NODE "sudo python /netstore/users/xma/dashboard/startFuncTests.py --testCase $Test")
    #res=$(_ssh root@$NODE "time /opt/xcalar/bin/xccli -c 'functests run --allNodes --testCase $Test'")
    echo $res
    #if [[ $res == *"Success"* ]]; then echo "Test passed"; else echo "Test failed"; exit 1; fi
    num_threads=$(_ssh root@$NODE 'sudo -E gdb -p $(ps -ef | grep usrnode | grep -v grep | awk '"'"'{print $2}'"'"' | head -1) -batch -ex '"'"'thread apply all bt'"'"' /opt/xcalar/bin/usrnode | grep Thread | grep LWP | wc -l')
    echo "After run, num of threads = "$num_threads

done

_ssh root@$NODE "sudo find /var/opt/xcalar/export/ -name "exportFile-*" -print0 | sudo xargs -0 rm -rf"


sleep 10
