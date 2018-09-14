#!/bin/bash

set -e

. infra-sh-lib
. aws-sh-lib

BUCKET=xcrepoe1
DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
ENV=${ENV:-prod}
FIND_AMI=false

# Return the path relative from XLRINFRADIR/aws.
# ie, ~/xcalar-infra/aws/cfn/xdp-template -> cfn/xdp-template
infra_aws_s3_path() {
    set -x
    local dir="${1:-$PWD}"
    echo "${dir#${XLRINFRADIR}/aws/cfn/}"
}

s3_sync() {
    (set -x; aws s3 sync --acl public-read --metadata-directive REPLACE --content-disposition inline --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' "$@")
}

s3_cp() {
    (set -x; aws s3 cp \
        --acl public-read \
        --metadata-directive REPLACE \
        --content-disposition inline \
        --content-type application/json \
        --cache-control 'no-cache, no-store, must-revalidate, max-age=0, no-transform' \
        "$@")
}

ec2_find_ami() {
    local name="$1"
    shift
    aws ec2 describe-images \
        --query 'Images[].[CreationDate, Name, ImageId]' \
        --output text \
        --filters \
        'Name=name,Values='${name}'*' "$@" | sort -rn | head -1 | awk '{print $(NF)}'
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
    local template="$1" output_yaml="$2" output_json="$(basename $2 .yaml).json"
    cfn-flip < "$template" > "$output_json.$$"
}


while [[ $# -gt 0 ]]; do
    cmd="$1"
    case "$cmd" in
        --dryrun) add_args+=(--dryrun); shift;;
        --find-ami) FIND_AMI=true; shift;;
        -*) echo >&2 "ERROR: Unknown option $cmd"; exit 1;;
        *) break;;
    esac
done

test -n "$RELEASE" || RELEASE=$(cat RELEASE)
test -n "$VERSION" || VERSION=$(cat VERSION)

mkdir -p v${RELEASE}/scripts/
cd v${RELEASE} || exit 1
shfmt -i 2 -ci -bn -sr -s < ../scripts/user-data.sh > scripts/user-data.sh

cfn-flip < ../xdp-standard.template > xdp-standard.json
cfn-flip < ../xdp-single.template > xdp-single.json

NAME="$(infra_aws_s3_path "$PWD")"
TARGET=cfn/${ENV}/${NAME}

BOOTSTRAP_URL="https://$(aws_s3_endpoint $BUCKET)/${TARGET}/scripts/user-data.sh"

if ! [ -f AMI.txt ] || $FIND_AMI; then
    AMI_US_EAST_1=$(ec2_find_ami AMZN1 --owner self --region us-east-1)
    AMI_US_WEST_2=$(ec2_find_ami AMZN1 --owner self --region us-west-2)
    echo "AMI_US_EAST_1=$AMI_US_EAST_1" > AMI.txt
    echo "AMI_US_WEST_2=$AMI_US_WEST_2" >> AMI.txt
fi
. AMI.txt

jq -r '
    .Mappings.AWSAMIRegionMap."us-east-1".AMZN1HVM = "'$AMI_US_EAST_1'" |
    .Mappings.AWSAMIRegionMap."us-west-2".AMZN1HVM = "'$AMI_US_WEST_2'" |
    .Parameters.BootstrapUrl.Default = "'${BOOTSTRAP_URL}'"
' < xdp-standard.json | cfn-flip -c > xdp-standard.yaml
cfn-flip < xdp-standard.yaml > xdp-standard.json

jq -r '
    .Mappings.AWSAMIRegionMap."us-east-1".AMZN1HVM = "'$AMI_US_EAST_1'" |
    .Mappings.AWSAMIRegionMap."us-west-2".AMZN1HVM = "'$AMI_US_WEST_2'"
' < xdp-single.json | cfn-flip -c > xdp-single.yaml
cfn-flip < xdp-single.yaml > xdp-single.json


s3_cp "${add_args[@]}" xdp-standard.json "s3://${BUCKET}/${TARGET}/"
s3_cp "${add_args[@]}" xdp-standard.yaml "s3://${BUCKET}/${TARGET}/"
s3_cp "${add_args[@]}" xdp-single.json "s3://${BUCKET}/${TARGET}/"
s3_cp "${add_args[@]}" xdp-single.yaml "s3://${BUCKET}/${TARGET}/"
s3_cp "${add_args[@]}" scripts/user-data.sh "s3://${BUCKET}/${TARGET}/scripts/"

echo "https://$(aws_s3_endpoint $BUCKET)/${TARGET}/xdp-standard.yaml"
echo "https://$(aws_s3_endpoint $BUCKET)/${TARGET}/xdp-single.yaml"
