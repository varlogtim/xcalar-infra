#!/bin/bash

TTL="${TTL:-900}"
ZONE="${ZONE:-xcalar-cloud}"
DOMAIN="${DOMAIN:-xcalar.cloud}"
DRYRUN="${DRYRUN-1}"

usage () {
    echo "Usage: $0 (add|remove) NAME1 IP1 NAME2 IP2 ..."
    echo
    echo "Set the following variables to control which zone/domain to update"
    echo
    echo " TTL=$TTL"
    echo " ZONE=$ZONE"
    echo " DOMAIN=$DOMAIN"
    echo " DRYRUN=$DRYRUN"
    echo
    exit 1
}

if [ $# -eq 0 ]; then
    usage
fi

OP="${1}"
shift

case "$OP" in
    -h|--help) usage ;;
    add) ;;
    remove) ;;
    *) echo >&2 "Operation must be add or remove"; exit 1;;
esac

gdnsr () {
    if [ "$DRYRUN" = 1 ]; then
        echo "dry-run: gcloud dns record-sets $* --zone ${ZONE}"
    else
        (
        set -x
        gcloud dns record-sets "$@" --zone "${ZONE}"
        )
    fi
}

gdnst () {
    gdnsr transaction "$@"
}

abort () {
    gdnst abort
    echo >&2 "ERROR: Aborted gcloud dns transaction: $*"
    exit 1
}


set -e
gdnsr export xcalar-cloud.zone --zone-file-format
gdnst start

set +e

while [ $# -ge 2 ]; do
    gdnst "${OP}" --name "${1}.${DOMAIN}" --ttl "${TTL}" --type A "${2}"
    shift 2
done
gdnst execute 
