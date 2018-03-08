#!/bin/bash

# set up admin account
echo 'setup admin acct'
ADMIN_USERNAME=${ADMIN_USERNAME:-xdpadmin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-Welcome1}
ADMIN_EMAIL=${ADMIN_EMAIL:-support@xcalar.com}

XCE_CONFIG="${XCE_CONFIG:-/etc/xcalar/default.cfg}"
if [ ! -e "$XCE_CONFIG" ]; then
  echo "File $XCE_CONFIG is not existing on $HOSTNAME!"
  exit 1
fi

# get value of Constants.XcalarRootCompletePath from the default file,
# which should be path to xcalar home (shared storage if cluster)
# the Xcalar API we call to set up admin account will write in to this dir
XCE_HOME=$(awk -F'=' '/^Constants.XcalarRootCompletePath/{print $2}' $XCE_CONFIG) # could be /mnt/xcalar etc
echo "xce home found: $XCE_HOME"

# check if this value is empty... if so fail out because api call is not going to work
if [ -z "$XCE_HOME" ]; then
  echo "var Constants.XcalarRootCompletePath in file $XCE_CONFIG is empty"
  echo "I can't set up admin account on this node $HOSTNAME"
  exit 1
fi

#XCE_HOME=/var/opt/xcalar
mkdir -p $XCE_HOME/config # this is where the api is going to write the config file to
chown -R xcalar:xcalar $XCE_HOME/config # so give xcalar permissions to write there
jsonData="{ \"defaultAdminEnabled\": true, \"username\": \"$ADMIN_USERNAME\", \"email\": \"$ADMIN_EMAIL\", \"password\": \"$ADMIN_PASSWORD\" }"
curl -H "Content-Type: application/json" -X POST -d "$jsonData" "http://127.0.0.1:12124/login/defaultAdmin/set"
