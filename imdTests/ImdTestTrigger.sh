#!/bin/bash -x

touch /tmp/${JOB_NAME}_${BUILD_ID}_START_TIME

export XLRDIR=/opt/xcalar
export PATH=$XLRDIR/bin:$PATH
export XCE_CONFIG=/etc/xcalar/default.cfg

restartXcalar() {
    sudo xcalar-infra/functests/launcher.sh $memAllocator
}

if [ $MemoryAllocator -eq 2 ]; then
    memAllocator=2
else
    memAllocator=0
fi

set +e
source doc/env/xc_aliases
xclean

set -e
sudo yum -y remove xcalar

sudo $INSTALLER_PATH --noStart

sudo rm $XCE_CONFIG
sudo -E $XLRDIR/scripts/genConfig.sh /etc/xcalar/template.cfg $XCE_CONFIG `hostname`

restartXcalar || true

if xccli -c version 2>&1 | grep -q 'Error'; then
    echo "Could not even start usrnodes after install"
    exit 1
fi

gitsha=`xccli -c "version" | head -n1 | cut -d\  -f3 | cut -d- -f5`
echo "GIT SHA: $gitsha"

##installing required python packages
sudo /opt/xcalar/bin/pip3.6 install psycopg2
sudo /opt/xcalar/bin/pip3.6 install faker

/opt/xcalar/bin/python3.6 xcalar-infra/imdTests/genIMD.py \
            --user $XCALAR_USER \
            --session "imdTests" --env $TARGET_ENV \
            --exportUrl $EXPORT_URL --bases \
            --updates --cube $CUBE_NAME \
            --numBaseRows $NUM_BASE_ROWS \
            --numUpdateRows $NUM_UPDATE_ROWS \
            --numUpdates $NUM_UPDATES \
            --updateSleep $UPDATE_SLEEP

sudo pkill -9 usrnode
sudo pkill -9 childnode
sudo pkill -9 xcmonitor
sudo pkill -9 xcmgmtd
sleep 60
