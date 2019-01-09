# automates environment setup required so ovirt_docker_wrapper can be run
# Setup: http://wiki.int.xcalar.com/mediawiki/index.php/Ovirttool#Setup
: "${XLRDIR:?Need to set non-empty XLRDIR}"
if [ -z "$XLRINFRADIR" ]; then
    export XLRINFRADIR="$(cd $SCRIPTDIR/.. && pwd)"
fi

# ovirt_docker_wrapper will create a ub14 Docker container and run ovirttool in it;
# setup so ub14 Docker containers can be built
cd "$XLRDIR/docker/ub14" && make
