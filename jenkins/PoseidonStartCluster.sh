#!/bin/bash

export PATH="$HOME/google-cloud-sdk/bin:$PATH"

set +e
sudo chown jenkins:jenkins /home/jenkins/.config
bash /netstore/users/jenkins/slave/setup.sh
set -e

installer="$INSTALLER_PATH"

cluster="$CLUSTER"

# Create new GCE instance(s)
ret=`gce/gce-cluster.sh $installer $NUM_INSTANCES $cluster`

if [ "$NOTPREEMPTIBLE" != "1" ]; then                                           
    ips=($(awk '/RUNNING/ {print $6":18552"}' <<< "$ret"))                      
else                                                                            
    ips=($(awk '/RUNNING/ {print $5":18552"}' <<< "$ret"))                      
fi   

echo "$ips"

stopXcalar() {
    gce/gce-cluster-ssh.sh $cluster "sudo /opt/xcalar/bin/xcalarctl stop-supervisor"
}

restartXcalar() {
    set +e
    stopXcalar
    gce/gce-cluster-ssh.sh $cluster "sudo service xcalar start"
    for ii in $(seq 1 $NUM_INSTANCES ) ; do
        host="${cluster}-${ii}"                                                                                                                                                                                                                                                                                                                                                                                               
        gcloud compute ssh $host --zone us-central1-f -- "sudo /opt/xcalar/bin/xcalarctl status" 2>&1 | grep -q  "Usrnodes started" 
        ret=$?
        numRetries=3600
        try=0
        while [ $ret -ne 0 -a "$try" -lt "$numRetries" ]; do
            sleep 1s
            gcloud compute ssh $host --zone us-central1-f -- "sudo /opt/xcalar/bin/xcalarctl status" 2>&1 | grep -q "Usrnodes started"
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
    gce/gce-cluster-ssh.sh $cluster "sudo /opt/xcalar/scripts/support-generate.sh"
}

startupDone() {
    for node in `gcloud compute instances list | grep $cluster | cut -d \  -f 1`; do
        gcloud compute ssh $node -- "sudo journalctl -r" | grep -q "Startup finished";
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

gce/gce-cluster-ssh.sh $cluster -- "sudo pip install google-cloud-storage"
gce/gce-cluster-ssh.sh $cluster -- "mkdir -p $XdbLocalSerDesPath"
gce/gce-cluster-ssh.sh $cluster -- "chmod +w $XdbLocalSerDesPath"
gce/gce-cluster-ssh.sh $cluster -- "sudo chown -R xcalar:xcalar $XdbLocalSerDesPath"
gce/gce-cluster-ssh.sh $cluster -- "sudo umount /mnt/xcalar"
gce/gce-cluster-ssh.sh $cluster -- "sudo mount -o noac /mnt/xcalar"
    
gce/gce-cluster-ssh.sh $cluster "echo \"$FuncTestParam\" | sudo tee -a /etc/xcalar/default.cfg"
restartXcalar
ret=$?
if [ "$ret" != "0" ]; then
    echo "Failed to bring Xcalar up"
    exit $ret
fi
