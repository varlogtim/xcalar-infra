#!/bin/bash

set -e

. infra-sh-lib
. aws-sh-lib

case "$AWS_DEFAULT_REGION" in
    us-west-2) BUCKET=xcrepo;;
    us-east-1) BUCKET=xcrepoe1;;
    *) BUCKET=xcrepoe1;;
esac

DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
FIND_AMI=false
DOIT=false
DRY=true

# Return the path relative from XLRINFRADIR/aws.
# ie, ~/xcalar-infra/aws/cfn/xdp-template -> cfn/xdp-template
infra_aws_s3_path() {
    set -x
    local dir="${1:-$PWD}"
    echo "${dir#${XLRINFRADIR}/aws/cfn/}"
}

s3_sync() {
    (set -x; aws s3 sync \
        --acl public-read \
        --metadata-directive REPLACE \
        --content-disposition inline \
        --content-type application/json \
        --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' "$@")
}

s3_cp() {
    (set -x; aws s3 cp \
        --acl public-read \
        --metadata-directive REPLACE \
        --content-disposition inline \
        --content-type application/json \
        --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' "$@")
}

ec2_find_ami() {
    aws ec2 describe-images \
        --query 'Images[].[CreationDate, Name, ImageId]' \
        --output text "$@" | sort -rn | head -1 | awk '{print $(NF)}'
}

jq_get_userata_from_lc() {
    jq -r '.Resources.ClusterLC.Properties.UserData."Fn::Base64"."Fn::Sub"[0]'
}


# STDIN = template
# $1 = Resource path to UserData
# $2 = shell script to inject
# Eg, jq_put_userata_in_lc ClusterLC.Properties.UserData deploy.sh < xdp-standard.json
jq_put_userata_in_lc() {
    jq -r ".Resources.ClusterLC.Properties.UserData.\"Fn::Base64\".\"Fn::Sub\"[0] = $(jq -R -s . < deploy.sh)" < xdp-standard.json
}

transform() {
    cfn-flip < $DIR/${1}.template > ${1}.json.tmp || return 1
    jq -r '
        .Mappings.AWSAMIRegionMap."us-east-1".AMZN1HVM = "'$AMI_US_EAST_1'" |
        .Mappings.AWSAMIRegionMap."us-west-2".AMZN1HVM = "'$AMI_US_WEST_2'" |
        .Parameters.BootstrapUrl.Default = "'${BOOTSTRAP_URL}'"
    ' < ${1}.json.tmp | cfn-flip -c > ${1}.yaml.tmp || return 1
    cfn-flip < ${1}.yaml.tmp > ${1}.json.tmp || return 1
    mv ${1}.json.tmp ${1}.json
    mv ${1}.yaml.tmp ${1}.yaml
}


add_args=()
while [[ $# -gt 0 ]]; do
    cmd="$1"
    shift
    case "$cmd" in
        --doit) DRY=false;;
        --dryrun) DRY=true;;
        --find-ami) FIND_AMI=true;;
        --force) FORCE=true;;
        -*) echo >&2 "ERROR: Unknown option $cmd"; exit 1;;
        *) break;;
    esac
done

test -n "$RELEASE" || RELEASE=$(cat RELEASE)
test -n "$VERSION" || VERSION=$(cat VERSION)
test -n "$ENVIRONMENT" || ENVIRONMENT=$(cat ENVIRONMENT)

mkdir -p ${RELEASE}/scripts/
cd ${RELEASE} || exit 1
if ! [ -e scripts/user-data.sh ]; then
    shfmt -i 2 -ci -bn -sr -s < $DIR/scripts/user-data.sh > scripts/user-data.sh
else
    echo >&2 "WARNING: Skipping scripts/user-data.sh because it exists"
fi

NAME="$(infra_aws_s3_path "$PWD")"
TARGET=cfn/${ENVIRONMENT}/${NAME}


BUCKET_ENDPOINT="https://$(aws_s3_endpoint $BUCKET)"

BOOTSTRAP_URL="${BUCKET_ENDPOINT}/${TARGET}/scripts/user-data.sh"

if ! [ -f AMI.txt ]; then
    if $FIND_AMI; then
        AMI_US_EAST_1=$(ec2_find_ami --filters 'Name=tag:BaseOS,Values=AMZN1-2018.03' --owner self --region us-east-1)
        AMI_US_WEST_2=$(ec2_find_ami --filters 'Name=tag:BaseOS,Values=AMZN1-2018.03' --owner self --region us-west-2)
        echo "AMI_US_EAST_1=$AMI_US_EAST_1" | tee AMI.txt
        echo "AMI_US_WEST_2=$AMI_US_WEST_2" | tee -a AMI.txt
    else
        cp $DIR/AMI.txt .
    fi
fi

. AMI.txt

for TEMPLATE in xdp-standard xdp-single; do
    if $FORCE || ! test -e ${TEMPLATE}.yaml;  then
        transform ${TEMPLATE} || exit 1
    else
        echo >&2 "WARNING: Skipping transform to ${TEMPLATE}.yaml, because it exists. Use --force"
    fi
    echo "${BUCKET_ENDPOINT}/${TARGET}/${TEMPLATE}.yaml"
done

#if [ -e xdp-launch.json ]; then
#    jq -r '
#        .Mappings.AWSAMIRegionMap."us-east-1".AMZN1HVM = "'$AMI_US_EAST_1'" |
#        .Mappings.AWSAMIRegionMap."us-west-2".AMZN1HVM = "'$AMI_US_WEST_2'"
#    ' < xdp-launch.json | cfn-flip -c > xdp-launch.yaml
#    cfn-flip < xdp-launch.yaml > xdp-launch.json
#fi

if $DRY; then
    add_args+=(--dryrun)
    echo >&2 "WARNING: Dry run only. Pass --doit, to actually copy."
fi

s3_sync --acl public-read "${add_args[@]}" . "s3://${BUCKET}/${TARGET}/"
