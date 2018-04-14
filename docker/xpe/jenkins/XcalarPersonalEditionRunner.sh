#!/bin/bash

set -e

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export XLRINFRADIR="${XLRNFRADIR:-$(readlink -f $SCRIPTDIR/../../..)}"
export XLRGUIDIR="${XLRGUIDIR:-$XLRINFRADIR/../xcalar-gui}"
export GRAFANADIR="${GRAFANADIR:-$XLRINFRADIR/../graphite-grafana}"

XPEDIR="$XLRINFRADIR/docker/xpe"

echo "current build number: $BUILD_NUMBER"
FINALDEST="$BUILD_DIRECTORY/$BUILD_NUMBER"
mkdir -p $FINALDEST

# build the xdpce container first. go to dir in xcalar where it lives
cd "$XLRINFRADIR/docker/xdpce"
make docker-image INSTALLER_PATH="$PATH_TO_XCALAR_INSTALLER"
# running make will save an image of the container (xdpce.tar.gz)
# along with these dirs which get generated install time in xcalar home,
# that you will need if you map local volumes there (as it will overwrite
# what is currently there)
cp -R .ipython $FINALDEST
cp -R .jupyter $FINALDEST
cp -R jupyterNotebooks $FINALDEST
cp defaultAdmin.json $FINALDEST
# copy here, the static files in infra for using nwjs, in to the xcalar-gui
# that was copied out in the Makefile; copy whole thing to final dest
# instead of taking care of the individual files during remote install
cp "$XPEDIR/staticfiles/config.js" "xcalar-gui/assets/js/"
cp "$XPEDIR/staticfiles/XD_package.json" "xcalar-gui/package.json"
cp -R xcalar-gui/ $FINALDEST
cp xdpce.tar.gz $FINALDEST

# build the grafana-graphite container.
cd $GRAFANADIR
make grafanatar
# it will have saved an image of the grafana container
cp grafana_graphite.tar.gz $FINALDEST

# tar what's needed for the local install
cd $FINALDEST
curl http://netstore/users/jolsen/xpeassets/sampleDatasets.tar.gz -o sampleDatasets.tar.gz
TARFILE=installertarball.tar.gz
TARCONTENTS="xdpce.tar.gz grafana_graphite.tar.gz defaultAdmin.json .ipython/ .jupyter/ jupyterNotebooks/ sampleDatasets.tar.gz"
tar -czf "$TARFILE" $TARCONTENTS

# run mkshar (ubuntu)
ubuntuinstaller=local_installer.sh
cp "$XPEDIR/scripts/$ubuntuinstaller" .
"$XLRINFRADIR/bin/mkshar.sh" "$TARFILE" "$ubuntuinstaller" > xpe_installer_ubuntu.sh
chmod u+x xpe_installer_ubuntu.sh

# make the mac app (mac)
echo "making mac app..."
bash -x "$XPEDIR/scripts/makeapp.sh"

# stop the docker containers created and remove them so not left over on jenkins slave after Job completes
# if you dont remove the images, then next time Jenkins slave runs this job, when it saves the xdpce and
# grafana/graphite images, will be saving all existing tagged images - not just the current one!
docker rm -f xdpce || true
docker rm -f grafana_graphite || true
docker rmi -f xdpce || true
docker rmi -f xdpce:"$BUILD_NUMBER" || true
docker rmi -f grafana_graphite || true
docker rmi -f grafana_graphite:"$BUILD_NUMBER" || true

# remove from final dir everything but the final mkshar installers
rm -r $TARCONTENTS
rm "$TARFILE"

# printing to stdout for other scripts to call
echo $FINALDEST
