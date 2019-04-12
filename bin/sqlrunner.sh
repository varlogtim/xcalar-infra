#!/bin/bash

# XXX: This needs to use clusterCmds.sh

set -e

myName=$(basename $0)

XLRINFRADIR=${XLRINFRADIR-$HOME/xcalar-infra}

optClusterName=""
optKeep=false
optUseExisting=false
optXcalarImage=""
optNumNodes=1
optRemoteXlrDir="/opt/xcalar"
optRemoteXlrRoot="/mnt/xcalar"
optRemotePwd="/tmp/test_jdbc"
optInstanceType="n1-standard-4"
optNoPreempt=0
optSetupOnly=false
optResultsPath="."
optTimeoutSec=$(( 10 * 60 ))
optEnableSpark=false
optBucket="sqlscaletest"
optHours=0

usage()
{
    cat << EOF
    Runs randomized, multi-user SQL tests at scale in GCE.  Handles all
    configuration, cluster management and installation.

    Requires paswordless GCE ssh (see Xcalar/GCE wiki), eg:
        eval \`ssh-agent\`
        ssh-add -t0 ~/.ssh/google_compute_engine

    Example invocation:
        $myName -c ecohen-sqlrunner -I n1-standard-8 -n 3 -i /netstore/builds/byJob/BuildTrunk/2707/prod/xcalar-2.0.0-2707-installer -N -d -- -w 1 -t test_tpch -s 1031 -U test-admin@xcalar.com -P welcome1
    All options following "--" are passed as-is to test_jdbc.py.

    Usage: $myName <options> -- <test_jdbc options>
        -c <name>       GCE cluster name
        -i <image>      Path to Xcalar installer image
        -I <type>       GCE instance type (eg n1-standard-8)
        -k              Leave cluster running on exit
        -l <license>    Path to Xcalar license
        -n <nodes>      Number of nodes in cluster
        -N              Disable GCE preemption
        -p <wdpath>     Remote working directory
        -r <results>    Directory to store perf results
        -S              Set up and configure cluster but skip SQL tests
        -t <timeout>    Cluster startup timeout (seconds)
        -T <hours>      Iterate test for at least this many hours
        -u              Use an existing cluster instead of creating one
        -x <instpath>   Path to Xcalar install directory on cluster
        -X <xlrpath>    Path to Xcalar root on cluster
        -b <bucket>     gcloud storage bucket
        -d              enable spark
EOF
}

while getopts "c:i:I:kn:Npr:St:T:ux:X:b:d" opt; do
  case $opt in
      c) optClusterName="$OPTARG";;
      i) optXcalarImage="$OPTARG";;
      I) optInstanceType="$OPTARG";;
      k) optKeep=true;;
      n) optNumNodes="$OPTARG";;
      N) optNoPreempt=1;;
      p) optRemotePwd="$OPTARG";;
      r) optResultsPath="$OPTARG";;
      S) optSetupOnly=true;;
      t) optTimeoutSec="$OPTARG";;
      T) optHours="$OPTARG";;
      u) optUseExisting=true;;
      x) optRemoteXlrDir="$OPTARG";;
      X) optRemoteXlrRoot="$OPTARG";;
      b) optBucket="$OPTARG";;
      d) optEnableSpark=true;;
      --) break;; # Pass all following to test_jdbc
      *) usage; exit 0;;
  esac
done

shift $(($OPTIND - 1))
optsTestJdbc="$@"

if [[ -z "$optClusterName" ]]
then
    echo "-c <clustername> required"
    exit 1
fi

# GCE requires lower case names
optClusterName=$(echo "$optClusterName" | tr '[:upper:]' '[:lower:]')
clusterLeadName="$optClusterName-1"

if [ "$IS_RC" = "true" ]; then
    prodLicense=`cat $XLRDIR/src/data/XcalarLic.key.prod | gzip | base64 -w0`
    export XCE_LICENSE="${XCE_LICENSE:-$prodLicense}"
else
    devLicense=`cat $XLRDIR/src/data/XcalarLic.key | gzip | base64 -w0`
    export XCE_LICENSE="${XCE_LICENSE:-$devLicense}"
fi

rcmdNode() {
    local nodeNum="$1"
    shift
    args="$@"
    gcloud compute ssh "$optClusterName-$nodeNum" --command "$args"
}

rcmd() {
    rcmdNode 1 "$@"
}

rcmdAll() {
    for nodeNum in $(seq 1 $optNumNodes)
    do
        rcmdNode $nodeNum "$@"
    done
}

gscpToNode() {
    local nodeNum="$1"
    local src="$2"
    local dst="$3"

    eval gcloud compute scp "$src" "$optClusterName-$nodeNum:$dst"
}

gscpTo() {
    local src="$1"
    local dst="$2"
    gscpToNode 1 "$src" "$dst"
}

gscpToAll() {
    local src="$1"
    local dst="$2"
    for nodeNum in $(seq 1 $optNumNodes)
    do
        gscpToNode $nodeNum "$src" "$dst"
    done
}

getNodeIp() {
    nodeNum=$1
    gcloud compute instances describe "$optClusterName-$nodeNum" \
        --format='value[](networkInterfaces.networkIP)' \
        | python -c 'import sys; print(eval(sys.stdin.readline())[0]);'
}

getSparkIp() {
    gcloud compute instances describe "$optClusterName-spark-m" \
        --format='value[](networkInterfaces.accessConfigs.natIP)' \
        | echo $(python -c 'import sys; print(eval(sys.stdin.readline())[0]);')
}

waitCmd() {
    local cmd="$1"
    local to="$2"
    local ct=1

    while ! eval $cmd
    do
        sleep 1
        local ct=$(( $ct + 1 ))
        echo "Waited $ct seconds for: $cmd"
        if [[ $ct -gt $to ]]
        then
            echo "Timed out waiting for: $cmd"
            exit 1
        fi
    done
}

createCluster() {
    if [[ ! -f "$optXcalarImage" ]]
    then
        echo "    -i <installerImagePath> required"
        echo "    Example: /netstore/builds/byJob/BuildStable/79/prod/xcalar-1.4.1-2413-installer"
        exit 1
    fi

    echo "Creating $optNumNodes node cluster $optClusterName"
    IMAGE="rhel-7" INSTANCE_TYPE=$optInstanceType NOTPREEMPTIBLE=$optNoPreempt \
        $XLRINFRADIR/gce/gce-cluster.sh "$optXcalarImage" $optNumNodes $optClusterName
    echo "Waiting for Xcalar start on $optNumNodes node cluster $optClusterName"

    waitCmd "rcmd $optRemoteXlrDir/bin/xccli -c version > /dev/null" $optTimeoutSec
    if $optEnableSpark
    then
        $XLRINFRADIR/bin/gce-dataproc.sh -c "$optClusterName-spark" -m $optInstanceType -n $(($optNumNodes - 1)) \
            -w $optInstanceType -b $optBucket -f "$optClusterName-port"
        SPARK_IP=$(getSparkIp)
    fi
}

installDeps() {
    rcmd sudo yum install -y tmux nc gcc gcc-c++
    rcmd sudo "$optRemoteXlrDir/bin/pip" install gnureadline multiset jaydebeapi
    # XXX: Fix in test_jdbc
    local imdTestDir="/opt/xcalar/src/sqldf/tests/IMDTest/"
    rcmd mkdir -p "$optRemotePwd"
    rcmd sudo mkdir -p "$imdTestDir"
    rcmd sudo chmod a+rwx "$imdTestDir"
    gscpTo "$XLRDIR/src/sqldf/tests/test_jdbc.py" "$optRemotePwd"
    gscpTo "$XLRGUIDIR/assets/test/json/*.json" "$optRemotePwd"
    gscpTo "$XLRDIR/src/sqldf/tests/IMDTest/*.json" "$imdTestDir"
    gscpTo "$XLRDIR/src/sqldf/tests/IMDTest/loadData.py" "$imdTestDir"

    gscpTo "$XLRINFRADIR/misc/sqlrunner/jodbc.xml" /tmp
    gscpTo "$XLRINFRADIR/misc/sqlrunner/supervisor.conf" /tmp
    gscpToAll "$XLRINFRADIR/misc/sqlrunner/LocalUtils.sh" /tmp
    rcmdAll echo "source /tmp/LocalUtils.sh >> $HOME/.bashrc"

    rcmd sudo mv "/tmp/jodbc.xml" "$optRemoteXlrRoot/config"
    rcmd sudo mv "/tmp/supervisor.conf" "/etc/xcalar/"
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock reread || true
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock reload || true
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock restart xcalar:sqldf || true
    if $optEnableSpark
    then
        waitCmd "rcmd 'nc $SPARK_IP 10000 </dev/null 2>/dev/null'" $optTimeoutSec
    fi
    waitCmd "rcmd 'nc localhost 10000 </dev/null 2>/dev/null'" $optTimeoutSec
}

dumpStats() {
    rcmdAll dumpNodeOSStats
    rcmd /opt/xcalar/bin/xccli -c top
}

runTest() {
    local testIter="$1"

    echo "######## Starting iteration $testIter ########"

    if $optEnableSpark
    then
        local results_spark="$optRemotePwd/$optClusterName-${optNumNodes}nodes-$optInstanceType-$testIter-spark"
        rcmd "XLRDIR=$optRemoteXlrDir" "$optRemoteXlrDir/bin/python3" "$optRemotePwd/test_jdbc.py" \
            -p "$optRemotePwd" -o $results_spark -n "$optNumNodes,$optInstanceType" -S $SPARK_IP --bucket "gs://$optBucket/" $optsTestJdbc --ignore-xcalar
        gcloud compute scp "$clusterLeadName:${results_spark}*.json" "$optResultsPath"
    fi

    local results_xcalar="$optRemotePwd/$optClusterName-${optNumNodes}nodes-$optInstanceType-$testIter"
    rcmd "XLRDIR=$optRemoteXlrDir" "$optRemoteXlrDir/bin/python3" "$optRemotePwd/test_jdbc.py" \
        -p "$optRemotePwd" -o $results_xcalar -n "$optNumNodes,$optInstanceType" $optsTestJdbc

    # IMD test doesn't generate a perf file
    gcloud compute scp "$clusterLeadName:${results_xcalar}*.json" "$optResultsPath" || true

    echo "######## Ending iteration $testIter ########"
}

destroyCluster() {
    if ! $optKeep
    then
        $XLRINFRADIR/gce/gce-cluster-delete.sh --all-disks $optClusterName
        if $optEnableSpark
        then
            $XLRINFRADIR/bin/gce-dataproc-delete.sh -c "$optClusterName-spark" -f "$optClusterName-port"
        fi
    fi
}

trap destroyCluster EXIT

if ! $optUseExisting
then
    createCluster
fi

installDeps

if ! $optSetupOnly
then
    testIter=0
    endTime=$(($(date +%s) + optHours * 60 * 60))

    dumpStats
    runTest $testIter
    dumpStats
    testIter=$((testIter + 1))

    while [[ "$(date +%s)" -lt "$endTime" ]]
    do
        echo "Current time: $(date +%s), End time: $endTime, remaining: $((endTime - $(date +%s)))"
        runTest $testIter
        dumpStats
        testIter=$((testIter + 1))
    done

fi
