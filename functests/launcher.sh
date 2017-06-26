#!/bin/bash

# This script shoould not start xcmonitor and usrnodes since the new monitor
# starts usrnodes itself. For now, to quickly get this script functional with
# the new monitor, continue launching usrnodes directly, without a monitor, by
# commenting out the monitor specific lines -> which will eventually be modified
# to correctly invoke the monitor (and remove the usrnode launching).

set +e

if [ `id -u` != 0 ]; then
    echo Please run as root
    exit 1
fi


ulimit -c unlimited
ulimit -l unlimited

# Change defaults for your installation in the following file
if [ -r "/etc/default/xcalar" ]; then
    . /etc/default/xcalar
fi

export XCE_CONFIG="${XCE_CONFIG:-/etc/xcalar/default.cfg}"
XCE_USER="${XCE_USER:-root}"
export XLRDIR="${XLRDIR:-/opt/xcalar}"
export XLRGUIDIR="${XLRGUIDIR:-/opt/xcalar/xcalar-gui}"
LIBHDFS3_CONF="${LIBHDFS3_CONF:-/etc/xcalar/hdfs-client.xml}"
PATH="$XLRDIR/bin:$PATH"
XCE_LICENSEDIR="${XCE_LICENSEDIR:-/etc/xcalar}"
XCE_LOGDIR="$(awk -F'=' '/^Constants.XcalarLogCompletePath/{print $2}' $XCE_CONFIG)"
XCE_LOGDIR="${XCE_LOGDIR:-/var/log/xcalar}"

export XCE_CONFIG XCE_USER XCE_LOGDIR XLRDIR LIBHDFS3_CONF PATH XCE_LICENSEDIR

mkdir -p /var/run/xcalar

oldpids="$(cat /var/run/xcalar/*.pid 2>/dev/null)"
if test -n "$oldpids"; then
    kill -- $oldpids 2>/dev/null || true
    sleep 5
    kill -9 $oldpids 2>/dev/null || true
    rm -f /var/run/xcalar/*.pid
fi

killall xcmgmtd usrnode childnode &>/dev/null || true
sleep 4
find /var/opt/xcalar -type f -delete
find /dev/shm -name "xcalar-*" -delete
find $XCE_LOGDIR -name "xcmonitorTmp.*" -type f -delete

/opt/xcalar/bin/xcmgmtd $XCE_CONFIG >> $XCE_LOGDIR/xcmgmtd.out 2>&1 </dev/null &
pid=$!
echo $pid > /var/run/xcalar/xcmgmtd.pid

NumNodes=$(awk -F= '/^Node.NumNodes/{print $2}' $XCE_CONFIG)

#declare -A monitorTmpLogs
for ii in $(seq 0 $(( $NumNodes - 1 ))); do
    # monitorLog=$XCE_LOGDIR/xcmonitor.${ii}.out
    # monitorTmpLog=`mktemp $XCE_LOGDIR/xcmonitorTmp.${ii}.XXXXXX`
    # monitorTmpLogs[$ii]="$monitorTmpLog"

    /opt/xcalar/bin/usrnode --nodeId $ii --numNodes $NumNodes --configFile $XCE_CONFIG 1>> $XCE_LOGDIR/node.${ii}.out 2>> $XCE_LOGDIR/node.${ii}.err </dev/null &
    pid=$!
    echo $pid > /var/run/xcalar/node.${ii}.pid
# ( /opt/xcalar/bin/xcmonitor -n $ii -c $XCE_CONFIG 2>&1 </dev/null & echo $! > /var/run/xcalar/xcmonitor.${ii}.pid ) | tee -a $monitorLog > $monitorTmpLog &
done

backendUp="false"
#monitorUp="false"
sleepTime=3
for ii in $(seq 60); do
    if xccli -c version 2>&1 | grep -q 'Backend Version:'; then
        backendUp="true"
        break
    fi
    sleep $sleepTime
done

if [ "$backendUp" = "false" ]; then
    echo "Backend not up after " $(($sleepTime * $ii)) " seconds"
    exit 1
fi

#foundMaster="false"
#for jj in $(seq 60); do
    #for ii in $(seq 0 $(( $NumNodes - 1 ))); do
        #grep "STATE CHANGE:" "${monitorTmpLogs[$ii]}" | grep -q "=> Master"
        #ret=$?
        #if [ "$ret" = "0" ]; then
            #foundMaster="true"
            #break
        #fi
    #done

    #if [ "$foundMaster" = "true" ]; then
        #monitorUp="true"
        #break
    #fi

    #sleep $sleepTime
#done

#if [ "$monitorUp" = "false" ]; then
    #echo "Monitor not up after " $(($sleepTime * $jj)) " seconds"
    #pkill -9 usrnode
    #exit 1
#fi

exit 0
