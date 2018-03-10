#!/bin/bash

export PATH="$HOME/google-cloud-sdk/bin:/opt/xcalar/bin:$PATH"
VmProvider=${VmProvider:-GCE}

startCluster() {
    local installer="$1"
    local numInstances="$2"
    local clusterName="$3"

    if [ "$VmProvider" = "GCE" ]; then
        ret=`xcalar-infra/gce/gce-cluster.sh "$installer" "$numInstances" "$clusterName"`

        if [ "$NOTPREEMPTIBLE" != "1" ]; then
            ips=($(awk '/RUNNING/ {print $6":18552"}' <<< "$ret"))
        else
            ips=($(awk '/RUNNING/ {print $5":18552"}' <<< "$ret"))
        fi

        return $?
    elif [ "$VmProvider" = "Azure" ]; then
        xcalar-infra/azure/azure-cluster.sh -i "$installer" -c "$numInstances" -n "$clusterName" -t "$INSTANCE_TYPE"
        ret=$?
        ips=`xcalar-infra/azure/azure-cluster-info.sh "$clusterName"`
        return $?
    fi

    return 1
}

getNodes() {
    cluster="$1"
    shift
    if [ "$VmProvider" = "GCE" ]; then
        gcloud compute instances list | grep $cluster | cut -d \  -f 1
        return $?
    else
        xcalar-infra/azure/azure-cluster-info.sh "$cluster"
        return $?
    fi

    echo 2>&1 "Unknown VmProvider $VmProvider"
}

nodeSsh() {
    cluster="$1"
    node="$2"
    shift 2
    if [ "$VmProvider" = "GCE" ]; then
        gcloud compute ssh --ssh-flag=-tt "$node" --zone us-central1-f -- "$@"
        return $?
    elif [ "$VmProvider" = "Azure" ]; then
        xcalar-infra/azure/azure-cluster-ssh.sh -c "$cluster" -n "$node" -- "$@"
        return $?
    fi

    echo 2>&1 "Unknown VmProvider $VmProvider"
    return 1
}

clusterSsh() {
    cluster="$1"
    shift
    if [ "$VmProvider" = "GCE" ]; then
        xcalar-infra/gce/gce-cluster-ssh.sh "$cluster" "$@"
        return $?
    elif [ "$VmProvider" = "Azure" ]; then
        xcalar-infra/azure/azure-cluster-ssh.sh -c "$cluster" -- "$@"
        return $?
    fi

    echo "Unknown VmProvider $VmProvider"
    return 1
}

stopXcalar() {
    clusterSsh $cluster "sudo /opt/xcalar/bin/xcalarctl stop-supervisor"
}

restartXcalar() {
    set +e
    stopXcalar
    clusterSsh $cluster "sudo service xcalar start"
    for ii in $(seq 1 $NUM_INSTANCES ) ; do
        host="${cluster}-${ii}"
        nodeSsh "$cluster" "$host" "sudo /opt/xcalar/bin/xcalarctl status" 2>&1 | grep -q  "Usrnodes started" 
        ret=$?
        numRetries=3600
        try=0
        while [ $ret -ne 0 -a "$try" -lt "$numRetries" ]; do
            sleep 1s
            nodeSsh "$cluster" "$host" "sudo /opt/xcalar/bin/xcalarctl status" 2>&1 | grep -q "Usrnodes started"
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

set +e
chown jenkins:jenkins /home/jenkins/.config

if [ "$VmProvider" = "GCE" ]; then
    bash /netstore/users/jenkins/slave/setup.sh
elif [ "$VmProvider" = "Azure" ]; then
    /usr/bin/az login --service-principal -u  5d35339e-4b1f-494e-840d-70aaa6910fd0  -p $(cat /netstore/infra/jenkins/jenkins-sp.txt) -t 7bbd3477-af8b-483b-bb48-92976a1f9dfb >/dev/null
else
    echo "Unknown VmProvider $VmProvider"
    exit 1
fi

pip install -U awscli

set -e

installer="$INSTALLER_PATH"

cluster="$CLUSTER"

ips=""
startCluster "$installer" "$NUM_INSTANCES" "$cluster"
ret=$?
if [ "$ret" != "0" ]; then
    exit $ret
fi

echo "$ips"

try=0
while ! startupDone ; do
    echo "Waited $try seconds for Xcalar to come up"
    sleep 1
    try=$(( $try + 1 ))
    if [[ $try -gt 3600 ]]; then
        echo "Timeout waiting for Xcalar to come up"
        exit 1
     fi
done

stopXcalar

clusterSsh $cluster -- "sudo yum install -y gcc-c++ wget texinfo screen emacs python-devel"

# Install gdb-8.0
if [ "$InstallGdb8" = "true" ]; then
    clusterSsh "$cluster" -- "sudo curl http://storage.googleapis.com/repo.xcalar.net/rpm-deps/xcalar-deps.repo -o /etc/yum.repos.d/xcalar-deps.repo"
    clusterSsh "$cluster" -- "sudo yum install -y optgdb8"
    clusterSsh "$cluster" -- "sudo ln -sfn /opt/gdb8/bin/gdb /usr/local/bin/gdb"
    clusterSsh "$cluster" -- "sudo ln -sfn /opt/gdb8/bin/gdb /usr/bin/gdb"
fi

# Set up SerDes
clusterSsh $cluster -- "mkdir -p $XdbLocalSerDesPath"
clusterSsh $cluster -- "chmod +w $XdbLocalSerDesPath"
clusterSsh $cluster -- "sudo chown -R xcalar:xcalar $XdbLocalSerDesPath"

# Remount xcalar with noac for liblog stress
#clusterSsh $cluster -- "sudo umount /mnt/xcalar"
#clusterSsh $cluster -- "sudo mount -o noac /mnt/xcalar"

clusterSsh $cluster "sudo sed -ie 's/Constants.XcMonSlaveMasterTimeout=.*/Constants.XcMonSlaveMasterTimeout=$XcMonSlaveMasterTimeout/' /etc/xcalar/default.cfg"
clusterSsh $cluster "sudo sed -ie 's/Constants.XcMonMasterSlaveTimeout=.*/Constants.XcMonMasterSlaveTimeout=$XcMonMasterSlaveTimeout/' /etc/xcalar/default.cfg"
clusterSsh $cluster "echo \"$FuncTestParam\" | sudo tee -a /etc/xcalar/default.cfg"

clusterSsh $cluster "echo \"vm.min_free_kbytes=$KernelMinFreeKbytes\" | sudo tee -a /etc/sysctl.conf"
clusterSsh $cluster "sudo sysctl -p"

restartXcalar
ret=$?
if [ "$ret" != "0" ]; then
    echo "Failed to bring Xcalar up"
    exit $ret
fi

clusterSsh $cluster "echo \"XLRDIR=/opt/xcalar\" | sudo tee -a /etc/bashrc"
