#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$PATH"

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

set +e
source "$XLRINFRADIR/bin/clusterCmds.sh"
initClusterCmds
set -e

set -x

cluster=`echo $CLUSTER | tr A-Z a-z`

if [ "$LEAVE_ON_FAILURE" = "true" ]; then
    echo "Make sure you delete the cluster once done"
else
    clusterDelete "$cluster"
fi

if [ "$cluster" != "" ]; then
    if [ "$VmProvider" = "GCE" ]; then
        nodeSsh "" "graphite" -- "sudo rm -rf /srv/grafana-graphite/data/whisper/collectd/$cluster"
    fi
fi
