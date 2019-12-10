#!/bin/bash

set +x
export XLRINFRADIR=$PWD
export PATH=$PWD/bin:/opt/xcalar/bin:$PATH
source azure/azure-sh-lib

az_login

for groupName in ${CLUSTER_NAME} ${CLUSTER_NAME%-rg}-rg ${CLUSTER_NAME}-rg ${CLUSTER_NAME%-*} ${CLUSTER_NAME%-*}-rg; do
  if az group show -g "$groupName"; then
     if [ "$RG_COMMAND" = delete ]; then
        az group delete -g "${groupName}" --yes
     elif [ "$RG_COMMAND" == scheduled_shutdown ]; then
        az_rg_scheduled_shutdown -g "${groupName}" --time "${TIME:-2300}" --timezone "${TIMEZONE:-pst}" --enable "${AUTOSHUTDOWN:-true}"
     else
        az_rg_${RG_COMMAND} "${groupName}"
     fi
     exit $?
  fi
done
echo "No cluster named ${CLUSTER_NAME} found"
exit 1
