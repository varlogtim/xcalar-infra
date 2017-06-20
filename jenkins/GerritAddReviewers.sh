#!/bin/bash

export XLRDIR=$PWD
export PATH=$XLRDIR/bin:$PATH

bash -e bin/gerrit-reviewers.sh
