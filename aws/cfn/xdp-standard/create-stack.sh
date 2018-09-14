#!/bin/bash

set -e

. infra-sh-lib
. aws-sh-lib


PREFIX=cfn/prod/v$(cat $DIR/VERSION)
BUCKET=xcrepoe1
URL_PREFIX=https://$(aws_s3_endpoint ${BUCKET})/${PREFIX%/}
TemplateUrl=${URL_PREFIX}/xdp-standard.template
BootstrapUrl=${URL_PREFIX}/scripts/user-data.sh
CustomScriptUrl=${URL_PREFIX}
export AWS_DEFAULT_REGION=us-east-1

check_url() {
    local http_code
    if ! http_code=$(curl -fsSL -o /dev/null -r 0-0 -w '%{http_code}\n' "$@"); then
        echo >&2 "Returned error"
        return 1
    fi
    if ! [[ $http_code =~ ^20 ]]; then
        echo >&2 "Returned ${http_code}"
        return 1
    fi
}

aws_cfn() {
    local cmd="$1"
    shift
    aws cloudformation $cmd \
        --region ${AWS_DEFAULT_REGION} --capabilities CAPABILITY_IAM --on-failure DO_NOTHING \
        --parameters ParameterKey=VPCID,ParameterValue=vpc-30100e55 \
                    ParameterKey=ClusterInstanceType,ParameterValue=c5d.2xlarge \
                    ParameterKey=AssociatePublicIpAddress,ParameterValue=true \
                    ParameterKey=ClusterAccessSGId,ParameterValue=sg-01c9dd12946e730bc \
                    ParameterKey=KeyName,ParameterValue=xcalar-${AWS_DEFAULT_REGION} \
                    ParameterKey=VPCCIDR,ParameterValue=$(curl -s -4 http://icanhazip.com)/32 \
                    ParameterKey=PrivateSubnetCluster,ParameterValue=subnet-6a7d1641 \
                    ParameterKey=BootstrapUrl,ParameterValue="${BootstrapUrl}" \
                    ParameterKey=CustomScriptUrl,ParameterValue="${CustomScriptUrl}" \
                    --template-body file://xdp-standard.template "$@"
}

aws_s3_endpoint $BUCKET

check_url "$BootstrapUrl" || exit 1
check_url "$TemplateUrl" || exit 1
check_url "$CustomScriptUrl" || exit 1

aws cloudformation validate-template --template-body file://xdp-standard.template \
    && aws_cfn create-stack "$@"
