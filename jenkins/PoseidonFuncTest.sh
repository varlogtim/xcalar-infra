#!/bin/bash

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

set +e
sudo chown jenkins:jenkins /home/jenkins/.config
source "$XLRINFRADIR/bin/clusterCmds.sh"
initClusterCmds
set -e

TestsToRun=($TestCases)
TAP="AllTests.tap"

TMPDIR="${TMPDIR:-/tmp/`id -un`}/$JOB_NAME/functests"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

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

sudo sysctl -w net.ipv4.tcp_keepalive_time=60 net.ipv4.tcp_keepalive_intvl=30 net.ipv4.tcp_keepalive_probes=100

gitsha=`cloudXccli "$CLUSTER" -c "version" | head -n1 | cut -d\  -f3 | cut -d- -f5`
echo "GIT SHA: $gitsha"

AllTests="$(cloudXccli "$CLUSTER" -c 'functests list' | tail -n+2)"
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
        if cloudXccli "$CLUSTER" -c version 2>&1 | grep 'Error'; then
           genSupport
           echo "$CLUSTER Crashed"
           exit 1
        elif [ $anyfailed -eq 1 ]
        then
            # cluster is up but got non zero return code. This means that
            # the ssh connection is lost. In such cases, just drive on with the
            # next test after restarting the cluster
            restartXcalar
            anyfailed=0
        fi
        time cloudXccli "$CLUSTER" -c "functests run --allNodes --testCase $Test" 2>&1 | tee "$logfile"
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

