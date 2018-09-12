#!/bin/bash

PREFIX=cfn/prod/v1/
BUCKET=xcrepoe1
URL=https://s3.amazonaws.com/${BUCKET}/${PREFIX}xdp-standard.template

aws cloudformation create-stack \
    --region us-east-1 --capabilities CAPABILITY_IAM --on-failure DO_NOTHING \
    --parameters ParameterKey=VPCID,ParameterValue=vpc-30100e55 \
                 ParameterKey=ClusterInstanceType,ParameterValue=c5d.2xlarge \
                 ParameterKey=AssociatePublicIpAddress,ParameterValue=true \
                 ParameterKey=ClusterAccessSGId,ParameterValue=sg-01c9dd12946e730bc \
                 ParameterKey=KeyPair,ParameterValue=xcalar-us-east-1 \
                 ParameterKey=VPCCIDR,ParameterValue=172.31.0.0/16 \
                 ParameterKey=PrivateSubnetCluster,ParameterValue=subnet-6a7d1641 \
                 --template-body file://xdp-standard.template "$@"
