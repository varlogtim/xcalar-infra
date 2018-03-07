#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$HOME/google-cloud-sdk/bin:$PATH"

set -x
set

cluster=`echo $CLUSTER | tr A-Z a-z`

if [ "$LEAVE_ON_FAILURE" = "true" ]; then
    echo "Make sure you delete the cluster once done"
else    
    xcalar-infra/gce/gce-cluster-delete.sh $cluster
fi    

if [ "$cluster" != "" ]; then
    gcloud compute ssh graphite -- "sudo rm -rf /srv/grafana-graphite/data/whisper/collectd/$cluster"
fi
