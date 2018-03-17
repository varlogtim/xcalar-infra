#!/bin/bash -x

git clean -fxd

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$HOME/google-cloud-sdk/bin:$PATH"
TAP="AllTests.tap"

set +e
sudo chown jenkins:jenkins /home/jenkins/.config
bash /netstore/users/jenkins/slave/setup.sh
set -e

# We need to build for xccli which is used by the systemTest
cmBuild clean
cmBuild config debug
cmBuild qa

installer=$INSTALLER_PATH
cluster=$CLUSTER

ret=`gcloud compute instances list | grep $cluster`

if [ "$NOTPREEMPTIBLE" != "1" ]; then                                           
    ips=($(awk '/RUNNING/ {print $6":18552"}' <<< "$ret"))                      
else                                                                            
    ips=($(awk '/RUNNING/ {print $5":18552"}' <<< "$ret"))                      
fi   

echo "$ips"

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

cloudXccli() {
    cmd="gcloud compute ssh $cluster-1 -- \"/opt/xcalar/bin/xccli\""
    for arg in "$@"; do
        arg="${arg//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        cmd="$cmd \"$arg\""
    done
    $cmd
}

funcstatsd() {
    local name="${1//::/_}"
    local status="$2"
    local gitsha="$3"
    if [ "$status" = "PASS" ]; then
        echo "prod.tests.${gitsha}.systemtests.${name}.${cluster//./_}.numRun:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.systemtests.${name}.${cluster//./_}.numPass:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.systemtests.${name}.${cluster//./_}.status:0|g" | nc -w 1 -u $GRAPHITE 8125
    elif [ "$status" = "FAIL" ]; then
        echo "prod.tests.${gitsha}.systemtests.${name}.${cluster//./_}.numRun:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.systemtests.${name}.${cluster//./_}.numFail:1|c" | nc -w 1 -u $GRAPHITE 8125
        echo "prod.tests.${gitsha}.systemtests.${name}.${cluster//./_}.status:1|g" | nc -w 1 -u $GRAPHITE 8125
    fi
}

genSupport() {
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo /opt/xcalar/scripts/support-generate.sh"
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

sudo yum install -y nc
cloudXccli -c "version"
gitsha=`cloudXccli -c "version" | head -n1 | cut -d\  -f3 | cut -d- -f5`
echo "GIT SHA: $gitsha"

# remove when bug 2670 fixed
hosts=$( IFS=$','; echo "${ips[*]}" )


source $XLRDIR/doc/env/xc_aliases
xcEnvEnter

echo "1..$NUM_ITERATIONS" | tee "$TAP"
set +e
for ii in `seq 1 $NUM_ITERATIONS`; do
    Test="$SYSTEM_TEST_CONFIG-$NUM_USERS"
    python "$XLRDIR/src/bin/tests/systemTests/runTest.py" -n $NUM_USERS -i $hosts -t $SYSTEM_TEST_CONFIG -w -c $XLRDIR/bin
    ret="$?"
    if [ "$ret" = "0" ]; then
        echo "Passed '$Test' at `date`"
        funcstatsd "$Test" "PASS" "$gitsha"
        echo "ok ${ii} - $Test-$ii"  | tee -a $TAP
    else
        genSupport
        funcstatsd "$Test" "FAIL" "$gitsha"
        echo "not ok ${ii} - $Test-$ii" | tee -a $TAP
        exit $ret
    fi
done
set -e

exit $ret
