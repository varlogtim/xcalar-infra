#!/bin/bash

echo >&2 "Starting user-data.sh"

set -x
LOGFILE=/var/log/user-data.log
touch $LOGFILE
chmod 0600 $LOGFILE
if [ -t 1 ]; then
  :
else
  exec > >(tee -a $LOGFILE | logger -t user-data -s 2> /dev/console) 2>&1
fi

ec2_find_cluster() {
  aws ec2 describe-instances \
    --filters Name=tag:$1,Values=$2 Name=instance-state-name,Values=running \
    --query "Reservations[].Instances[].[AmiLaunchIndex,${3:-PrivateIpAddress}]" \
    --output text | sort -n | awk '{print $2}'
}

eval $(ec2-tags -s -i)

NFS_TYPE=nfs
NFS_OPTS="vers=4.0,_netdev,defaults"

while [ $# -gt 0 ]; do
  cmd="$1"
  shift
  case "$cmd" in
  --nfs-mount)
    NFSMOUNT="$1"
    shift
    ;;
  --nfs-type) NFS_TYPE="$1"; shift;;
  --nfs-opts) NFS_OPTS="$1"; shift;;
  --tag-key)
    TAG_KEY="$1"
    shift
    ;;
  --tag-value)
    TAG_VALUE="$1"
    shift
    ;;
  --s3bucket)
    S3BUCKET="$1"
    shift
    ;;
  --s3prefix)
    S3PREFIX="$1"
    shift
    ;;
  --bootstrap-expect)
    BOOTSTRAP_EXPECT="$1"
    shift
    ;;
  --license)
    test -z "$1" || LICENSE="$1"
    shift
    ;;
  --installer-url)
    test -z "$1" || INSTALLER_URL="$1"
    shift
    ;;
  --stack-name)
    STACK_NAME="$1"
    shift
    ;;
  --resource-id)
    RESOURCE_ID="$1"
    shift
    ;;
  *) echo >&2 "WARNING: Unknown command $cmd" ;;
  esac
done

RELEASE_NAME=$(rpm -qf /etc/system-release --qf '%{NAME}')
RELEASE_VERSION=$(rpm -qf /etc/system-release --qf '%{VERSION}')
case "$RELEASE_VERSION" in
6 | 6*) OSID=el6 ;;
7 | 7*) OSID=el7 ;;
2018*) OSID=amzn1 ;;
2) OSID=amzn2 ;;
*)
  echo >&2 "ERROR: Unknown OS version $RELEASE_VERSION"
  exit 1
  ;;
esac

INSTANCE_ID=$(curl -sSf http://169.254.169.254/latest/meta-data/instance-id)
AVZONE=$(curl -sSf http://169.254.169.254/latest/meta-data/placement/availability-zone)
INSTANCE_TYPE=$(curl -sSf http://169.254.169.254/latest/meta-data/instance-type)
export AWS_DEFAULT_REGION="${AVZONE%[a-f]}"

export PATH=/opt/mssql-tools/bin:/opt/xcalar/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/opt/aws/bin:/bin
echo "export PATH=$PATH" > /etc/profile.d/path.sh

set +e
if [ -e /etc/ec2.env ]; then
  . /etc/ec2.env
fi

if [ -z "$NFS_MOUNT" ]; then
    case "$AWS_DEFAULT_REGION" in
        us-east-1 | us-west-2) NFSMOUNT="netstore.${AWS_DEFAULT_REGION}.aws.xcalar.com:/";;
        *) echo >&2 "Region ${AWS_DEFAULT_REGION} is not supported properly!"; exit 1;;
    esac
fi

if ! rpm -q xcalar; then
  yum clean all --enablerepo='*'
  yum install -y unzip yum-utils epel-release patch
  yum install -y http://repo.xcalar.net/xcalar-release-${OSID}.rpm
  yum-config-manager --enable xcalar-deps xcalar-deps-common epel
  yum install -y jq amazon-efs-utils

  mkdir -p -m 0700 /var/lib/xcalar-installer
  cd /var/lib/xcalar-installer

  yum install -y xcalar-sqldf ## Workaround a packaging bug

  curl -L "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip" -o awscli-bundle.zip && unzip awscli-bundle.zip && ./awscli-bundle/install -i /opt/aws -b /usr/local/bin/aws
  yum install -y https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.amzn1.noarch.rpm
  yum install -y ephemeral-disk ec2tools --enablerepo='xcalar-deps'

  if rpm -q java-1.7.0-openjdk > /dev/null 2>&1; then
    yum remove -y java-1.7.0-openjdk || true
  fi

  sed -i -r 's/^(G|U)ID_MIN.*$/\1ID_MIN            1000/g' /etc/login.defs

  if test -e installer.sh; then
    mv installer.sh installer.sh.$$
  fi
  if [[ $INSTALLER_URL =~ ^http ]]; then
    curl -fL "$INSTALLER_URL" -o installer.sh
  elif [[ $INSTALLER_URL =~ s3:// ]]; then
    aws s3 cp "$INSTALLER_URL" installer.sh
  fi
  if [ $? -eq 0 ] && test -s installer.sh; then
    export ACCEPT_EULA=Y
    chmod 0700 installer.sh
    ./installer.sh --nostart 2>&1 | tee -a installer.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
      echo "Failed to install ${PWD}/installer.sh (from $INSTALLER_URL)"
      exit 1
    fi
  fi
fi

if [ -n "$LICENSE" ]; then
  if [[ $LICENSE =~ ^s3:// ]]; then
    aws s3 cp $LICENSE - | base64 -d | gzip -dc > /etc/xcalar/XcalarLic.key
  else
    echo "$LICENSE" | base64 -d | gzip -dc > /etc/xcalar/XcalarLic.key
  fi
fi

touch /etc/xcalar/XcalarLic.key
chown xcalar:xcalar /etc/xcalar/XcalarLic.key

if [ -n "$NFSMOUNT" ]; then
  mkdir -p /netstore
  echo "${NFSMOUNT} /netstore ${NFS_TYPE} ${NFS_OPTS} 0	0" >> /etc/fstab
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
  echo "${NFSMOUNT}cluster/$CLUSTER_ID ${XLRROOT} ${NFS_TYPE} ${NFS_OPTS} 0	0" >> /etc/fstab
  mkdir -p ${XLRROOT}
  mount ${XLRROOT}
  if ! test -d ${XLRROOT}/jupyterNotebooks; then
    rsync -avzr /var/opt/xcalar/ ${XLRROOT}/
  fi
  /opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - ${IPS[@]} | sed 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath='${XLRROOT}'@g' | tee /etc/xcalar/default.cfg
else
  XLRROOT=/var/opt/xcalar
  mkdir -p $XLRROOT
  chown xcalar:xcalar $XLRROOT
  /opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - localhost | tee /etc/xcalar/default.cfg
fi

mkdir -m 0700 -p $XLRROOT/config
chown xcalar:xcalar $XLRROOT $XLRROOT/config
chmod 0700 $XLRROOT/config
cat > $XLRROOT/config/defaultAdmin.json << EOF
{
  "username": "xdpadmin",
  "password": "9021834842451507407c09c7167b1b8b1c76f0608429816478beaf8be17a292b",
  "email": "info@xcalar.com",
  "defaultAdminEnabled": true
}
EOF
chmod 0600 $XLRROOT/config/defaultAdmin.json
chown -R xcalar:xcalar $XLRROOT $XLRROOT/config

XCE_XDBSERDESPATH=${XCE_XDBSERDESPATH:-/var/opt/xcalar/serdes/}
XCE_CONFIG=${XCE_CONFIG:-/etc/xcalar/default.cfg}

sed -i '/^Constants.XdbLocalSerDesPath=/d' $XCE_CONFIG
echo "Constants.XdbLocalSerDesPath=$XCE_XDBSERDESPATH" >> $XCE_CONFIG
mkdir -p $XCE_XDBSERDESPATH
chown xcalar:xcalar $XCE_XDBSERDESPATH
/etc/init.d/xcalar start
rc=$?

chkconfig xcalar on

#aws s3 cp s3://blim-export/queue_handler.py /usr/local/bin/queue_handler.py
#/opt/xcalar/bin/python3 /usr/local/bin/queue_handler.py  >> /var/log/queue_handler.log 2>&1 </dev/null &

# test_db
echo >&2 "All done with user-data.sh (rc=$rc)"
exit $rc
