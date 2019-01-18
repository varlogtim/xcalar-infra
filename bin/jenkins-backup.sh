#!/bin/bash

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JENKINS_URL=${JENKINS_URL:-https://jenkins.int.xcalar.com}

if ! vault read auth/token/lookup-self >/dev/null 2>&1; then
    ${DIR}/vault-puppet.sh
fi

JSON=$(vault kv get -format=json -field=data secret/roles/jenkins-slave/swarm)

PASSWORD="$(jq -r .password <<<$JSON)"
USERNAME="$(jq -r .username <<<$JSON)"

butler plugins e -s $JENKINS_URL -u $USERNAME -p $PASSWORD
butler jobs e -s $JENKINS_URL -u $USERNAME -p $PASSWORD
