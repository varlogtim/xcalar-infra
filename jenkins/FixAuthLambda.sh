#!/bin/bash

# Inputs:
# REGION (maps to: AWS_REGION)
# SESSION_TABLE_NAME
# CLOUDFORMATION_STACK_NAME

set -ex
export AWS_DEFAULT_REGION=us-west-2
export AWS_DEFAULT_FNAME="AwsServerlessExpressFunction"
export AWS_REGION="${REGION:-$AWS_DEFAULT_REGION}"
export XLRINFRADIR=${XLRINFRADIR-$HOME/xcalar-infra}
SAAS_AUTH_DIR="$XLRINFRADIR/aws/lambdaFns/saas/saas-auth"

PATH=/opt/xcalar/bin:$PATH
export PATH


API_URL="$(aws cloudformation describe-stacks \
                                 --region ${AWS_REGION} \
                                    --stack-name ${CLOUDFORMATION_STACK_NAME} \
                                    --query "Stacks[*].Outputs[?OutputKey=='ApiUrl'].OutputValue" \
                                    --output text)"
PARAM_STR="XCE_CLOUD_MODE=1\nXCE_CLOUD_SESSION_TABLE=${SESSION_TABLE_NAME}\nXCE_SAAS_LAMBDA_URL=${API_URL}\nXCE_CLOUD_REGION=${AWS_REGION}\nXCE_CLOUD_PREFIX=xc\nXCE_CLOUD_HASH_KEY=id\n"

aws ssm put-parameter --region $AWS_REGION --name "/xcalar/cloud/auth/${CLOUDFORMATION_STACK_NAME}" --value "$PARAM_STR" --type String
