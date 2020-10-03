#!/bin/bash

set -x

metadata() { curl -fsL --connect-timeout 1 -H "Metadata-Flavor:Google" http://metadata.google.internal/computeMetadata/v1/"$1"; }
attr() { metadata "instance/attributes/$1"; }

if ! NAME=$(metadata instance/name); then
  NAME=$(hostname -s)
fi
BASENAME="${NAME%-[0-9]*}"
if ! CLUSTER=$(attr cluster); then
  CLUSTER="$BASENAME"
fi

if ! COUNT=$(attr count); then
  COUNT=1
fi

if ! EPHEMERAL=$(attr ephemeral_disk); then
    EPHEMERAL=/ephemeral/data
fi

LOCALCFG=/etc/xcalar/localcfg.cfg
CONFIG=/etc/xcalar/default.cfg

if CONFIG_DATA="$(attr config)"; then
    echo "$CONFIG_DATA" > "$LOCALCFG"
fi

if [[ $COUNT -gt 1 ]]; then
	XLRROOT=/mnt/xcalar
	NODE_ID="${NAME#${BASENAME}-}"

    if ! NFS_SHARE=$(attr nfs); then
        mkdir -p /mnt/nfs
        mount -t nfs -o defaults nfs:/srv/share/nfs/ /mnt/nfs
        mkdir -p /mnt/nfs/cluster/$CLUSTER
        umount /mnt/nfs
        NFS_SHARE=nfs:/srv/share/nfs/cluster/$CLUSTER
    fi

	sed -i '\@'$XLRROOT'@d' /etc/fstab
	echo "$NFS_SHARE $XLRROOT nfs defaults,nofail 0 0" >> /etc/fstab
	mkdir -p $XLRROOT
	mount $XLRROOT
	if ! test -e "$LOCALCFG"; then
        /opt/xcalar/scripts/genConfig.sh  /etc/xcalar/template.cfg - $(eval echo ${NAME%-[0-9]*}-{1..$COUNT}) > $LOCALCFG
    fi
else
	XLRROOT=/var/opt/xcalar
	NODE_ID=1
	if ! test -e "$LOCALCFG"; then
        /opt/xcalar/scripts/genConfig.sh  /etc/xcalar/template.cfg - $NAME > $LOCALCFG
    fi
fi
if ((EPHEMERAL)); then
    sed -i 'd/SWAP/' /etc/sysconfig/ephemeral-disk
    echo 'LV_SWAP_SIZE=MEMSIZE' >> /etc/sysconfig/ephemeral-disk
    ephemeral-disk
    # Constants.XcalarRootCompletePath=/mnt/xcalar
    # Constants.XdbSerDesMode=2
    # Constants.XdbMaxPagingFileSize=0
    # Constants.XcalarLogCompletePath=/var/log/xcalar
    # Constants.XdbLocalSerDesPath=/ephemeral/data/serdes
    # Constants.SendSupportBundle=true
    # Constants.IncludeTopStats=true
    # Constants.XdbSerDesMaxDiskMB=77357
    # Constants.RuntimePerfPort=6000
fi
if mountpoint -q $EPHEMERAL; then
    SERDES=$EPHEMERAL/serdes
    mkir -m 1777 $SERDES
else
    sed -i '/XdbSerDes/d; /XdbLocalSerDes/d' $LOCALCFG
fi

sed -i "s,Constants.XcalarRootCompletePath=.*$,Constants.XcalarRootCompletePath=$XLRROOT," $LOCALCFG
chown xcalar:xcalar $LOCALCFG
ln -sfn $LOCALCFG $CONFIG

if [[ $NODE_ID -eq 1 ]]; then
  mkdir -m 0700 -p $XLRROOT/config || true
  echo '{"username": "xdpadmin",  "password": "9021834842451507407c09c7167b1b8b1c76f0608429816478beaf8be17a292b",  "email": "info@xcalar.com",  "defaultAdminEnabled": true}' > $XLRROOT/config/defaultAdmin.json
  chmod 0600 $XLRROOT/config/defaultAdmin.json
fi

until test -e $XLRROOT/config/defaultAdmin.json; do
	sleep 3
	echo >&2 "Waiting for defaultAdmin ..."
done

systemctl start xcalar
