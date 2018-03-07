#!/bin/bash

export PATH="$HOME/google-cloud-sdk/bin:/opt/xcalar/bin:$PATH"

set +e
sudo chown jenkins:jenkins /home/jenkins/.config
bash /netstore/users/jenkins/slave/setup.sh
set -e

installer="$INSTALLER_PATH"

cluster="$CLUSTER"

# Create new GCE instance(s)
ret=`xcalar-infra/gce/gce-cluster.sh $installer $NUM_INSTANCES $cluster`

if [ "$NOTPREEMPTIBLE" != "1" ]; then                                           
    ips=($(awk '/RUNNING/ {print $6":18552"}' <<< "$ret"))                      
else                                                                            
    ips=($(awk '/RUNNING/ {print $5":18552"}' <<< "$ret"))                      
fi   

echo "$ips"

stopXcalar() {
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo /opt/xcalar/bin/xcalarctl stop-supervisor"
}

restartXcalar() {
    set +e
    stopXcalar
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo service xcalar start"
    for ii in $(seq 1 $NUM_INSTANCES ) ; do
        host="${cluster}-${ii}"                                                                                                                                                                                                                                                                                                                                                                                               
        gcloud compute ssh --ssh-flag=-tt $host --zone us-central1-f -- "sudo /opt/xcalar/bin/xcalarctl status" 2>&1 | grep -q  "Usrnodes started" 
        ret=$?
        numRetries=3600
        try=0
        while [ $ret -ne 0 -a "$try" -lt "$numRetries" ]; do
            sleep 1s
            gcloud compute ssh --ssh-flag=-tt $host --zone us-central1-f -- "sudo /opt/xcalar/bin/xcalarctl status" 2>&1 | grep -q "Usrnodes started"
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
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo /opt/xcalar/scripts/support-generate.sh"
}

startupDone() {
    for node in `gcloud compute instances list | grep $cluster | cut -d \  -f 1`; do
        gcloud compute ssh --ssh-flag=-tt $node -- "sudo journalctl -r" | grep -q "Startup finished";
        ret=$?
        if [ "$ret" != "0" ]; then
            return $ret
        fi
    done
    return 0
}

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

# Install gdb-8.0
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo yum install -y gcc-c++ wget texinfo screen emacs python-devel"
if [ "$InstallGdb8" = "true" ]; then
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "wget https://ftp.gnu.org/gnu/gdb/gdb-8.0.tar.gz"
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "tar -zxvf gdb-8.0.tar.gz"
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "cd gdb-8.0 && ./configure --with-python && make && sudo make install"
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo ln -s /usr/local/bin/gdb /usr/bin/gdb"
fi

# Install GCS
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo pip install google-cloud-storage"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "mkdir -p $XdbLocalSerDesPath"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "chmod +w $XdbLocalSerDesPath"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo chown -R xcalar:xcalar $XdbLocalSerDesPath"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo umount /mnt/xcalar"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo mount -o noac /mnt/xcalar"
if [ "$EnableXcMonitor" = "true" ]; then
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo sed -ie 's/XCE_MONITOR=0/XCE_MONITOR=1/' /etc/default/xcalar"
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo sed -ie 's/#XCE_MONITOR=1/XCE_MONITOR=1/' /etc/default/xcalar"
else
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo sed -ie 's/XCE_MONITOR=1/XCE_MONITOR=0/' /etc/default/xcalar"
    xcalar-infra/gce/gce-cluster-ssh.sh $cluster -- "sudo sed -ie 's/#XCE_MONITOR=0/XCE_MONITOR=0/' /etc/default/xcalar"
fi

xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo sed -ie 's/Constants.XcMonSlaveMasterTimeout=.*/Constants.XcMonSlaveMasterTimeout=$XcMonSlaveMasterTimeout/' /etc/xcalar/default.cfg"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo sed -ie 's/Constants.XcMonMasterSlaveTimeout=.*/Constants.XcMonMasterSlaveTimeout=$XcMonMasterSlaveTimeout/' /etc/xcalar/default.cfg"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster "echo \"$FuncTestParam\" | sudo tee -a /etc/xcalar/default.cfg"

xcalar-infra/gce/gce-cluster-ssh.sh $cluster "echo \"vm.min_free_kbytes=$KernelMinFreeKbytes\" | sudo tee -a /etc/sysctl.conf"
xcalar-infra/gce/gce-cluster-ssh.sh $cluster "sudo sysctl -p"

restartXcalar
ret=$?
if [ "$ret" != "0" ]; then
    echo "Failed to bring Xcalar up"
    exit $ret
fi

xcalar-infra/gce/gce-cluster-ssh.sh $cluster "echo \"XLRDIR=/opt/xcalar\" | sudo tee -a /etc/bashrc"
