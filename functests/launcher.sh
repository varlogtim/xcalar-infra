#!/bin/bash
set -x

# This script starts up xcmonitor which starts up the usrnode

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
export MALLOC_CHECK_=2

export XCE_CONFIG XCE_USER XCE_LOGDIR XLRDIR LIBHDFS3_CONF PATH XCE_LICENSEDIR

mkdir -p /var/run/xcalar

oldpids="$(cat /var/run/xcalar/*.pid 2>/dev/null)"
if test -n "$oldpids"; then
    kill -- $oldpids 2>/dev/null || true
    sleep 5
    kill -9 $oldpids 2>/dev/null || true
    rm -f /var/run/xcalar/*.pid
fi

killall xcmgmtd xcmonitor usrnode childnode &>/dev/null || true
# Give enough time for processes to go away and free up the tcp ports
sleep 30
find /var/opt/xcalar -type f -not -path '/var/opt/xcalar/support/*' -delete
find /dev/shm -name "xcalar-*" -delete

/opt/xcalar/bin/xcmgmtd $XCE_CONFIG >> $XCE_LOGDIR/xcmgmtd.out 2>&1 </dev/null &
pid=$!
echo $pid > /var/run/xcalar/xcmgmtd.pid

NumNodes=$(awk -F= '/^Node.NumNodes/{print $2}' $XCE_CONFIG)

# Run half of the jobs with jemalloc allocator
if [ $(( $BUILD_ID % 2 )) -eq 0 ]; then
    jemallocEnabled=1
else
    jemallocEnabled=0
fi

for ii in $(seq 0 $(( $NumNodes - 1 ))); do
    monitorLog=$XCE_LOGDIR/xcmonitor.${ii}.out
    if [ $jemallocEnabled -eq 1 ]; then
        MALLOC_CONF=tcache:false,junk:true /opt/xcalar/bin/xcmonitor -n $ii -m $NumNodes -c $XCE_CONFIG > $monitorLog 2>&1 &
    else
        /opt/xcalar/bin/xcmonitor -n $ii -m $NumNodes -c $XCE_CONFIG > $monitorLog 2>&1 &
    fi
    pid=$!
    echo $pid > /var/run/xcalar/xcmonitor.${ii}.pid
done

backendUp="false"
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

exit 0
