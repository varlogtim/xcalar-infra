#!/bin/bash -x

export MALLOC_CHECK_=2
export XLRDIR=/opt/xcalar
export PATH=$XLRDIR/bin:$PATH
export XCE_CONFIG=/etc/xcalar/default.cfg

TestsToRun=($TestCases)
TAP="AllTests.tap"
rm -f "$TAP"

restartXcalar() {
    sudo xcalar-infra/functests/launcher.sh
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
        echo "prod.functests.$TEST_TYPE.${hostname//./_}.${name}:0|g" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.numRun:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.numPass:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.status:0|g" | nc -w 1 -u $GRAPHITE 8125
    elif [ "$status" = "FAIL" ]; then
        echo "prod.functests.$TEST_TYPE.${hostname//./_}.${name}:1|g" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.numRun:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.numFail:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${hostname//./_}.status:1|g" | nc -w 1 -u $GRAPHITE 8125
    fi
}

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

    sudo sed --in-place '/\dev\/shm/d' /etc/fstab
    tmpFsSizeGb=`cat /proc/meminfo | grep MemTotal | awk '{ printf "%.0f\n", $2/1024/1024 }'`
    let "tmpFsSizeGb = $tmpFsSizeGb * 95 / 100"

    echo "none  /dev/shm    tmpfs   defaults,size=${tmpFsSizeGb%.*}G    0   0" | sudo tee -a /etc/fstab
    sudo mount -o remount /dev/shm

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

echo "prod.functests.$TEST_TYPE.${hostname//./_}.currentIter:$CURRENT_ITERATION|g" | nc -w 1 -u $GRAPHITE 8125
echo "prod.functests.$TEST_TYPE.${hostname//./_}.numberOfIters:$NUMBER_ITERATIONS|g" | nc -w 1 -u $GRAPHITE 8125

echo "1..$NumTests" | tee "$TAP"
set +e
anyfailed=0
    for Test in "${TestsToRun[@]}"; do
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

        xccli -c "loglevelset Debug"
        time xccli -c "functests run --allNodes --testCase $Test" 2>&1 | tee "$logfile"
        rc=${PIPESTATUS[0]}
        if [ $rc -ne 0 ]; then
            now=$(date +"%T")
            filepath="`pwd`$now"

            sudo cp /opt/xcalar/bin/usrnode "$filepath"
            funcstatsd "$Test" "FAIL" "$gitsha"
            echo "not ok ${ii} - $Test" | tee -a $TAP
            anyfailed=1
        else
            if grep -q Error "$logfile"; then
                funcstatsd "$Test" "FAIL" "$gitsha"
                echo "Failed test output in $logfile at `date`"
                cat >&2 "$logfile"
                echo "not ok ${ii} - $Test"  | tee -a $TAP
                anyfailed=1
            else
                echo "Passed test at `date`"
                funcstatsd "$Test" "PASS" "$gitsha"
                echo "ok ${ii} - $Test"  | tee -a $TAP
            fi
        fi
        ii=$(( $ii + 1 ))
    done
