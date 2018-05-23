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
APPDATA=$HOME/Library/Application\ Support/Xcalar\ Design
XPEDATA="$APPDATA/.sessions" # want data in here hidden in mac Finder
LOCALLOGDIR="$XPEDATA/Xcalar Logs" # will mount to /var/log/xcalar so logs persist through upgrades
LOCALXCEHOME="$XPEDATA/Xcalar Home" # will mount /var/opt/xcalar here so session data, etc. persissts through upgrde
LOCALDATASETS="$APPDATA/sampleDatasets"

# this should match defaults given in xcalar/src/bin/pyClient/local/xcalar/compute/local/target/__init__.py
MAINHOSTMNT=/hostmnt

XEM_PORT_NUMBER=15000 # should be port # in xemconfig
# files that will be required for completing the installation process
XDPCE_TARBALL=xdpce.tar.gz
GRAFANA_TARBALL=grafana_graphite.tar.gz

# clear current container
# if user has changed its name; won't be removing that
# remove the latest images.
cmd_clear_containers() {
    debug "Remove old docker containers..."
    docker rm -f $XCALAR_CONTAINER_NAME $GRAFANA_CONTAINER_NAME >/dev/null 2>&1 || true
}

cmd_cleanly_delete_image() {

    if [[ -z "$1" ]]; then
        echo "No image ID supplied to cleanly_delete_image. you must supply an image ID to remove!" >&2
        exit 1
    fi

    # remove any containers (running or not) hosting this image
    docker ps -a -q --filter ancestor="$1" --format="{{.ID}}" | xargs -I {} docker rm -f {}
    # now remove the image itself
    docker rmi -f "$1"

}

cmd_setup () {

    local cwd=$(pwd)

    debug "Create install dirs and unpack tar file for install"

    ## CREATE INSTALLER DIRS, move required files to final dest ##
    if [ -e "$STAGING_DIR" ]; then
        echo "staging dir exists already $STAGING_DIR" >&2
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
    # because tarred dir and dirname in APPDATA are same
    # and don't want to overwrite the dir in APPDATA if it's there,
    # in case we've taken out sample datasets in a new build.
    # instead extract in staging area then copy all the contents over.
    # this way they get new datasets, updated existing ones, and keep their old ones
    tar xzf sampleDatasets.tar.gz --strip-components=1 -C "$LOCALDATASETS/"
    rm sampleDatasets.tar.gz

    cd "$cwd"
}

cmd_start_wait_docker() {
    open -a Docker.app
    until docker version >/dev/null 2>&1; do
        echo "docker daemon not avaiable yet" >&2
        sleep 1
    done
}

cmd_load_packed_images() {

    local cwd=$(pwd)

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

cmd_create_grafana() {

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

# create xdpce container
#    1st arg: image to use (Defaults to xdpce:latest)
#   2nd arg: ram (int in gb)
#    3rd arg: num cores
cmd_create_xdpce() {

    debug "create xcalar container"

    local container_image=xdpce:latest
    if [[ ! -z "$1" ]]; then
        container_image="$1"
    fi
    local extraArgs=""
    if [[ ! -z "$2" ]]; then
        extraArgs="$extraArgs --memory=${2}g"
    fi
    if [[ ! -z "$3" ]]; then
        extraArgs="$extraArgs --cpus=${3}"
    fi
    # if there is grafana container hook it to it as additional arg
    if docker container inspect "$GRAFANA_CONTAINER_NAME"; then
        extraArgs="$extraArgs --link $GRAFANA_IMAGE:graphite"
    fi

    # create the xdpce container
    docker run -d -t --user xcalar --cap-add=ALL --cap-drop=MKNOD \
    --restart unless-stopped \
    --security-opt seccomp:unconfined --ulimit core=0:0 \
    --ulimit nofile=64960 --ulimit nproc=140960:140960 \
    --ulimit memlock=-1:-1 --ulimit stack=-1:-1 --shm-size=10g \
    --memory-swappiness=10 -e IN_DOCKER=1 \
    -e XLRDIR=/opt/xcalar -e container=docker \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HOME":"$MAINHOSTMNT":ro \
    -v "$LOCALXCEHOME":/var/opt/xcalar \
    -v "$LOCALLOGDIR":/var/log/xcalar \
    -p $XEM_PORT_NUMBER:15000 \
    --name "$XCALAR_CONTAINER_NAME" \
    -p 8818:8818 \
    $extraArgs $MNTARGS "$container_image" bash
}

cmd_start_xcalar() {
    debug "Start xcalar service inside the docker"
    # entrypoint for xcalar startup only hitting on container restart; start xcalar the initial time
    docker exec --user xcalar "$XCALAR_CONTAINER_NAME" /opt/xcalar/bin/xcalarctl start
}

cmd_stop_xcalar() {
    debug "Stop xcalar service inside the docker"
    # entrypoint for xcalar startup only hitting on container restart; start xcalar the initial time
    docker exec --user xcalar "$XCALAR_CONTAINER_NAME" /opt/xcalar/bin/xcalarctl stop
}

# revert_xdpce <img id> to revert to
cmd_revert_xdpce() {

    local revert_img_id="$1" # new img id or sha
    if [[ -z "${revert_img_id// }" ]]; then  # checks only whitespace chars
        echo "you must supply a value to revert image id!" >&2
        exit 1
    fi

    # check if xdpce container exists in expected name
    if docker container inspect "$XCALAR_CONTAINER_NAME"; then
        # get SHA of image hosted by current xdpce container, if any
        local curr_img_sha=$(docker container inspect --format='{{.Image}}' "$XCALAR_CONTAINER_NAME")

        # compares sha to check if already hosting the requested img
        local revert_img_sha=$(docker image inspect --format='{{.Id}}' "$revert_img_id")

        if [[ "$curr_img_sha" == $revert_img_sha ]]; then
            echo "$revert_img_id already hosted by $XCALAR_CONTAINER_NAME - revert is unecessary!" >&2
            exit 0
        fi

        # delete the container
        docker rm -f "$XCALAR_CONTAINER_NAME"
    else
        echo "there is NOT a $XCALAR_CONTAINER_NAME container" >&2
    fi

    # now call to create the new container
    cmd_create_xdpce "$revert_img_id"
}

# nuke all the xdpce containers and images; optional $1 removes local xpe dir
cmd_nuke() {
    debug "Remove all the xdpce containers"
    docker ps -a | awk '{ print $1,$2 }' | grep -w "$XCALAR_CONTAINER_NAME" | awk '{print $1 }' | xargs -I {} docker rm -f {} || true

    debug "remove all the xdpce images"
    docker images | awk '$1 ~ /^'$XCALAR_IMAGE'$/ { print $3}' | xargs -I {} docker rmi -f {} || true # not working w " " in the grep

    # grafana
    docker ps -a | awk '{ print $1,$2 }' | grep -w "$GRAFANA_CONTAINER_NAME" | awk '{print $1 }' | xargs -I {} docker rm -f {} || true
    docker images | awk '$1 ~ /^'$GRAFANA_IMAGE'$/ { print $3}' | xargs -I {} docker rmi -f {} || true

    if [ ! -z "$1" ]; then
        if [ -d "$APPDATA" ]; then
            rm -r "$APPDATA"
        fi
    fi
}

cmd_cleanup() {

    debug "Cleanup and remove staging dir"

    rm -r "$STAGING_DIR"
}

command="$1"
shift
cmd_${command} "$@"
