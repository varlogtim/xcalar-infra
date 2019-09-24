#!/bin/bash
set -ex

export AWS_DEFAULT_REGION=us-west-2
export XLRINFRADIR=${XLRINFRADIR:-$PWD}
#have user name list, need find the stack id via tag
#username list is ALL, update all

if [ "${USERNAME_LIST}" == "ALL" ]; then
    RET=$(aws cloudformation describe-stacks --query "Stacks[?starts_with(StackName, '${STACK_PREFIX}')]")
    STACK_LIST=$(echo $RET | jq .[].StackId | cut -d '"' -f 2)
elif [ "${USERNAME_LIST}" != "ALL" ] && ! [ -z "${USERNAME_LIST}"]; then
    for USERNAME in ${USERNAME_LIST[@]}; do
        RET=$(aws cloudformation describe-stacks --query "Stacks[?Tags[?Value=='${USERNAME}']]")
        STACK_LIST+=( $(echo $RET | jq .[].StackId | cut -d '"' -f 2) )
    done
else
    echo "Need to Specific USERNAME_LIST"
    exit 1
fi



for STACK in ${STACK_LIST[@]}; do
    #TODO
    #generate license key
    echo ${STACK}
    aws cloudformation update-stack --stack-name ${STACK} \
                                    --no-use-previous-template \
                                    --template-url ${CFN_TEMPLATE_URL} \
                                    --parameters  ParameterKey=ImageId,ParameterValue="${AMI}",UsePreviousValue=false \
                                                ParameterKey=ClusterSize,ParameterValue=${STARTING_CLUSTER_SIZE},UsePreviousValue=false \
                                    --role-arn ${ROLE} \
                                    --capabilities CAPABILITY_IAM
done

while true; do
    echo "Checking whether update was successful"
    NEW_STACK_LIST=(${STACK_LIST[@]})
    for STACK in ${STACK_LIST[@]}; do
        echo "Checking status for $STACK"
        STATUS=$(aws cloudformation describe-stacks --query "Stacks[?StackId==\`${STACK}\`].StackStatus" | jq .[0] | cut -d '"' -f 2)
        if [ $STATUS == "UPDATE_COMPLETE" ]; then
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
