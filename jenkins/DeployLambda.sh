#!/bin/bash

set -ex
export AWS_DEFAULT_REGION=us-west-2
export XLRINFRADIR=${XLRINFRADIR-$HOME/xcalar-infra}
SAM_SAAS_DIR="$XLRINFRADIR/aws/lambdaFns/saas/sam-saas"


if ! aws s3 ls ${S3_BUCKET}; then
    aws s3 mb "s3://${S3_BUCKET}"
fi

if ! aws dynamodb describe-table --table-name ${USER_TABLE_NAME}; then
    aws dynamodb create-table --table-name ${USER_TABLE_NAME}
        --attribute-definitions AttributeName=user_name,AttributeType=S \
        --key-schema AttributeName=user_name,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST
fi

if ! aws dynamodb describe-table --table-name ${BILLING_TABLE_NAME}; then
    aws dynamodb create-table --table-name ${BILLING_TABLE_NAME} \
        --attribute-definitions AttributeName=user_name,AttributeType=S AttributeName=timestamp,AttributeType=N \
        --key-schema AttributeName=user_name,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
        --billing-mode PAY_PER_REQUEST
fi


(cd "$SAM_SAAS_DIR" &&
sam build &&
sam package --output-template packaged.yaml --s3-bucket ${S3_BUCKET} &&
sam deploy --template-file packaged.yaml \
           --capabilities CAPABILITY_IAM \
           --stack-name ${STACK_NAME} \
           --role-arn ${ROLE})







