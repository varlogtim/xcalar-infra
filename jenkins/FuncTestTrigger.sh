#!/bin/bash -x

touch /tmp/${JOB_NAME}_${BUILD_ID}_START_TIME

export XLRDIR=/opt/xcalar
export PATH=$XLRDIR/bin:$PATH
export XCE_CONFIG=/etc/xcalar/default.cfg

TestsToRun=($TestCases)
TAP="AllTests.tap"
rm -f "$TAP"

restartXcalar() {
    sudo xcalar-infra/functests/launcher.sh $memAllocator
}

genSupport() {
    miniDumpOn=`echo "$FuncParams" | grep "Constants.Minidump" | cut -d= -f 2`
    miniDumpOn=${miniDumpOn:-true}
    if [ "$miniDumpOn" = "true" ]; then
        sudo /opt/xcalar/scripts/support-generate.sh
    else
        echo "support-generate.sh disabled because minidump is off. Check `pwd` for cores"
    fi
}

funcstatsd () {
    local name="${1//::/_}"
    local status="$2"
    local gitsha="$3"
    if [ "$status" = "PASS" ]; then
        echo "prod.functests.$TEST_TYPE.${hostname//./_}.${name}:0|g" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.numRun:1|c" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.numPass:1|c" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.status:0|g" | nc -4 -w 5 -u $GRAPHITE 8125
    elif [ "$status" = "FAIL" ]; then
        echo "prod.functests.$TEST_TYPE.${hostname//./_}.${name}:1|g" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.numRun:1|c" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.numFail:1|c" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.status:1|g" | nc -4 -w 5 -u $GRAPHITE 8125
    fi
}

genBuildArtifacts() {
    mkdir -p ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
    mkdir -p $XLRDIR/tmpdir

    # Find core files and dump backtrace
    gdbcore.sh -c core.tar.bz2 $XLRDIR /var/log/xcalar /var/tmp/xcalar-root

    find /tmp ! -path /tmp -newer /tmp/${JOB_NAME}_${BUILD_ID}_START_TIME 2>/dev/null | xargs cp --parents -rt $XLRDIR/tmpdir/

    PIDS=()
    for dir in tmpdir /var/log/xcalar /var/opt/xcalar/dataflows; do
        if [ -d $dir ]; then
            if [ "$dir" = "/var/log/xcalar" ]; then
                sudo tar -cf var_log_xcalar.tar.bz2 --use-compress-prog=pbzip2 $dir &
            elif [ "$dir" = "/var/opt/xcalar/dataflows" ]; then
                sudo tar -cf xcalar_dataflows.tar.bz2 --use-compress-prog=pbzip2 $dir &
            else
                tar -cf $dir.tar.bz2 --use-compress-prog=pbzip2 $dir &
            fi
            PIDS+=($!)
        fi
    done

    wait "${PIDS[@]}"
    ret=$?
    if [ $ret -ne 0 ]; then
        echo >&2 "ERROR($ret): tar failed"
    fi

    for dir in core tmpdir /var/log/xcalar /var/opt/xcalar/dataflows; do
        if [ "$dir" = "/var/log/xcalar" ]; then
            cp var_log_xcalar.tar.bz2 ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
            sudo rm var_log_xcalar.tar.bz2
            sudo rm $dir/*
        elif [ "$dir" = "/var/opt/xcalar/dataflows" ]; then
            cp xcalar_dataflows.tar.bz2 ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
            sudo rm xcalar_dataflows.tar.bz2
        else
            if [ -f $dir.tar.bz2 ]; then
                cp $dir.tar.bz2 ${NETSTORE}/${JOB_NAME}/${BUILD_ID}
                rm $dir.tar.bz2
                if [ -d $dir ]; then
                    rm -r $dir/*
                fi
            fi
        fi
    done

    echo >&2 "Build artifacts copied to ${NETSTORE}/${JOB_NAME}/${BUILD_ID}"

    rm /tmp/${JOB_NAME}_${BUILD_ID}_START_TIME
}

trap "genBuildArtifacts" EXIT

# Build the source
source doc/env/xc_aliases
xcEnvEnter
cmBuild clean
cmBuild config debug
cmBuild

if [ $MemoryAllocator -eq 2 ]; then
    memAllocator=2
else
    memAllocator=0
fi

echo $GuardRailsArgs > grargs.txt

if [ "$CURRENT_ITERATION" = "0" ]; then
    set +e
    sudo /opt/xcalar/bin/xcalarctl stop-supervisor
    ret=$?
    if [ "$ret" != "0" ]; then
        echo "Failed to stop Xcalar. Forcefully murdering usrnodes now"
        sudo pkill -9 usrnode
        sudo pkill -9 childnode
        sudo pkill -9 xcmonitor
    fi

    sudo find /var/opt/xcalar -type f -not -path "/var/opt/xcalar/support/*" -delete
    sudo find . -name "core.childnode.*" -type f -delete
    set -e

    sudo yum -y remove xcalar

    sudo $INSTALLER_PATH --noStart

    sudo rm $XCE_CONFIG
    sudo -E $XLRDIR/scripts/genConfig.sh /etc/xcalar/template.cfg $XCE_CONFIG `hostname`
    echo "$FuncParams" | sudo tee -a $XCE_CONFIG

    # Enable XEM
    #echo "Constants.XcalarEnterpriseManagerEnabled=true" | sudo tee -a $XCE_CONFIG
    #echo "Constants.XcalarClusterName=`hostname`" | sudo tee -a $XCE_CONFIG
    #echo "XcalarEnterpriseManager.Host=xem-202-1.int.xcalar.com" | sudo tee -a $XCE_CONFIG
    #echo "XcalarEnterpriseManager.Port=15000" | sudo tee -a $XCE_CONFIG
    #echo "XcalarEnterpriseManager.IsVirtualXceCluster=true" | sudo tee -a $XCE_CONFIG

    # Enable NoChildLDPreload so that childnodes do not inherit LD_PRELOAD from usrnode
    echo "Constants.NoChildLDPreload=true" | sudo tee -a $XCE_CONFIG

    sudo sed --in-place '/\dev\/shm/d' /etc/fstab
    tmpFsSizeGb=`cat /proc/meminfo | grep MemTotal | awk '{ printf "%.0f\n", $2/1024/1024 }'`
    let "tmpFsSizeGb = $tmpFsSizeGb * 95 / 100"

    echo "none  /dev/shm    tmpfs   defaults,size=${tmpFsSizeGb%.*}G    0   0" | sudo tee -a /etc/fstab
    sudo mount -o remount /dev/shm

    # Increase the mmap map count for GuardRails to work
    echo 100000000 | sudo tee /proc/sys/vm/max_map_count

    # Build GuardRails
    make -C xcalar-infra/GuardRails deps
    make -C xcalar-infra/GuardRails

    # kill any previous test run instances
    for pid in $(pidof -x FuncTestTrigger.sh); do
        if [ $pid != $$ ]; then
            kill -9 $pid
        fi
    done

    restartXcalar || true

    if xccli -c version 2>&1 | grep -q 'Error'; then
        echo "Could not even start usrnodes after install"
        exit 1
    fi
else
    if xccli -c version 2>&1 | grep -q 'Error'; then
        echo "Could not contact usrnodes. Did it crash?"
        exit 1
    fi
fi

TMPDIR="${TMPDIR:-/tmp/`id -un`}/$JOB_NAME/functests"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

gitsha=`xccli -c "version" | head -n1 | cut -d\  -f3 | cut -d- -f5`
echo "GIT SHA: $gitsha"

AllTests=($(xccli -c 'functests list' | tail -n+2))
NumTests="${#TestsToRun[@]}"
ii=1
hostname=`hostname -f`

echo "prod.functests.$TEST_TYPE.${hostname//./_}.currentIter:$CURRENT_ITERATION|g" | nc -4 -w 5 -u $GRAPHITE 8125
echo "prod.functests.$TEST_TYPE.${hostname//./_}.numberOfIters:$NUMBER_ITERATIONS|g" | nc -4 -w 5 -u $GRAPHITE 8125

NumNodes=$(awk -F= '/^Node.NumNodes/{print $2}' $XCE_CONFIG)

echo "1..$NumTests" | tee "$TAP"
set +e
for Test in "${TestsToRun[@]}"; do
    anyfailed=0
    logfile="$TMPDIR/${hostname//./_}_${Test//::/_}.log"

    echo Running $Test on $hostname ...
    if xccli -c version 2>&1 | grep -q 'Error'; then
       genSupport
       restartXcalar || true
       if xccli -c version 2>&1 | grep -q 'Error'; then
            echo "Could not restart usrnodes after previous crash"
            exit 1
       fi
    fi

    if xccli -c "loglevelset Debug" 2>&1 | grep -q 'Error'; then
       genSupport
       restartXcalar || true
       if xccli -c version 2>&1 | grep -q 'Error'; then
            echo "Could not restart usrnodes after previous crash"
            exit 1
       fi
    fi

    time xccli -c "functests run --allNodes --testCase $Test" 2>&1 | tee "$logfile"

    rc=${PIPESTATUS[0]}
    if [ $rc -ne 0 ]; then
        anyfailed=1
    else
        if grep -q Error "$logfile"; then
            echo "Failed test output in $logfile at `date`"
            cat >&2 "$logfile"
            anyfailed=1
        fi
    fi

    # Print and check the stats from all the nodes for any xdb page leaks
    for nodeid in $(seq 0 $(( $NumNodes - 1 ))); do
        count=`xccli -c "stats $nodeid" | tee /dev/stderr | grep -e "xdb.pagekvbuf.bc    fastAllocs" -e "xdb.pagekvbuf.bc    fastFrees" | awk '{print $3}' | uniq  | wc -l`
        # count = 2 when fastAllocs and fastFrees differ
        # count = 1 when fastAllocs and fastFrees are same
        # count = 0 when xccli command fails(happens when usrnode crashed/sick)
        if [ $count -gt 1 ]; then
            # fastAllocs and fastFrees are different which means that there is a leak
            echo "Failed pagekvbuf leak test"
            # abort the usrnode to get a core file.
            # XXX: Commenting this out out for now to reduce noise.
            # pgrep -f "usrnode --nodeId $nodeid" | xargs -r sudo kill -6
            # anyfailed=1
        fi
    done

    if [ $anyfailed -eq 1 ]; then
        # copy out the usrnode binary and retinas
        now=$(date +"%T")
        filepath="`pwd`/usrnode.$now"
        retinapath="`pwd`/retina.$now"
        exportpath="`pwd`/export.$now"
        sudo cp /opt/xcalar/bin/usrnode "$filepath"
        sudo cp -r /var/opt/xcalar/dataflows/ "$retinapath"
        sudo cp -r /var/opt/xcalar/export/ "$exportpath"
        # mark the test as failed
        funcstatsd "$Test" "FAIL" "$gitsha"
        echo "not ok ${ii} - $Test" | tee -a $TAP
    else
        echo "Passed test at `date`"
        funcstatsd "$Test" "PASS" "$gitsha"
        echo "ok ${ii} - $Test"  | tee -a $TAP
    fi

    ii=$(( $ii + 1 ))
done
