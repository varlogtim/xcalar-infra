#!/bin/bash -x

sudo pkill -9 gdbserver || true
sudo pkill -9 usrnode || true
sudo pkill -9 childnode || true
sudo pkill -9 xcmonitor || true
sudo pkill -9 xcmgmtd || true

# build
cmBuild clean
cmBuild config prod
cmBuild qa

installerPath="$(readlink -f $INSTALLER_PATH)"

# This extracts the SHA from the installer name
# xcalar-0.9.10.10-3.2de1db29-installer
# The stuff before '\K' is cut off and we are left with
# 2de1db29-installer
# Then the '(?=)' bit makes it cut off the installer part,
# so only the SHA is captured in '()', and grep -o makes it return the capture
sha=`echo $installerPath | awk -F '/' '{print $(NF-2)}' | awk -F '-' '{print $NF}'`

# Copy in the sqlite db file locally from netstore
# This is because the nfs file locking is flaky(seen that taking in minutes)
cp $PERFTEST_DB $XLRDIR/
export ExpServerd=false
python "$XLRDIR/src/bin/tests/perfTest/runPerf.py" -p "$installerPath" -t "$XLRDIR/src/bin/tests/perfTest/perfTests" -r "$XLRDIR/perf.db" -s "$sha"
ret="$?"

[ "$ret" = "0" ] || exit 1

python "$XLRDIR/src/bin/tests/perfTest/perfResults.py" -r "$XLRDIR/perf.db"
ret="$?"

[ "$ret" = "0" ] || exit 2

# Copy out the sqlite db file to netstore on success
cp $XLRDIR/perf.db $PERFTEST_DB

exit 0
