#!/bin/bash

export PATH="$HOME/google-cloud-sdk/bin:$PATH"

set +e
sudo chown jenkins:jenkins /home/jenkins/.config
bash /netstore/users/jenkins/slave/setup.sh
set -e

TestsToRun=($TestCases)
TAP="AllTests.tap"

if [ "$NOTPREEMPTIBLE" != "1" ]; then                                           
    ips=($(awk '/RUNNING/ {print $6}' <<< "$ret"))                      
else                                                                            
    ips=($(awk '/RUNNING/ {print $5}' <<< "$ret"))                      
fi

TMPDIR="${TMPDIR:-/tmp/`id -un`}/$JOB_NAME/functests"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

cloudXccli() {
    cmd="gcloud compute ssh $CLUSTER-1 -- \"/opt/xcalar/bin/xccli\""
    for arg in "$@"; do
        arg="${arg//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        cmd="$cmd \"$arg\""
    done
    $cmd
}

stopXcalar() {
    gce/gce-cluster-ssh.sh $CLUSTER "sudo /opt/xcalar/bin/xcalarctl stop-supervisor"
}

restartXcalar() {
    set +e
    stopXcalar
    gce/gce-cluster-ssh.sh $CLUSTER "sudo service xcalar start"
    for ii in $(seq 1 $NUM_INSTANCES ) ; do
        host="${CLUSTER}-${ii}"                                                                                                                                                                                                                                                                                                                                                                                               
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
    gce/gce-cluster-ssh.sh $CLUSTER "sudo /opt/xcalar/scripts/support-generate.sh"
}

funcstatsd() {
    local name="${1//::/_}"
    local status="$2"
    local gitsha="$3"
    if [ "$status" = "PASS" ]; then
        echo "prod.tests.${gitsha}.functests.${name}.${CLUSTER//./_}.numRun:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${CLUSTER//./_}.numPass:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${CLUSTER//./_}.status:0|g" | nc -w 1 -u $GRAPHITE 8125
    elif [ "$status" = "FAIL" ]; then
        echo "prod.tests.${gitsha}.functests.${name}.${CLUSTER//./_}.numRun:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${CLUSTER//./_}.numFail:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.functests.${name}.${CLUSTER//./_}.status:1|g" | nc -w 1 -u $GRAPHITE 8125
    fi
}

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

        echo "Running $Test on $CLUSTER ..."
        if cloudXccli -c version 2>&1 | grep 'Error'; then
           genSupport
           echo "$CLUSTER Crashed"
           exit 1
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

exit $anyfailed

