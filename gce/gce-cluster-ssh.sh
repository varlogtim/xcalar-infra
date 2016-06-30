#!/bin/bash

if [ -z "$1" ]; then
    echo >&2 "usage: $0 <cluster (default: `whoami`-xcalar)> ssh-command"
    exit 1
fi

if [ -n "$1" ]; then
    CLUSTER="${1}"
    shift
else
    CLUSTER="`whoami`-xcalar"
fi

HOSTS="$(gcloud compute instances list | grep RUNNING | grep ${CLUSTER}- | awk '{print $5}')"


pssh -i -H "$HOSTS" "$@"
