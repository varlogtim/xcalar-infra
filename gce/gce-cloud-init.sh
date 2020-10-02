metadata() { curl -fsL --connect-timeout 1 -H "Metadata-Flavor:Google" http://metadata.google.internal/computeMetadata/v1/"$1"; }
if ! NAME=$(metadata instance/name); then
  NAME=$(hostname -s)
fi
BASENAME="${NAME%-[0-9]*}"
if ! CLUSTER=$(metadata instance/attributes/cluster); then
  CLUSTER="$BASENAME"
fi

if ! COUNT=$(metadata instance/attributes/count); then
  COUNT=1
fi

LOCALCFG=/etc/xcalar/localcfg.cfg
CONFIG=/etc/xcalar/default.cfg

if [[ $COUNT -gt 1 ]]; then
	XLRROOT=/mnt/xcalar
	NODE_ID="${NAME#${BASENAME}-}"
	mkdir -p /mnt/nfs
	mount -t nfs -o defaults nfs:/srv/share/nfs/ /mnt/nfs
	mkdir -p /mnt/nfs/cluster/$CLUSTER
	umount /mnt/nfs
	sed -i '\@'$XLRROOT'@d' /etc/fstab
	echo "nfs:/srv/share/nfs/cluster/$CLUSTER $XLRROOT nfs defaults 0 0" >> /etc/fstab
	mkdir -p $XLRROOT
	mount $XLRROOT
	/opt/xcalar/scripts/genConfig.sh  /etc/xcalar/template.cfg - $(eval echo ${NAME%-[0-9]*}-{1..$COUNT}) > $LOCALCFG
else
	XLRROOT=/var/opt/xcalar
	NODE_ID=1
	/opt/xcalar/scripts/genConfig.sh  /etc/xcalar/template.cfg - $NAME > $LOCALCFG
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
