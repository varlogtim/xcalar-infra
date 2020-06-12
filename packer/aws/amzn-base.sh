#!/bin/bash
#
# shellcheck disable=SC1091,SC2086

. infra-sh-lib
. aws-sh-lib

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE=$DIR/amzn-base.yaml
MANIFEST="$(basename "$TEMPLATE" .yaml)"-manifest.json
while [ $# -gt 0 ]; do
    cmd="$1"
    shift
    case "$cmd" in
        -t|--template) TEMPLATE="$1"; shift;;
        --installer) INSTALLER="$1"; shift;;
        *) die "Unknown parameter $cmd";;
    esac
done

chmod 0700 $XLRINFRADIR/packer/ssh
chmod 0600 $XLRINFRADIR/packer/ssh/id_packer.pem

if ! jq -r . < $TEMPLATE >/dev/null 2>&1; then
    if ! cfn-flip < ${TEMPLATE} > ${TEMPLATE%.*}.json; then
        die "Failed to convert template $TEMPLATE"
    fi
    TEMPLATE="${TEMPLATE%.*}.json"
fi


#AMZN1_AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/amzn-ami-hvm-x86_64-gp2  --query Parameter.Value --output text)
#AMZN2_AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2  --query Parameter.Value --output text)

#aws ec2 describe-images --image-ids $AMZN1_AMI $AMZN2_AMI --query Images[].Name --output text

#exit

aws_ssm_update_base() {
    aws ssm put-parameter --tier Standard --type String --name /xcalar/cloud/images/xdp-base-latest/xdp-base-amzn2  --value ami-0331cc46cb5937bc5 \
        --tags \
            Key=Name,Value=xdp-base-amzn2-2.0.20191024.3-1-20191106 \
            Key=OSID,Value=amzn2 \
            Key=BuildNumber,Value=${BUILD_NUMBER:-1} \
            Key=Today,Value="$(date +%Y%m%d)"
}

aws_ssm_del_tags() {
    [ $# -gt 0 ] || return 1
    aws ssm add-tags-for-resource --resource-type Parameter --resource-id "$@"
}

aws_ssm_add_tags() {
    [ $# -gt 0 ] || return 1
    aws ssm add-tags-for-resource --resource-type Parameter --resource-id "$@"
}

aws_ssm_get_tags() {
    [ $# -gt 0 ] || set -- /xcalar/cloud/images/xdp-base-latest/xdp-base-amzn2
    aws ssm list-tags-for-resource --resource-type Parameter --resource-id "$@"
}

if ! installer-version.sh "$INSTALLER" > installer-version.json; then
    die "Failed to get installer info"
fi
if [ -z "$INSTALLER_URL" ]; then
    if  ! INSTALLER_URL="$(installer-url.sh -d s3 "$INSTALLER")"; then
        die "Failed to get installer url for $INSTALLER"
    fi
fi

INSTALLER_URL="${INSTALLER_URL%\?*}"

# eval $(vault-aws-credentials-provider.sh -e)

if ! packer.io build \
    -machine-readable \
    -timestamp-ui \
    -only=amazon-ebs-amzn2 \
    -var base_owner='137112412989' \
    -var region=${AWS_DEFAULT_REGION:-us-west-2} \
    -var destination_regions=${REGIONS:-us-west-2,us-east-1} \
    -var disk_size=${DISK_SIZE:-10} \
    -var manifest="$MANIFEST" \
    -var installer="$INSTALLER" \
    -var installer_url="$INSTALLER_URL" \
    -var-file installer-version.json \
    -parallel=true $TEMPLATE; then
    exit 1
fi

if ami_amzn2=$(packer_ami_from_manifest amazon-ebs-amzn2 $MANIFEST); then
    #echo "ami_amzn1: $ami_amzn1"
    echo "ami_amzn2: $ami_amzn2"
    exit 0
fi
exit 1
