#!/bin/bash

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
optLicensePath=""
optNoPreempt=0
optSetupOnly=false

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
        -S              Set up and configure cluster but skip SQL tests
        -u              Use an existing cluster instead of creating one
        -x <instpath>   Path to Xcalar install directory on cluster
        -X <xlrpath>    Path to Xcalar root on cluster
EOF
}

while getopts "c:i:I:kl:n:NpSux:X:" opt; do
  case $opt in
      c) optClusterName="$OPTARG";;
      i) optXcalarImage="$OPTARG";;
      I) optInstanceType="$OPTARG";;
      k) optKeep=true;;
      l) optLicensePath="$OPTARG";;
      n) optNumNodes="$OPTARG";;
      N) optNoPreempt=1;;
      p) optRemotePwd="$OPTARG";;
      S) optSetupOnly=true;;
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

rcmd() {
    ssh $clusterLeadIp "$@"
}

getNodeIp() {
    nodeNum=$1
    gcloud compute instances describe "$optClusterName-$nodeNum" \
        --format='value[](networkInterfaces.accessConfigs.natIP)' \
        | python -c 'import sys; print(eval(sys.stdin.readline())[0]);'
}

createCluster() {
    if [[ ! -f "$optXcalarImage" ]]
    then
        echo "    -i <installerImagePath> required"
        echo "    Example: /netstore/builds/byJob/BuildStable/79/prod/xcalar-1.4.1-2413-installer"
        exit 1
    fi

    if [[ ! -f "$optLicensePath" ]]
    then
        echo "    -l <pathToXcalarLicense> required"
        exit 1
    fi

    echo "Creating $optNumNodes node cluster $optClusterName"
    IMAGE="rhel-7" INSTANCE_TYPE=$optInstanceType NOTPREEMPTIBLE=$optNoPreempt XCE_LICENSE=$(cat $optLicensePath) \
        $XLRINFRADIR/gce/gce-cluster.sh "$optXcalarImage" $optNumNodes $optClusterName
    echo "Waiting for Xcalar start on $optNumNodes node cluster $optClusterName"

    clusterLeadIp=$(getNodeIp 1)
    local ct=1
    while ! rcmd $optRemoteXlrDir/bin/xccli -c version > /dev/null
    do
        sleep 1
        echo "Waited $ct seconds for Xcalar to come up"
        local ct=$(( $ct + 1 ))
    done
}

installDeps() {
    rcmd sudo yum install -y tmux nc gcc gcc-c++
    rcmd sudo "$optRemoteXlrDir/bin/pip" install gnureadline multiset jaydebeapi
    rcmd mkdir -p "$optRemotePwd"
    scp "$XLRDIR/src/sqldf/tests/test_jdbc.py" "$clusterLeadIp:$optRemotePwd"
    scp "$XLRGUIDIR/assets/test/json/SQLTest.json" "$clusterLeadIp:$optRemotePwd"

    scp "$XLRINFRADIR/misc/sqlrunner/jodbc.xml" "$clusterLeadIp:/tmp"
    scp "$XLRINFRADIR/misc/sqlrunner/supervisor.conf" "$clusterLeadIp:/tmp"

    rcmd sudo mv "/tmp/jodbc.xml" "$optRemoteXlrRoot/config"
    rcmd sudo mv "/tmp/supervisor.conf" "/etc/xcalar/"
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock reread || true
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock reload || true
    rcmd sudo /opt/xcalar/bin/supervisorctl -s unix:///var/tmp/xcalar-root/supervisor.sock restart xcalar:sqldf || true
    local ct=1
    while ! rcmd nc localhost 10000 </dev/null 2>/dev/null
    do
        sleep 1
        echo "Waited $ct seconds for JDBC server to come up"
        local ct=$(( $ct + 1 ))
    done
}

runTest() {
    local results="$optRemotePwd/$optClusterName-${optNumNodes}nodes-$optInstanceType"
    rcmd "XLRDIR=$optRmoteXlrDir" "$optRemoteXlrDir/bin/python3" "$optRemotePwd/test_jdbc.py" \
        -p "$optRemotePwd" -o $results -n "$optNumNodes,$optInstanceType" $optsTestJdbc

    scp "$clusterLeadIp:${results}*.json" .
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

clusterLeadIp=$(getNodeIp 1)

installDeps

if ! $optSetupOnly
then
    runTest
fi