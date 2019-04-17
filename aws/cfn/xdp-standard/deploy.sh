#!/bin/bash
# shellcheck disable=SC1091,SC2086

set -e

. infra-sh-lib
. aws-sh-lib

readonly DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FIND_AMI=false
DRY=false

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

ec2_find_ami() {
    aws ec2 describe-images \
        --query 'Images[].[CreationDate, Name, ImageId]' \
        --output text "$@" | sort -rn | head -1 | awk '{print $(NF)}'
}

xcalar_latest() {
    AMZN1HVM_US_EAST_1=$(ec2_find_ami --filters 'Name=tag:BaseOS,Values=AMZN1-2018.03' --owner self --region us-east-1)
    AMZN1HVM_US_WEST_2=$(ec2_find_ami --filters 'Name=tag:BaseOS,Values=AMZN1-2018.03' --owner self --region us-west-2)
    echo "ami_us_east_1: $AMZN1HVM_US_EAST_1" > $DIR/vars/amis.yaml
    echo "ami_us_west_2: $AMZN1HVM_US_WEST_2" >> $DIR/vars/amis.yaml
}

jq_get_userata_from_lc() {
    jq -r '.Resources.LaunchConfiguration.Properties.UserData."Fn::Base64"."Fn::Sub"[0]'
}

jq_get_userata_from_lt() {
    jq -r '.Resources.LaunchTemplate.Properties.LaunchTemplateData.UserData."Fn::Base64"."Fn::Sub"[0]'
}

jq_put_userata_in_lc() {
    # STDIN = template $1 = Resource path to UserData $2 = shell script to inject
    # Eg, jq_put_userata_in_lc ClusterLC.Properties.UserData deploy.sh < xdp-standard.json
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
}

add_args=()
while [[ $# -gt 0 ]]; do
    cmd="$1"
    shift
    case "$cmd" in
        --help|-h) usage;;
        --project|-p) PROJECT="$1"; shift;;
        --release|-r) RELEASE="$1"; shift;;
        --version|-v) VERSION="$1"; shift;;
        --environment|--env|-e) ENVIRONMENT="$1"; shift;;
        --template) TEMPLATE="$1"; shift;;
        --dryrun|--dry-run|-n) DRY=true;;
        --find-ami) FIND_AMI=true;;
        --force) FORCE=true;;
        --url-file) URL_FILE="$1"; shift;;
        -*) echo >&2 "ERROR: Unknown argument $cmd"; usage;;
        *) break;;
    esac
done

test -n "$VERSION" || VERSION=$(cat VERSION)
test -n "$RELEASE" || RELEASE=$(cat RELEASE)
test -n "$ENVIRONMENT" || ENVIRONMENT=$(cat ENVIRONMENT)
test -n "$PROJECT" || PROJECT="$(basename "$(pwd)")"

TMPDIR=$(mktemp -d /tmp/deploy.XXXXXX)
trap 'rm -r -f -v $TMPDIR' EXIT

BUILD_ID="${VERSION}-${RELEASE}"
mkdir -p ${TMPDIR}/${BUILD_ID}/scripts/
cd ${TMPDIR}/${BUILD_ID} || exit 1
if $FORCE || ! test -e scripts/user-data.sh; then
    cp $DIR/scripts/user-data.sh scripts/user-data.sh
else
    echo >&2 "WARNING: Skipping scripts/user-data.sh because it exists"
fi

case "$AWS_DEFAULT_REGION" in
    us-west-2) BUCKET=xcrepo;;
    us-east-1) BUCKET=xcrepoe1;;
    *)
        export AWS_DEFAULT_REGION=us-east-1
        BUCKET=xcrepoe1
        ;;
esac

BUCKET_ENDPOINT="https://$(aws_s3_endpoint $BUCKET)"
TARGET=cfn/${ENVIRONMENT}/${PROJECT}/${BUILD_ID}
BASE_URL="${BUCKET_ENDPOINT}/${TARGET}"
BOOTSTRAP_URL="${BASE_URL}/scripts/user-data.sh"

cat > $DIR/vars/deploy.yaml <<EOF
VERSION: '$VERSION'
PROJECT: '$PROJECT'
RELEASE: '$RELEASE'
bootstrapUrl: '$BOOTSTRAP_URL'
EOF

for J2TEMPLATE in "$DIR"/*.template.j2; do
    TEMPLATE=$(basename $J2TEMPLATE .template.j2)
    if $FORCE || ! test -e ${TEMPLATE}.yaml;  then
        #cat $DIR/vars/*.yaml | jinja2 $J2TEMPLATE > ${J2TEMPLATE%.j2}
        transform ${TEMPLATE} || exit 1
    else
        echo >&2 "WARNING: Skipping transform to ${TEMPLATE}.yaml, because it exists. Use --force"
    fi
    templateUrl="${BASE_URL}/${TEMPLATE}.json"
    if [ -n "$URL_FILE" ]; then
        echo "$templateUrl" > "$URL_FILE"
    fi
done

if $DRY; then
    add_args+=(--dryrun)
    echo >&2 "Dry run mode"
fi

add_args+=('--exclude=*.yaml')

s3_sync "${add_args[@]}" . "s3://${BUCKET}/${TARGET}/"
