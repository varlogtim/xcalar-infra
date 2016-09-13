#!/bin/bash
export CLOUDSDK_COMPUTE_REGION=${CLOUDSDK_COMPUTE_REGION-us-central1}
export CLOUDSDK_COMPUTE_ZONE=${CLOUDSDK_COMPUTE_ZONE-us-central1-f}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo >&2 "$0 <cluster-name (default: `id -un`-xcalar>"
    exit 1
fi
CLUSTER="${1:-`id -un`-xcalar}"

if [ -z "$CLUSTER" ]; then
    echo >&2 "Invalid cluster"
    exit 1
fi

INSTANCES="$(gcloud compute instances list | grep -w $CLUSTER | awk '{print $1}')"

if [ -z "$INSTANCES" ]; then
    echo >&2 "No instances found for cluster $CLUSTER"
else
    gcloud compute instances delete -q $INSTANCES
fi
echo "Deleting nfs:/srv/share/nfs/cluster/$CLUSTER"
gcloud compute ssh nfs --command 'sudo rm -rf /srv/share/nfs/cluster/'$CLUSTER
