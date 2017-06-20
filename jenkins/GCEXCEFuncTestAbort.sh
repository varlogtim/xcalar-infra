#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$HOME/google-cloud-sdk/bin:$PATH"

cluster=`echo $CLUSTER | tr A-Z a-z`

gce/gce-cluster-delete.sh $cluster

if [ "$cluster" != "" ]; then
    gcloud compute ssh graphite -- "sudo rm -rf /srv/grafana-graphite/data/whisper/collectd/$cluster"
fi
