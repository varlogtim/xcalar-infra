#!/bin/bash

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
XCE_LOGDIR="${XCE_LOGDIR:-/var/log/xcalar}"
export XLRDIR="${XLRDIR:-/opt/xcalar}"
export XLRGUIDIR="${XLRGUIDIR:-/opt/xcalar/xcalar-gui}"
LIBHDFS3_CONF="${LIBHDFS3_CONF:-/etc/xcalar/hdfs-client.xml}"
PATH="$XLRDIR/bin:$PATH"
XCE_LICENSEDIR="${XCE_LICENSEDIR:-/etc/xcalar}"

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
/opt/xcalar/bin/xcmgmtd $XCE_CONFIG >> $XCE_LOGDIR/xcmgmtd.out 2>&1 </dev/null &
pid=$!
echo $pid > /var/run/xcalar/xcmgmtd.pid

NumNodes=$(awk -F= '/^Node.NumNodes/{print $2}' $XCE_CONFIG)

for ii in $(seq 0 $(( $NumNodes - 1 ))); do
	/opt/xcalar/bin/usrnode --nodeId $ii --numNodes $NumNodes --configFile $XCE_CONFIG >> $XCE_LOGDIR/node.${ii}.log 2>&1 </dev/null &
	pid=$!
	echo $pid > /var/run/xcalar/node.${ii}.pid
done

for ii in $(seq 60); do
	if xccli -c version 2>&1 | grep -q 'Backend Version:'; then
		exit 0
	fi
	sleep 3
done
exit 1
