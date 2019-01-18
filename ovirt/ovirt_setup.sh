#!/bin/bash
# automates setup required for ovirt_docker_wrapper to run
# http://wiki.int.xcalar.com/mediawiki/index.php/Ovirttool#Setup

: "${XLRDIR:?Need to set non-empty XLRDIR}"
if [ -z "$XLRINFRADIR" ]; then
    export XLRINFRADIR="$(cd $SCRIPTDIR/.. && pwd)"
fi

set -e
# ovirt_docker_wrapper will create a ub14 Docker container and run ovirttool in it;
# setup so ub14 Docker containers can be built
if ! docker pull registry.int.xcalar.com/xcalar/ub14-build:ovirttool; then
    cd "$XLRDIR/docker/ub14"
    echo "export http_proxy:=${http_proxy:-http://cacher:3128}" > local.mk
    make ub14-build
else
    docker tag registry.int.xcalar.com/xcalar/ub14-build:ovirttool ub14-build:latest
fi
