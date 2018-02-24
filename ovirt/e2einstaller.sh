#!/bin/bash

###########
#
#  ./e2einstall.sh netstoreinstallpath node-name node-ip [True|False] 
#	(if True will start up Xcalar at end)
#
###########
DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# set the hostname
echo "set hostname to $2"
/bin/hostnamectl set-hostname $2
# restart so logs will see the new hostname
echo "restart service rsyslog restart"
service rsyslog restart

# install xcalar:
# get the requested CLI installer from netstore, and kick off the installation
# remove some yum repos first to clean things up
echo "yo"
curl http://netstore/$1 -o $DIR/installer.sh
rm -f /etc/yum.repos.d/epel*.repo /etc/yum.repos.d/mapr.repo /etc/yum.repos.d/nodesource.repo /etc/yum.repos.d/sbt.repo /etc/yum.repos.d/draios.repo /etc/yum.repos.d/ius.repo /etc/yum.repos.d/azure-cli.repo
chmod u+x $DIR/installer.sh
/bin/bash $DIR/installer.sh --nostart --caddy --startonboot

# copy in the license files
echo 'copy lic files in to xcalar'
cp $DIR/XcalarLic.key /etc/xcalar/XcalarLic.key
cp $DIR/EcdsaPub.key /etc/xcalar/EcdsaPub.key

# generate config file.
# if you passed only one node (single node cluster - use localhost)
# multiple nodes passed put that node list
echo 'generate config file via templatehelper.sh'
chmod u+x $DIR/templatehelper.sh
/bin/bash $DIR/templatehelper.sh $3
#genconfigscript='/opt/xcalar/scripts/genConfig.sh'
#templatefile='/etc/xcalar/template.cfg'
#fileloc='/etc/xcalar/default.cfg'

#$genconfigscript $templatefile - localhost > $fileloc

# now start the xcalar service
#service xcalar start

