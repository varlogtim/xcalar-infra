#!/bin/bash

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo >&2 "$0 <cluster-name (default: `id -un`-xcalar>"
    exit 1
fi
CLUSTER="${1:-`id -un`-xcalar}"

if [ -z "$CLUSTER" ]; then
    echo >&2 "Invalid cluster"
    exit 1
fi

INSTANCES="$(gcloud compute instances list | grep $CLUSTER | awk '{print $1}')"

if [ -z "$INSTANCES" ]; then
    echo >&2 "No instances found for cluster $CLUSTER"
else
    gcloud compute instances delete $INSTANCES
fi
echo "Deleting nfs::/srv/share/nfs/cluster/$CLUSTER"
gcloud compute ssh nfs --zone us-central1-f --command 'sudo rm -rf /srv/share/nfs/cluster/'$CLUSTER
