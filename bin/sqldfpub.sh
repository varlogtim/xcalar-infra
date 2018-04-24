#!/bin/bash

set -e

if [ "$#" -ne 1 ]
then
    echo "Usage:"
    echo "  $0 <iterationNumber>"
    exit 1
fi

ITER=$1
TMPDIR="/tmp/tmpsqldf_$(date +%s)"
mkdir "$TMPDIR"

onExit() {
    rm "$TMPDIR"/*.rpm "$TMPDIR"/*.deb
    cd
    rmdir "$TMPDIR"
}

cd "$TMPDIR"

trap onExit EXIT

wget http://jenkins.int.xcalar.com/job/BuildSqldf/${ITER}/artifact/build/el6/xcalar-sqldf-0.2-${ITER}.el6.noarch.rpm
$XLRDIR/bin/reposync.sh rhel6-repo xcalar-sqldf-0.2-${ITER}.el6.noarch.rpm

wget http://jenkins.int.xcalar.com/job/BuildSqldf/${ITER}/artifact/build/el7/xcalar-sqldf-0.2-${ITER}.el7.noarch.rpm
$XLRDIR/bin/reposync.sh rhel7-repo xcalar-sqldf-0.2-${ITER}.el7.noarch.rpm

wget http://jenkins.int.xcalar.com/job/BuildSqldf/lastSuccessfulBuild/artifact/build/ub14/xcalar-sqldf_0.2-${ITER}_all.deb
$XLRDIR/bin/apt-includedeb.sh xcalar-sqldf_0.2-${ITER}_all.deb
