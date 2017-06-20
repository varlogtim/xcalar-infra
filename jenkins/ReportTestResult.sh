#!/bin/bash

XLRDIR=`pwd`
PATH="$PATH:$XLRDIR/bin"
bin/qa/parseJenkinsConsole.sh "$jenkinsLogUrl" "$dburl" "$dbuser" "$dbpass" "$gitCommitTested"
