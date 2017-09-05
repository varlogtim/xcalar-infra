bash /netstore/users/jenkins/slave/setup.sh

export XLRDIR=`pwd`
export PATH="$HOME/google-cloud-sdk/bin:$PATH"

set +e
sudo chown jenkins:jenkins /home/jenkins/.config
set -e

TestsToRun=($TestCases)
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

echo "Host *.us-west-2.compute.amazonaws.com
    User ec2-user
    IdentityFile "$AWS_PEM"
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR" > ~/.ssh/config

chmod 0600 ~/.ssh/config

if [ "$CLUSTER" = "" ]; then
    cluster=`echo $JOB_NAME-$BUILD_NUMBER | tr A-Z a-z`
    ret=`xcalar-infra/aws/aws-cloudformation.sh $INSTALLER_PATH $NUM_INSTANCES $cluster`

else
    cluster=$CLUSTER
fi

sleep 120

TMPDIR="${TMPDIR:-/tmp/`id -un`}/$JOB_NAME/functests"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

cloudXccli() {
    cmd="xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster singleNode \"/opt/xcalar/bin/xccli\""
    for arg in "$@"; do
        arg="${arg//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        cmd="$cmd \"$arg\""
    done
    $cmd
}

startupDone() {
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo journalctl -r | grep -q 'Startup finished'"
    ret=$?
    if [ "$ret" != "0" ]; then
        return $ret
    fi
    return 0
}

try=0
while ! startupDone ; do
    echo "Waited $try seconds for Xcalar to come up"
    sleep 2
    try=$(( $try + 1 ))
    if [ "$try" -gt 600 ]; then
        genSupport
        echo "Timeout while waiting for Xcalar to come up"
        if [ "$LEAVE_ON_FAILURE" = "true" ]; then
            echo "As requested, cluster will not be cleaned up."
            echo "Run 'xcalar-infra/aws/aws-cloudformation-delete.sh ${cluster}' once finished."
        else
            xcalar-infra/aws/aws-cloudformation-delete.sh $cluster || true
        fi
        exit 1
    fi
done

waitForUsrnodes() {
    set +e

    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo /opt/xcalar/bin/xcalarctl status 2>&1 | grep -q 'Usrnodes started'"

    ret=$?
    numRetries=600
    try=0

    while [ $ret -ne 0 -a "$try" -lt "$numRetries" ]; do
        sleep 1s
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo /opt/xcalar/bin/xcalarctl status 2>&1 | grep -q 'Usrnodes started'"
        ret=$?
        try=$(( $try + 1 ))
    done

    if [ $ret -eq 0 ]; then
        echo "All nodes ready"
        return 0
    else
        echo "Error while waiting for nodes to come up"
        return 1
    fi

    set -e
}

stopXcalar() {
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "sudo /opt/xcalar/bin/xcalarctl stop-supervisor"
}

restartXcalar() {
    set +e

    stopXcalar

    sleep 60

    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "sudo service xcalar start"

    set -e
}

genSupport() {
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "sudo /opt/xcalar/scripts/support-generate.sh"
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

waitForUsrnodes

stopXcalar

if [ "$CLUSTER" = "" ]; then
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "echo \"$FuncTestParam\" | sudo tee -a /etc/xcalar/default.cfg"
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "echo Constants.SendSupportBundle=true | sudo tee -a /etc/xcalar/default.cfg"
fi

restartXcalar

waitForUsrnodes

ret=$?
if [ "$ret" != "0" ]; then
    echo "Failed to bring Xcalar up"

    if [ "$LEAVE_ON_FAILURE" = "true" ]; then
        echo "As requested, cluster will not be cleaned up."
        echo "Run 'xcalar-infra/aws/aws-cloudformation-delete.sh ${cluster}' once finished."
    else
        xcalar-infra/aws/aws-cloudformation-delete.sh $cluster || true
    fi

    exit $ret
fi

gitsha=`cloudXccli -c "version" | head -n2 | cut -d\  -f3 | cut -d- -f5`
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
               if [ "$LEAVE_ON_FAILURE" = "true" ]; then
                   echo "As requested, cluster will not be cleaned up."
                   echo "Run 'xcalar-infra/aws/aws-cloudformation-delete.sh ${cluster}' once finished."
               else
                   xcalar-infra/aws/aws-cloudformation-delete.sh $cluster || true
               fi
               exit 1
           fi
        fi
        time cloudXccli -c "functests run --allNodes --testCase $Test" 2>&1 | tee "$logfile"
        rc=${PIPESTATUS[0]}
        if [ $rc -ne 0 ]; then
            funcstatsd "$Test" "FAIL" "$gitsha"
            echo "not ok1 ${jj} - $Test-$ii" | tee -a $TAP

            anyfailed=1
        else
            if grep -v 'No such file or directory' "$logfile" | grep -q Error; then
                funcstatsd "$Test" "FAIL" "$gitsha"
                echo "Failed test output in $logfile at `date`"
                cat >&2 "$logfile"
                echo "not ok2 ${jj} - $Test-$ii"  | tee -a $TAP
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
    xcalar-infra/aws/aws-cloudformation-delete.sh $cluster || true
else
    echo "One or more tests failed"
    genSupport

    if [ "$LEAVE_ON_FAILURE" = "true" ]; then
        echo "As requested, cluster will not be cleaned up."
        echo "Run 'xcalar-infra/aws/aws-cloudformation-delete.sh ${cluster}' once finished."
    else
        xcalar-infra/aws/aws-cloudformation-delete.sh $cluster || true
    fi
fi

rm -rf ~/.ssh/config

exit 0
