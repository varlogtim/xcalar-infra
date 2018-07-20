#!/bin/bash

set -e
set -o pipefail

usage() {
    echo "Usage: $0 [options] <iterationNumber> [version]"
    echo "  -l  List repo state after publish"
}

onExit() {
    rm -f "$TMPDIR"/*.rpm "$TMPDIR"/*.deb "$TMPDIR"/*.jar
    rm -rf "$TMPDIR"/tmp "$TMPDIR"/el7
    cd
    rmdir "$TMPDIR"
}

optListRepo=false
while getopts "l" opt; do
  case $opt in
      l) optListRepo=true;;
      *) usage; exit 1;;
  esac
done

shift $(($OPTIND - 1))
ITER="$1"
VERSION=${2:-"0.2"}

if [[ -z "$ITER" ]]; then
    echo "Missing iteration number"
    usage
    exit 1
fi

trap onExit EXIT
TMPDIR=$(mktemp --tmpdir -d sqldfpub.XXXXXX)
cd "$TMPDIR"

wget http://jenkins.int.xcalar.com/job/BuildSqldf/${ITER}/artifact/xcalar-sqldf-${VERSION}-${ITER}.noarch.rpm
$XLRDIR/bin/reposync.sh rpmcommon -- xcalar-sqldf-${VERSION}-${ITER}.noarch.rpm

wget http://jenkins.int.xcalar.com/job/BuildSqldf/${ITER}/artifact/xcalar-sqldf_${VERSION}-${ITER}_all.deb
$XLRDIR/bin/apt-includedeb.sh -d all xcalar-sqldf_${VERSION}-${ITER}_all.deb

tar -xOf /netstore/builds/byJob/BuildSqldf/${ITER}/archive.tar xcalar-sqldf-${VERSION}-${ITER}.noarch.rpm | rpm2cpio | cpio -i --to-stdout ./opt/xcalar/lib/xcalar-sqldf.jar > xcalar-sqldf-${VERSION}.jar
gsutil cp ./xcalar-sqldf-${VERSION}.jar gs://repo.xcalar.net/deps
echo "# Please update SQLDF_VERSION in xcalar/bin/build-user-installer.sh to use version ${VERSION} for non-RPM builds #"

if $optListRepo; then
    echo
    echo "Final sqldf repo state: "
    gsutil ls -r gs://repo.xcalar.net/rpm-deps/common/x86_64/Packages/xcalar-sqldf-0.2-84.noarch.rpm | grep sqldf | xargs gsutil hash -h
    echo "User installer sqldf repo state: "
    gsutil ls -r gs://repo.xcalar.net/deps/ | grep sqldf | xargs gsutil hash -h
fi
