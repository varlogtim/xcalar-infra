#!/bin/bash

if [ -n "$1" ]; then
    CLUSTER="${1}"
    shift
else
    CLUSTER="`id -un`-xcalar"
fi

DEPLOY="$CLUSTER-deploy"

count=`az group deployment show --resource-group "$CLUSTER" --name "$DEPLOY" --output json --query 'properties.outputs.scaleNumber.value' --output tsv`
domainNameLabel=`az group deployment show --resource-group "$CLUSTER" --name "$DEPLOY" --output json --query 'properties.outputs.domainNameLabel.value' --output tsv`
location=`az group deployment show --resource-group "$CLUSTER" --name "$DEPLOY" --output json --query 'properties.outputs.location.value' --output tsv`
for ii in `seq 0 $(( $count - 1 ))`; do
    echo "${domainNameLabel}-${ii}.${location}.cloudapp.azure.com"
done

