#!/bin/bash

set -e

: "${BUILD_DIRECTORY:?Need to set non-empty env var BUILD_DIRECTORY}"
: "${BUILD_NUMBER:?Need to set non-empty env var BUILD_NUMBER}"

# remove the docker images created, regardless of build failure/success
# if you don't remove the images, next time Jenkins slave runs this job,
# when it saves the xdpce and grafana images during Make, will be saving all
# existing tagged images, from previous builds too
# do not remove main grafana image though - do not want to rebuild everytime
cleanup() {
    docker rm -f xdpce || true
    docker rmi -f xdpce:latest || true
    docker rmi -f xdpce:"$BUILD_NUMBER" || true
    docker rm -f grafana_graphite || true
    docker rmi -f grafana_graphite:"$BUILD_NUMBER" || true
}

trap cleanup EXIT SIGINT SIGTERM # SIGTERM should handle if you abort the job through Jenkins

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export XLRINFRADIR="${XLRNFRADIR:-$(readlink -f $SCRIPTDIR/../../..)}"
export XLRGUIDIR="${XLRGUIDIR:-$XLRINFRADIR/../xcalar-gui}"
export GRAFANADIR="${GRAFANADIR:-$XLRINFRADIR/../graphite-grafana}"
export CADDY_PORT="${CADDYPORT:-443}"
export BUILD_GRAFANA="${BUILD_GRAFANA:-true}"
export DEV_BUILD="${DEV_BUILD:-true}"

XPEDIR="$XLRINFRADIR/docker/xpe"

echo "current build number: $BUILD_NUMBER" >&2
FINALDEST="$BUILD_DIRECTORY/$BUILD_NUMBER"
mkdir -p $FINALDEST

# contents of tarfile that will be packaged with the app and used by the installer
# (all additional files required for an install on the host)
# script generates these during build process; everythign needs to end up in FINALDEST
TARCONTENTS="xdpce.tar.gz defaultAdmin.json .ipython/ .jupyter/ jupyterNotebooks/ sampleDatasets.tar.gz .caddyport"

# build the grafana-graphite container if requested.
# (BUILD_GRAFANA is a boolean arg in the Jenkins job)
if [ "$BUILD_GRAFANA" = true ]; then
    cd $GRAFANADIR
    make grafanatar
    # it will have saved an image of the grafana container
    cp grafana_graphite.tar.gz $FINALDEST
    TARCONTENTS="$TARCONTENTS grafana_graphite.tar.gz"
fi

# build xdpce container
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

# set caddy port as a text file, so host side will know which Caddyport to use
echo "$CADDY_PORT" > "$FINALDEST/.caddyport"

# tar what's needed for the local install
cd $FINALDEST
curl -f -L http://repo.xcalar.net/deps/sampleDatasets.tar.gz -O
TARFILE=installertarball.tar.gz
tar -czf "$TARFILE" $TARCONTENTS

# run mkshar (ubuntu)
ubuntuinstaller=local_installer.sh
cp "$XPEDIR/scripts/$ubuntuinstaller" .
"$XLRINFRADIR/bin/mkshar.sh" "$TARFILE" "$ubuntuinstaller" > xpe_installer_ubuntu.sh
chmod u+x xpe_installer_ubuntu.sh

# make the mac app (mac)
echo "making mac app..." >&2
bash -x "$XPEDIR/scripts/makeapp.sh"

# remove from final dir everything but the final mkshar installers
# don't do this as general cleanup - want to keep these dirs on build failures
rm -r $TARCONTENTS
rm "$TARFILE"

# symlink to this bld
cd "$BUILD_DIRECTORY" && ln -sfn "$BUILD_NUMBER" lastSuccessful

# printing to stdout for other scripts to call
echo $FINALDEST
