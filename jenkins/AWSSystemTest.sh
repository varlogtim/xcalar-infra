export XLRDIR=`pwd`

export PATH=$PATH:"$XLRDIR/bin"

sudo sysctl -w net.ipv4.tcp_keepalive_time=60 net.ipv4.tcp_keepalive_intvl=30 net.ipv4.tcp_keepalive_probes=100

if $BUILD; then
    build clean
    build config
    build
fi

if [ -n "$INSTALLER_PATH" ]; then
    installer=$INSTALLER_PATH
else
    export XLRGUIDIR=`pwd`/xcalar-gui
    cd docker
    make
    cd -
    cbuild el7-build prod
    cbuild el7-build package
    installer=`find build -type f -name 'xcalar-*-installer'`
fi


cluster=`echo $JOB_NAME-$BUILD_NUMBER | tr A-Z a-z`

if ! uname -a | grep -i ubuntu; then
        # XXX Remove
        sudo yum -y install sshpass-1.06-1.el7.x86_64

        sudo yum -y install awscli-1.11.90-1.el7.noarch
else
        sudo aptitude -y install sshpass
    sudo aptitude -y install awscli
fi

# XXX Remove below 2 lines
rm -rf xcalar-infra
sshpass -p rkadam git clone ssh://rkadam@kalam/home/rkadam/xcalar-infra/

#rm -rf ~/.aws
#mkdir ~/.aws

#cp xcalar-infra/aws/config ~/.aws/
#cp xcalar-infra/aws/credentials ~/.aws/

ret=`xcalar-infra/aws/aws-cloudformation.sh $INSTALLER_PATH $NUM_INSTANCES $cluster`

sleep 120

if [ "$NOTPREEMPTIBLE" != "1" ]; then
    ips=($(awk '/RUNNING/ {print $6":18552"}' <<< "$ret"))
else
    ips=($(awk '/RUNNING/ {print $5":18552"}' <<< "$ret"))
fi

echo "$ips"

cloudXccli() {
    cmd="xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster singleNode \"/opt/xcalar/bin/xccli\""
    for arg in "$@"; do
        arg="${arg//\\/\\\\}"
        arg="${arg//\"/\\\"}"
        cmd="$cmd \"$arg\""
    done
    $cmd
}

startupDone() {
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo journalctl -r | grep -q 'Startup finished'"
    ret=$?
    if [ "$ret" != "0" ]; then
        return $ret
    fi
    return 0
}

waitForUsrnodes() {
        set +e

        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo /opt/xcalar/bin/xcalarctl status 2>&1 | grep -q 'Usrnodes started'"
        ret=$?
    numRetries=180
    try=0
    while [ $ret -ne 0 -a "$try" -lt "$numRetries" ]; do
        sleep 1s
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo /opt/xcalar/bin/xcalarctl status 2>&1 | grep -q 'Usrnodes started'"
        ret=$?
        try=$(( $try + 1 ))
    done

        if [ $ret -eq 0 ]; then
        echo "All nodes ready"
        return 0
    else
        echo "Error while waiting for nodes to come up"
        return 1
    fi

    set +e

}

stopXcalar() {
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "sudo /opt/xcalar/bin/xcalarctl stop-supervisor"
}

restartXcalar() {
    set +e

    stopXcalar

    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "echo Constants.SendSupportBundle=true | sudo tee -a /etc/xcalar/default.cfg"

    sleep 60

    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "sudo service xcalar start"

    set -e
}

genSupport() {
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "sudo /opt/xcalar/scripts/support-generate.sh"
}

mountSsd() {
    # XXX check if /dev/xvdb is present
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo cat /sys/block/xvdb/queue/discard_max_bytes"
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo mkfs.ext4 -E nodiscard /dev/xvdb"
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo chown -R ec2-user:ec2-user /ssd"
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "echo /dev/xvdb /ssd ext4 defaults,nofail,noatime,discard 0 2 | sudo tee -a /etc/fstab"
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo mount /ssd"
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo mkdir -p /ssd/xdbser"
    xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "sudo chmod -R 777 /ssd"
        xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "runClusterCmd" "echo Constants.XdbLocalSerDesPath=/ssd/xdbser | sudo tee -a /etc/xcalar/default.cfg"
}

try=0
while ! startupDone ; do
    echo "Waited $try seconds for Xcalar to come up"
    sleep 2
    try=$(( $try + 1 ))
    if [ "$try" -gt 600 ]; then
        echo "Timeout while waiting for Xcalar to come up"
        exit 1
    fi
done

waitForUsrnodes

mountSsd

restartXcalar

waitForUsrnodes

host=$(xcalar-infra/aws/aws-cloudformation-ssh.sh $cluster "host")

set +e
python "$XLRDIR/src/bin/tests/systemTests/runTest.py" -n 1 -i "$host":18552 -t gce52Config -w --serial
ret="$?"

xcalar-infra/aws/aws-cloudformation-ssh.sh "$cluster" runClusterCmd "/opt/xcalar/bin/xccli -c 'stats 0'"
xcalar-infra/aws/aws-cloudformation-ssh.sh "$cluster" runClusterCmd "/opt/xcalar/bin/xccli -c 'stats 1'"

if [ $ret -eq 0 ]; then
        xcalar-infra/aws/aws-cluster-delete.sh $cluster || true
    if [ "$cluster" != "" ]; then
        #gcloud compute ssh graphite -- "sudo rm -rf /srv/grafana-graphite/data/whisper/collectd/$cluster"
        echo "graphite"
    fi
else
    genSupport
    echo "One or more tests failed"
        if [ "$LEAVE_ON_FAILURE" = "true" ]; then
                echo "As requested, cluster will not be cleaned up."
                echo "Run 'xcalar-infra/aws/aws-cloudformation-delete.sh ${cluster}' once finished."
        else
                xcalar-infra/aws/aws-cloudformation-delete.sh $cluster || true
        fi
fi

sudo sysctl -w net.ipv4.tcp_keepalive_time=7200 net.ipv4.tcp_keepalive_intvl=75 net.ipv4.tcp_keepalive_probes=9

exit $ret
