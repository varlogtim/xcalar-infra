#!/bin/bash
export XLRINFRADIR=$PWD
export PATH=$XLRINFRADIR/bin:$PATH

FILES="$(bin/git-changed-files.sh)"
$XLRINFRADIR/bin/check.sh $FILES
exit $?
