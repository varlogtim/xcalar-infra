#!/bin/bash
#
# Create an AWS Cloudformation Stack
#
# Usage:
#  ./aws-cluster.sh -h
#
# Usage (legacy, will be deprecated):
#  ./aws-cluster.sh [node-count (default:2)] [instance-type (default: i3.4xlarge)]
#
# RECOMMENDED INSTANCE TYPES for DEMOS
#
# i3.4xlarge = 16 vCPUs x 122GiB x 3800GiB SSD = $1.248/hr
# i3.8xlarge = 32 vCPUs x 244GiB x 7600GiB SSD = $2.496/hr
# r3.8xlarge = 32 vCPUs x 244GB x 600GB SSD = $2.660/hr
#
# Compare EC2 instance types for CPU, RAM, SSD with this calculator:
# http://www.ec2instances.info/?min_memory=60&min_vcpus=32&min_storage=1&region=us-west-2)
#
DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

NOW=$(date +%Y%m%d%H%M)
TEMPLATE="file://./cfn/XCE-CloudFormationMultiNodeInternal.yaml"
BUCKET=xcrepo
COUNT=2
INSTANCE_TYPE='i3.2xlarge'
NODEID=0
BOOTSTRAP=aws-cfn-bootstrap.sh
SUBNET=subnet-b9ed4ee0  # subnet-4e6e2d15
ROLE="xcalar_field"
#BOOTSTRAP_URL="${BOOTSTRAP_URL:-http://repo.xcalar.net/scripts/aws-asg-bootstrap-field-new.sh}"
INSTALLER="${INSTALLER:-s3://xcrepo/builds/3c9a47f4-65ad6827/prod/xcalar-1.2.3-1296-installer}"
LOGNAME="${LOGNAME:-`id -un`}"
STACK_NAME="$LOGNAME-cluster-$NOW"
#BootstrapUrl	http://repo.xcalar.net/scripts/aws-asg-bootstrap-field.sh
#InstallerUrl    "$(aws s3 presign s3://xcrepo/builds/c94df876-5ab9a93c/prod/xcalar-1.2.2-1236-installer)"
IMAGE=ami-f729da8f

usage () {
    cat << EOF
usage: $0 [-a image-id (default: $IMAGE)] [-i installer (default: $INSTALLER)] [-u installer-url (default: $INSTALLER_URL)]
          [-t instance-type (default: $INSTANCE_TYPE)] [-c count (default: $COUNT)] [-n stack-name (default: $STACK_NAME)]
          [-b bootstrap (default: $BOOTSTRAP)] [-f template (default: $TEMPLATE) [-s subnet-id (default: $SUBNET)]

EOF
    exit 1
}

upload_bysha1 () {
    local sha1= bn= key= s3path=
    sha1="$(shasum "$1" | cut -d' ' -f1)"
    bn="$(basename "$1")"
    key="bysha1/${sha1}/${bn}"
    s3path="s3://${BUCKET}/${key}"
    if ! aws s3 ls "$s3path" >/dev/null 2>&1; then
        aws s3 cp "$1" "$s3path" >/dev/null || return 1
    fi
    aws s3 presign --expires-in 3600 "$s3path"
}

check_url () {
    local code=
    if code="$(curl -fsSL -r 0-0 -w '%{http_code}\n' -o /dev/null "$1")"; then
        if [[ $code =~ ^[23] ]]; then
            return 0
        fi
    fi
    return 1
}

while getopts "ha:i:u:t:c:n:s:b:f:r:" opt "$@"; do
    case "$opt" in
        h) usage;;
        a) IMAGE="$OPTARG";;
        i) INSTALLER="$OPTARG";;
        u) INSTALLER_URL="$OPTARG";;
        t) INSTANCE_TYPE="$OPTARG";;
        c) COUNT="$OPTARG";;
        n) STACK_NAME="$OPTARG";;
        s) SUBNET="$OPTARG";;
        b) BOOTSTRAP="$OPTARG";;
        f) TEMPLATE="$OPTARG";;
        r) ROLE="$OPTARG";;
        --) break;;
        *) echo >&2 "Unknown option $opt"; usage;;
    esac
done

shift $((OPTIND-1))

if [ -z "$INSTALLER_URL" ]; then
    if [ "$INSTALLER" = "none" ]; then
        INSTALLER_URL="http://none"
    elif [[ "$INSTALLER" =~ ^s3:// ]]; then
        if ! INSTALLER_URL="$(aws s3 presign "$INSTALLER")"; then
            echo >&2 "Unable to sign the s3 uri: $INSTALLER"
        fi
    elif [[ "$INSTALLER" =~ ^gs:// ]]; then
        INSTALLER_URL="http://${INSTALLER#gs://}"
    elif [[ "$INSTALLER" =~ ^http[s]?:// ]]; then
        INSTALLER_URL="$INSTALLER"
    else
        if ! INSTALLER_URL="$($XLRINFRADIR/bin/installer-url.sh -d s3 "$INSTALLER")"; then
            echo >&2 "Failed to upload or generate a url for $INSTALLER"
            exit 1
        fi
    fi
fi

if [ -z "$BOOTSTRAP_URL" ]; then
    if ! BOOTSTRAP_URL="$(upload_bysha1 ${BOOTSTRAP})"; then
        echo >&2 "Failed to upload $BOOTSTRAP"
    fi
fi

if [ -z "$INSTALLER_URL" ]; then
    echo >&2 "Bad installer url or unable to open provided url"
    exit 1
fi

for URL in "$INSTALLER_URL" "$BOOTSTRAP_URL"; do
    if ! check_url "$URL"; then
        echo >&2 "Failed to access the installer url: $URL"
        exit 1
    fi
done

PARMS=(\
BootstrapUrl	"${BOOTSTRAP_URL}"
InstallerUrl    "${INSTALLER_URL}"
InstanceCount	${COUNT}
InstanceType	${INSTANCE_TYPE}
KeyName	        xcalar-us-west-2
SSHLocation	    0.0.0.0/0
Subnet	        $SUBNET
ImageId         $IMAGE
VpcId	        vpc-22f26347)

ARGS=()
for ii in $(seq 0 2 $(( ${#PARMS[@]} - 1)) ); do
    k=$(( $ii + 0 ))
    v=$(( $ii + 1 ))
    ARGS+=(ParameterKey=${PARMS[$k]},ParameterValue=\"${PARMS[$v]}\")
done

set -e
aws cloudformation validate-template --template-body ${TEMPLATE}
aws cloudformation create-stack \
        --stack-name ${STACK_NAME} \
        --template-body ${TEMPLATE} \
        --timeout-in-minutes 30 \
        --on-failure DELETE \
        --tags \
            Key=Name,Value=${STACK_NAME} \
            Key=Owner,Value=${LOGNAME} \
            Key=Role,Value=${ROLE} \
        --parameters "${ARGS[@]}"
aws cloudformation wait stack-create-complete --stack-name ${STACK_NAME}

