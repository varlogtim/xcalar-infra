#!/bin/bash

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
    gcloud compute ssh $host --command "grep 'XUsrNodeMain All nodes now network ready' /var/log/Xcalar.log" </dev/null &
    PIDS+=($!)
done
wait ${PIDS[@]}
