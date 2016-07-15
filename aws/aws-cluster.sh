#!/bin/bash
INSTALLER="${1}"
COUNT="${2:-3}"
CLUSTER="${3:-`whoami`-xcalar}"
DIR="$(cd "$(dirname ${BASH_SOURCE[0]})" && pwd)"
XLRINFRA="$(cd "$DIR"/.. && pwd)"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"
XC_AZ="${AWS_DEFAULT_REGION}c"
IMAGE_ID=${IMAGE_ID:-ami-9a8849fa}
INST_TYPE=${INST_TYPE:-c4.8xlarge}
KEY_NAME=${KEY_NAME:-xcalar-us-west-2}
SUBNET_ID=${SUBNET_ID:-subnet-b9ed4ee0}
SEC_GROUPS=(default http-from-office)
EMAIL="$(git config user.email)"
NFSHOST="${NFSHOST:-nfs.xcalar.org}"
PGROUP="${PGROUP:-${CLUSTER}-pg}"
USER_DATA="${USER_DATA:-file://$DIR/cloud-init.sh}"

say () {
    echo >&2 "$*"
}

die () {
    say "ERROR: $*"
    exit 1
}

if [ -z "$1" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    die "usage: $0 <installer-url> <count (default: 3)> <cluster (default: `whoami`-xcalar)>"
fi
URL="$($XLRINFRA/bin/publish-build.sh $INSTALLER)"
res=$?
if [ $res -ne 0 ] || [ -z "$URL" ]; then
    die "($res) Failed to find or upload $INSTALLER"
fi

if ! aws ec2 describe-placement-groups --group-names ${PGROUP} &>/dev/null; then
    aws ec2 create-placement-group --group-name ${PGROUP} --strategy cluster --output text
    res=$?
    if [ $res -ne 0 ]; then
        die "Failed to create placement group ${PGROUP}"
    fi
fi

INSTANCES=($(aws ec2 run-instances --image-id $IMAGE_ID --count $COUNT \
        --key-name ${KEY_NAME} --user-data "${USER_DATA}" \
        --instance-type ${INST_TYPE} --security-groups "${SEC_GROUPS[@]}" \
        --placement "{\"AvailabilityZone\": \"${XC_AZ}\", \"GroupName\": \"${PGROUP}\",\"Tenancy\": \"default\"}" --query 'Instances[].InstanceId' --output text))
res=$?
if [ $res -ne 0 ]; then
    die "($res) Failed to launch instances"
fi

INSTANCES_SORTED=($(aws ec2 describe-instances --instance-ids "${INSTANCES[@]}" --query 'Reservations[].Instances[].[AmiLaunchIndex,InstanceId]' --output text | sort -n | awk '{print $2}'))

aws ec2 create-tags --resources "${INSTANCES_SORTED[@]}" \
    --tags "Key=Owner,Value=$EMAIL" \
           "Key=URL,Value=$URL" \
           "Key=Cluster,Value=$CLUSTER" \
           "Key=NFSHOST,Value=$NFSHOST"
idx=1
for INSTANCE_ID in "${INSTANCES_SORTED[@]}"; do
    aws ec2 create-tags --resources "$INSTANCE_ID" --tags "Key=Name,Value=${CLUSTER}-${idx}"
    idx=$(( $idx + 1 ))
done
