#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$HOME/google-cloud-sdk/bin:$PATH"

set +e
sudo chown jenkins:jenkins /home/jenkins/.config
bash /netstore/users/jenkins/slave/setup.sh
set -e

TestsToRun=($TestCases)
cluster=`echo $JOB_NAME-$BUILD_NUMBER | tr A-Z a-z`
TAP="AllTests.tap"

if [ "$DEPLOY_TYPE" = "Source" ]; then
    export XLRGUIDIR=`pwd`/xcalar-gui
    cd docker
    make
    cd -
    if [ "$BUILD_TYPE" = "prod" ]; then
        cbuild ub14-build prod
    else
        cbuild ub14-build config
        cbuild ub14-build
    fi
    cbuild ub14-build package
    INSTALLER_PATH=`find build -type f -name 'xcalar-*-installer'`
fi

ret=`xcalar-infra/gce/gce-cluster.sh $INSTALLER_PATH $NUM_INSTANCES $cluster`

if [ "$NOTPREEMPTIBLE" != "1" ]; then
    ips=($(awk '/RUNNING/ {print $6}' <<< "$ret"))
else
    ips=($(awk '/RUNNING/ {print $5}' <<< "$ret"))
fi

TMPDIR="${TMPDIR:-/tmp/`id -un`}/$JOB_NAME/functests"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

cloudXccli() {
    cmd="gcloud compute ssh $cluster-1 -- \"/opt/xcalar/bin/xccli\""
    for arg in "$@"; do
        arg="${arg//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        cmd="$cmd \"$arg\""
    done
    $cmd
}


stopXcalar() {
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo /opt/xcalar/bin/xcalarctl stop-supervisor"
}

restartXcalar() {
    set +e
    stopXcalar
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo service xcalar start"
    for ii in $(seq 1 $NUM_INSTANCES ) ; do
        host="${cluster}-${ii}"
        gcloud compute ssh $host --zone us-central1-f -- "sudo /opt/xcalar/bin/xcalarctl status" 2>&1 | grep -q  "Usrnodes started"
        ret=$?
        numRetries=60
        try=0
        while [ $ret -ne 0 -a "$try" -lt "$numRetries" ]; do
            sleep 1s
            gcloud compute ssh $host --zone us-central1-f -- "sudo /opt/xcalar/bin/xcalarctl status" 2>&1 | grep -q "Usrnodes started"
            ret=$?
            try=$(( $try + 1 ))
        done
        if [ $ret -eq 0 ]; then
            echo "All nodes ready"
        else
            echo "Error while waiting for node $ii to come up"
            return 1
        fi
    done
    set -e
}

genSupport() {
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo /opt/xcalar/scripts/support-generate.sh"
}

funcstatsd() {
    local name="${1//::/_}"
    local status="$2"
    local gitsha="$3"
    if [ "$status" = "PASS" ]; then
        echo "prod.tests.${gitsha}.functests.${name}.${cluster//./_}.numRun:1|c" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${cluster//./_}.numPass:1|c" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${cluster//./_}.status:0|g" | nc -4 -w 5 -u $GRAPHITE 8125
    elif [ "$status" = "FAIL" ]; then
        echo "prod.tests.${gitsha}.functests.${name}.${cluster//./_}.numRun:1|c" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${cluster//./_}.numFail:1|c" | nc -4 -w 5 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${cluster//./_}.status:1|g" | nc -4 -w 5 -u $GRAPHITE 8125
    fi
}

startupDone() {
    for node in `gcloud compute instances list | grep $cluster | cut -d \  -f 1`; do
        gcloud compute ssh $node -- "sudo journalctl -r" | grep -q "Startup finished";
        ret=$?
        if [ "$ret" != "0" ]; then
            return $ret
        fi
    done
    return 0
}

try=0
while ! startupDone ; do
    echo "Waited $try seconds for Xcalar to come up"
    sleep 1
    try=$(( $try + 1 ))
    if [ "$try" -gt 180 ]; then
        echo "Timeout while waiting for Xcalar to come up"
        exit 1
    fi
done

stopXcalar
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "mkdir -p $XdbLocalSerDesPath"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "chmod +w $XdbLocalSerDesPath"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo chown -R xcalar:xcalar $XdbLocalSerDesPath"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo umount /mnt/xcalar"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo mount -o noac /mnt/xcalar"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster "echo \"$FuncTestParam\" | sudo tee -a /etc/xcalar/default.cfg"
restartXcalar
ret=$?
if [ "$ret" != "0" ]; then
    echo "Failed to bring Xcalar up"
    exit $ret
fi

sudo yum install -y nc

gitsha=`cloudXccli -c "version" | head -n1 | cut -d\  -f3 | cut -d- -f5`
echo "GIT SHA: $gitsha"

AllTests="$(cloudXccli -c 'functests list' | tail -n+2)"
NumTests="${#TestsToRun[@]}"
hostname=`hostname -f`

echo "1..$(( $NumTests * $NUM_ITERATIONS ))" | tee "$TAP"
set +e
anyfailed=0
for ii in `seq 1 $NUM_ITERATIONS`; do
    echo "Iteration $ii"
    jj=1

    for Test in "${TestsToRun[@]}"; do
        logfile="$TMPDIR/${hostname//./_}_${Test//::/_}_$ii.log"

        echo "Running $Test on $cluster ..."
        if cloudXccli -c version 2>&1 | grep 'Error'; then
           genSupport
           restartXcalar
           if cloudXccli -c version 2>&1 | grep 'Error'; then
               echo "Could not restart usrnodes after previous crash"
               exit 1
           fi
        fi
        time cloudXccli -c "functests run --allNodes --testCase $Test" 2>&1 | tee "$logfile"
        rc=${PIPESTATUS[0]}
        if [ $rc -ne 0 ]; then
            funcstatsd "$Test" "FAIL" "$gitsha"
            echo "not ok ${jj} - $Test-$ii" | tee -a $TAP
            anyfailed=1
        else
            if grep -q Error "$logfile"; then
                funcstatsd "$Test" "FAIL" "$gitsha"
                echo "Failed test output in $logfile at `date`"
                cat >&2 "$logfile"
                echo "not ok ${jj} - $Test-$ii"  | tee -a $TAP
                anyfailed=1
            else
                echo "Passed test at `date`"
                funcstatsd "$Test" "PASS" "$gitsha"
                echo "ok ${jj} - $Test-$ii"  | tee -a $TAP
            fi
        fi
        jj=$(( $jj + 1 ))
    done
done

if [ "$anyfailed" = "0" ]; then
    xcalar-infra/gce/gce-cluster-delete.sh $cluster || true
else
    echo "One or more tests failed"
    if cloudXccli -c version 2>&1 | grep -q 'Error'; then
         genSupport
    fi

    if [ "$LEAVE_ON_FAILURE" = "true" ]; then
        echo "As requested, cluster will not be cleaned up."
        echo "Run 'xcalar-infra/gce/gce-cluster-delete.sh ${cluster}' once finished."
    else
        xcalar-infra/gce/gce-cluster-delete.sh $cluster || true
    fi
fi

