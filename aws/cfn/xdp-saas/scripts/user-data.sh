#!/bin/bash
#
# shellcheck disable=SC2086,SC2304,SC2034

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

#Name=tag:aws:autoscaling:groupName,Values=$AWS_AUTOSCALING_GROUPNAME
ec2_find_cluster() {
    aws ec2 describe-instances \
        --filters Name=tag:$1,Values=$2 \
                  Name=instance-state-name,Values=running \
        --query "Reservations[].Instances[].[LaunchTime,AmiLaunchIndex,${3:-PrivateIpAddress}]" \
        --output text | sort -n | awk '{print $(NF)}'
}

asg_healthy_instances() {
    aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$1" --query 'AutoScalingGroups[].Instances[?HealthStatus==`Healthy`]|[] | length(@)'
}


asg_capacity() {
    aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$1" --query 'AutoScalingGroups[][MinSize,MaxSize,DesiredCapacity]'  --output text
}

efsip() {
    local EFSIP
    until EFSIP=$(aws efs describe-mount-targets --file-system-id "$1" --query 'MountTargets[?SubnetId==`'$2'`].IpAddress' --output text); do
        echo >&2 "Waiting for EFS $1 to be up ..."
        sleep 5
    done
    echo "$EFSIP"
}

# $1 = server:/path/to/share
# $2 = /mnt/localpath
mount_xlrroot() {
    local NFSHOST="${1%%:*}"
    local NFSDIR="${1#$NFSHOST}"
    local MOUNT="$2"

    NFSDIR="${NFSDIR#:}"
    NFSDIR="${NFSDIR#/}"

    local existing_mount
    if existing_mount="$(set -o pipefail; findmnt -nT "$2" | awk '{print $2}')"; then
        if [ "$existing_mount" == "$1" ]; then
            echo >&2 "$1 already mounted to $2"
            return 0
        fi
    fi

    # shellcheck disable=SC2046
    local tmpdir="$(mktemp -d -t nfs.XXXXXX)"
    set +e
    mount -t $NFS_TYPE -o ${NFS_OPTS},timeo=3 $NFSHOST:/$NFSDIR $tmpdir
    local rc=$?
    if [ $rc -eq 32 ]; then
        mount -t $NFS_TYPE -o ${NFS_OPTS},timeo=3 $NFSHOST:/ $tmpdir
        rc=$?
        if [ $rc -eq 0 ]; then
            mkdir -p ${tmpdir}/${NFSDIR}/members
            chmod 0700 ${tmpdir}/${NFSDIR}
            chown xcalar:xcalar ${tmpdir}/${NFSDIR} ${tmpdir}/${NFSDIR}/members
            umount ${tmpdir}
        fi
    fi
    if mountpoint -q $tmpdir; then
        umount $tmpdir || true
    fi
    rmdir $tmpdir || true

    if [ $rc -eq 0 ]; then
        sed -i '\@'$MOUNT'@d' /etc/fstab
        echo "${NFSHOST}:/${NFSDIR} $MOUNT $NFS_TYPE  $NFS_OPTS 0 0" >> /etc/fstab
        test -d $MOUNT || mkdir -p $MOUNT
        mountpoint -q $MOUNT || mount $MOUNT
        rc=$?
    fi
    return $rc
}


eval $(ec2-tags -s -i)

# shellcheck disable=SC2046
ENV_FILE=/var/lib/cloud/instance/ec2.env

if [ -e "$ENV_FILE" ]; then
    . $ENV_FILE
fi

while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        --nic)
            NIC="$1"
            shift
            ;;
        --subnet)
            SUBNET="$1"
            shift
            ;;
        --nfs-mount)
            NFSMOUNT="$1"
            shift
            ;;
        --nfs-type)
            NFS_TYPE="$1"
            shift
            ;;
        --nfs-opts)
            NFS_OPTS="$1"
            shift
            ;;
        --tag-key)
            TAG_KEY="$1"
            shift
            ;;
        --tag-value)
            TAG_VALUE="$1"
            shift
            ;;
        --bucket)
            BUCKET="$1"
            shift
            ;;
        --prefix)
            PREFIX="$1"
            shift
            ;;
        --cluster-size)
            CLUSTER_SIZE="$1"
            shift
            ;;
        --node-id)
            NODE_ID="$1"
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
        --cluster-name)
            CLUSTER_NAME="$1"
            shift
            ;;
        --resource-id)
            RESOURCE_ID="$1"
            shift
            ;;
        --admin-username)
            ADMIN_USERNAME="$1"
            shift
            ;;
        --admin-password)
            ADMIN_PASSWORD="$1"
            shift
            ;;
        --admin-email)
            ADMIN_EMAIL="$1"
            shift
            ;;
        *)
            echo >&2 "WARNING: Unknown command $cmd"
            ;;
    esac
done

CLUSTER_SIZE=${CLUSTER_SIZE:-1}
XCE_CONFIG=${XCE_CONFIG:-/etc/xcalar/default.cfg}
XCE_TEMPLATE=${XCE_TEMPLATE:-/etc/xcalar/template.cfg}

RELEASE_NAME=$(rpm -qf /etc/system-release --qf '%{NAME}')
RELEASE_VERSION=$(rpm -qf /etc/system-release --qf '%{VERSION}')
case "$RELEASE_VERSION" in
    6 | 6*) OSID=el6 ;;
    7 | 7*) OSID=el7 ;;
    201*) OSID=amzn1 ;;
    2) OSID=amzn2 ;;
    *)
        echo >&2 "ERROR: Unknown OS version $RELEASE_VERSION"
        exit 1
        ;;
esac

INSTANCE_ID=$(curl -sSf http://169.254.169.254/latest/meta-data/instance-id)
AVZONE=$(curl -sSf http://169.254.169.254/latest/meta-data/placement/availability-zone)
INSTANCE_TYPE=$(curl -sSf http://169.254.169.254/latest/meta-data/instance-type)
LOCAL_IPV4=$(curl -sSf http://169.254.169.254/latest/meta-data/local-ipv4)
LOCAL_HOSTNAME=$(curl -sSf http://169.254.169.254/latest/meta-data/local-hostname)
sed -i "/^${LOCAL_IPV4}/d; /${LOCAL_HOSTNAME}/d;" /etc/hosts
echo "$LOCAL_IPV4	$LOCAL_HOSTNAME     $(hostname -s)" | tee -a /etc/hosts

export AWS_DEFAULT_REGION="${AVZONE%[a-f]}"

JAVA_HOME="$(readlink -f $(command -v java))"
export JAVA_HOME="${JAVA_HOME%/bin/java}"
echo "export JAVA_HOME=$JAVA_HOME" > /etc/profile.d/java.sh

export PATH=/opt/mssql-tools/bin:/opt/xcalar/bin:/opt/aws/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "export PATH=$PATH" > /etc/profile.d/path.sh

NFSHOST="${NFSMOUNT%%:*}"
NFSDIR="${NFSMOUNT#$NFSHOST}"
NFSDIR="${NFSDIR#:}"
NFSDIR="${NFSDIR#/}"

if [ -z "$NFS_TYPE" ]; then
    if [[ $NFSHOST =~ ^fs-[0-9a-f]{8}$ ]]; then
        if [ -n "$SUBNET" ]; then
            if EFSIP="$(efsip $NFSHOST $SUBNET)"; then
                NFSHOST=$EFSIP
                NFS_TYPE=nfs
                NFS_OPTS="nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport"
            fi
        else
            rpm -q amazon-efs-utils || yum install -y amazon-efs-utils
            NFS_TYPE=efs
            NFS_OPTS="_netdev"
        fi
    else
        NFS_TYPE=nfs
        NFS_OPTS="nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport"
    fi
fi

if [ -n "$LICENSE" ]; then
    if [[ $LICENSE =~ ^s3:// ]]; then
        aws s3 cp $LICENSE - | base64 -d | gzip -dc > /etc/xcalar/XcalarLic.key
    elif [[ $LICENSE =~ ^https:// ]]; then
        curl -fsSL "$LICENSE" | base64 -d | gzip -dc > /etc/xcalar/XcalarLic.key
    else
        echo "$LICENSE" | base64 -d | gzip -dc > /etc/xcalar/XcalarLic.key
    fi
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to decode license"
        rm -f /etc/xcalar/XcalarLic.key
    else
        chown xcalar:xcalar /etc/xcalar/XcalarLic.key
        chmod 0600 /etc/xcalar/XcalarLic.key
    fi
fi

if [ -n "$TAG_KEY" ] && [ -z "$TAG_VALUE" ]; then
    case "$TAG_KEY" in
        aws:autoscaling:groupName)
            TAG_VALUE="$AWS_AUTOSCALING_GROUPNAME"
            ;;
        aws:cloudformation:stack-name)
            TAG_VALUE="$AWS_CLOUDFORMATION_STACK_NAME"
            ;;
        ClusterName)
            TAG_VALUE="$CLUSTERNAME"
            ;;
        Name)
            TAG_VALUE="$NAME"
            ;;
        *)
            echo >&2 "WARNING: Unrecognized clustering tag: TAG_KEY=$TAG_KEY"
            ;;
    esac
fi

if [ -z "$TAG_KEY" ]; then
    if [ -n "$AWS_AUTOSCALING_GROUPNAME" ]; then
        TAG_KEY=aws:autoscaling:groupName
        TAG_VALUE=$AWS_AUTOSCALING_GROUPNAME
    elif [ -n "$AWS_CLOUDFORMATION_STACK_NAME" ]; then
        TAG_KEY=aws:cloudformation:stack-name
        TAG_VALUE=$AWS_CLOUDFORMATION_STACK_NAME
    elif [ -n "$CLUSTERNAME" ]; then
        TAG_KEY=ClusterName
        TAG_VALUE="$CLUSTERNAME"
    elif [ -n "$NAME" ]; then
        TAG_KEY=Name
        TAG_VALUE=$NAME
    else
        echo >&2 "No valid tags found"
    fi
fi

if [ -n "$TAG_KEY" ] && [ -n "$TAG_VALUE" ]; then
    IPS=()
    while true; do
        if IPS=($(ec2_find_cluster "$TAG_KEY" "$TAG_VALUE")); then
            NUM_INSTANCES="${#IPS[@]}"
            if [ $NUM_INSTANCES -gt 0 ]; then
                echo >&2 "Found $NUM_INSTANCES cluster members!"
                if [ -z "$CLUSTER_SIZE" ]; then
                    break
                fi
                if [ $NUM_INSTANCES -eq $CLUSTER_SIZE ]; then
                    break
                fi
            fi
        fi
        sleep 2
    done
    for NODE_ID in $(seq 0 $((NUM_INSTANCES-1))); do
        if [ "$LOCAL_IPV4" == "${IPS[$NODE_ID]}" ]; then
            break
        fi
    done
    if [ "$LOCAL_IPV4" != "${IPS[$NODE_ID]}" ]; then
        echo >&2 "WARNING: Unable to find $LOCAL_IPV4 in the list of IPS: ${IPS[*]}"
    fi
else
    IPS=( "$LOCAL_IPV4" )
    NODE_ID=0
fi

MOUNT_OK=false
XLRROOT=/var/opt/xcalar
if [ -n "$NFSMOUNT" ]; then
    mkdir -p /mnt/xcalar
    if mount_xlrroot $NFSHOST:/${NFSDIR:-cluster/$CLUSTER_NAME} /mnt/xcalar; then
        MOUNT_OK=true
        XLRROOT=/mnt/xcalar
    fi
fi

sed -i '/^Constants.Cgroups/d' ${XCE_TEMPLATE}
if [ "$CGROUPS_ENABLED" != true ]; then
    (echo "Constants.Cgroups=false"; cat ${XCE_TEMPLATE}) > ${XCE_TEMPLATE}.tmp \
        && mv ${XCE_TEMPLATE}.tmp ${XCE_TEMPLATE}
fi

if [ "$MOUNT_OK" = true ]; then
    if ! test -d ${XLRROOT}/jupyterNotebooks; then
        rsync -avzr /var/opt/xcalar/ ${XLRROOT}/
    fi
    /opt/xcalar/scripts/genConfig.sh ${XCE_TEMPLATE} - "${IPS[@]}" | sed 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath='${XLRROOT}'@g' | tee /etc/xcalar/default.cfg
else
    XLRROOT=/var/opt/xcalar
    mkdir -p $XLRROOT
    chown xcalar:xcalar $XLRROOT
    /opt/xcalar/scripts/genConfig.sh ${XCE_TEMPLATE} - localhost | tee /etc/xcalar/default.cfg
fi

if [ $NODE_ID -eq 0 ]; then
    if [ -n "$NIC" ]; then
        while true; do
            eni_status=$(aws ec2 describe-network-interfaces --query 'NetworkInterfaces[].Status' --network-interface-ids ${NIC} --output text)
            if [[ "$eni_status" == available ]]; then
                if aws ec2 attach-network-interface --network-interface-id ${NIC} --instance-id ${INSTANCE_ID} --device-index 1; then
                    echo >&2 "ENI $NIC attached to $INSTANCE_ID"
                    break
                fi
            fi
            eni_instance=$(aws ec2 describe-network-interfaces --query 'NetworkInterfaces[].Attachment.InstanceId' --network-interface-ids ${NIC} --output text)
            if [[ "$eni_instance" == "$INSTANCE_ID" ]]; then
                echo >&2 "ENI $NIC already attached"
                break
            fi
            echo >&2 "Waiting for ENI $NIC that is $eni_status by $eni_instance .."
            sleep 10
        done
    fi

    test -d $XLRROOT/config || mkdir -p $XLRROOT/config
    /opt/xcalar/scripts/genDefaultAdmin.sh \
        --username "${ADMIN_USERNAME}" \
        --email "${ADMIN_EMAIL:-info@xcalar.com}" \
        --password "${ADMIN_PASSWORD}" > /tmp/defaultAdmin.json \
        && mv /tmp/defaultAdmin.json $XLRROOT/config/defaultAdmin.json
    chmod 0700 $XLRROOT/config
    chmod 0600 $XLRROOT/config/defaultAdmin.json
fi

chown -R xcalar:xcalar $XLRROOT

/etc/init.d/xcalar stop || true
/etc/init.d/xcalar start
rc=$?

if [ $rc -eq 0 ]; then
	aws ec2 create-tags --resources $INSTANCE_ID \
		--tags Key=Name,Value="${AWS_CLOUDFORMATION_STACK_NAME}-${NODE_ID}" \
			   Key=Node_ID,Value="${NODE_ID}"
fi

chkconfig xcalar on

echo >&2 "All done with user-data.sh (rc=$rc)"
exit $rc
