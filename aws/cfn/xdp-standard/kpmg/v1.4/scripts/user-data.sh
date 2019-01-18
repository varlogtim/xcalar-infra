#!/bin/bash

echo >&2 "Starting user-data.sh"

set -x
LOGFILE=/var/log/user-data.log
touch $LOGFILE
chmod 0600 $LOGFILE
if [ -t 1 ]; then
  :
else
  exec > >(tee -a $LOGFILE |logger -t user-data -s 2>/dev/console) 2>&1
fi

eval $(ec2-tags -s -i)

while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        --nfs-mount) NFSMOUNT="$1"; shift;;
        --tag-key) TAG_KEY="$1"; shift;;
        --tag-value) TAG_VALUE="$1"; shift;;
        --s3bucket) S3BUCKET="$1"; shift;;
        --s3prefix) S3PREFIX="$1"; shift;;
        --bootstrap-expect) BOOTSTRAP_EXPECT="$1"; shift;;
        --license) test -z "$1" || LICENSE="$1"; shift;;
        --installer-url) test -z "$1" || INSTALLER_URL="$1"; shift;;
        --stack-name) STACK_NAME="$1"; shift;;
        --resource-id) RESOURCE_ID="$1"; shift;;
        *) echo >&2 "WARNING: Unknown command $cmd";;
    esac
done


RELEASE_NAME=$(rpm -qf /etc/system-release --qf '%{NAME}')
RELEASE_VERSION=$(rpm -qf /etc/system-release --qf '%{VERSION}')
case "$RELEASE_VERSION" in
    6|6*) OSID=el6;;
    7|7*) OSID=el7;;
    2018*) OSID=amzn1;;
    2) OSID=amzn2;;
    *) echo >&2 "ERROR: Unknown OS version $RELEASE_VERSION"; exit 1;;
esac

INSTANCE_ID=$(curl -sSf http://169.254.169.254/latest/meta-data/instance-id)
AVZONE=$(curl -sSf http://169.254.169.254/latest/meta-data/placement/availability-zone)
INSTANCE_TYPE=$(curl -sSf http://169.254.169.254/latest/meta-data/instance-type)
export AWS_DEFAULT_REGION="${AVZONE%[a-f]}"

export PATH=/opt/mssql-tools/bin:/opt/xcalar/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin:/opt/aws/bin
echo "export PATH=$PATH" > /etc/profile.d/path.sh

set +e
if [ -e /etc/ec2.env ]; then
    . /etc/ec2.env
fi

case "$AWS_DEFAULT_REGION" in
    us-east-1|us-west-2)
        test -n "$NFSMOUNT" || NFSMOUNT="netstore.${AWS_DEFAULT_REGION}.aws.xcalar.com:/"
        ;;
    *)
        echo >&2 "Region ${AWS_DEFAULT_REGION} is not supported properly!"
        test -n "$NFSMOUNT" || NFSMOUNT="netstore.${AWS_DEFAULT_REGION}.aws.xcalar.com:/"
        ;;
esac

if [ -n "$LICENSE" ]; then
    echo "$LICENSE" | base64 -d | gzip -dc >/etc/xcalar/XcalarLic.key
fi

touch /etc/xcalar/XcalarLic.key
chown xcalar:xcalar /etc/xcalar/XcalarLic.key

mkdir -p /netstore
if [ -n "$NFSMOUNT" ]; then
    #echo "${NFSMOUNT} /netstore efs defaults,_netdev 0	0" >>/etc/fstab
    echo "${NFSMOUNT} /netstore nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev 0 0" >>/etc/fstab
    mount /netstore
fi

if [ -n "$CLUSTERNAME" ]; then
    TAG_KEY=ClusterName
    TAG_VALUE=$CLUSTERNAME
elif [ -n "$AWS_CLOUDFORMATION_STACK_NAME" ]; then
    TAG_KEY=aws:cloudformation:stack-name
    TAG_VALUE=$AWS_CLOUDFORMATION_STACK_NAME
elif [ -n "$NAME" ]; then
    TAG_KEY=Name
    TAG_VALUE=$NAME
else
    echo >&2 "No valid tags found"
fi

XLRROOT=/var/opt/xcalar
if [ -n "$TAG_VALUE" ]; then
    CLUSTER_ID=$TAG_VALUE
    IPS=()
    while [ "${#IPS[@]}" -eq 0 ]; do
        if IPS=($(discover addrs provider=aws addr_type=private_v4 tag_key=$TAG_KEY tag_value=$TAG_VALUE region=$AWS_DEFAULT_REGION)); then
            break
        fi
        sleep 5
    done
    sleep 5
else
    CLUSTER_ID="xcalar-$(uuid-gen)"
    IPS=(localhost)
fi
NUM_INSTANCES="${#IPS[@]}"
if [ $NUM_INSTANCES -gt 1 ]; then
    XLRROOT=/mnt/xcalar
    mkdir -p /netstore/cluster/$CLUSTER_ID
    chown xcalar:xcalar /netstore/cluster/$CLUSTER_ID
    #echo "${NFSMOUNT}cluster/$CLUSTER_ID ${XLRROOT} efs  defaults,_netdev	0	0" >>/etc/fstab
    echo "${NFSMOUNT}cluster/$CLUSTER_ID ${XLRROOT} nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev 0 0" >>/etc/fstab

    mkdir -p ${XLRROOT}
    mount ${XLRROOT}
    if ! test -d ${XLRROOT}/jupyterNotebooks; then
        rsync -avzr /var/opt/xcalar/ ${XLRROOT}/
    fi
else
    XLRROOT=/var/opt/xcalar
    mkdir -p $XLRROOT
    chown xcalar:xcalar $XLRROOT
fi

/opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - ${IPS[@]} | sed 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath='${XLRROOT}'@g' | tee /etc/xcalar/default.cfg

if ! test -e $XLRROOT/config; then
    mkdir -m 0700 -p $XLRROOT/config
    chown xcalar:xcalar $XLRROOT $XLRROOT/config
fi
chmod 0700 $XLRROOT/config
cat > $XLRROOT/config/defaultAdmin.json<<EOF
{
  "username": "xdpadmin",
  "password": "9021834842451507407c09c7167b1b8b1c76f0608429816478beaf8be17a292b",
  "email": "info@xcalar.com",
  "defaultAdminEnabled": true
}
EOF
chmod 0600 $XLRROOT/config/defaultAdmin.json
chown -R xcalar:xcalar $XLRROOT $XLRROOT/config

if test -z "$XCE_XDBSERDESPATH"; then
    if test -d /ephemeral/data; then
        XCE_XDBSERDESPATH=/ephemeral/data/
        chmod 0777 $XCE_XDBSERDESPATH
    else
        XCE_XDBSERDESPATH=/var/opt/xcalar/
    fi
fi
XCE_CONFIG=${XCE_CONFIG:-/etc/xcalar/default.cfg}

sed -i '/^Constants.XdbLocalSerDesPath=/d' $XCE_CONFIG
echo "Constants.XdbLocalSerDesPath=$XCE_XDBSERDESPATH" >>$XCE_CONFIG
if ! test -d $XCE_XDBSERDESPATH; then
    mkdir -m 0777 -p $XCE_XDBSERDESPATH
fi
mkdir -p ${XLRROOT}/workbooks/
curl -sL https://s3.amazonaws.com/xcrepoe1/cfn/prod/v1.4/kpmg_20190114.tar.gz | tar zxvf - -C ${XLRROOT}/workbooks/ --keep-newer-files
chown -R xcalar:xcalar ${XLRROOT}/workbooks/
chkconfig xcalar on
service xcalar start
rc=$?

# test_db
echo >&2 "All done with user-data.sh"
exit $rc
