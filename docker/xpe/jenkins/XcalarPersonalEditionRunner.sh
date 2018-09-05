#!/bin/bash

# to be called by Jenkins job 'XcalarPersonalEditionBuilder'

set -e

: "${BUILD_DIRECTORY:?Need to set non-empty env var BUILD_DIRECTORY}"
: "${BUILD_NUMBER:?Need to set non-empty env var BUILD_NUMBER}"
: "${PATH_TO_XCALAR_INSTALLER:?Need to set netstore rpm installer path as PATH_TO_XCALAR_INSTALLER)}"

SCRIPTSTART=$(pwd)
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export XLRINFRADIR="${XLRNFRADIR:-$(readlink -f $SCRIPTDIR/../../..)}"
export XLRGUIDIR="${XLRGUIDIR:-$XLRINFRADIR/../xcalar-gui}"
export GRAFANADIR="${GRAFANADIR:-$XLRINFRADIR/../graphite-grafana}"
export CADDY_PORT="${CADDYPORT:-443}"
export BUILD_GRAFANA="${BUILD_GRAFANA:-true}"
export DEV_BUILD="${DEV_BUILD:-true}"
export OFFICIAL_RELEASE="${OFFICIAL_RELEASE:-false}" # if true will tag Docker images with official Xcalar build Strings
export XCALAR_IMAGE_NAME="${XCALAR_IMAGE_NAME:-xcalar_design}"
export XCALAR_CONTAINER_NAME="${XCALAR_CONTAINER_NAME:-xcalar_design}"

INFRA_XPE_DIR="$XLRINFRADIR/docker/xpe"
BASH_HELPER_FUNCS="$INFRA_XPE_DIR/scripts/local_installer_mac.sh"
XDEE_BUILD_TARGET_DIR="xcalar-design-ee" # dirname of the build target of the xcalar-gui project this app will require
XDEE_GUI_BUILD_DIR="${XDEE_GUI_BUILD_DIR:-"$XLRGUIDIR/$XDEE_BUILD_TARGET_DIR"}" # custom gui build for xdee; will build in XLRGUIDIR if this dir doesn't exist

APPBASENAME="${APPBASENAME:-"Xcalar Design"}" # basename for the app
APPTARFILE="${APPTARFILE:-"$APPBASENAME.tar.gz"}" # name of final tarred app that ends up in bld
INSTALLERTARFILE=installertarball.tar.gz # name for tarball containing docker images, dependencies, etc.

### CREATE STAGING DIR TO DO BUILDING IN ###
STAGING_DIR="$(mktemp -d --tmpdir xpeBldStagingXXXXXX)"

###  CLEAENUP/HELPER FUNCTIONS ###

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
    echo "cleanup"
    cd "$SCRIPTSTART" # go back before removing staging dir in case you're in staging dir
    rm -r "$STAGING_DIR"
    removeBuildArtefacts
    clearDockerArtefacts
}

# builds the xcalar-gui project in the state required by the app to be in the Docker container
# (builds from XLRGUIDIR if build does not exist)
# (RPM installers will install xcalar-gui build with standard build targets; for xcalar-gui
# to work in the app needs to be built with --product=XDEE option)
buildXcalarGuiForApp() {
    if [ ! -d "$XDEE_GUI_BUILD_DIR" ]; then
        echo ">>> gui build dir does NOT exist; building from $XLRGUIDIR" >&2
        cd "$XLRGUIDIR"
        git submodule update --init
        git submodule update
        npm install --save-dev
        node_modules/grunt/bin/grunt init
        node_modules/grunt/bin/grunt dev --product=XDEE
        # make sure expected target exists
        if [ ! -d "$XDEE_BUILD_TARGET_DIR" ]; then
            echo "Gui build target $XDEE_BUILD_TARGET_DIR does not exist in $XLRGUIDIR after building (has target name changed?)" >&2
            exit 1
        else
            cd "$XDEE_BUILD_TARGET_DIR"
            XDEE_GUI_BUILD_DIR=$(pwd)
        fi
    fi

    # build the xpe server
    cd "$XDEE_GUI_BUILD_DIR/services/xpeServer"
    npm install
}

# create installer tarball to be packaged in the app (tarball with
# the files needed during app install-time on host) by generating all the
# required assets including the saved Docker images.
# saves the tarball in the staging dir.
generate_app_assets()  {

    cd "$STAGING_DIR"

    echo "Create installer tarball for app " >&2

    # create dir to get tarrred at end of this function,
    # and included in the installer assets for the app.
    # it should include all files required for setting up the container
    # on the host, including the Docker images
    local tarDir="tarfiles"
    mkdir -p "$tarDir"
    # get full path so know where to copy files in to
    cd "$tarDir"
    local tarDirPath=$(pwd)
    cd "$STAGING_DIR"

    # build the grafana-graphite container if requested.
    # (BUILD_GRAFANA is a boolean arg in the Jenkins job)
    if [ "$BUILD_GRAFANA" = true ]; then
        cd $GRAFANADIR
        make grafanatar
        # it will have saved an image of the grafana container
        # add saved image to dir for installer tarball
        cp grafana_graphite.tar.gz "$tarDirPath"
    fi

    # build custom GUI to be consumed by Makefile for building the Xcalar Docker container
    # (Makefile provides option to swap out what gets installed by rpm installer)
    # (this is temporary until RPM installers are generated with the GUI needed)
    buildXcalarGuiForApp

    # build xdpce container
    # (do not actually need any port exposed since just need the image, so do not expose any port when blding
    # just to reduce chances of port conflicts on this machine if the container gets left over somehow)
    cd "$XLRINFRADIR/docker/xdpce"
    make docker-image INSTALLER_PATH="$PATH_TO_XCALAR_INSTALLER" CONTAINER_NAME="$XCALAR_CONTAINER_NAME" CONTAINER_IMAGE="$XCALAR_IMAGE_NAME" PORT_MAPPING="" CUSTOM_GUI="$XDEE_GUI_BUILD_DIR"

    # make will save an image of the container (xdpce.tar.gz),
    # and also copies of dirs saved in 'xcalar home'.
    # these dirs are needed on the host at app install time, if you map local
    # volumes to them (as this mapping will overwrite what's saved in the
    # image, so need these as defaults for initial installs)
    # - move these dirs to be included in the installer tarball
    mv .ipython "$tarDirPath"
    mv .jupyter "$tarDirPath"
    mv jupyterNotebooks "$tarDirPath"
    mv xdpce.tar.gz "$tarDirPath"
    # make also saves a copy of the xcalar-gui dir that got installed in the
    # Docker container; move to staging dir to be consumed by makeapp.sh
    # (this should NOT be part of installer tarball; its just a byproduct of
    # generating the installer tarball assets so dealing with it here)
    mv xcalar-gui "$STAGING_DIR"

    # copy in defaultAdmin from the infra repo, for installer tarball
    cp "$XLRINFRADIR/docker/xdpce/defaultAdmin.json" "$tarDirPath"

    # set caddy port as a text file, so host side will know which Caddyport to use
    echo "$CADDY_PORT" > "$tarDirPath/.caddyport"

    # download sample datasets for the installer tarball
    # (they will be saved locally on the host installing the app,
    # and mapped in to the container created on that host.)
    cd "$tarDirPath"
    curl -f -L http://repo.xcalar.net/deps/sampleDatasets.tar.gz -O

    # create the installer tarball with the assets gathered
    cd "$STAGING_DIR"
    tar -czf "$INSTALLERTARFILE" -C "$tarDirPath" .
}

# generates the .app, tars it, and put that tarfile in final build dest
build_app() {
    # generate installer tarball and other assets needed for app
    generate_app_assets

    echo "making mac app..." >&2
    # create the app; supply gui that was copied out from the container during Makefile
    APPOUT="$STAGING_DIR/$APPBASENAME.app" GUIBUILD="$STAGING_DIR/xcalar-gui" INSTALLERTARBALL="$STAGING_DIR/$INSTALLERTARFILE" bash -x "$INFRA_XPE_DIR/scripts/makeapp.sh"

    # tar the app
    # (will need to be downloaded from Mac, but nwjs binaries
    # are not world readbale)
    tar -czf "$APPTARFILE" "$APPBASENAME.app"

    # copy to build directory
    # (building app in staging dir instead of directly in to build because most likely the
    # build dir is remotely on netstore, want all work to be done exclusively on the
    # jenkins slave then copy it in only when everything complete)
    cp -r "$APPTARFILE" "$FINALDEST"
}

trap cleanup EXIT SIGTERM SIGINT # Jenkins sends SIGTERM on abort

### START JOB ###

cd "$STAGING_DIR"

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

build_app

# symlink to this bld
cd "$BUILD_DIRECTORY" && ln -sfn "$BUILD_NUMBER" lastSuccessful

# (staging dir removed in cleanup, which is called on normal exit)

# printing to stdout for other scripts to call
echo "$FINALDEST"
