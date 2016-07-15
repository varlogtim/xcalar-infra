#!/bin/bash

CLUSTER="${1:-`whoami`-xcalar}"

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"


INSTANCE_IDS=($(aws ec2 describe-instances --filter Name=tag:Cluster,Values=$CLUSTER --query 'Reservations[].Instances[].[InstanceId]' --output text))

set -x
aws ec2 terminate-instances "${INSTANCE_IDS[@]}"
