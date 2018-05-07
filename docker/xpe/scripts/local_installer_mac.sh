#!/usr/bin/env bash

# INSTALL:
#        bash <script path>/local_installer.sh
#
# UNINSTALL:
#        (backs up and removes existing install directory and removes containers)
#        bash <script path>/local_installer.sh uninstall
#
# EFFECT OF RUNNING THIS SCRIPT:
#
# When you run this script in dir with required files,
# any previous xdpce and grafana containers will be destroyed.
# it will create two docker containers (one for Grafana/graphite
# one for XEM cluster), and load the saved images for Grafana and XCE cluster
# included in the tarball, in to those containers.
# Grafana and XCE will be configured to communiicate automatically for stats collection.
#
set -e

# to make debug statements
#  debug "debug comment"
#  then run script as: `VERBOSE=1 ./local_installer.sh`
debug() {
    if [ "$VERBOSE" = 1 ]; then echo >&2 "debug: $@"; fi
}

SCRIPT_DIR="$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STAGING_DIR="/tmp/xpestaging"
XCALAR_IMAGE=xdpce
GRAFANA_IMAGE=grafana_graphite
XCALAR_CONTAINER_NAME=xdpce
GRAFANA_CONTAINER_NAME=grafana_graphite
# installer dirs created on the local machine
# these should remain even after installation complete, as long as they want XPE)
XPEDIR="$HOME/xcalar_personal_edition_data"
LOCALLOGDIR="$XPEDIR/xceLogs" # will mount to /var/log/xcalar so logs persist through upgrades
LOCALXCEHOME="$XPEDIR/xceHome" # will mount /var/opt/xcalar here so session data, etc. persissts through upgrde
LOCALDATASETS="$XPEDIR/sampleDatasets"

# this should match defaults given in xcalar/src/bin/pyClient/local/xcalar/compute/local/target/__init__.py
MAINHOSTMNT=/hostmnt

XEM_PORT_NUMBER=15000 # should be port # in xemconfig
# files that will be required for completing the installation process
XDPCE_TARBALL=xdpce.tar.gz
GRAFANA_TARBALL=grafana_graphite.tar.gz

hello() {
    echo "hello"
}

clear_containers() {
    debug "Remove old docker containers..."
    docker rm -f $XCALAR_CONTAINER_NAME $GRAFANA_CONTAINER_NAME >/dev/null 2>&1 || true
    docker rmi -f $XCALAR_IMAGE $GRAFANA_IMAGE || true
}

setup () {

    cwd=$(pwd)

    debug "Create install dirs and unpack tar file for install"

    ## CREATE INSTALLER DIRS, move required files to final dest ##
    if [ -e "$STAGING_DIR" ]; then
        echo "staging dir exists already $STAGING_DIR"
        rm -r "$STAGING_DIR"
    fi
    mkdir -p "$STAGING_DIR"
    cd "$STAGING_DIR"

    # copy installer tarball to the staging dir and extract it there
    cp "$SCRIPT_DIR/installertarball.tar.gz" "$STAGING_DIR"
    tar xzf installertarball.tar.gz

    mkdir -p "$LOCALXCEHOME/config"
    mkdir -p "$LOCALLOGDIR"
    mkdir -p "$LOCALDATASETS"

    cp -R .ipython .jupyter jupyterNotebooks "$LOCALXCEHOME" # put these here in case of initial install, need them in xce home
    cp defaultAdmin.json "$LOCALXCEHOME/config"
    # untar the datasets and copy those in
    # do this from the staging dir.
    # because tarred dir and dirname in XPEDIR are same
    # and don't want to overwrite the dir in XPEDIR if it's there,
    # in case we've taken out sample datasets in a new build.
    # instead extract in staging area then copy all the contents over.
    # this way they get new datasets, updated existing ones, and keep their old ones
    tar xzf sampleDatasets.tar.gz --strip-components=1 -C "$LOCALDATASETS/"
    rm sampleDatasets.tar.gz

    cd "$cwd"
}

load_packed_images() {

    cwd=$(pwd)

        ###  LOAD THE PACKED IMAGES AND START THE NEW CONTAINERS ##

    cd "$STAGING_DIR"

    # each load, will have 2 versions of the image:
    # xdpce:latest and xdpce:<build number> (same for grafana-graphite)
    # want to keep previous install images, but only need one - the xdpce:<old build number>
    # (if you specify 'rmi image' without a tag, will remove image:latest)
    # also if you do not do this, when you load the new images in the tar
    # (xdpce:latest and xdpce:<new build number>, and similar for grafana-graphite)
    # will detect existing xdpce:latest (the one from the old build),
    # and rename it to an unnamed image (keeping the xdpce:<old buld> as well)
    debug "load the packed images"
    gzip -dc "$XDPCE_TARBALL" | docker load -q
    gzip -dc "$GRAFANA_TARBALL" | docker load -q

    cd "$cwd"

}

create_grafana() {

    debug "Create grafana container"

    # create the grafana container
    docker run -d \
    --restart unless-stopped \
    -p 8082:80 \
    -p 81:81 \
    -p 8125:8125/udp \
    -p 8126:8126 \
    -p 2003:2003  \
    --name $GRAFANA_CONTAINER_NAME \
    $GRAFANA_IMAGE
}

create_xdpce() {

    debug "create xcalar container"

    local ram="$1"g;
    local cores="$2";
    # create the xdpce container
    docker run -d -t --user xcalar --cap-add=ALL --cap-drop=MKNOD \
    --restart unless-stopped \
    --memory=$ram \
    --cpus=$cores \
    --security-opt seccomp:unconfined --ulimit core=0:0 \
    --ulimit nofile=64960 --ulimit nproc=140960:140960 \
    --ulimit memlock=-1:-1 --ulimit stack=-1:-1 --shm-size=10g \
    --memory-swappiness=10 -e IN_DOCKER=1 \
    -e XLRDIR=/opt/xcalar -e container=docker \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v $HOME:$MAINHOSTMNT:ro \
    -v $LOCALXCEHOME:/var/opt/xcalar \
    -v $LOCALLOGDIR:/var/log/xcalar \
    -p $XEM_PORT_NUMBER:15000 \
    --name $XCALAR_CONTAINER_NAME \
    -p 8818:8818 \
    --link $GRAFANA_IMAGE:graphite $MNTARGS $XCALAR_IMAGE bash
}

start_xcalar() {

    debug "Start xcalar service inside the docker"

    # entrypoint for xcalar startup only hitting on container restart; start xcalar the initial time
    local cmd="docker exec --user xcalar $XCALAR_CONTAINER_NAME /opt/xcalar/bin/xcalarctl start"
    $cmd
}

cleanup() {

    debug "Cleanup and remove staging dir"

    rm -r "$STAGING_DIR"
}

"$@"
