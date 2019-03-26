#!/bin/bash
# shellcheck disable=SC1091,SC2086

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

readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FIND_AMI=false
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
    usage: $0 [--project PROJECT] [--version VERSION] [--release|-r RELEASE]
              [--dry-run]  [--force]
              [--find-ami Look for newest AMI in each supported region]

    $0 takes CloudFormation stack templates, applies some preprocessing on it then
    publish the templates/scripts to the appropriate directories in S3. The S3 URLs
    can then be used by customers for their own deployment.
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
    jq -r '.Resources.LaunchConfiguration.Properties.UserData."Fn::Base64"."Fn::Sub"[0]'
}

jq_get_userata_from_lt() {
    jq -r '.Resources.LaunchTemplate.Properties.LaunchTemplateData.UserData."Fn::Base64"."Fn::Sub"[0]'
}

# STDIN = template
# $1 = Resource path to UserData
# $2 = shell script to inject
# Eg, jq_put_userata_in_lc ClusterLC.Properties.UserData deploy.sh < xdp-standard.json
jq_put_userata_in_lc() {
    jq -r ".Resources.ClusterLC.Properties.UserData.\"Fn::Base64\".\"Fn::Sub\"[0] = $(jq -R -s . < scripts/user-data.sh)" < xdp-standard.json
}

jq_put_userata_in_lt() {
    jq -r ".Resources.LaunchTemplate.Properties.LaunchTemplateData.UserData.\"Fn::Base64\".\"Fn::Sub\"[0] = $(jq -R -s . < scripts/user-data.sh)" < xdp-standard.json
}

transform() {
    cat $DIR/vars/*.yaml | jinja2 $DIR/${1}.template.j2 | tee ${1}.yaml.tmp | cfn-flip > ${1}.json.tmp
    local rc=${PIPESTATUS[1]}
    if [ $rc -ne 0 ]; then
        return $rc
    fi

    mv ${1}.yaml.tmp ${1}.yaml
    mv ${1}.json.tmp ${1}.json
    return 0
#    cfn-flip < $DIR/${1}.template > ${1}.json.tmp || return 1
#    jq -r '
#        .Mappings.AWSAMIRegionMap."us-east-1".AMZN1HVM = "'$AMZN1HVM_US_EAST_1'" |
#        .Mappings.AWSAMIRegionMap."us-west-2".AMZN1HVM = "'$AMZN1HVM_US_WEST_2'" |
#        .Parameters.BootstrapUrl.Default = "'${BOOTSTRAP_URL}'"
#    ' < ${1}.json.tmp | cfn-flip -c > ${1}.yaml.tmp || return 1
#    cfn-flip < ${1}.yaml.tmp > ${1}.json.tmp || return 1
#    mv ${1}.json.tmp ${1}.json
#    mv ${1}.yaml.tmp ${1}.yaml
}

## The directory is cfn/{env}/{name}/{build-id}/, where
## env is prod/dev/test, and

add_args=()
while [[ $# -gt 0 ]]; do
    cmd="$1"
    shift
    case "$cmd" in
        --help|-h) usage;;
        --project|-p) PROJECT="$1"; shift;;
        --release|-r) RELEASE="$1"; shift;;
        --version|-v) VERSION="$1"; shift;;
        --build-id) BUILD_ID="$1"; shift;;
        --dryrun|--dry-run|-n) DRY=true;;
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
test -n "$PROJECT" || PROJECT="$(basename "$(pwd)")"

mkdir -p ${BUILD_ID}/scripts/
cd ${BUILD_ID} || exit 1
if $FORCE || ! test -e scripts/user-data.sh; then
    cp $DIR/scripts/user-data.sh scripts/user-data.sh
else
    echo >&2 "WARNING: Skipping scripts/user-data.sh because it exists"
fi

BUCKET_ENDPOINT="https://$(aws_s3_endpoint $BUCKET)"
TARGET=cfn/${ENVIRONMENT}/${PROJECT}/${BUILD_ID}
BASE_URL="${BUCKET_ENDPOINT}/${TARGET}"
BOOTSTRAP_URL="${BASE_URL}/scripts/user-data.sh"

xcalar_latest() {

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
}

cat > $DIR/vars/deploy.yaml <<EOF
VERSION: '$VERSION'
PROJECT: '$PROJECT'
RELEASE: '$RELEASE'
bootstrapUrl: "$BOOTSTRAP_URL"
EOF

for J2TEMPLATE in "$DIR"/*.template.j2; do
    TEMPLATE=$(basename $J2TEMPLATE .template.j2)
    if $FORCE || ! test -e ${TEMPLATE}.yaml;  then
        #cat $DIR/vars/*.yaml | jinja2 $J2TEMPLATE > ${J2TEMPLATE%.j2}
        transform ${TEMPLATE} || exit 1
    else
        echo >&2 "WARNING: Skipping transform to ${TEMPLATE}.yaml, because it exists. Use --force"
    fi
    templateURL="${BASE_URL}/${TEMPLATE}.yaml"
    echo "templateURL: $templateURL"
    cfnURL="$(jinja2 -D templateURL="$templateURL" -D region=$AWS_DEFAULT_REGION -D stackName=XcalarS${TEMPLATE#xdp-s} $DIR/cloudformation-new.url.j2)"
    echo "cfnURL: $cfnURL"
done

if $DRY; then
    add_args+=(--dryrun)
    echo >&2 "Dry run mode"
fi

add_args+=('--exclude=*.json')

s3_sync --acl public-read "${add_args[@]}" . "s3://${BUCKET}/${TARGET}/"
