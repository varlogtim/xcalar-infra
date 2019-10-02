#!/bin/bash
set -ex

export AWS_DEFAULT_REGION=us-west-2
export XLRINFRADIR=${XLRINFRADIR:-$PWD}
#have user name list, need find the stack id via tag
#username list is ALL, update all
EXIT_CODE=0
CheckStatus() {
    STACKS=("$@")
    while true; do
        echo "Checking whether update was successful"
        NEW_STACK_LIST=(${STACKS[@]})
        for STACK in ${STACKS[@]}; do
            echo "Checking status for $STACK"
            STATUS=$(aws cloudformation describe-stacks --query "Stacks[?StackId==\`${STACK}\`].StackStatus" | jq .[0] | cut -d '"' -f 2)
            if [ $STATUS == "UPDATE_COMPLETE" ] || [ $STATUS == "CREATE_COMPLETE" ]; then
                echo "$STACK is ready"
                DELETE=($STACK)
                L=${#NEW_STACK_LIST[@]}
                for (( i=0; i<$L; i++ )); do
                    if [[ ${NEW_STACK_LIST[$i]} = $DELETE  ]]; then
                        unset NEW_STACK_LIST[$i]
                    fi
                done
            elif [ $STATUS == "UPDATE_ROLLBACK_IN_PROGRESS" ] || [ $STATUS == "UPDATE_ROLLBACK_COMPLETE" ]; then
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
            echo "${STACKS[@]}"
        done
        if [ ${#NEW_STACK_LIST[@]} -eq 0 ]; then
            echo "All stacks ready!"
            break;
        fi

        STACKS=("${NEW_STACK_LIST[@]}")
        sleep 15
    done
}

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
    RET=$(aws cloudformation describe-stacks --stack-name ${STACK})
    SIZE=$(echo $RET | jq '.[][0].Parameters[] | select(.ParameterKey=="ClusterSize")' | jq .ParameterValue | cut -d '"' -f 2)
    CNAME=$(echo $RET | jq '.[][0].Parameters[] | select(.ParameterKey=="CNAME")' | jq .ParameterValue | cut -d '"' -f 2)
    AUTHSTACKNAME=$(echo $RET | jq '.[][0].Parameters[] | select(.ParameterKey=="AuthStackName")' | jq .ParameterValue | cut -d '"' -f 2)
    if [ -z "$CNAME" ]; then
        CNAME_PARAMETER=''
    else
        CNAME_PARAMETER='ParameterKey=CNAME,UsePreviousValue=true'
    fi
    if [ -z "$AUTHSTACKNAME" ]; then
        AUTHSTACKNAME_PARAMETER=''
    else
        AUTHSTACKNAME='ParameterKey=AuthStackName,UsePreviousValue=true'
    fi
    if [ $SIZE != 0 ]; then
        aws cloudformation update-stack --stack-name ${STACK} --use-previous-template \
                                        --parameters ParameterKey=ClusterSize,ParameterValue=0, $CNAME_PARAMETER $AUTHSTACKNAME_PARAMETER \
                                        --role-arn ${ROLE} \
                                        --capabilities CAPABILITY_IAM
    fi
done

CheckStatus "${STACK_LIST[@]}"

for STACK in ${STACK_LIST[@]}; do
    STACK_NAME=$(echo ${STACK} | cut -d "/" -f 2)
    RET=$(aws cloudformation describe-stacks --stack-name ${STACK})
    UPDATE_STATUS=$(echo $RET| jq .[][0].StackStatus | cut -d '"' -f 2)
    CNAME=$(echo $RET | jq '.[][0].Parameters[] | select(.ParameterKey=="CNAME")' | jq .ParameterValue | cut -d '"' -f 2 | cut -d '.' -f 1)
    if [ $UPDATE_STATUS == "UPDATE_COMPLETE" ] || [ $UPDATE_STATUS == "CREATE_COMPLETE" ]; then
        UPDATE_STACK_LIST+=("${STACK}")
        if [ -z "$CNAME" ]; then
            CNAME=$(cat /dev/urandom | tr -dc 'a-z1-9' | fold -w 4 | head -n 1)
        fi
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
                                        --parameters  ParameterKey=ImageId,ParameterValue="${AMI}" \
                                                    ParameterKey=ClusterSize,ParameterValue=${STARTING_CLUSTER_SIZE}\
                                                    ParameterKey=License,ParameterValue=${KEY} \
                                                    ParameterKey=CNAME,ParameterValue="${CNAME}" \
                                                    ParameterKey=SessionTable,UsePreviousValue=true \
                                                    ParameterKey=AuthStackName,ParameterValue=${AUTH_STACK_NAME} \
                                        --role-arn ${ROLE} \
                                        --capabilities CAPABILITY_IAM
    fi
done

CheckStatus "${UPDATE_STACK_LIST[@]}"

exit ${EXIT_CODE}
