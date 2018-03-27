#!/bin/bash

# INSTALL:
#        bash <script path>/local_installer.sh
#
# UNINSTALL:
#        (backs up and removes existing install directory and removes containers)
#        bash <script path>/local_installer.sh uninstall
#
# script should exist in the same dir as restar.tar.gz tarball
# (that tarball should contain the docker images, required install files,
# and default Xcalar mappings for xlr home, config, etc.)
#
# - You can generate the restar.tar.gz tarball by running Jenkins job:
#   XcalarPersonalEditionBuilder
# (the most recent copy of this script, will be included in dir created by the job)
#
# EFFECT OF RUNNING THIS SCRIPT:
#
# When you run this script in a dir with the restar.tar.gz tarball,
# any previous xdpce and grafana containers will be destroyed.
# it will create two docker containers (one for Grafana/graphite
# one for XEM cluster), and load the saved images for Grafana and XCE cluster
# included in the tarball, in to those containers.
# Grafana and XCE will be configured to communiicate automatically for stats collection.
#
# dirs on local filesystem are mapped in to the xdpce container
# to certain Xcalar directories (such as xcalar home, config, logs),
# running this installer if you already have XPE installed will 'upgrade' to latest Xcalar,
# but persist current session data
#
set -e

if ! docker run --rm hello-world | grep -q 'Hello from Docker'; then

    echo "

Please install Docker to use this program. https://www.docker.com/get-docker

" >&2
    exit 1
fi

XCALAR_IMAGE=xdpce
GRAFANA_IMAGE=grafana_graphite
XCALAR_CONTAINER_NAME=xdpce
GRAFANA_CONTAINER_NAME=grafana_graphite

clear_containers() {

    debug "Remove old docker containers..."
    remove_image $XCALAR_IMAGE
    remove_image $GRAFANA_IMAGE
    remove_container $XCALAR_CONTAINER_NAME
    remove_container $GRAFANA_CONTAINER_NAME
}

remove_image() {

    # must remove any containers hosting that image, too

    # stop any running containers before deleting them
    # ('docker ps' returns only running containers)
    debug "Stop any running containers hosting image $1..."
    docker ps | awk '{ print $1,$2 }' | grep $1 | awk '{print $1 }' | xargs -I {} docker stop {}

    # 'docker ps -a' returns all dockers containrers running or not...
    debug "Remove any stopped containers hosting image $1..."
    docker ps -a | awk '{ print $1,$2 }' | grep $1 | awk '{print $1 }' | xargs -I {} docker rm {}

    # remove the image, if it exists
    debug "Remove image of name $1..."
    docker ps -a | awk '{ print $1,$2 }' | grep $1 | awk '{print $1 }' | xargs -I {} docker rmi {}
}

remove_container() {

    # 'docker ps' returns only running containers
    debug "Stop any running containers by name $1..."
    if [ "$(docker ps -q -f name=$1)" ]; then
        debug "stopping $1..."
        docker stop $1
    fi
    # 'docker ps -a' will return all up and down; remove any
    debug "Remove any containers by name $1 ... "
    if [ "$(docker ps -a -q -f name=$1)" ]; then
        # get the image
        debug "removing container $1..."
        docker rm $1
    fi
}

# to make debug statements
#  debug "debug comment"
#  then run script as: `VERBOSE=1 ./local_installer.sh`
debug() {
    if [ "$VERBOSE" = 1 ]; then echo >&2 "debug: $@"; fi
}

            ## SETUP ##

# installer dirs created on the local machine
# (not the staging/tmp dir where install work is done,
# these should remain even after installation complete, as long as they want XPE)
XPEDIR="$HOME/xcalar_personal_edition"

XEM_PORT_NUMBER=15000 # should be port # in xemconfig
# files that will be required for completing the installation process
XDPCE_TARBALL=xdpce.tar.gz
GRAFANA_TARBALL=grafana_graphite.tar.gz
XEMCONFIGFILE=xem.cfg # going to create default.cfg from this
REQ_INSTALL_FILES=("$GRAFANA_TARBALL" "$XDPCE_TARBALL" "$XEMCONFIGFILE" "$VOLMNTS")

# create tmp staging dir for extracting the installation contents
# move the tarball there and extract it
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
STAGING_DIR=`mktemp -d 2>/dev/null || mktemp -d -t 'xpeinstaller'` # creates tmp dir on osx and linux
debug "Staging directory: $STAGING_DIR"
cd $STAGING_DIR

            ## UNINSTALL OPTION ##

# if user running this as an uninstall, back up contents before deleting the dir
if [ "$1" == uninstall ]; then

    if [ -d $XPEDIR ]; then
        BACKUPDIR="$HOME/xpe_backup_$(date +%F_%T)"
        mkdir -p $BACKUPDIR
        debug "Backup $XPEDIR to $BACKUPDIR then remove"
        cp -a "$XPEDIR/." "$BACKUPDIR"
        rm -r $XPEDIR
    fi

    clear_containers

    echo "XPE has been uninstalled.  A backup of previous install data found, can be found here $BACKUPDIR" >&2

    exit 0
fi

    ## CREATE INSTALLER DIRS, and UNPACK TAR FILE W REQUIRED FILES INTO INSTALLER DIR ##

# make the default user installation dirs
mkdir -p $XPEDIR

echo "Copy tar file.. (if over netstore could take some time...)" >&2
cp "$DIR/restar.tar.gz" .
tar -xzf restar.tar.gz

# all required files should be here now that untarred...
for reqfile in "${REQ_INSTALL_FILES[@]}"
do
    if [ ! -e $reqfile ]; then
        echo "Missing required file $reqfile (is it being packed in your tarball?)" >&2
        exit 1
    fi
done

    ## CONFIGURE default.cfg FOR XCALAR / GRAFANA COMMUNICATION

# base version of the file required to link Xcalar with Grafana is included in the installer (xem.cfg)
# append the user's IP hosting grafana, to it

debug "OS type: $OSTYPE"
if [ $OSTYPE == 'linux-gnu' ]; then
    hostip="$(ifconfig eth0 | grep "inet addr" | cut -d ':' -f 2 | cut -d ' ' -f 1)"
else
    hostip="$(ipconfig getifaddr en0)"
fi
debug "HOST IP: $hostip"

if [ ! -f $XEMCONFIGFILE ]; then
    echo "No xem config file $XEMCONFIGFILE (is it being packed in your tar?)" >&2
    exit 1
fi

REQVARS=(
    XemStatsPushHeartBeat=10000
    XemClusterName=xemmonitorcluster
    XemHostAddress=$hostip
    XemHostPortNumber=$XEM_PORT_NUMBER
    XemStatsShipmentEnabled=true
)
for extravar in "${REQVARS[@]}"
do
    echo "Constants.$extravar" >> "$STAGING_DIR/$XEMCONFIGFILE"
done
#echo "Constants.XemHostAddress=$hostip" >> "$STAGING_DIR/$XEMCONFIGFILE"

# copy to mount location for default.cfg, even on upgrade, in case ip has changed
cp "$XEMCONFIGFILE" "$HOME/xcalar_personal_edition/default.cfg"

    ## set up volume mounts for xdpce container ##

# when creating docker containers via docker run,
# will map in outside volumes with -v option
# while going through mount file, construct the arg string
# for each volume to map
MNTARGS=""

# for each path to mount:
# d|f (file or dir) <path on local file system> <destination path on xdpce container> <default content packaged in installer (if any)> 
mounts=(
    "d" "$XPEDIR/IMPORTS" "/mnt/imports2" ""
    "d" "$XPEDIR/XCE_HOME" "/var/opt/xcalar" "homecopy/"
    "d" "$XPEDIR/XCE_CONFIG" "/etc/xcalar" "configcopy/"
    "d" "$XPEDIR/XCE_LOGS" "/var/log/xcalar" ""
    "f" "$XPEDIR/xcalar" "/etc/default/xcalar" "xcalar"
    "f" "$XPEDIR/XcalarLic.key" "/etc/xcalar/XcalarLic.key" "XcalarLic.key"
    "f" "$XPEDIR/default.cfg" "/etc/xcalar/default.cfg" "default.cfg"
)

ITER=0
mtype=""
lpath=""
dpath=""
installerDefault=""
for item in "${mounts[@]}"
do
    ITER=$((ITER+1))
    if [ "$ITER" -gt "0" ] && [ $((ITER % 4)) -eq 0 ]; then
        mtype=${mounts[$((ITER-4))]}
        lpath=${mounts[$((ITER-3))]}
        dpath=${mounts[$((ITER-2))]}
        installerDefault=${mounts[$((ITER-1))]}
    else
        continue
    fi

    if [ ! -e "$lpath" ]; then

        if [ "$mtype" == "d" ]; then
            mkdir -p $lpath
        fi

        if [ -n "$installerDefault" ]; then
            if ! [ -e "$installerDefault" ]; then
                echo " $installerDefault specified as default for $dpath, but not in the installer dir. (is it being packed in your tar?)" >&2
                exit 1
            fi

            if [ "$mtype" == "d" ]; then
                cp -a "$installerDefault/." "$lpath"
            elif [ "$mtype" == "f" ]; then
                cp "$installerDefault" "$lpath"
            fi
        else
            if [ "$mtype" == "f" ]; then
                "Trying to map local file $lpath; can't find installer default and file doesn't exist on your computer..."
                exit 1
            fi
        fi
    fi

    MNTARGS="$MNTARGS -v $lpath:$dpath"
done

    ###  REMOVE OLD DOCKER GRAFANA AND XDPCE CONTAINERS AND INSTALLE NEW ONES ##

clear_containers

debug "load the packed images"
gzip -dc ${XCALAR_IMAGE}.tar.gz | docker load -q
gzip -dc ${GRAFANA_IMAGE}.tar.gz | docker load -q

# create the grafana container
run_cmd="docker run -d \
--restart unless-stopped \
-p 8082:80 \
-p 81:81 \
-p 8125:8125/udp \
-p 8126:8126 \
-p 2003:2003  \
--name $GRAFANA_CONTAINER_NAME \
$GRAFANA_IMAGE"
debug "Docker run cmd: $run_cmd"
$run_cmd

# create the xdpce container
run_cmd="docker run -d -t --user xcalar --cap-add=ALL --cap-drop=MKNOD \
--restart unless-stopped \
--security-opt seccomp:unconfined --ulimit core=0:0 \
--ulimit nofile=64960 --ulimit nproc=140960:140960 \
--ulimit memlock=-1:-1 --ulimit stack=-1:-1 --shm-size=10g \
--memory-swappiness=10 -e IN_DOCKER=1 \
-e XLRDIR=/opt/xcalar -e container=docker \
-v /var/run/docker.sock:/var/run/docker.sock \
-p $XEM_PORT_NUMBER:15000 \
--name $XCALAR_CONTAINER_NAME \
-p 8080:8080 -p 443:443 -p 5000:5000 \
-p 8443:8443 -p 9090:9090 -p 8889:8889 \
-p 12124:12124 -p 18552:18552 \
--link $GRAFANA_IMAGE:graphite $MNTARGS $XCALAR_IMAGE bash"
debug "Docker run cmd: $run_cmd"
$run_cmd
wait
# entrypoint for xcalar startup only hitting on container restart; start xcalar the initial time
docker exec -it --user xcalar $XCALAR_IMAGE /opt/xcalar/bin/xcalarctl start
# get admin login
debug "get admin credentials"
docker exec -it --user xcalar $XCALAR_IMAGE mkdir -p /var/opt/xcalar/config/ && curl -4 -H "Content-Type: application/json" -X POST -d "{ \"defaultAdminEnabled\": true, \"username\": \"admin\", \"email\": \"admin@xyz.com\", \"password\": \"admin\" }" "http://127.0.0.1:12124/login/defaultAdmin/set"

echo "

    Xcalar : http://$hostip:8080
    Grafana: http://$hostip:8082

    start a bash session:
        docker exec -it $XCALAR_IMAGE bash
        docker exec -it $GRAFANA_IMAGE bash

" >&2
