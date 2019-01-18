#!/bin/bash

set -e

. infra-sh-lib
. aws-sh-lib

case "$AWS_DEFAULT_REGION" in
    us-west-2) BUCKET=xcrepo;;
    us-east-1) BUCKET=xcrepoe1;;
    *)
        export AWS_DEFAULT_REGION=us-east-1
        BUCKET=xcrepoe1
        ;;
esac

readonly DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)

FIND_AMI=false
DOIT=false
DRY=false

# Return the path relative from XLRINFRADIR/aws.
# ie, ~/xcalar-infra/aws/cfn/xdp-template -> cfn/xdp-template
infra_aws_s3_path() {
    set -x
    local dir="${1:-$PWD}"
    echo "${dir#${XLRINFRADIR}/aws/cfn/}"
}

usage() {
    cat <<EOF
    usage: $0 [--version VERSION] [--product PRODUCT] [--release|-r RELEASE]
              [--dry-run]  [--force]
              [--find-ami Look for newest AMI in each supported region]

    $0 takes VERSION PRODUCT RELEASE , and use this to
    publish the templates/scripts to those release directories on S3. These can then be referenced
    by customers for their own deployment. The idea is we never break/change existing deploys.E
EOF
    exit 2
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
    jq -r ".Resources.ClusterLC.Properties.UserData.\"Fn::Base64\".\"Fn::Sub\"[0] = $(jq -R -s . < scripts/user-data.sh)" < xdp-standard.json
}

transform() {
    cfn-flip < $DIR/${1}.template > ${1}.json.tmp || return 1
    jq -r '
        .Mappings.AWSAMIRegionMap."us-east-1".AMZN1HVM = "'$AMZN1HVM_US_EAST_1'" |
        .Mappings.AWSAMIRegionMap."us-west-2".AMZN1HVM = "'$AMZN1HVM_US_WEST_2'" |
        .Parameters.BootstrapUrl.Default = "'${BOOTSTRAP_URL}'"
    ' < ${1}.json.tmp | cfn-flip -c > ${1}.yaml.tmp || return 1
    cfn-flip < ${1}.yaml.tmp > ${1}.json.tmp || return 1
    mv ${1}.json.tmp ${1}.json
    mv ${1}.yaml.tmp ${1}.yaml
}

## The directory is cfn/{env}/{name}/{build-id}/, where
## env is prod/dev/test, and

add_args=()
while [[ $# -gt 0 ]]; do
    cmd="$1"
    shift
    case "$cmd" in
        -h|--help) usage;;
        --release|-r) RELEASE="$1"; shift;;
        --version) VERSION="$1"; shift;;
        --product) PRODUCT="$1"; shift;;
        --build-id) BUILD_ID="$1"; shift;;
        --dryrun|--dry-run) DRY=true;;
        --find-ami) FIND_AMI=true;;
        --force) FORCE=true;;
        -*) echo >&2 "ERROR: Unknown argument $cmd"; usage;;
        *) break;;
    esac
done

test -n "$VERSION" || VERSION=$(cat VERSION)
test -n "$RELEASE" || RELEASE=$(cat RELEASE)
test -n "$ENVIRONMENT" || ENVIRONMENT=$(cat ENVIRONMENT)
test -n "$BUILD_ID" || BUILD_ID="${VERSION}-${RELEASE}"
test -n "$PRODUCT" || PRODUCT="$(basename "$(pwd)")"

mkdir -p ${BUILD_ID}/scripts/
cd ${BUILD_ID} || exit 1
if $FORCE || ! test -e scripts/user-data.sh; then
    cp $DIR/scripts/user-data.sh scripts/user-data.sh
else
    echo >&2 "WARNING: Skipping scripts/user-data.sh because it exists"
fi

BUCKET_ENDPOINT="https://$(aws_s3_endpoint $BUCKET)"
TARGET=cfn/${ENVIRONMENT}/${PRODUCT}/${BUILD_ID}
BASE_URL="${BUCKET_ENDPOINT}/${TARGET}"
BOOTSTRAP_URL="${BASE_URL}/scripts/user-data.sh"

if $FORCE || ! test -f AMI.ini; then
    if $FIND_AMI; then
        AMZN1HVM_US_EAST_1=$(ec2_find_ami --filters 'Name=tag:BaseOS,Values=AMZN1-2018.03' --owner self --region us-east-1)
        AMZN1HVM_US_WEST_2=$(ec2_find_ami --filters 'Name=tag:BaseOS,Values=AMZN1-2018.03' --owner self --region us-west-2)
        echo "AMZN1HVM_US_EAST_1=$AMZN1HVM_US_EAST_1" | tee AMI.ini
        echo "AMZN1HVM_US_WEST_2=$AMZN1HVM_US_WEST_2" | tee -a AMI.ini
    else
        cp $DIR/AMI.ini .
    fi
fi

. AMI.ini

for TEMPLATE in xdp-standard xdp-single; do
    if $FORCE || ! test -e ${TEMPLATE}.yaml;  then
        transform ${TEMPLATE} || exit 1
    else
        echo >&2 "WARNING: Skipping transform to ${TEMPLATE}.yaml, because it exists. Use --force"
    fi
    templateURL="${BASE_URL}/${TEMPLATE}.yaml"
    echo "templateURL: $templateURL"
    cfnURL="$(jinja2 -D templateURL="$templateURL" -D region=$AWS_DEFAULT_REGION -D stackName=XcalarS${TEMPLATE#xdp-s} $DIR/cloudformation-new.url.j2)"
    echo "cfnURL: $cfnURL"
done

#if [ -e xdp-launch.json ]; then
#    jq -r '
#        .Mappings.AWSAMIRegionMap."us-east-1".AMZN1HVM = "'$AMZN1HVM_US_EAST_1'" |
#        .Mappings.AWSAMIRegionMap."us-west-2".AMZN1HVM = "'$AMZN1HVM_US_WEST_2'"
#    ' < xdp-launch.json | cfn-flip -c > xdp-launch.yaml
#    cfn-flip < xdp-launch.yaml > xdp-launch.json
#fi

if $DRY; then
    add_args+=(--dryrun)
    echo >&2 "Dry run mode"
fi

add_args+=(--exclude='*.json')

s3_sync --acl public-read "${add_args[@]}" . "s3://${BUCKET}/${TARGET}/"
