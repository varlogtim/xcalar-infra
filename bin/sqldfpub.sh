#!/bin/bash

set -e

if [ "$#" -ne 1 ]
then
    echo "Usage:"
    echo "  $0 <iterationNumber>"
    exit 1
fi

ITER=$1
VERSION=${2:-"0.2"}
TMPDIR="/tmp/tmpsqldf_$(date +%s)"
mkdir "$TMPDIR"

onExit() {
    rm -f "$TMPDIR"/*.rpm "$TMPDIR"/*.deb "$TMPDIR"/*.jar
    rm -rf "$TMPDIR"/tmp "$TMPDIR"/el7
    cd
    rmdir "$TMPDIR"
}

cd "$TMPDIR"

trap onExit EXIT

wget http://jenkins.int.xcalar.com/job/BuildSqldf/${ITER}/artifact/build/el6/xcalar-sqldf-${VERSION}-${ITER}.el6.noarch.rpm
$XLRDIR/bin/reposync.sh rhel6-repo xcalar-sqldf-${VERSION}-${ITER}.el6.noarch.rpm

wget http://jenkins.int.xcalar.com/job/BuildSqldf/${ITER}/artifact/build/el7/xcalar-sqldf-${VERSION}-${ITER}.el7.noarch.rpm
$XLRDIR/bin/reposync.sh rhel7-repo xcalar-sqldf-${VERSION}-${ITER}.el7.noarch.rpm

wget http://jenkins.int.xcalar.com/job/BuildSqldf/${ITER}/artifact/build/amzn1/xcalar-sqldf-${VERSION}-${ITER}.amzn1.noarch.rpm
$XLRDIR/bin/reposync.sh amzn1-repo xcalar-sqldf-${VERSION}-${ITER}.amzn1.noarch.rpm

wget http://jenkins.int.xcalar.com/job/BuildSqldf/lastSuccessfulBuild/artifact/build/ub14/xcalar-sqldf_${VERSION}-${ITER}_all.deb
$XLRDIR/bin/apt-includedeb.sh xcalar-sqldf_${VERSION}-${ITER}_all.deb

tar xvf /netstore/builds/byJob/BuildSqldf/${ITER}/archive.tar el7/xcalar-sqldf-${VERSION}-${ITER}.el7.tar.gz
! test -f el7/xcalar-sqldf-${VERSION}-${ITER}.el7.tar.gz && \
    echo "xcalar-sqldf-${VERSION}-${ITER}.el7.tar.gz not found. repo.xcalar.net/deps not updated" && exit 1
tar xvzf el7/xcalar-sqldf-${VERSION}-${ITER}.el7.tar.gz
SQLDF_FILE=$(find tmp -name xcalar-sqldf.jar -print | head -1)
test -z "$SQLDF_FILE" && echo "xcalar-sqldf.jar not found. repo.xcalar.net/deps not updated." && exit 1
mv ${SQLDF_FILE} ./xcalar-sqldf-${VERSION}.jar
gsutil cp ./xcalar-sqldf-${VERSION}.jar gs://repo.xcalar.net/deps

