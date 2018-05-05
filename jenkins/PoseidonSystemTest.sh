#!/bin/bash -x

git clean -fxd

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$HOME/google-cloud-sdk/bin:$PATH"
TAP="AllTests.tap"

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

set +e
sudo chown jenkins:jenkins /home/jenkins/.config
source "$XLRINFRADIR/bin/clusterCmds.sh"
initClusterCmds
set -e

# We need to build for xccli which is used by the systemTest
cmBuild clean
cmBuild config debug
cmBuild qa

installer=$INSTALLER_PATH
cluster=$CLUSTER

if [ "$VmProvider" = "GCE" ]; then
    ret=`gcloud compute instances list | grep $cluster`

    if [ "$NOTPREEMPTIBLE" != "1" ]; then
        ips=($(awk '/RUNNING/ {print $6":18552"}' <<< "$ret"))
    else
        ips=($(awk '/RUNNING/ {print $5":18552"}' <<< "$ret"))
    fi
elif [ "$VmProvider" = "Azure" ]; then
    ret=`getNodes "$cluster"`
    ips=($(awk '{print $0":18552"}' <<< "$ret"))
else
    echo 2>&1 "Unknown VmProvider $VmProvider"
    exit 1
fi

echo "${ips[*]}"

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

export http_proxy=

sudo sysctl -w net.ipv4.tcp_keepalive_time=60 net.ipv4.tcp_keepalive_intvl=30 net.ipv4.tcp_keepalive_probes=100

sudo yum install -y nc
cloudXccli "$cluster" -c "version"
gitsha=`cloudXccli "$cluster" -c "version" | head -n1 | cut -d\  -f3 | cut -d- -f5`
echo "GIT SHA: $gitsha"

# remove when bug 2670 fixed
hosts=$( IFS=$','; echo "${ips[*]}" )

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
