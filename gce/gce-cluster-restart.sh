#!/bin/bash
export CLOUDSDK_COMPUTE_REGION=${CLOUDSDK_COMPUTE_REGION-us-central1}
export CLOUDSDK_COMPUTE_ZONE=${CLOUDSDK_COMPUTE_ZONE-us-central1-f}

say () {
    echo >&2 "$*"
}

if [ -z "$1" ] || [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "usage: $0 <count (default: 3)> <cluster (default: `whoami`-xcalar)>" >&2
    exit 1
fi
DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"
COUNT="${1:-3}"
CLUSTER="${2:-`whoami`-xcalar}"
CONFIG=/tmp/$CLUSTER-config.cfg
UPLOADLOG=/tmp/$CLUSTER-manifest.log
WHOAMI="$(whoami)"
EMAIL="$(git config user.email)"
INSTANCES=($(set -o braceexpand; eval echo $CLUSTER-{1..$COUNT}))

PIDS=()

for host in ${INSTANCES[@]}; do
    gcloud compute ssh $host --command "sudo service xcalar stop" </dev/null &
    PIDS+=($!)
done
ret=0
for pid in ${PIDS[@]}; do
    wait $pid
    if [ $? -ne 0 ]; then
        ret=1
    fi
done
if [ $ret -eq 1 ]; then
    echo "service xcalar stop failed"
    exit $ret
fi
PIDS=()

for host in ${INSTANCES[@]}; do
    gcloud compute ssh $host --command "sudo service xcalar start" </dev/null &
    PIDS+=($!)
done
ret=0
for pid in ${PIDS[@]}; do
    wait $pid
    if [ $? -ne 0 ]; then
        ret=1
    fi
done
if [ $ret -eq 1 ]; then
    echo "service xcalar start failed"
    exit $ret
fi
