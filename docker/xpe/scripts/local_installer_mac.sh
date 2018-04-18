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
    docker rm -f $XCALAR_CONTAINER_NAME >/dev/null 2>&1 || true
    docker rm -f $GRAFANA_CONTAINER_NAME >/dev/null 2>&1 || true
    debug "rmi xdpce:latest and grafana-graphite:latest"
    docker rmi -f $XCALAR_IMAGE || true
	docker rmi -f $GRAFANA_IMAGE || true
}

setup () {
    ## CREATE INSTALLER DIRS, move required files to final dest ##
	if [ -e "$STAGING_DIR" ]; then
		echo "staging dir exists already $STAGING_DIR"
		rm -r "$STAGING_DIR"
	fi
	mkdir -p "$STAGING_DIR"
	cd "$STAGING_DIR"

	# copy installer tarball to the staging dir and extract it there
	cp "$SCRIPT_DIR/installertarball.tar.gz" "$STAGING_DIR"
	tar xvzf installertarball.tar.gz

	mkdir -p "$LOCALXCEHOME/config"
	mkdir -p "$LOCALLOGDIR"
	mkdir -p "$LOCALDATASETS"

	echo cp -R .ipython .jupyter jupyterNotebooks "$LOCALXCEHOME"
	cp -R .ipython .jupyter jupyterNotebooks "$LOCALXCEHOME" # put these here in case of initial install, need them in xce home
	cp defaultAdmin.json "$LOCALXCEHOME/config"
	# untar the datasets and copy those in
	# do this from the staging dir.
	# because tarred dir and dirname in XPEDIR are same
	# and don't want to overwrite the dir in XPEDIR if it's there,
	# in case we've taken out sample datasets in a new build.
	# instead extract in staging area then copy all the contents over.
	# this way they get new datasets, updated existing ones, and keep their old ones
	tar xvzf sampleDatasets.tar.gz
	cp -a sampleDatasets/. "$LOCALDATASETS/"
	rm sampleDatasets.tar.gz
}

load_packed_images() {
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

}

create_grafana() {	

	echo "in create grafana"
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
	echo "$run_cmd"
	$run_cmd
}

create_xdpce() {

	ram="$1"g;
	cores="$2";
	# create the xdpce container
	run_cmd="docker run -d -t --user xcalar --cap-add=ALL --cap-drop=MKNOD \
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
	-p 8080:8080 -p 443:443 -p 5000:5000 -p 8443:8443 \
	-p 9090:9090 -p 8889:8889 \
	-p 12124:12124 -p 18552:18552 \
	--link $GRAFANA_IMAGE:graphite $MNTARGS $XCALAR_IMAGE bash"
	debug "Docker run cmd: $run_cmd"
	echo "$run_cmd"
	$run_cmd
	wait
}

start_xcalar() {
	# entrypoint for xcalar startup only hitting on container restart; start xcalar the initial time
	echo "go in to the xdpce container and come out ok!"
	cmd="docker exec --user xcalar $XCALAR_CONTAINER_NAME /opt/xcalar/bin/xcalarctl start"
	echo "$cmd"
	$cmd


	# now set up the data target
	echo "setup a default datatarget based on their home dir"
	targetname="$HOME"
	cmd="docker exec --user xcalar $XCALAR_CONTAINER_NAME /opt/xcalar/bin/python3.6 /tmp/setupTarget.py $targetname $MAINHOSTMNT"
	echo "$cmd"
	$cmd
}


cleanup() {
	echo "remove staging dir and tarball"
	rm -r "$STAGING_DIR"
}

"$@"
