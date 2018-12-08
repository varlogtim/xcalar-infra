#!/bin/bash -x

DIR="$(cd "$(dirname "$BASH_SOURCE")" && pwd)"

if test -z "$XLRINFRADIR"; then
    export XLRINFRADIR="$(cd "$DIR"/.. && pwd)"
fi

export NETSTORE="${NETSTORE:-/netstore/qa/jenkins}"

RESULTS_PATH="${NETSTORE}/${JOB_NAME}/${BUILD_ID}"
mkdir -p "$RESULTS_PATH"

${XLRINFRADIR}/sqlrunner.sh -c "$JOB_NAME-$BUILD_ID" -I $INSTANCE_TYPE -n $NUM_INSTANCES -i "$INSTALLER_PATH" -N -r "$RESULTS_PATH" -- -w $SQL_NUM_USERS -t $SQL_TEST_GROUP $TEST_JDBC_OPTS
