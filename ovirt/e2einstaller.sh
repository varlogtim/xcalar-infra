#!/bin/bash

###########
#
#  ./e2einstall.sh installerurl node-name node-ip [True|False]
#	(if True will start up Xcalar at end)
#   Assumes Xcalar license file XcalarLic.key exists in same dir the shell script lives in
#
###########
DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# set the hostname
echo "set hostname to $2"
/bin/hostnamectl set-hostname $2
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi

# restart so logs will see the new hostname
echo "restart service rsyslog restart"
service rsyslog restart
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi

# install xcalar:
# get the requested CLI installer from netstore, and kick off the installation
# remove some yum repos first to clean things up
curl "$1" -o $DIR/installer.sh
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi

rm -f /etc/yum.repos.d/epel*.repo /etc/yum.repos.d/mapr.repo /etc/yum.repos.d/nodesource.repo /etc/yum.repos.d/sbt.repo /etc/yum.repos.d/draios.repo /etc/yum.repos.d/ius.repo /etc/yum.repos.d/azure-cli.repo
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi

chmod u+x $DIR/installer.sh
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi
/bin/bash $DIR/installer.sh --nostart --caddy --startonboot
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi

# copy in the license files
echo 'copy lic files in to xcalar'
cp $DIR/XcalarLic.key /etc/xcalar/XcalarLic.key
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi

# generate config file.
# if you passed only one node (single node cluster - use localhost)
# multiple nodes passed put that node list
echo 'generate config file via templatehelper.sh'
chmod u+x $DIR/templatehelper.sh
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi

/bin/bash $DIR/templatehelper.sh $3
rc=$?
if [ $rc != 0 ]; then
  exit $rc
fi

