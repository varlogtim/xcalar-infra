#!/bin/bash

say () {
    echo >&2 "$*"
}

if [ -z "$1" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "usage: $0 <installer-url> <cluster (default: `whoami`-xcalar)> <count (default: 3)>" >&2
    exit 1
fi
DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
INSTALLER="${1}"
CLUSTER="${2:-`whoami`-xcalar}"
COUNT="${3:-3}"
INSTANCES=($(set -o braceexpand; eval echo $CLUSTER-{1..$COUNT}))
say "Launching ${#INSTANCES[@]} instances: ${INSTANCES[@]} .."
set -x
gcloud compute instances create ${INSTANCES[@]} \
    --image ${IMAGE:-xcbuilder-ubuntu-1404-1458251279} \
    --zone ${ZONE:-us-central1-f} \
    --machine-type ${INSTANCE_TYPE:-n1-standard-4} \
    --network=private \
    --metadata installer="$INSTALLER" \
    --preemptible \
    --metadata-from-file user-data=$DIR/gce-userdata.sh
