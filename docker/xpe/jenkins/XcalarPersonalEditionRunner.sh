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

XPEDIR="$XLRINFRADIR/docker/xpe"

# removes xcalar and grafana Docker artefacts. to run at job start and cleanup.
# clear xcalar repo entirely; don't want to cache
# (mostly in case xdpce Dockerfile changes in future to incorporate src code checkout as part of its bld
# which wouldn't want to cache; the build time it saves from using cache is about < 1 min so not worth this risk...)
clearDockerArtefacts() {
    # try to remove expected container in case not associated w image
    # (if it is associated w the image, remove_docker_image_repo will run much faster if you give this cmd first)
    docker rm -fv "$XCALAR_CONTAINER_NAME" || true
    "$BASH_HELPER_FUNCS" remove_docker_image_repo "$XCALAR_IMAGE_NAME"
    # only remove grafana container, not image; keep in cache so won't need to rebuild
    docker rm -fv grafana_graphite || true
}

# removes build specific artefacts which require context of this run (for cleanup)
removeBuildArtefacts() {
    docker kill "$XCALAR_CONTAINER_NAME" || true # use kill because it's quicker than rm and Jenkins abort cleanup has limited time
    docker rmi -f grafana_graphite:"$BUILD_NUMBER" || true
}

cleanup() {
    # if you are running through Jenkins - if the job fails or completes, this entire function will run
    # but if aborted, there are only a couple seconds before shell is terminated
    # therefore prioritize cleaning up objects which could interfere w future runs or other jobs using this machine
    removeBuildArtefacts
    clearDockerArtefacts
}

trap cleanup EXIT SIGTERM SIGINT # Jenkins sends SIGTERM on abort

### START JOB ###

clearDockerArtefacts

echo "current build number: $BUILD_NUMBER" >&2
FINALDEST="$BUILD_DIRECTORY/$BUILD_NUMBER"
mkdir -p $FINALDEST

# write out a file with build info
cat > "$FINALDEST/BLDINFO.txt" <<EOF
PATH_TO_XCALAR_INSTALLER=$PATH_TO_XCALAR_INSTALLER
OFFICIAL_RELEASE=$OFFICIAL_RELEASE
DEV_BUILD=$DEV_BUILD
BUILD_GRAFANA=$BUILD_GRAFANA
EOF

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
# (do not actually need any port exposed since just need the image, so do not expose any port when blding
# just to reduce chances of port conflicts on this machine if the container gets left over somehow)
cd "$XLRINFRADIR/docker/xdpce"
make docker-image INSTALLER_PATH="$PATH_TO_XCALAR_INSTALLER" CONTAINER_NAME="$XCALAR_CONTAINER_NAME" CONTAINER_IMAGE="$XCALAR_IMAGE_NAME" PORT_MAPPING=""

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
