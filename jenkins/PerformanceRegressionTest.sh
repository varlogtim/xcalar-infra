#!/bin/bash -x

trap '(xclean; kill $(jobs -p)) || true' SIGINT SIGTERM EXIT

# build
cmBuild clean
cmBuild config prod
cmBuild qa

# Copy in the sqlite db file locally from netstore
# This is because the nfs file locking is flaky(seen that taking in minutes)
cp $PERFTEST_DB $XLRDIR/
export ExpServerd=false
python "$XLRDIR/src/bin/tests/perfTest/runPerf.py" -p "" -t "$XLRDIR/src/bin/tests/perfTest/perfTests" -r "$XLRDIR/perf.db" -s "`git rev-parse HEAD`"
ret="$?"

[ "$ret" = "0" ] || exit 1

python "$XLRDIR/src/bin/tests/perfTest/perfResults.py" -r "$XLRDIR/perf.db"
ret="$?"

[ "$ret" = "0" ] || exit 2

# Copy out the sqlite db file to netstore on success
cp $XLRDIR/perf.db $PERFTEST_DB

exit 0
