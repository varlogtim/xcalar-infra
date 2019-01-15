#!/bin/bash

set -e

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$PATH"

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

source "$XLRINFRADIR/bin/clusterCmds.sh"
initClusterCmds

set -x

cluster=`echo $CLUSTER | tr A-Z a-z`

if [ "$LEAVE_ON_FAILURE" = "true" ]; then
    echo "Make sure you delete the cluster once done"
else
    clusterDelete "$cluster"
fi

# in GCE case, remove dir for this cluster from the graphite VM stored on GC
# ignore cluster arg when calling nodeSsh; want the cmd sent to the graphite VM
if [ "$cluster" != "" ]; then
    if [ "$VmProvider" = "GCE" ]; then
        nodeSsh "" "graphite" "sudo rm -rf /srv/grafana-graphite/data/whisper/collectd/$cluster"
    fi
fi
