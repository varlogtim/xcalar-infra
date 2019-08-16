#!/bin/bash
#
# shellcheck disable=SC1091,SC2086

set -ex

export XLRINFRADIR=${XLRINFRADIR:-$PWD}
export PATH=$XLRINFRADIR/bin:/opt/xcalar/bin:$HOME/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin:$PATH

NUM_AVAIL=$(aws cloudformation describe-stacks --query 'Stacks[?Tags[?Key==`available`]] | length(@)')

if [ $NUM_AVAIL -lt $TOTAL_AVAIL ]; then
    NUM_TO_CREATE=$(expr $TOTAL_AVAIL - $NUM_AVAIL)
    echo "Creating ${NUM_TO_CREATE} stacks"
    for i in `seq 1 $NUM_TO_CREATE`; do
        echo "Creating stack ${i}"
        SUFFIX=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
        aws cloudformation create-stack --stack-name ${STACK_PREFIX}${SUFFIX} \
        --template-url ${TEMPLATE_URL} \
        --parameters ParameterKey=ClusterSize,ParameterValue=${STARTING_CLUSTER_SIZE} \
                    ParameterKey=AMIUsWest2,ParameterValue=${AMI} \
        --tags Key=available,Value=true \
                Key=deployment,Value=saas \
        --capabilities CAPABILITY_IAM
    done
fi
