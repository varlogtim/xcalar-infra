#!/bin/bash

set -e

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export XLRINFRADIR="${XLRNFRADIR:-$(readlink -f $SCRIPTDIR/../..)}"
export GRAFANADIR="$XLRINFRADIR/graphite-grafana"

FINALDEST="$BUILD_DIRECTORY/$BUILD_NUMBER"
mkdir -p $FINALDEST

# build the xdpce container first. go to dir in xcalar where it lives
cd "$XLRINFRADIR/docker/xdpce"
make docker-image INSTALLER_PATH="$PATH_TO_XCALAR_INSTALLER"
# running make will save an image of the container (xdpce.tar.gz)
# along with these dirs which are default dirs for xcalar's config and home,
# that you will need if you map local volumes there (as it will overwrite
# what is currently there)
cp -R configcopy/ $FINALDEST
cp xcalar $FINALDEST
cp xdpce.tar.gz $FINALDEST
cp -R homecopy/ $FINALDEST

# build the grafana-graphite container.
cd $GRAFANADIR
make
# it will have saved an image of the grafana container
cp grafana_graphite.tar.gz $FINALDEST

# go to the final dir tar these both together
cd $FINALDEST
cp "$XLRINFRADIR/docker/xdpce/XcalarLic.key" .
cp "$XLRINFRADIR/docker/xdpce/xem.cfg" .
cp "$XLRINFRADIR/docker/xdpce/local_installer.sh" .
thingstotar="xdpce.tar.gz grafana_graphite.tar.gz configcopy/ homecopy/ XcalarLic.key xcalar xem.cfg"
tarfile=restar.tar.gz
tar -czf $tarfile $thingstotar

# stop the docker containers created and remove them so not left over on jenkins slave after Job completes
docker rm -f xdpce || true

# remove the files we put in to the tar file
rm -r $thingstotar #$tarfile

# printing to stdout for other scripts to call
echo $FINALDEST >&2
