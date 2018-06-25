#!/bin/bash

set -e

: "${BUILD_DIRECTORY:?Need to set non-empty env var BUILD_DIRECTORY}"
: "${BUILD_NUMBER:?Need to set non-empty env var BUILD_NUMBER}"
: "${PATH_TO_XCALAR_INSTALLER:?Need to set netstore rpm installer path as PATH_TO_XCALAR_INSTALLER)}"

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export XLRINFRADIR="${XLRNFRADIR:-$(readlink -f $SCRIPTDIR/../../..)}"
export XLRGUIDIR="${XLRGUIDIR:-$XLRINFRADIR/../xcalar-gui}"
export GRAFANADIR="${GRAFANADIR:-$XLRINFRADIR/../graphite-grafana}"
export CADDY_PORT="${CADDYPORT:-443}"
export BUILD_GRAFANA="${BUILD_GRAFANA:-true}"
export DEV_BUILD="${DEV_BUILD:-true}"
export OFFICIAL_RELEASE="${OFFICIAL_RELEASE:-false}" # if true will tag the Docker images with official Xcalar build Strings
export XCALAR_IMAGE_NAME="${XCALAR_IMAGE_NAME:-xcalar_design}"
export XCALAR_CONTAINER_NAME="${XCALAR_CONTAINER_NAME:-xcalar_design}"

BASH_HELPER_FUNCS="$SCRIPTDIR/../scripts/local_installer_mac.sh"

# remove build-specific Docker artefacts regardless of build failure/success
# keeping grafana:latest so it'll be in cache at next build and won't need to re-build
# but for Xcalar image, clearing repo entirely each time; don't want to cache
# (mostly in case xdpce Dockerfile changes in future to incorporate src code checkout
# which wouldn't want to cache; the build time it saves from the cache is about < 1 min so not worth this risk...)
cleanup() {
    "$BASH_HELPER_FUNCS" remove_docker_image_repo "$XCALAR_IMAGE_NAME"
    # try to remove expected container too in case it did not become associated w image somehow
    docker rm -f "$XCALAR_CONTAINER_NAME" || true
    # only remove grafana image tag specific to this bld, leave main image
    # so it'll be cached for next build
    docker rm -f grafana_graphite || true
    docker rmi -f grafana_graphite:"$BUILD_NUMBER" || true
    # remove any dangling images (was getting some leftover layers)
    docker image prune -f
}

trap cleanup EXIT SIGINT SIGTERM # SIGTERM should handle if you abort the job through Jenkins

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
make docker-image INSTALLER_PATH="$PATH_TO_XCALAR_INSTALLER" CONTAINER_NAME="$XCALAR_CONTAINER_NAME" CONTAINER_IMAGE="$XCALAR_IMAGE_NAME"
# running make will save an image of the container (xdpce.tar.gz)
# along with these dirs which get generated install time in xcalar home,
# that you will need if you map local volumes there (as it will overwrite
# what is currently there)
cp -R .ipython $FINALDEST
cp -R .jupyter $FINALDEST
cp -R jupyterNotebooks $FINALDEST
cp defaultAdmin.json $FINALDEST
# makefile copies the xcalar-gui dir that was installed in to the Docker container
# by the rpm installer, out of the Docker container.
# TODO: Once all the gui code is checked in to the xcalar-gui project,
# use this xcalar-gui dir as the one being included in the app
# until then, having to build own xcalar-gui from private branch.
#cp "$XPEDIR/staticfiles/config.js" "xcalar-gui/assets/js/" <-- add in the needed files here?
#cp -R xcalar-gui/ $FINALDEST <-- @TODO: will cp in to $FINALDEST so makeapp.sh can use
cp xdpce.tar.gz $FINALDEST

# set caddy port as a text file, so host side will know which Caddyport to use
echo "$CADDY_PORT" > "$FINALDEST/.caddyport"

# tar what's needed for the local install
cd $FINALDEST
curl -f -L http://repo.xcalar.net/deps/sampleDatasets.tar.gz -O
TARFILE=installertarball.tar.gz
tar -czf "$TARFILE" $TARCONTENTS

# run mkshar (ubuntu)
# (taking this out for now to speed up bld process)
# @TODO: Add options in Jenkins job for build mac, ubuntu, etc.
# and do these based on that.
#ubuntuinstaller=local_installer.sh
#cp "$XPEDIR/scripts/$ubuntuinstaller" .
#"$XLRINFRADIR/bin/mkshar.sh" "$TARFILE" "$ubuntuinstaller" > xpe_installer_ubuntu.sh
#chmod u+x xpe_installer_ubuntu.sh

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
