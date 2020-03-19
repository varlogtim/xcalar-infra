#!/bin/bash -x

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

export XLRGUIDIR="${XLRGUIDIR:-$XLRDIR/xcalar-gui}"
export NETSTORE="${NETSTORE:-/netstore/qa/jenkins}"
export RUN_COVERAGE="${RUN_COVERAGE:-false}"
export PERSIST_COVERAGE_ROOT="${PERSIST_COVERAGE_ROOT:-/netstore/qa/coverage}"

RESULTS_PATH="${NETSTORE}/${JOB_NAME}/${BUILD_ID}"
mkdir -p "$RESULTS_PATH"

set +e

CLUSTERNAME="${JOB_NAME}-${BUILD_ID}"
CLUSTERNAME="${CLUSTERNAME,,}"
VmProvider=${VmProvider:-GCE}

onExit() {
    exitCode=$1
    # Mask anything that could interrupt us
    trap '' HUP QUIT INT TERM
    if [ -n "$CLUSTERNAME" ]; then
        case "$VmProvider" in
            GCE)  ${XLRINFRADIR}/gce/gce-cluster-delete.sh --all-disks "$CLUSTERNAME";;
        esac
    fi
    # Remove all handlers so we can exit without this being called again
    trap - EXIT HUP QUIT INT TERM
    exit $exitCode
}

trap 'onExit $?' EXIT HUP QUIT INT TERM

export IMAGE=${IMAGE:-centos-7}
${XLRINFRADIR}/bin/sqlrunner.sh -c "$CLUSTERNAME" -I $INSTANCE_TYPE -n $NUM_INSTANCES \
    -i "$INSTALLER_PATH" -N -r "$RESULTS_PATH" $SQL_RUNNER_OPTS -- -w $SQL_NUM_USERS -t $SQL_TEST_GROUP $TEST_JDBC_OPTS
onExit $?
