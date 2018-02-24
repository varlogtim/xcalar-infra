#!/bin/bash

############
#
# ./templatehelper.sh node0ip node1ip ... nodeN-ip
#
# if only 1 ip, calls the genConfig with localhost for one node cluster
#
############

genconfigscript='/opt/xcalar/scripts/genConfig.sh'
templatefile='/etc/xcalar/template.cfg'
fileloc='/etc/xcalar/default.cfg'

NUM_IPS=$#
if [ $NUM_IPS -eq 1 ]; then
  $genconfigscript $templatefile - localhost > $fileloc
else
  echo "This is for a cluster configuration..."
  CLUSTERDIR=$1
  shift
  echo "Cluster dir: $CLUSTERDIR"
  echo "IP list: $@"
  $genconfigscript $templatefile - "$@" > $fileloc
  # replace the XcalarRootCompletePath with cluster dir passed in
  CLSVAR=Constants.XcalarRootCompletePath
  CLSVARTEMPLATEVAL=$(grep -oP "(?<=$CLSVAR=)"\\S* $fileloc)
  echo $CLUSTERDIR
  echo $CLSVAR
  echo $CLSVARTEMPLATEVAL
  # replace what's there with the cluster
  sed -i s@$CLSVARTEMPLATEVAL@$CLUSTERDIR@g $fileloc
fi
