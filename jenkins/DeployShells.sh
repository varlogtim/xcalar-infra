#!/bin/bash
#
# shellcheck disable=SC1091,SC2086

set -ex
export AWS_DEFAULT_REGION=us-west-2
export XLRINFRADIR=${XLRINFRADIR:-$PWD}
export PATH=$XLRINFRADIR/bin:/opt/xcalar/bin:$HOME/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin:$PATH

EXIT_CODE=0
NUM_AVAIL=$(aws cloudformation describe-stacks --query 'Stacks[?Tags[?Key==`available`]] | length(@)')
if [ $NUM_AVAIL -lt $TOTAL_AVAIL ]; then
    NUM_TO_CREATE=$(expr $TOTAL_AVAIL - $NUM_AVAIL)
    echo "Creating ${NUM_TO_CREATE} stacks"
    for i in `seq 1 $NUM_TO_CREATE`; do
        echo "Creating stack ${i}"
        SUFFIX=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 10 | head -n 1)
        if [ "${LICENSE_TYPE}" == "dev" ]; then
            KEY=$(curl -d '{"secret":"xcalarS3cret","userId":"'"${STACK}${SUFFIX}"'","licenseType":"Developer","compress":true,
                "usercount":1,"nodecount":1025,"expiration":90,"licensee":"Xcalar, Inc","product":"Xcalar Data Platform",
                "onexpiry":"Warn","jdbc":true}' -H "Content-type: application/json" -X POST "${LICENSE_DEV_ENDPOINT}" | jq .Compressed_Sig | cut -d '"' -f 2)
        elif [ "${LICENSE_TYPE}" == "prod" ]; then
            KEY=$(curl -d '{"secret":"xcalarS3cret","userId":"'"${STACK}"'","licenseType":"Production","compress":true,
                "usercount":1,"nodecount":1025,"expiration":90,"licensee":"Xcalar, Inc","product":"Xcalar Data Platform",
                "onexpiry":"Warn","jdbc":true}' -H "Content-type: application/json" -X POST "${LICENSE_PROD_ENDPOINT}" | jq .Compressed_Sig | cut -d '"' -f 2)
        else
            echo "Need to provide the licenseType"
            exit 1
        fi
        RET=$(aws cloudformation create-stack \
        --role-arn ${ROLE} \
        --stack-name ${STACK_PREFIX}${SUFFIX} \
        --template-url ${CFN_TEMPLATE_URL} \
        --parameters ParameterKey=ClusterSize,ParameterValue=${STARTING_CLUSTER_SIZE} \
                    ParameterKey=ImageId,ParameterValue=${AMI} \
                    ParameterKey=LicenseKey,ParameterValue=${KEY} \
        --tags Key=available,Value=true \
                Key=deployment,Value=saas \
        --capabilities CAPABILITY_IAM)
        STACK_LIST+=( $(echo $RET | jq .StackId | cut -d '"' -f 2) )
    done
fi

while true; do
    echo "Checking whether creation was successful"
    NEW_STACK_LIST=("${STACK_LIST[@]}")
    for STACK in "${STACK_LIST[@]}"; do
        echo "Checking status for $STACK"
        STATUS=$(aws cloudformation describe-stacks --query "Stacks[?StackId==\`${STACK}\`].StackStatus" | jq .[0] | cut -d '"' -f 2)
        if [ $STATUS == "CREATE_COMPLETE" ]; then
            echo "$STACK is ready"
            DELETE=($STACK)
            L=${#NEW_STACK_LIST[@]}
            for (( i=0; i<$L; i++ )); do
                if [[ ${NEW_STACK_LIST[$i]} = $DELETE  ]]; then
                    unset NEW_STACK_LIST[$i]
                fi
            done
        elif [ $STATUS == "ROLLBACK_IN_PROGRESS" ] | [ $STATUS == "ROLLBACK_COMPLETE" ]; then
            echo "$STACK is faulty"
            EXIT_CODE=1
            DELETE=($STACK)
            L=${#NEW_STACK_LIST[@]}
            for (( i=0; i<$L; i++ )); do
                if [[ ${NEW_STACK_LIST[$i]} = $DELETE  ]]; then
                    unset NEW_STACK_LIST[$i]
                fi
            done
        else
            STATUS=$(aws cloudformation describe-stacks --query "Stacks[?StackId==\`${STACK}\`].StackStatus" | jq .[0])
            echo "$STACK is not ready. Status: $STATUS"
        fi

        echo "$STACK"
        echo "${NEW_STACK_LIST[@]}"
        echo "${STACK_LIST[@]}"
    done
    if [ ${#NEW_STACK_LIST[@]} -eq 0 ]; then
        echo "All stacks ready!"
        exit ${EXIT_CODE}
    fi

    STACK_LIST=("${NEW_STACK_LIST[@]}")
    sleep 15
done