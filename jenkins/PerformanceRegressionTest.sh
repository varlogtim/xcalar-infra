#!/bin/bash

export XLRDIR=`pwd`
export PATH="$XLRDIR/bin:$PATH"

# We need the cli, so lets build it
build clean
build config
build

installerPath="$(readlink -f $INSTALLER_PATH)"

# This extracts the SHA from the installer name
# xcalar-0.9.10.10-3.2de1db29-installer
# The stuff before '\K' is cut off and we are left with
# 2de1db29-installer
# Then the '(?=)' bit makes it cut off the installer part,
# so only the SHA is captured in '()', and grep -o makes it return the capture
sha=$(basename $installerPath | grep -oP "xcalar-.*\.\K([a-f0-9]*)(?=-installer)")

python "$XLRDIR/src/bin/tests/perfTest/runPerf.py" -p "$installerPath" -t "$XLRDIR/src/bin/tests/perfTest/perfTests" -r "$PERFTEST_DB" -s "$sha" --remote
ret="$?"

[ "$ret" = "0" ] || exit 1

python "$XLRDIR/src/bin/tests/perfTest/perfResults.py" -r "$PERFTEST_DB"
ret="$?"

[ "$ret" = "0" ] || exit 2

exit 0
