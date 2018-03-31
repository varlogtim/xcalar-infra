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
# along with these dirs which get generated install time in xcalar home,
# that you will need if you map local volumes there (as it will overwrite
# what is currently there)
cp -R .ipython/ $FINALDEST
cp -R .jupyter/ $FINALDEST
cp -R jupyterNotebooks $FINALDEST
cp xcalar $FINALDEST
cp xdpce.tar.gz $FINALDEST

# build the grafana-graphite container.
cd $GRAFANADIR
make grafanatar
# it will have saved an image of the grafana container
cp grafana_graphite.tar.gz $FINALDEST

# go to the final dir tar these both together
cd $FINALDEST
cp "$XLRINFRADIR/docker/xdpce/trial.key" .
cp "$XLRINFRADIR/docker/xdpce/xem.cfg" .
cp "$XLRINFRADIR/docker/xdpce/local_installer.sh" .
thingstotar="xdpce.tar.gz grafana_graphite.tar.gz trial.key xcalar xem.cfg .ipython/ .jupyter/ jupyterNotebooks"
tarfile=restar.tar.gz
tar -czf $tarfile $thingstotar

# stop the docker containers created and remove them so not left over on jenkins slave after Job completes
# if you dont remove the images, then next time Jenkins slave runs this job, when it saves the xdpce and
# grafana/graphite images, will be saving all existing tagged images - not just the current one!
docker rm -f xdpce || true
docker rm -f grafana_graphite || true
docker rmi -f xdpce || true
docker rmi -f xdpce:$BUILD_NUMBER || true
docker rmi -f grafana_graphite || true
docker rmi -f grafana_graphite:$BUILD_NUMBER || true

# remove the files we put in to the tar file
rm -r $thingstotar #$tarfile

# printing to stdout for other scripts to call
echo $FINALDEST
