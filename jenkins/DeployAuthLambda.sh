#!/bin/bash

# Inputs:
# REGION (maps to: AWS_REGION)
# S3_BUCKET
# ACCOUNT_ID
# FUNCTION_NAME
# USER_TABLE_NAME
# SESSION_TABLE_NAME
# IDENTITY_POOL_ID
# USER_POOL_ID
# CLIENT_ID
# CLOUDFORMATION_STACK_NAME
# CORS_ORIGIN

set -ex
export AWS_DEFAULT_REGION=us-west-2
export AWS_DEFAULT_FNAME="AwsServerlessExpressFunction"
export AWS_REGION="${REGION:-$AWS_DEFAULT_REGION}"
export XLRINFRADIR=${XLRINFRADIR-$HOME/xcalar-infra}
SAAS_AUTH_DIR="$XLRINFRADIR/aws/lambdaFns/saas/saas-auth"

PATH=/opt/xcalar/bin:$PATH
export PATH

if ! aws s3api get-bucket-location --bucket ${S3_BUCKET} \
         --region ${AWS_REGION}; then
    aws s3 mb s3://${S3_BUCKET} --region ${AWS_REGION}
fi

(cd "$SAAS_AUTH_DIR" &&
     /opt/xcalar/bin/node \
         ./scripts/configure.js \
         --account-id ${ACCOUNT_ID} --bucket-name ${S3_BUCKET} \
         --function-name ${FUNCTION_NAME:-$AWS_DEFAULT_FNAME} \
         --region ${AWS_REGION} \
         --user-table-name ${USER_TABLE_NAME} \
         --session-table-name ${SESSION_TABLE_NAME} \
         --identity-pool-id ${IDENTITY_POOL_ID} \
         --user-pool-id ${USER_POOL_ID} \
         --client-id ${CLIENT_ID} \
         --cloudformation-stack ${CLOUDFORMATION_STACK_NAME} \
         --cors-origin ${CORS_ORIGIN} &&
     /opt/xcalar/bin/npm install &&
     /opt/xcalar/bin/npm uninstall passport-cognito --no-save &&
     /opt/xcalar/bin/npm install ./passport-cognito-1.0.0.tgz &&
     aws cloudformation package --template ./cloudformation.yaml \
         --s3-bucket ${S3_BUCKET} --output-template ./packaged-sam.yaml \
         --region ${AWS_REGION} &&
     aws cloudformation deploy --template-file packaged-sam.yaml \
         --stack-name ${CLOUDFORMATION_STACK_NAME} \
         --capabilities CAPABILITY_IAM --region ${AWS_REGION} \
         --role-arn ${ROLE} ||
         aws cloudformation describe-stack-events --stack-name saas-sam-auth-test)
# we want to deconfigure no matter what
(cd "$SAAS_AUTH_DIR" &&
     /opt/xcalar/bin/node ./scripts/deconfigure.js)
