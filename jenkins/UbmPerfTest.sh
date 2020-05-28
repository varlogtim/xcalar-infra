#!/bin/bash -x
# Params:
#   DATA_SIZE - size of data loaded before running rest of the UBM operators

source $XLRDIR/doc/env/xc_aliases
export XLRGUIDIR="${XLRGUIDIR:-$XLRDIR/xcalar-gui}"
export XLRINFRADIR="${XLRINFRADIR:-$XLRDIR/xcalar-infra}"
export XCE_NEWCONFIG=/tmp/test_ubm_perf.cfg

export NETSTORE_JENKINS="${NETSTORE_JENKINS:-/netstore/qa/jenkins}"
RESULTS_PATH="${NETSTORE_JENKINS}/${JOB_NAME}/${BUILD_ID}"
mkdir -p "$RESULTS_PATH"

set +e

# Clean up existing running cluster if any
sudo pkill -9 usrnode || true
sudo pkill -9 childnode || true
sudo pkill -9 xcmonitor || true
sudo pkill -9 xcmgmtd || true
xclean

# build XCE now

echo "Building XCE"
cd $XLRDIR
cmBuild clean
cmBuild config prod
cmBuild xce

# Build xcalar-gui so that expServer will run
# export XLRGUIDIR=$PWD/xcalar-gui
echo "Building XD"
(cd $XLRGUIDIR && make trunk)

# then, launch 3-node cluster
# eventually, 'dcc' should be invoked (each node in its own  container)

# modify cluster config to accommodate large data sizes by letting XdbSerDesMaxDiskMB be
# unlimited (i.e. set to 0) since this will run on bare-metal labelled machines, with
# sufficient memory and swap (e.g. bare-metal machines node4,5.9 have 251GB RAM, 190G+
# swap) - without this, the test may fail with out of resources and disallow perf
# measurements for large data sizes

export XCE_CONFIG="${XCE_CONFIG:-$XLRDIR/src/data/test.cfg}"
sed 's/^[ \t]*Constants.XdbSerDesMaxDiskMB.*/Constants.XdbSerDesMaxDiskMB=0/' < "${XCE_CONFIG}" > "${XCE_NEWCONFIG}"
sedCode=$?
if [ $sedCode -ne 0 ]; then
    echo "failed to modify cluster config"
    exit $sedCode
fi
export XCE_CONFIG=$XCE_NEWCONFIG

# This is a perf eval test, so num-nodes=1 wouldn't be sufficient to cover
# the inter-node paths, and no point in having more than 2 nodes fighting
# for resources on the one-host multi-node cluster.
# XXX: Eventually, we should configure/allow multi-host clusters in the
# test automation infra
xc2 cluster start --num-nodes 2
exitCode=$?
if [ $exitCode -ne 0 ]; then
    echo "failed to start the cluster"
    exit $exitCode
fi

# 0. The --no-stats turns off fiber stats app launch and kill - which takes too
#    long and more importantly, isn't necessary
# 1. The --action=all cycles through all operators and reports timing for each
# 2. The iter-num is a placeholder for the scenario when this command is invoked
#    multiple times with the iter-num bumped each time to record results for
#    different iterations

exitCode=1
$XLRDIR/scripts/performance/operator_perf.py --action=all --no-stats --size=$DATA_SIZE --notes="jenkins run" --results-output-dir=$RESULTS_PATH --iter-num=0
exitCode=$?

xc2 cluster stop

exit $exitCode
