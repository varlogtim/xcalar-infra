#!/bin/bash

set -e

# set up admin account
echo 'This script will set up admin acct' >&2
ADMIN_USERNAME=${ADMIN_USERNAME:-xdpadmin}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-Welcome1}
ADMIN_EMAIL=${ADMIN_EMAIL:-support@xcalar.com}

XCE_CONFIG="${XCE_CONFIG:-/etc/xcalar/default.cfg}"
if [ ! -e "$XCE_CONFIG" ]; then
    echo "$XCE_CONFIG does not exist on $HOSTNAME!" >&2
    exit 1
fi

# get value of Constants.XcalarRootCompletePath from the default file,
# which should be path to xcalar home (shared storage if cluster)
# the Xcalar API we call to set up admin account will write in to this dir
XCE_HOME=$(awk -F'=' '/^Constants.XcalarRootCompletePath/{print $2}' $XCE_CONFIG) # could be /mnt/xcalar etc

# check if this value is empty... if so fail out because api call is not going to work
if [ -z "$XCE_HOME" ]; then
    echo "var Constants.XcalarRootCompletePath in $XCE_CONFIG is empty; Can't set up admin account on $HOSTNAME" >&2
    exit 1
fi

#XCE_HOME=/var/opt/xcalar
mkdir -p -m 0777 $XCE_HOME/config # this is where the api is going to write the config file to
jsonData="{ \"defaultAdminEnabled\": true, \"username\": \"$ADMIN_USERNAME\", \"email\": \"$ADMIN_EMAIL\", \"password\": \"$ADMIN_PASSWORD\" }"
curl -H "Content-Type: application/json" -X POST -d "$jsonData" "http://127.0.0.1:12124/login/defaultAdmin/set"
