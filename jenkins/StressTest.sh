#!/bin/bash

echo Building on $NODE_NAME
XLRDIR=`pwd`
PATH="$PATH:$XLRDIR/bin"

# Make the qa data directory
if [ -a /var/tmp/qa ]
then
    rm /var/tmp/qa
fi
ln -s "$XLRDIR/src/data/qa" /var/tmp

build clean
build config
build CC="gcc"
./src/misc/xcalarsim/xcalarsim -n /var/tmp/yelp/user/yelp_academic_dataset_user_fixed.json -s /tmp/yelp_users_schema -o /tmp -y -u 100

# Kill all of the old processes
pgrep -u `whoami` lt-usrnode | xargs kill -9
pgrep -u `whoami` xcmgmtd | xargs kill -9


