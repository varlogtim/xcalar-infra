#!/bin/bash

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

export VmProvider=${VmProvider:-GCE}
# XCE_LICENSE is Jenkins param to PoseidonStartCluster
# if not supplied, base on if it was checked as IS_RC in parent job SystemTestStart
if [ -z "$XCE_LICENSE" ]; then
    if [ "$IS_RC" = "true" ]; then
        XCE_LICENSE=$(cat $XLRDIR/src/data/XcalarLic.key.prod | gzip | base64 -w0)
    else
        XCE_LICENSE=$(cat $XLRDIR/src/data/XcalarLic.key | gzip | base64 -w0)
    fi
fi
export XCE_LICENSE="$XCE_LICENSE"

initClusterCmds() {
    if [ "$VmProvider" = "GCE" ]; then
        bash /netstore/users/jenkins/slave/setup.sh
    elif [ "$VmProvider" = "Azure" ]; then
        az login --service-principal -u http://Xcalar/Jenkins/SP -p /netstore/infra/jenkins/jenkins-sp.pem --tenant 7bbd3477-af8b-483b-bb48-92976a1f9dfb
    else
        echo "Unknown VmProvider $VmProvider"
        exit 1
    fi
}

startCluster() {
    local installer="$1"
    local numInstances="$2"
    local clusterName="$3"

    if [ "$VmProvider" = "GCE" ]; then
        # gce-cluster.sh will based xcalar license on an XCE_LICENSE env variable
        $XLRINFRADIR/gce/gce-cluster.sh "$installer" "$numInstances" "$clusterName"
        return $?
    elif [ "$VmProvider" = "Azure" ]; then
        # azure-cluster.sh bases xcalar license on what you supply to -k option
        $XLRINFRADIR/azure/azure-cluster.sh -i "$installer" -c "$numInstances" -n "$clusterName" -t "$INSTANCE_TYPE" -k "$XCE_LICENSE"
        return $?
    fi

    echo 2>&1 "Unknown VmProvider $VmProvider"
    return 1
}

# print hostname of each node in a cluster to stdout
# one line per node
getNodes() {
    if [ -z "$1" ]; then
        echo "Must provide a cluster to getNodes" >&2
        exit 1
    fi
    local cluster="$1"
    if [ "$VmProvider" = "GCE" ]; then
        gcloud compute instances list | grep $cluster | cut -d \  -f 1
        return ${PIPESTATUS[0]}
    elif [ "$VmProvider" = "Azure" ]; then
        $XLRINFRADIR/azure/azure-cluster-info.sh "$cluster" | awk '{print $0}' # goal here: should just be hostname
        return ${PIPESTATUS[0]}
    fi

    echo 2>&1 "Unknown VmProvider $VmProvider"
    return 1
}

# print IPs of each node in a cluster to stdout
getNodeIps() {
    if [ -z "$1" ]; then
        echo "Must provide a cluster to getNodeIps" >&2
        exit 1
    fi
    local cluster="$1"
    if [ "$VmProvider" = "GCE" ]; then
        # NOTPREEMPTIBLE Is Jenkins param in SystemStartTest; GCE vms created
        # with preemptible option have additional col in output
        if [ "$NOTPREEMPTIBLE" != "1" ]; then
            gcloud compute instances list | grep $cluster | awk '/RUNNING/ {print $6}'
            return ${PIPESTATUS[0]}
        else
            gcloud compute instances list | grep $cluster | awk '/RUNNING/ {print $5}'
            return ${PIPESTATUS[0]}
        fi
    elif [ "$VmProvider" = "Azure" ]; then
        # @TODO - Azure case to get IPs - what's below is for printing hostname
        $XLRINFRADIR/azure/azure-cluster-info.sh "$cluster" | awk '{print $0}' # goal here: col w/ IPs
        return ${PIPESTATUS[0]}
    fi

    echo 2>&1 "Unknown VmProvider $VmProvider"
    return 1

}

nodeSsh() {
    # cluster arg only required for Azure case
    if [ "$VmProvider" = "Azure" ] && [ -z "$1" ]; then
        echo "Must provide a cluster to nodeSsh for the Azure case" >&2
        exit 1
    fi
    if [ -z "$2" ]; then
        echo "Must provide a node as second arg to nodeSsh" >&2
        exit 1
    fi
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

# send ssh cmd to all nodes in a cluster
clusterSsh() {
    if [ -z "$1" ]; then
        echo "Must provide a cluster to clusterSsh" >&2
        exit 1
    fi
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
    if [ -z "$1" ]; then
        echo "Must provide a cluster to stopXcalar" >&2
        exit 1
    fi
    clusterSsh "$1" "sudo service xcalar stop-supervisor"
}

restartXcalar() {
    if [ -z "$1" ]; then
        echo "Must provide a cluster to restartXcalar" >&2
        exit 1
    fi
    local cluster="$1"
    set +e
    stopXcalar "$cluster"
    clusterSsh $cluster "sudo service xcalar start"
    local host
    for host in $(getNodes "$cluster"); do
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
    if [ -z "$1" ]; then
        echo "Must provide a cluster to genSupport" >&2
        exit 1
    fi
    clusterSsh "$1" "sudo /opt/xcalar/scripts/support-generate.sh"
}

startupDone() {
    if [ -z "$1" ]; then
        echo "Must provide a cluster to startupDone" >&2
        exit 1
    fi
    local cluster="$1"
    if [ "$VmProvider" = "GCE" ]; then
        local node
        for node in $(getNodes "$cluster"); do
            nodeSsh "$cluster" "$node" "sudo journalctl -r" | grep -q "Startup finished"
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
    if [ -z "$1" ]; then
        echo "Must provide a cluster to clusterDelete" >&2
        exit 1
    fi
    local cluster="$1"
    if [ "$VmProvider" = "GCE" ]; then
        $XLRINFRADIR/gce/gce-cluster-delete.sh "$cluster"
    elif [ "$VmProvider" = "Azure" ]; then
        $XLRINFRADIR/azure/azure-cluster-delete.sh "$cluster"
    else
        echo 2>&1 "Unknown VmProvider $VmProvider"
        exit 1
    fi
}

# print to stdout, the hostname of just the first node in <cluster>,
# from the list of getNodes <cluster>
getSingleNodeFromCluster() {
    if [ -z "$1" ]; then
        echo "Must specify cluster to getSingleNodeFromCluster" >&2
        exit 1
    fi
    echo $(getNodes "$1") | head -1
}

cloudXccli() {
    if [ -z "$1" ]; then
        echo "Must specify cluster to cloudXccli" >&2
        exit 1
    fi
    local cluster="$1"
    shift

    # only want to send to one node in the cluster
    local node=$(getSingleNodeFromCluster $cluster)
    local cmd="nodeSsh $cluster $node \"/opt/xcalar/bin/xccli\""
    local arg
    for arg in "$@"; do
        arg="${arg//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        cmd="$cmd \"$arg\""
    done
    $cmd
}

