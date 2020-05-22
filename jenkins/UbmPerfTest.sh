#!/bin/bash -x

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if test -z "$XLRINFRADIR"; then
	export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

export NETSTORE_JENKINS="${NETSTORE_JENKINS:-/netstore/qa/jenkins}"
RESULTS_PATH="${NETSTORE_JENKINS}/${JOB_NAME}/${BUILD_ID}"
mkdir -p "$RESULTS_PATH"

set +e

# launch 3-node cluster
# eventually, 'dcc' should be invoked (each node in its own  container)

export XCE_CONFIG="${XCE_CONFIG:-$XLRDIR/src/data/test.cfg}"
xc2 cluster start --num-nodes 3
exitCode=$?
if [ $exitCode -ne 0 ]; then
    echo "failed to start the cluster"
    exit $exitCode
fi

# XXX: change size from 1MB to something larger when going into production

# The --no-stats turns off fiber stats app launch and kill - which takes too
# long and more importantly, isn't necessary

# The --action=all cycles through all operators and reports timing for each

# The iter-num is a placeholder for the scenario when this command is invoked
# multiple times with the iter-num bumped each time to record results for
# different iterations

exitCode=1
$XLRDIR/scripts/performance/operator_perf.py --action=all --no-stats --size=1MB --notes="jenkins run" --results-output-dir=$RESULTS_PATH --iter-num=0
exitCode=$?

xc2 cluster stop

exit $exitCode
