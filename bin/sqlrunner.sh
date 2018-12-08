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

usage()
{
    cat << EOF
    Runs randomized, multi-user SQL tests at scale in GCE.  Handles all
    configuration, cluster management and installation.

    Requires paswordless GCE ssh (see Xcalar/GCE wiki), eg:
        eval \`ssh-agent\`
        ssh-add -t0 ~/.ssh/google_compute_engine

    Example invocation:
        $myName -c ecohen-sqlrunner -I n1-standard-8 -n 3 -i /netstore/builds/byJob/BuildTrunk/2427/prod/xcalar-1.4.1-2427-installer -l ~/archive/xcelicense.lic -N -- -w 3 -s 1031 -IC -t test_xcTest -U test-admin@xcalar.com -P <password>

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
        -u              Use an existing cluster instead of creating one
        -x <instpath>   Path to Xcalar install directory on cluster
        -X <xlrpath>    Path to Xcalar root on cluster
EOF
}

while getopts "c:i:I:kn:Npr:St:ux:X:" opt; do
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
      u) optUseExisting=true;;
      x) optRemoteXlrDir="$OPTARG";;
      X) optRemoteXlrRoot="$OPTARG";;
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

rcmd() {
    args="$@"
    gcloud compute ssh $clusterLeadName --command "$args"
}

getNodeIp() {
    nodeNum=$1
    gcloud compute instances describe "$optClusterName-$nodeNum" \
        --format='value[](networkInterfaces.accessConfigs.natIP)' \
        | python -c 'import sys; print(eval(sys.stdin.readline())[0]);'
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
}

installDeps() {
    rcmd sudo yum install -y tmux nc gcc gcc-c++
    rcmd sudo "$optRemoteXlrDir/bin/pip" install gnureadline multiset jaydebeapi
    rcmd mkdir -p "$optRemotePwd"
    gcloud compute scp "$XLRDIR/src/sqldf/tests/test_jdbc.py" "$clusterLeadName:$optRemotePwd"
    gcloud compute scp "$XLRGUIDIR/assets/test/json/SQLTest.json" "$clusterLeadName:$optRemotePwd"

    gcloud compute scp "$XLRINFRADIR/misc/sqlrunner/jodbc.xml" "$clusterLeadName:/tmp"
    gcloud compute scp "$XLRINFRADIR/misc/sqlrunner/supervisor.conf" "$clusterLeadName:/tmp"

    rcmd sudo mv "/tmp/jodbc.xml" "$optRemoteXlrRoot/config"
    rcmd sudo mv "/tmp/supervisor.conf" "/etc/xcalar/"
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock reread || true
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock reload || true
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock restart xcalar:sqldf || true
    waitCmd "rcmd nc localhost 10000 </dev/null 2>/dev/null" $optTimeoutSec
}

runTest() {
    local results="$optRemotePwd/$optClusterName-${optNumNodes}nodes-$optInstanceType"
    rcmd "XLRDIR=$optRmoteXlrDir" "$optRemoteXlrDir/bin/python3" "$optRemotePwd/test_jdbc.py" \
        -p "$optRemotePwd" -o $results -n "$optNumNodes,$optInstanceType" $optsTestJdbc

    gcloud compute scp "$clusterLeadName:${results}*.json" "$optResultsPath"
}

destroyCluster() {
    if ! $optKeep
    then
        $XLRINFRADIR/gce/gce-cluster-delete.sh $optClusterName
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
    runTest
fi
