#!/bin/bash

set +e

NAME="$(basename ${BASH_SOURCE[0]})"

export CLOUDSDK_COMPUTE_REGION=${CLOUDSDK_COMPUTE_REGION-us-central1}
export CLOUDSDK_COMPUTE_ZONE=${CLOUDSDK_COMPUTE_ZONE-us-central1-f}

usage () {
    cat <<EOF >&2
    usage: $NAME {start|stop} vm-name ...

    example:

    $NAME start myvm-1
    $NAME stop myvm-1
EOF
    exit 1
}

gce_instances () {
    gcloud compute instances "$@"
    local rc=$?
    if [ $rc -ne 0 ]; then
        logger -t "$NAME" -i -s "[ERROR:$rc] gcloud compute instances $*"
    else
        logger -t "$NAME" -i -s "[OK] gcloud compute instances $*"
    fi
    return $rc
}

if [ -z "$1" ]; then
    usage
fi

cmd="$1"
case "$cmd" in
    -h|--help) usage ;;
    start) ;;
    stop) ;;
    list) ;;
    *) usage ;;
esac

gce_instances "$@"
exit $?
