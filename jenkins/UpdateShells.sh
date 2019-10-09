#!/bin/bash
set -ex

export AWS_DEFAULT_REGION=us-west-2
export XLRINFRADIR=${XLRINFRADIR:-$PWD}
#have user name list, need find the stack id via tag
#username list is ALL, update all

if [ "${USERNAME_LIST}" == "ALL" ]; then
    RET=$(aws cloudformation describe-stacks --query "Stacks[?starts_with(StackName, '${STACK_PREFIX}')]")
    STACK_LIST=$(echo $RET | jq .[].StackId | cut -d '"' -f 2)
elif [ "${USERNAME_LIST}" != "ALL" ] && ! [ -z "${USERNAME_LIST}" ]; then
    for USERNAME in ${USERNAME_LIST[@]}; do
        RET=$(aws cloudformation describe-stacks --query "Stacks[?Tags[?Value=='${USERNAME}']]")
        STACK_LIST+=( $(echo $RET | jq .[].StackId | cut -d '"' -f 2) )
    done
else
    echo "Need to Specific USERNAME_LIST"
    exit 1
fi

for STACK in ${STACK_LIST[@]}; do
    STACK_NAME=$(echo ${STACK} | cut -d "/" -f 2)
    if [ "${LICENSE_TYPE}" == "dev" ]; then
        KEY=$(curl -d '{"secret":"xcalarS3cret","userId":"'"${STACK_NAME}"'","licenseType":"Developer","compress":true,
              "usercount":1,"nodecount":1025,"expiration":90,"licensee":"Xcalar, Inc","product":"Xcalar Data Platform",
              "onexpiry":"Warn","jdbc":true}' -H "Content-type: application/json" -X POST "${LICENSE_ENDPOINT}" | jq .Compressed_Sig | cut -d '"' -f 2)
    elif [ "${LICENSE_TYPE}" == "prod" ]; then
        KEY=$(curl -d '{"secret":"xcalarS3cret","userId":"'"${STACK_NAME}"'","licenseType":"Production","compress":true,
              "usercount":1,"nodecount":1025,"expiration":90,"licensee":"Xcalar, Inc","product":"Xcalar Data Platform",
              "onexpiry":"Warn","jdbc":true}' -H "Content-type: application/json" -X POST "${LICENSE_ENDPOINT}" | jq .Compressed_Sig | cut -d '"' -f 2)
    else
        echo "Need to provide the licenseType"
        exit 1
    fi
    aws cloudformation update-stack --stack-name ${STACK} \
                                    --no-use-previous-template \
                                    --template-url ${CFN_TEMPLATE_URL} \
                                    --parameters  ParameterKey=ImageId,ParameterValue="${AMI}",UsePreviousValue=false \
                                                ParameterKey=ClusterSize,ParameterValue=${STARTING_CLUSTER_SIZE},UsePreviousValue=false \
                                                ParameterKey=LicenseKey,ParameterValue=${KEY},UsePreviousValue=false \
                                                ParameterKey=AuthStackName,ParameterValue=${AUTH_STACK_NAME},UsePreviousValue=false \
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
        elif [ $STATUS == "UPDATE_ROLLBACK_IN_PROGRESS" ] | [ $STATUS == "UPDATE_ROLLBACK_COMPLETE" ]; then
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
