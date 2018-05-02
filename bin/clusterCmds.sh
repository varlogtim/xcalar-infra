#!/bin/bash

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

export VmProvider=${VmProvider:-GCE}
devLicense=`cat $XLRDIR/src/data/XcalarLic.key | gzip | base64 -w0`
export XCE_LICENSE="${XCE_LICENSE:-$devLicense}"

initClusterCmds() {
    if [ "$VmProvider" = "GCE" ]; then
        bash /netstore/users/jenkins/slave/setup.sh
    elif [ "$VmProvider" = "Azure" ]; then
        az login --service-principal -u http://Xcalar/Jenkins/SP -p /netstore/infra/jenkins/jenkins-sp.pem --tenant 7bbd3477-af8b-483b-bb48-92976a1f9dfb
    else
        echo "Unknown VmProvider $VmProvider"
        exit 1
    fi

    pip install -U awscli
}

startCluster() {
    local installer="$1"
    local numInstances="$2"
    local clusterName="$3"

    if [ "$VmProvider" = "GCE" ]; then
        local rawOutput=`$XLRINFRADIR/gce/gce-cluster.sh "$installer" "$numInstances" "$clusterName"`
        local ret=$?

        if [ "$NOTPREEMPTIBLE" != "1" ]; then
            ips=($(awk '/RUNNING/ {print $6":18552"}' <<< "$rawOutput"))
        else
            ips=($(awk '/RUNNING/ {print $5":18552"}' <<< "$rawOutput"))
        fi

        return $ret
    elif [ "$VmProvider" = "Azure" ]; then
        $XLRINFRADIR/azure/azure-cluster.sh -i "$installer" -c "$numInstances" -n "$clusterName" -t "$INSTANCE_TYPE" -k "$XCE_LICENSE"
        local ret=$?
        local rawOutput=`$XLRINFRADIR/azure/azure-cluster-info.sh "$clusterName"`
        ips=($(awk '{print $0":18552"}' <<< "$rawOutput"))
        return $ret
    fi

    return 1
}

getNodes() {
    local cluster="$1"
    shift
    if [ "$VmProvider" = "GCE" ]; then
        gcloud compute instances list | grep $cluster | cut -d \  -f 1
        return ${PIPESTATUS[0]}
    else
        $XLRINFRADIR/azure/azure-cluster-info.sh "$cluster"
        return $?
    fi

    echo 2>&1 "Unknown VmProvider $VmProvider"
    return 1
}

nodeSsh() {
    local cluster="$1"
    local node="$2"
    shift 2
    if [ "$VmProvider" = "GCE" ]; then
        gcloud compute ssh --ssh-flag=-tt "$node" --zone us-central1-f -- "$@"
        return $?
    elif [ "$VmProvider" = "Azure" ]; then
        $XLRINFRADIR/azure/azure-cluster-ssh.sh -c "$cluster" -n "$node" -- "$@"
        return $?
    fi

    echo 2>&1 "Unknown VmProvider $VmProvider"
    return 1
}

clusterSsh() {
    local cluster="$1"
    shift
    if [ "$VmProvider" = "GCE" ]; then
        $XLRINFRADIR/gce/gce-cluster-ssh.sh "$cluster" "$@"
        return $?
    elif [ "$VmProvider" = "Azure" ]; then
        $XLRINFRADIR/azure/azure-cluster-ssh.sh -c "$cluster" -- "$@"
        return $?
    fi

    echo "Unknown VmProvider $VmProvider"
    return 1
}

stopXcalar() {
    clusterSsh $cluster "sudo service xcalar stop-supervisor"
}

restartXcalar() {
    set +e
    stopXcalar
    clusterSsh $cluster "sudo service xcalar start"
    for ii in $(seq 1 $NUM_INSTANCES ) ; do
        local host="${cluster}-${ii}"
        nodeSsh "$cluster" "$host" "sudo service xcalar status" 2>&1 | grep -q  "Usrnodes started"
        local ret=$?
        local numRetries=3600
        local try=0
        while [ $ret -ne 0 -a "$try" -lt "$numRetries" ]; do
            sleep 1s
            nodeSsh "$cluster" "$host" "sudo service xcalar status" 2>&1 | grep -q "Usrnodes started"
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
    clusterSsh $cluster "sudo /opt/xcalar/scripts/support-generate.sh"
}

startupDone() {
    if [ "$VmProvider" = "GCE" ]; then
        for node in `getNodes "$cluster"`; do
            nodeSsh "$cluster" "$node" "sudo journalctl -r" | grep -q "Startup finished";
            ret=$?
            if [ "$ret" != "0" ]; then
                return $ret
            fi
        done
        return 0
    elif [ "$VmProvider" = "Azure" ]; then
        # azure-cluster.sh is synchronous. When it returns, either it has run to completion or failed
        return 0
    fi

    echo "Unknown VmProvider $VmProvider"
    return 1
}

clusterDelete() {
    local cluster="$1"
    shift

    if [ "$VmProvider" = "GCE" ]; then
        $XLRINFRADIR/gce/gce-cluster-delete.sh "$cluster"
    elif [ "$VmProvider" = "Azure" ]; then
        $XLRINFRADIR/azure/azure-cluster-delete.sh "$cluster"
    else
        echo 2>&1 "Unknown VmProvider $VmProvider"
        exit 1
    fi
}

cloudXccli() {
    local cluster="$1"
    shift

    cmd="nodeSsh $cluster $cluster-1 -- \"/opt/xcalar/bin/xccli\""
    for arg in "$@"; do
        arg="${arg//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        cmd="$cmd \"$arg\""
    done
    $cmd
}

