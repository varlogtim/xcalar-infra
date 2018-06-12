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
IMGID_FILE="$SCRIPT_DIR/../../../Data/.imgid"
XCALAR_IMAGE_REPO=xdpce
GRAFANA_IMAGE_REPO=grafana_graphite
XCALAR_CONTAINER=xdpce
GRAFANA_CONTAINER=grafana_graphite
# installer dirs created on the local machine
# these should remain even after installation complete, as long as they want XPE)
APPDATA="$HOME/Library/Application Support/Xcalar Design"
XPEDATA="$APPDATA/.sessions" # want data in here hidden in mac Finder
LOCALLOGDIR="$XPEDATA/Xcalar Logs" # will mount to /var/log/xcalar so logs persist through upgrades
LOCALXCEHOME="$XPEDATA/Xcalar Home" # will mount to XCALAR_ROOT so session data, etc. persissts through upgrde
XCALAR_ROOT="/var/opt/xcalar"
LIC_FILENAME=XcalarLic.key # name of file of uncompressed license
XCALAR_LIC_REL="xpeinstalledlic" # dir rel to XCALAR_ROOT where lic file will go
LOCALDATASETS="$APPDATA/sampleDatasets"

MAINHOSTMNT=/host # path in the Xcalar Docker container to mount user's $HOME dir to
# will set as Xcalar's Default Data Target path (it must be a path in the container where Xcalar running)
# this way when user opens file browser they will see contents of their $HOME dir (else will be default container root which won't make sense to user)

XEM_PORT_NUMBER=15000 # should be port # in xemconfig
# files that will be required for completing the installation process
XDPCE_TARBALL=xdpce.tar.gz
GRAFANA_TARBALL=grafana_graphite.tar.gz

# clear current container
# if user has changed its name; won't be removing that
# remove the latest images.
cmd_clear_containers() {
    cmd_ensure_docker_up
    debug "Remove old docker containers..."
    docker rm -fv $XCALAR_CONTAINER >/dev/null 2>&1 || true
    # only remove grafana container if you're going to install it
    if [ ! -z "$INSTALL_GRAFANA" ]; then
        docker rm -fv "$GRAFANA_CONTAINER" >/dev/null 2>&1 || true
    fi
}

cmd_cleanly_delete_image() {

    if [[ -z "$1" ]]; then
        echo "No image ID supplied to cleanly_delete_image. you must supply an image ID to remove!" >&2
        exit 1
    fi

    cmd_ensure_docker_up

    # remove any containers (running or not) hosting this image
    docker ps -a -q --filter ancestor="$1" --format="{{.ID}}" | xargs -I {} docker rm -fv {}
    # now remove the image itself
    docker rmi -f "$1"

}

cmd_setup () {

    local cwd=$(pwd)

    debug "Create install dirs and unpack tar file for install"

    ## CREATE INSTALLER DIRS, move required files to final dest ##
    if [ -e "$STAGING_DIR" ]; then
        debug "staging dir exists already $STAGING_DIR"
        rm -r "$STAGING_DIR"
    fi
    mkdir -p "$STAGING_DIR"
    cd "$STAGING_DIR"

    # copy installer tarball to the staging dir and extract it there
    cp "$SCRIPT_DIR/installertarball.tar.gz" "$STAGING_DIR"
    tar xzf installertarball.tar.gz

    if [ -e ".caddyport" ]; then
        CADDY_PORT=$(cat .caddyport)
    fi

    mkdir -p "$LOCALXCEHOME/config"
    mkdir -p "$LOCALXCEHOME/$XCALAR_LIC_REL"
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

cmd_load_packed_images() {
    cmd_ensure_docker_up

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
    # if grafana supposed to be installed, make sure grafana tarball is here
    # else fail early
    if [ ! -z "$INSTALL_GRAFANA" ]; then
        if [ -e "$GRAFANA_TARBALL" ]; then
            gzip -dc "$GRAFANA_TARBALL" | docker load -q
        else
            echo "This build marked for Grafana install, but no Grafana image tar was included!" >&2
            exit 1
        fi
    fi

    cd "$cwd"

}

cmd_create_grafana() {
    cmd_ensure_docker_up

    debug "Create grafana container"

    # create the grafana container
    docker run -d \
    --restart unless-stopped \
    -p 8082:80 \
    -p 81:81 \
    -p 8125:8125/udp \
    -p 8126:8126 \
    -p 2003:2003  \
    --name "$GRAFANA_CONTAINER" \
    "$GRAFANA_IMAGE_REPO:latest"
}

# create xdpce container
#    1st arg: image to use (Defaults to xdpce:latest)
#   2nd arg: ram (int in gb)
#    3rd arg: num cores
cmd_create_xdpce() {
    cmd_ensure_docker_up

    debug "create xcalar container"

    local container_image="${1:-$XCALAR_IMAGE_REPO:latest}"
    local extraArgs=""
    if [[ ! -z "$2" ]]; then
        extraArgs="$extraArgs --memory=${2}g"
    fi
    if [[ ! -z "$3" ]]; then
        extraArgs="$extraArgs --cpus=${3}"
    fi
    # if there is grafana container hook it to it as additional arg
    # only do if set to install, in case they've an old grafana container
    # but this install is not including grafana
    if [ ! -z "$INSTALL_GRAFANA" ]; then
        if docker container inspect "$GRAFANA_CONTAINER" >/dev/null 2>&1; then
            # the link to Grafana breaks if you specify the container name as --link instead of this
            extraArgs="$extraArgs --link $GRAFANA_IMAGE_REPO:graphite"
        fi
    fi

    # create license file and add env var to let Xcalar know where it is
    if [[ ! -z "$4" ]]; then
        echo "$4" > "$LOCALXCEHOME/$XCALAR_LIC_REL/$LIC_FILENAME"
        extraArgs="$extraArgs -e XCE_LICENSEFILE=$XCALAR_ROOT/$XCALAR_LIC_REL/$LIC_FILENAME"
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
    -e XCE_CUSTOM_DEFAULT_DATA_TARGET_PATH="$MAINHOSTMNT" \
    -v "$LOCALXCEHOME":"$XCALAR_ROOT" \
    -v "$LOCALLOGDIR":/var/log/xcalar \
    -p $XEM_PORT_NUMBER:15000 \
    --name "$XCALAR_CONTAINER" \
    -p 8818:"${CADDY_PORT:-443}" \
    $extraArgs $MNTARGS "$container_image" bash
}

cmd_start_xcalar() {
    cmd_ensure_docker_up

    debug "Start xcalar service inside the docker"
    # entrypoint for xcalar startup only hitting on container restart; start xcalar the initial time
    docker exec --user xcalar "$XCALAR_CONTAINER" /opt/xcalar/bin/xcalarctl start
}

cmd_stop_xcalar() {
    cmd_ensure_docker_up

    debug "Stop xcalar service inside the docker"
    # entrypoint for xcalar startup only hitting on container restart; start xcalar the initial time
    docker exec --user xcalar "$XCALAR_CONTAINER" /opt/xcalar/bin/xcalarctl stop
}

cmd_verify_install() {
    cmd_ensure_docker_up
    local appImgSha
    if [ ! -f "$IMGID_FILE" ]; then
        echo "Can not find image sha file to compare against for verification! (Looking at: $IMGID_FILE)" >&2
        exit 1
    else
        appImgSha=$(cat "$IMGID_FILE")
    fi
    local userlatest
    if ! userlatest=$(docker image inspect "$XCALAR_IMAGE_REPO":latest -f '{{ .Id }}'); then
       echo "No image sha found for latest $XCALAR_IMAGE_REPO:latest!  Install was not successful!" >&2
       exit 1
    fi
    if [ "$userlatest" != "$appImgSha" ]; then
       echo "Latest image of Xcalar is not image associated with this app" >&2
       exit 1
    fi
}

cmd_cleanup() {
    debug "Cleanup and remove staging dir"
    rm -r "$STAGING_DIR"
}

# revert_xdpce <img id> to revert to
cmd_revert_xdpce() {
    cmd_ensure_docker_up

    local revert_img_id="$1" # new img id or sha
    if [[ -z "${revert_img_id// }" ]]; then  # checks only whitespace chars
        echo "you must supply a value to revert image id!" >&2
        exit 1
    fi

    # check if xdpce container exists in expected name
    if docker container inspect "$XCALAR_CONTAINER"; then
        # get SHA of image hosted by current xdpce container, if any
        local curr_img_sha=$(docker container inspect --format='{{.Image}}' "$XCALAR_CONTAINER")

        # compares sha to check if already hosting the requested img
        local revert_img_sha=$(docker image inspect --format='{{.Id}}' "$revert_img_id")

        if [[ "$curr_img_sha" == $revert_img_sha ]]; then
            debug "$revert_img_id already hosted by $XCALAR_CONTAINER - revert is unecessary!"
            exit 0
        fi

        # delete the container
        docker rm -fv "$XCALAR_CONTAINER"
    else
        debug "there is NOT a $XCALAR_CONTAINER container"
    fi

    # now call to create the new container
    cmd_create_xdpce "$revert_img_id"
}

cmd_remove_containers() {
    if [ -z "$1" ]; then
        echo "You must supply a container to remove" >&2
        exit 1
    fi
    local containerId="$1"
    docker ps -a | awk '{ print $1,$2 }' | grep -w "$containerId" | awk '{print $1 }' | xargs -I {} docker rm -fv {} || true
}

cmd_remove_images() {
    if [ -z "$1" ]; then
        echo "You must supply an image to remove" >&2
        exit 1
    fi
    local imageId="$1"
    docker images | awk '$1 ~ /^'$imageId'$/ { print $3}' | xargs -I {} docker rmi -f {} || true # not working w " " in the grep
}

# nuke all the xdpce containers and images; optional $1 removes local xpe dir
cmd_nuke() {
    cmd_ensure_docker_up

    debug "Remove all the xdpce containers and images"
    cmd_remove_containers "$XCALAR_CONTAINER"
    cmd_remove_images "$XCALAR_IMAGE_REPO"

    debug "Remove all grafana containers and images"
    cmd_remove_containers "$GRAFANA_CONTAINER"
    cmd_remove_images "$GRAFANA_IMAGE_REPO"

    if [ ! -z "$1" ]; then
        debug "Remove all app data (specified full uninstall)"
        if [ -d "$APPDATA" ]; then
            rm -r "$APPDATA"
        fi
    fi
}

docker_up() {
    docker version >/dev/null 2>&1
}

docker_installed() {
    command -v docker >/dev/null 2>&1
}

# DOCKER UTILS # ##TODO: move in to own util file;
# and the installer functions above in their own file?

# optional arg 1: if true, do not start Docker daemon, just wait for it to come up
# optional arg 2: seconds to wait before timing out waiting for Docker to come up
cmd_ensure_docker_up() {
    local dontStartDocker="${1:-false}"
    if ! docker_up; then
        if [ "$dontStartDocker" != true ]; then
            cmd_docker_start
        fi
        cmd_docker_wait "$2"
    fi
}

# starts docker and waits to come up, unless env variable
# NODOCKERSTART is set
cmd_docker_start() {
    if [ ! -z "$NODOCKERSTART" ]; then
        echo "Will not start Docker - NODOCKERSTART env variable detected" >&2
    else
        open -a Docker.app
    fi
}

# optional arg: number of seconds to wait before timing out waiting for Docker to come up
cmd_docker_wait() {
    local timeout="${1:-120}"
    local remainingTime=$timeout
    local pauseTime=1
    until docker_up || [ "$remainingTime" -eq "0" ]; do
        debug "docker daemon not avaiable yet $remainingTime"
        sleep "$pauseTime"
        remainingTime=$((remainingTime - pauseTime))
    done

    if ! docker_up; then
        # timed out waiting for daemon to come up
        echo "Timed out after waiting $timeout seconds for Docker daemon to come up!" >&2
        exit 1
    fi
}

cmd_bring_up_containers() {
    cmd_ensure_docker_up
    docker start "$XCALAR_CONTAINER"
    docker start "$GRAFANA_CONTAINER" || true
}

command="$1"
shift
cmd_${command} "$@"
