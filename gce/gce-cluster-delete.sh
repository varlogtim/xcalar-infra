#!/bin/bash

export CLOUDSDK_COMPUTE_REGION=${CLOUDSDK_COMPUTE_REGION-us-central1}
export CLOUDSDK_COMPUTE_ZONE=${CLOUDSDK_COMPUTE_ZONE-us-central1-f}

say () {
    echo >&2 "$*"
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    say "$0 <cluster-name (default: `id -un`-xcalar>"
    exit 1
fi
CLUSTER="${1:-`id -un`-xcalar}"

set +e

INSTANCES=($(gcloud compute instances list | awk '$1~/^'$CLUSTER'-[0-9]+/{print $1}'))

if [ "${#INSTANCES[@]}" -eq 0 ]; then
    say "No instances found for cluster $CLUSTER"
else
    say "WARNING: Deleting the following instances! Press Ctrl-C to abort. Sleeping for 10s."
    say "${INSTANCES[@]}"
    sleep 10
    say "Deleting ${INSTANCES[@]} ..."
    gcloud compute instances delete -q "${INSTANCES[@]}"
    say "** Detaching swap. Please ignore any errors **"
    for inst in "${INSTANCES[@]}"; do
        ii="${inst##${CLUSTER}-}"
        gcloud compute instances detach-disk -q ${CLUSTER}-${ii} --disk=${CLUSTER}-swap-${ii} || true
    done
fi
echo "Deleting nfs:/srv/share/nfs/cluster/$CLUSTER"
gcloud compute ssh nfs --command 'sudo rm -rf /srv/share/nfs/cluster/'$CLUSTER

DISKS=($(gcloud compute disks list | awk '$1~/^'$CLUSTER'-swap-[0-9]+/{print $1}'))
if [ "${#DISKS[@]}" -gt 0 ]; then
    say "** Deleting swap. Please ignore any errors **"
    gcloud compute disks delete -q "${DISKS[@]}"
fi
