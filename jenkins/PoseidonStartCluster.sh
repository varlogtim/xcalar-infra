#!/bin/bash

export PATH="$HOME/google-cloud-sdk/bin:/opt/xcalar/bin:$PATH"

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

set +e
chown jenkins:jenkins /home/jenkins/.config
source "$XLRINFRADIR/bin/clusterCmds.sh"
initClusterCmds
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